import AVFoundation
import CallKit
import Flutter
import ImageIO
import JavaScriptCore
import PDFKit
import Security
import UIKit
import UniformTypeIdentifiers
import Vision

/// Shared settings between the app and its extensions (Message Filter, Call Directory).
/// The extensions only READ these; Apple doesn't let the Message Filter write anything back.
enum SLShared {
    static let group = "group.com.secondlook.shared"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }
    static var callDirectoryId: String { (Bundle.main.bundleIdentifier ?? "com.secondlook.secondLook") + ".CallDirectory" }
    /// Numbers many Second Look users reported, downloaded from our server for the Call Directory to block and label.
    static var communityFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("community.json")
    }
}

/// Runs the Second Look engine (the same JavaScript used on the web) inside JavaScriptCore. Fully offline.
final class SLEngine {
    static let shared = SLEngine()
    private let queue = DispatchQueue(label: "secondlook.engine")
    private var context: JSContext?

    private func load() -> JSContext? {
        if let c = context { return c }
        let bundles = [Bundle(for: SecondLookPlugin.self), Bundle.main]
        guard let url = bundles.compactMap({ $0.url(forResource: "secondlook_engine", withExtension: "js") }).first,
              let src = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, err in NSLog("Second Look engine error: \(String(describing: err))") }
        ctx.evaluateScript(src)
        context = ctx
        return ctx
    }

    func call(_ fn: String, _ args: [Any], done: @escaping (String?) -> Void) {
        queue.async {
            let out = self.load()?.objectForKeyedSubscript("SL")?.invokeMethod(fn, withArguments: args)?.toString()
            DispatchQueue.main.async { done(out) }
        }
    }
}

/// Reads the words in a screenshot and decodes its QR codes with Apple's Vision framework. Fully on the iPhone.
enum SLImageReader {
    static let maxSide = 2500
    static let maxText = 10000
    static let maxQr = 5
    static let maxQrLen = 2048
    /// Layout (document) mode: Aadhaar's secure QR is a long decimal number, so allow much longer QR values.
    static let maxQrLenDoc = 16384
    static let maxFileBytes = 30 * 1024 * 1024
    private static let queue = DispatchQueue(label: "secondlook.vision", qos: .userInitiated)

    /// Only files whose real location is inside this app's tmp, Caches or Documents folder (image_picker copies
    /// picked photos into tmp). Symlinks and "../" are resolved first, so they can't escape.
    static func allowedURL(_ path: String) -> URL? {
        guard !path.isEmpty, path.count < 4096, !path.contains("\0") else { return nil }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let p = url.path
        var roots = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]
        roots += fm.urls(for: .cachesDirectory, in: .userDomainMask)
        roots += fm.urls(for: .documentDirectory, in: .userDomainMask)
        for root in roots {
            var r = root.standardizedFileURL.resolvingSymlinksInPath().path
            if !r.hasSuffix("/") { r += "/" }
            guard r.count > 1, p.hasPrefix(r) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
                  let size = (try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= maxFileBytes else { return nil }
            return url
        }
        return nil
    }

    /// Calls done on the main thread with the JSON string, or a FlutterError.
    /// layout: true rebuilds the text in reading rows (tables such as bank statements stay row by row).
    static func read(path: String, layout: Bool = false, done: @escaping (Any?) -> Void) {
        queue.async {
            let out: Any? = autoreleasepool { () -> Any? in
                guard let url = SLImageReader.allowedURL(path) else {
                    return FlutterError(code: "blocked", message: "This image can't be opened", details: nil)
                }
                if let json = SLImageReader.scan(url, layout: layout) { return json }
                return FlutterError(code: "image", message: "Couldn't read this image", details: nil)
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    private static func scan(_ url: URL, layout: Bool) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 && orientation <= 8 { swap(&w, &h) } // rotated 90°: report the upright size
        let longest = max(w, h)
        // Decodes straight to a downscaled, upright image (never the full-size bitmap).
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest > 0 ? min(longest, maxSide) : maxSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if w <= 0 || h <= 0 { w = cg.width; h = cg.height }

        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = false
        textReq.recognitionLanguages = ["en-US"]
        let qrReq = VNDetectBarcodesRequest()
        qrReq.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([textReq, qrReq]) } catch { return nil }

        var text: String
        if layout {
            text = SLTextRows.build(SLTextRows.lines(textReq.results ?? [], width: CGFloat(cg.width), height: CGFloat(cg.height)))
        } else {
            text = (textReq.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        if text.count > maxText { text = String(text.prefix(maxText)) }
        let qrCap = layout ? maxQrLenDoc : maxQrLen
        var qr: [String] = []
        for o in qrReq.results ?? [] {
            if qr.count >= maxQr { break }
            guard var v = o.payloadStringValue, !v.isEmpty else { continue }
            if v.count > qrCap { v = String(v.prefix(qrCap)) }
            if !qr.contains(v) { qr.append(v) }
        }
        var geometry = SLLayout.Acc()
        geometry.add(textReq.results ?? [], width: CGFloat(cg.width), height: CGFloat(cg.height))
        let o: [String: Any] = ["text": text, "qr": qr, "width": w, "height": h, "layout": geometry.json(checked: true)]
        guard let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}

/// Rebuilds OCR text in reading rows. Plain OCR output often comes out column by column, which breaks tables such as
/// bank statements. Every recognised line keeps its box; lines whose vertical centres are within 0.6 × the median line
/// height form one row, each row is ordered left to right and joined with two spaces, and rows are joined with "\n".
/// Same algorithm as Android's TextRows.java.
enum SLTextRows {
    /// One recognised line; rect is in image pixels with a TOP-left origin.
    struct Line {
        let text: String
        let rect: CGRect
    }

    /// Vision observations → lines in top-left pixel coordinates (Vision boxes are normalised, bottom-left origin).
    static func lines(_ observations: [VNRecognizedTextObservation], width: CGFloat, height: CGFloat) -> [Line] {
        return observations.compactMap { o -> Line? in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            let bb = o.boundingBox
            return Line(text: s, rect: CGRect(x: bb.minX * width, y: (1 - bb.maxY) * height,
                                              width: bb.width * width, height: bb.height * height))
        }
    }

    static func build(_ input: [Line]) -> String {
        let lines = input.compactMap { l -> Line? in
            let t = l.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Line(text: t, rect: l.rect.standardized)
        }
        guard !lines.isEmpty else { return "" }
        let heights = lines.map { max(0, $0.rect.height) }.sorted()
        var median = heights[heights.count / 2]
        if median <= 0 { median = 1 }
        let threshold = 0.6 * median
        let sorted = lines.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[Line]] = []
        var centre: CGFloat = 0
        for l in sorted {
            let cy = l.rect.midY
            if !rows.isEmpty, abs(cy - centre) <= threshold {
                rows[rows.count - 1].append(l)
                centre += (cy - centre) / CGFloat(rows[rows.count - 1].count) // running mean of the row's centres
            } else {
                rows.append([l])
                centre = cy
            }
        }
        return rows.map { row -> String in
            row.sorted { a, b in a.rect.minX != b.rect.minX ? a.rect.minX < b.rect.minX : a.text < b.text }
                .map { $0.text }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

/// Text-geometry check from OCR word boxes (same rule as Android): in lines with at least 3 words, a word (2+
/// characters, containing a letter or digit) is "odd" when its box height differs by more than 30% from the line's
/// median word height, or its bottom edge is off the line's median bottom by more than 35% of that height. Pasted-in
/// digits or names often sit slightly off the line they were edited into.
enum SLLayout {
    static let maxSamples = 5

    struct Acc {
        var lines = 0
        var odd = 0
        var samples: [String] = []

        /// Adds every recognised line of one image (Vision boxes are normalised with a bottom-left origin).
        mutating func add(_ observations: [VNRecognizedTextObservation], width: CGFloat, height: CGFloat) {
            for o in observations {
                guard let cand = o.topCandidates(1).first else { continue }
                let s = cand.string
                // Each word's box: (text, height, bottom edge) in top-left pixel coordinates.
                var words: [(String, CGFloat, CGFloat)] = []
                var i = s.startIndex
                while i < s.endIndex {
                    if s[i].isWhitespace { i = s.index(after: i); continue }
                    var j = i
                    while j < s.endIndex && !s[j].isWhitespace { j = s.index(after: j) }
                    if let box = try? cand.boundingBox(for: i..<j) {
                        let bb = box.boundingBox
                        words.append((String(s[i..<j]), bb.height * height, (1 - bb.minY) * height))
                    }
                    i = j
                }
                guard words.count >= 3 else { continue }
                lines += 1
                let hs = words.map { $0.1 }.sorted()
                let bs = words.map { $0.2 }.sorted()
                let medH = hs[hs.count / 2]
                let medB = bs[bs.count / 2]
                guard medH > 0 else { continue }
                for (w, h, b) in words {
                    guard w.count >= 2, w.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    if abs(h - medH) > 0.30 * medH || abs(b - medB) > 0.35 * medH {
                        odd += 1
                        if samples.count < SLLayout.maxSamples { samples.append(SLLayout.mask(String(w.prefix(40)))) }
                    }
                }
            }
        }

        func json(checked: Bool) -> [String: Any] {
            ["checked": checked && lines > 0, "lines": lines, "odd": odd, "samples": samples]
        }
    }

    static let notChecked: [String: Any] = ["checked": false, "lines": 0, "odd": 0, "samples": [String]()]

    /// In any run of 8+ digits, every digit except the last 4 becomes "X".
    static func mask(_ w: String) -> String {
        var out = ""
        var run = ""
        func flush() {
            if run.count >= 8 { out += String(repeating: "X", count: run.count - 4) + run.suffix(4) } else { out += run }
            run = ""
        }
        for ch in w {
            if ch.isASCII && ch.isNumber { run.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }
}

/// "Check a document": the picked PDF or photo is copied into tmp/docs/, read on the iPhone (PDFKit, Vision) and
/// deleted when the user leaves the screen. Nothing is uploaded, stored or logged.
enum SLDocs {
    static let maxBytes = 25 * 1024 * 1024
    static let maxText = 50000
    static let maxTextPages = 20
    static let maxOcrPages = 6
    static let pdfSide: CGFloat = 2000
    static let maxInputBytes = 1_000_000
    static let maxCerts = 8
    static let maxCertBytes = 64 * 1024
    static let maxSignedBytes = 1024 * 1024
    static let maxSignatureBytes = 2048
    private static let queue = DispatchQueue(label: "secondlook.docs", qos: .userInitiated)

    static var dir: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("docs", isDirectory: true) }

    static func fail(_ code: String) -> FlutterError {
        let message: String
        switch code {
        case "too_large": message = "This file is bigger than 25 MB. Choose a smaller file or a photo of the page."
        case "unsupported": message = "Choose a PDF or a photo of the document."
        case "locked": message = "This PDF is protected with a password. Open it, save a copy without the password, and try again."
        default: message = "Couldn't open this file. It may be damaged."
        }
        return FlutterError(code: code, message: message, details: nil)
    }

    /// Deletes every copied document.
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }

    private static func json(_ o: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// The file's name for display only: control and bidi-override characters and path separators removed.
    static func cleanName(_ n: String) -> String {
        var out = String.UnicodeScalarView()
        for u in n.unicodeScalars {
            let v = u.value
            if v < 0x20 || v == 0x7f || u == "/" || u == "\\" { continue }
            if (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200e || v == 0x200f { continue }
            out.append(u)
        }
        let t = String(String(out).trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return t.isEmpty ? "document" : t
    }

    /// Removes the picker's own copy (it lives in our tmp folder) once we have ours.
    private static func removePickerCopy(_ url: URL) {
        var tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        if !tmp.hasSuffix("/") { tmp += "/" }
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        if tmp.count > 1, p.hasPrefix(tmp) { try? FileManager.default.removeItem(atPath: p) }
    }

    /// Copies the picked document into tmp/docs/ and returns {"path","name","mime","size"} JSON, or a FlutterError.
    /// Call off the main thread.
    static func importPicked(_ src: URL) -> Any {
        let fm = FileManager.default
        let scoped = src.startAccessingSecurityScopedResource()
        defer {
            if scoped { src.stopAccessingSecurityScopedResource() }
            removePickerCopy(src)
        }
        let values = try? src.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        if values?.isRegularFile == false { return fail("unsupported") }
        guard let type = values?.contentType ?? UTType(filenameExtension: src.pathExtension) else { return fail("unsupported") }
        let isPdf = type.conforms(to: .pdf)
        let isImage = !isPdf && type.conforms(to: .image)
        guard isPdf || isImage else { return fail("unsupported") }
        if let size = values?.fileSize, size > maxBytes { return fail("too_large") }

        let mime = isPdf ? "application/pdf" : (type.preferredMIMEType ?? "image/jpeg")
        var ext = isPdf ? "pdf" : type.conforms(to: .png) ? "png" : type.conforms(to: .jpeg) ? "jpg" : (type.preferredFilenameExtension ?? "img")
        if ext.isEmpty || ext.count > 5 || !ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { ext = "img" }

        clear() // keep only the latest document
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return fail("unreadable")
        }
        let dest = dir.appendingPathComponent("doc_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
        do {
            try fm.copyItem(at: src, to: dest)
        } catch {
            return fail("unreadable")
        }
        let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { try? fm.removeItem(at: dest); return fail("unreadable") }
        guard size <= maxBytes else { try? fm.removeItem(at: dest); return fail("too_large") }
        // It must really be what it claims to be.
        let genuine: Bool
        if isPdf {
            let head = (try? Data(contentsOf: dest, options: .mappedIfSafe))?.prefix(1024) ?? Data()
            genuine = head.range(of: Data("%PDF-".utf8)) != nil
        } else if let isrc = CGImageSourceCreateWithURL(dest as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            genuine = CGImageSourceGetCount(isrc) > 0 && CGImageSourceGetType(isrc) != nil
        } else {
            genuine = false
        }
        guard genuine else { try? fm.removeItem(at: dest); return fail("unsupported") }
        let o: [String: Any] = ["path": dest.path, "name": cleanName(src.lastPathComponent), "mime": mime, "size": size]
        guard let s = json(o) else { try? fm.removeItem(at: dest); return fail("unreadable") }
        return s
    }

    // MARK: Reading a PDF

    /// Calls done on the main thread with {"text","pages","pagesRead","ocr"} JSON, or a FlutterError.
    static func readPdf(path: String, done: @escaping (Any?) -> Void) {
        queue.async {
            let out: Any? = autoreleasepool { () -> Any? in
                guard let url = SLImageReader.allowedURL(path) else {
                    return FlutterError(code: "blocked", message: "This file can't be opened", details: nil)
                }
                return SLDocs.pdfText(url)
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    private static func nonSpaceCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
    }

    private static func pdfText(_ url: URL) -> Any {
        guard let doc = PDFDocument(url: url) else { return fail("unreadable") }
        if doc.isLocked { return fail("locked") }
        let pages = doc.pageCount
        guard pages > 0 else { return fail("unreadable") }

        // 1. The PDF's own text (made by a computer): up to 20 pages, rebuilt in rows where possible.
        var parts: [String] = []
        var total = 0
        var read = 0
        for i in 0..<min(pages, maxTextPages) where total < maxText {
            let t: String = autoreleasepool { () -> String in
                guard let page = doc.page(at: i) else { return "" }
                return pageTextRows(page)
            }
            read += 1
            if !t.isEmpty { parts.append(t); total += t.count }
        }
        var text = parts.joined(separator: "\n\n")
        var ocr = false
        var layout = SLLayout.notChecked // only OCR'd pages have word boxes to compare

        // 2. A scanned PDF has (almost) no text: render up to 6 pages and read them with Vision.
        if nonSpaceCount(text) < 50 {
            var scanned: [String] = []
            var scannedTotal = 0
            var scannedRead = 0
            var geometry = SLLayout.Acc()
            for i in 0..<min(pages, maxOcrPages) where scannedTotal < maxText {
                let t: String? = autoreleasepool { () -> String? in
                    guard let page = doc.page(at: i), let cg = render(page) else { return nil }
                    return ocrRows(cg, geometry: &geometry)
                }
                guard let pageText = t else { break } // keep what earlier pages gave
                scannedRead += 1
                if !pageText.isEmpty { scanned.append(pageText); scannedTotal += pageText.count }
            }
            let scannedText = scanned.joined(separator: "\n\n")
            if scannedRead > 0 && nonSpaceCount(scannedText) >= nonSpaceCount(text) {
                text = scannedText
                read = scannedRead
                ocr = true
                layout = geometry.json(checked: true)
            } else if scannedRead == 0 && nonSpaceCount(text) == 0 {
                return fail("unreadable")
            }
        }
        if text.count > maxText { text = String(text.prefix(maxText)) }
        guard let s = json(["text": text, "pages": pages, "pagesRead": read, "ocr": ocr, "layout": layout]) else { return fail("unreadable") }
        return s
    }

    /// A page's text in reading rows (from the text's positions); falls back to PDFKit's own order.
    private static func pageTextRows(_ page: PDFPage) -> String {
        let rotation = ((page.rotation % 360) + 360) % 360
        let box = page.bounds(for: .cropBox)
        if rotation == 0, box.width > 0, box.height > 0, let sel = page.selection(for: box) {
            let lines = sel.selectionsByLine().compactMap { s -> SLTextRows.Line? in
                guard let t = s.string else { return nil }
                let b = s.bounds(for: page)
                // PDF space has its origin at the bottom: flip so rows read top to bottom.
                return SLTextRows.Line(text: t, rect: CGRect(x: b.minX, y: box.maxY - b.maxY, width: b.width, height: b.height))
            }
            let rows = SLTextRows.build(lines)
            if !rows.isEmpty { return rows }
        }
        return page.string ?? ""
    }

    /// Renders a page upright on white, longest side about 2000 px.
    private static func render(_ page: PDFPage) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let box = ref.getBoxRect(.cropBox)
        let rotation = ((Int(ref.rotationAngle) % 360) + 360) % 360
        var w = box.width, h = box.height
        if rotation == 90 || rotation == 270 { swap(&w, &h) }
        guard w > 0, h > 0 else { return nil }
        let k = pdfSide / max(w, h)
        let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height) // UIKit is top-down, PDF is bottom-up
            cg.scaleBy(x: k, y: -k)
            // Maps the page box (with its rotation) onto a same-size rect; the scale above does the enlarging,
            // because getDrawingTransform never scales up.
            cg.concatenate(ref.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
            cg.drawPDFPage(ref)
            cg.restoreGState()
        }
        return image.cgImage
    }

    /// Vision OCR of one rendered page, rebuilt in reading rows. nil if Vision failed.
    /// Also adds the page's word boxes to the layout check.
    private static func ocrRows(_ cg: CGImage, geometry: inout SLLayout.Acc) -> String? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        geometry.add(req.results ?? [], width: CGFloat(cg.width), height: CGFloat(cg.height))
        return SLTextRows.build(SLTextRows.lines(req.results ?? [], width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    // MARK: analyzeDocument input

    /// Caps the text inside the Dart side's JSON (50,000 characters). nil for malformed input.
    static func capInput(_ s: String) -> String? {
        guard s.utf8.count <= maxInputBytes, let d = s.data(using: .utf8),
              var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let t = o["text"] as? String ?? ""
        o["text"] = t.count > maxText ? String(t.prefix(maxText)) : t
        return json(o)
    }

    // MARK: Signatures (Aadhaar secure QR)

    /// True if signature is a valid SHA256withRSA (PKCS#1 v1.5) signature of data under ANY of the DER X.509
    /// certificates' public keys. Bad input is simply false. Certificate dates are not checked.
    /// true = valid, false = checked against a usable key and failed, nil = no usable key (shown as "not checked").
    static func verifySignature(data: Data?, signature: Data?, certs: [Data]) -> Bool? {
        guard let data = data, let sig = signature, !data.isEmpty, data.count <= maxSignedBytes,
              !sig.isEmpty, sig.count <= maxSignatureBytes else { return false }
        var usable = false
        let alg = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        for der in certs.prefix(maxCerts) where !der.isEmpty && der.count <= maxCertBytes {
            guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                  let key = SecCertificateCopyKey(cert),
                  SecKeyIsAlgorithmSupported(key, .verify, alg) else { continue }
            usable = true
            if SecKeyVerifySignature(key, alg, data as CFData, sig as CFData, nil) { return true }
        }
        return usable ? false : nil
    }
}

/// The system document picker (Files, iCloud Drive, Downloads): PDFs and images only. No permission prompt needed.
final class SLDocPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: SLDocPicker? // keeps the delegate alive while the picker is open
    private var done: ((Any?) -> Void)?
    private weak var controller: UIViewController?
    private var importing = false

    static func present(_ done: @escaping (Any?) -> Void) {
        if let c = current {
            // A picker that vanished without telling us (should not happen) must not block the feature for good.
            if c.importing || c.controller?.presentingViewController != nil {
                done(FlutterError(code: "busy", message: "A file is already being chosen", details: nil))
                return
            }
            c.finish(nil)
        }
        guard let top = topViewController() else {
            done(FlutterError(code: "unsupported", message: "Couldn't open the file picker", details: nil))
            return
        }
        let p = SLDocPicker()
        p.done = done
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .image], asCopy: true)
        vc.allowsMultipleSelection = false
        vc.delegate = p
        p.controller = vc
        current = p
        top.present(vc, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        var top = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController
        while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
        return top
    }

    private func finish(_ r: Any?) {
        if SLDocPicker.current === self { SLDocPicker.current = nil }
        guard let d = done else { return }
        done = nil
        d(r)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { finish(nil); return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SLDocs.importPicked(url)
            DispatchQueue.main.async {
                self.importing = false
                self.finish(r)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
}

/// Private crash log (v1.6). Kept only on this iPhone in Application Support/crash_log.json (newest 20 entries,
/// file protection on, excluded from backups) and never uploaded; the user can share it from Settings.
/// Messages and stacks are cleaned before they are stored: links, e-mail addresses, phone-like numbers and any run
/// of 6+ digits are replaced, so no SMS text, codes or numbers end up in the report. Nothing here throws or traps.
enum SLCrashLog {
    static let appVersion = "1.6.0"
    private static let maxEntries = 20
    private static let maxMessage = 500
    private static let maxStack = 6000
    private static let maxFileBytes = 512 * 1024
    /// All file access happens on this serial queue.
    static let queue = DispatchQueue(label: "secondlook.crashlog", qos: .utility)

    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("crash_log.json", isDirectory: false)
    }

    // MARK: redaction

    private static let patterns: [(NSRegularExpression?, String)] = [
        (try? NSRegularExpression(pattern: #"\b(?:[a-z][a-z0-9+.\-]{1,15}://|www\.)[^\s"'<>()\[\]{}]+"#, options: [.caseInsensitive]), "[link]"),
        (try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#), "[email]"),
        // Bare web addresses; lower-case only and without io/app/me/co/net so Swift/Dart symbols stay readable.
        (try? NSRegularExpression(pattern: #"\b[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.(?:com|in|org|info|top|xyz|online|site|live|club|shop|link|ly|biz|cc|tk|ml|ga|cf|gq|icu|vip|buzz|cn|ru|store|website|space|fun|click|page|co\.in|org\.in|net\.in)\b(?:/[^\s"'<>]*)?"#), "[link]"),
        // Phone numbers written with spaces/dashes ("+91 98765 43210"): 8+ digits with separators in between.
        (try? NSRegularExpression(pattern: #"\+?\d(?:[ \-().]{0,2}\d){7,}"#), "[number]"),
        (try? NSRegularExpression(pattern: #"\d{6,}"#), "[number]"),
    ]

    /// Removes links, e-mail addresses, phone-like numbers and runs of 6+ digits.
    static func redact(_ s: String) -> String {
        if s.isEmpty { return "" }
        var out = s
        for (re, replacement) in patterns {
            guard let re = re else {
                // A pattern failed to compile (should not happen): mask every digit rather than keep them.
                out = String(out.map { (ch: Character) -> Character in ch.isASCII && ch.isNumber ? Character("#") : ch })
                continue
            }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, options: [], range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return out
    }

    private static func cap(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) }

    static var osLabel: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// "Apple iPhone14,2" (the hardware model id; no name or identifier of the person).
    static var deviceLabel: String {
        var u = utsname()
        guard uname(&u) == 0 else { return "Apple" }
        var chars: [Character] = []
        for child in Mirror(reflecting: u.machine).children {
            guard let c = child.value as? CChar, c != 0, chars.count < 64 else { break }
            chars.append(Character(UnicodeScalar(UInt8(bitPattern: c))))
        }
        let machine = String(chars).trimmingCharacters(in: .whitespaces)
        return machine.isEmpty ? "Apple" : "Apple \(machine)"
    }

    // MARK: file (call on `queue`)

    private static func readList() -> [[String: Any]] {
        guard let url = fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0, size <= maxFileBytes,
              let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return Array(arr.compactMap { $0 as? [String: Any] }.prefix(maxEntries))
    }

    private static func writeList(_ list: [[String: Any]]) {
        guard var url = fileURL, JSONSerialization.isValidJSONObject(list),
              let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        // .atomic writes a temporary file and renames it over the old one.
        guard (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return }
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? url.setResourceValues(rv)
    }

    // MARK: API (never throws)

    /// Adds one entry (source "dart" or "native").
    static func record(source: String, message: String, stack: String) {
        let entry: [String: Any] = [
            "at": Int(Date().timeIntervalSince1970 * 1000),
            "source": source == "dart" ? "dart" : "native",
            // Cut very long input first so cleaning stays quick, then clean and cap.
            "message": cap(redact(String(message.prefix(maxMessage * 8))), maxMessage),
            "stack": cap(redact(String(stack.prefix(maxStack * 4))), maxStack),
            "app": appVersion,
            "os": osLabel,
            "device": deviceLabel,
        ]
        SLCrashLog.queue.async {
            var entries = SLCrashLog.readList()
            entries.insert(entry, at: 0)
            SLCrashLog.writeList(Array(entries.prefix(SLCrashLog.maxEntries)))
        }
    }

    /// Entries, newest first. Delivered on the main queue.
    static func list(_ done: @escaping ([[String: Any]]) -> Void) {
        SLCrashLog.queue.async {
            let l = SLCrashLog.readList()
            DispatchQueue.main.async { done(l) }
        }
    }

    /// Removes the log. Delivered on the main queue.
    static func clear(_ done: (() -> Void)? = nil) {
        SLCrashLog.queue.async {
            if let url = SLCrashLog.fileURL { try? FileManager.default.removeItem(at: url) }
            if let done = done { DispatchQueue.main.async { done() } }
        }
    }

    /// Plain-text report (already redacted; cleaned again here to be safe).
    static func report(_ entries: [[String: Any]]) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        var out = "Second Look crash report\n"
        out += "App \(appVersion) | \(osLabel) | \(deviceLabel)\n"
        out += "Entries: \(entries.count) (newest first)\n"
        out += "This report contains no messages, numbers or links.\n"
        for (i, e) in entries.enumerated() {
            let s = { (k: String) -> String in SLCrashLog.redact((e[k] as? String) ?? "") }
            var when = "?"
            if let at = e["at"] as? NSNumber { when = fmt.string(from: Date(timeIntervalSince1970: at.doubleValue / 1000)) }
            out += "\n#\(i + 1) | \(when) | \(s("source")) | app \(s("app")) | \(s("os")) | \(s("device"))\n"
            out += cap(s("message"), maxMessage) + "\n"
            let st = cap(s("stack"), maxStack)
            if !st.isEmpty { out += st + "\n" }
        }
        return out
    }

    /// Opens the share sheet with the report. false if there is nothing to share or no screen to show it on.
    static func share(_ done: @escaping (Bool) -> Void) {
        SLCrashLog.list { entries in
            guard !entries.isEmpty, let top = SLDocPicker.topViewController() else { done(false); return }
            let vc = UIActivityViewController(activityItems: [SLCrashLog.report(entries)], applicationActivities: nil)
            if let pop = vc.popoverPresentationController { // iPad: anchor the sheet
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
            top.present(vc, animated: true)
            done(true)
        }
    }
}

public class SecondLookPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private let speech = AVSpeechSynthesizer()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let ch = FlutterMethodChannel(name: "secondlook/native", binaryMessenger: registrar.messenger())
        let instance = SecondLookPlugin()
        instance.channel = ch
        instance.speech.delegate = instance
        registrar.addMethodCallDelegate(instance, channel: ch)
        SLPrivacyCover.shared.start()
        // Documents are never kept: remove any copy left behind if the app was closed mid-check.
        DispatchQueue.global(qos: .utility).async { SLDocs.clear() }
        // Warn the user the moment their screen starts being recorded or shared (a common scam step).
        NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
            ch.invokeMethod("onScreenCaptured", arguments: UIScreen.main.isCaptured)
        }
    }

    private var d: UserDefaults { SLShared.defaults }

    private func json(_ o: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// "history" and "number_actions" are encrypted; "reports" stays readable by the Call Directory extension
    /// (it holds only numbers you marked).
    private static let encryptedLists: Set<String> = ["history", "number_actions"]
    private static let maxHistory = 300
    private static let maxActions = 500

    private func list(_ key: String) -> [[String: Any]] {
        let raw = d.string(forKey: key)
        let text = Self.encryptedLists.contains(key) ? SLSecurity.decrypt(raw) : raw
        guard let s = text, let data = s.data(using: .utf8),
              let a = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return a
    }

    private func saveList(_ key: String, _ a: [[String: Any]]) {
        let text = json(a)
        if Self.encryptedLists.contains(key) {
            guard let enc = SLSecurity.encrypt(text) else { return } // never store history unencrypted
            d.set(enc, forKey: key)
        } else {
            d.set(text, forKey: key)
        }
    }

    private func secret(_ key: String) -> String { SLSecurity.decrypt(d.string(forKey: key)) ?? "" }
    private func setSecret(_ key: String, _ v: String) { d.set(SLSecurity.encrypt(v), forKey: key) }

    private static func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    private static func parse(_ s: String?) -> [String: Any]? {
        guard let s = s, let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Saves an alert to history and returns its id (nil if the result is malformed). extra adds the v1.3 fields
    /// (number, senderType, firstTime, preview, test).
    @discardableResult
    private func addHistory(kind: String, title: String, result r: [String: Any], extra: [String: Any] = [:]) -> String? {
        guard let level = (r["level"] as? [String: Any])?["key"] as? String else { return nil }
        let reasons = (r["reasons"] as? [[String: Any]]) ?? []
        let summary = reasons.first(where: { (($0["weight"] as? NSNumber)?.intValue ?? 0) > 0 })?["title"] as? String ?? ""
        let id = UUID().uuidString
        var e: [String: Any] = ["id": id, "at": Self.now(), "kind": kind, "title": title,
                                "summary": summary, "level": level, "score": r["score"] ?? 0, "result": r]
        for (k, v) in extra { e[k] = v }
        var h = list("history")
        h.insert(e, at: 0)
        saveList("history", Array(h.prefix(Self.maxHistory)))
        return id
    }

    // Keep flagged results from checks the user runs, so Home and Alerts can show them.
    private func remember(_ resultJson: String?, kind: String, title: String, extra: [String: Any] = [:]) {
        guard let r = Self.parse(resultJson),
              let level = (r["level"] as? [String: Any])?["key"] as? String, level != "safe" else { return }
        addHistory(kind: kind, title: title, result: r, extra: extra)
    }

    /// The sender fields of a history entry: phone numbers vs. SMS headers such as "VK-HDFCBK".
    private static func senderFields(_ sender: String) -> [String: Any] {
        let s = String(sender.prefix(64))
        let isNumber = !s.contains(where: { $0.isLetter }) && s.filter({ $0.isNumber }).count >= 3
        return ["number": s, "senderType": isNumber ? "number" : "header"]
    }

    /// E.164 for phone numbers (via the engine); otherwise the digits, or a cleaned SMS header. Calls done on main.
    private func normalize(_ raw: String, _ done: @escaping (String) -> Void) {
        let input = String(raw.prefix(64))
        SLEngine.shared.call("lookupNumber", [input]) { r in
            if let e = Self.parse(r)?["e164"] as? String, !e.isEmpty { done(e); return }
            let digits = SLSecurity.cleanNumber(input)
            if digits.filter({ $0.isNumber }).count >= 3 { done(digits); return }
            done(String(input.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(20)))
        }
    }

    /// Saves (or replaces) the user's own mark for a number. Blocked numbers are blocked by the Call Directory.
    private func upsertReport(_ number: String, type: String, label: String, kind: String, blocked: Bool) {
        var reps = list("reports").filter { ($0["number"] as? String) != number }
        var e: [String: Any] = ["number": number, "type": type, "label": label, "kind": kind, "at": Self.now()]
        if blocked { e["blocked"] = true }
        reps.insert(e, at: 0)
        saveList("reports", Array(reps.prefix(500)))
    }

    private func status(_ done: @escaping (String) -> Void) {
        var s: [String: Any] = [
            "platform": "ios",
            "onboarded": d.bool(forKey: "onboarded"),
            "termsVersion": d.string(forKey: "terms_version") ?? "",
            "prefs": [
                "language": d.string(forKey: "pref_language") ?? "",
                "voice": d.string(forKey: "pref_voice") ?? "", // missing / "" means off (read-out only on Listen)
                "voice_name": d.string(forKey: "pref_voice_name") ?? "",
                "voice_rate": d.string(forKey: "pref_voice_rate") ?? "",
                "log_all": d.string(forKey: "pref_log_all") ?? "",
                "call_popup": d.string(forKey: "pref_call_popup") ?? "",
                "sms_popup": d.string(forKey: "pref_sms_popup") ?? "",
                "lite_mode": d.string(forKey: "pref_lite_mode") ?? "", // '' = auto
                "community_off": d.string(forKey: "pref_community_off") ?? "",
                "community_sync": d.string(forKey: "pref_community_sync") ?? "",
                "checks_done": d.string(forKey: "pref_checks_done") ?? "",
                "last_ad_at": d.string(forKey: "pref_last_ad_at") ?? "",
            ],
            "overlayAllowed": false, // iOS never lets an app draw over a call
            "smsShield": d.bool(forKey: "sms_on"),
            "smsNeedsPermission": false,
            "autoSilence": false,
            "appLock": d.bool(forKey: "app_lock"),
            "screenCaptured": UIScreen.main.isCaptured,
            "trustedName": secret("trusted_name"),
            "trustedNumber": secret("trusted_number"),
            "device": Self.deviceInfo(),
        ]
        let wanted = d.bool(forKey: "call_on")
        CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(withIdentifier: SLShared.callDirectoryId) { st, _ in
            DispatchQueue.main.async {
                let enabled = st == .enabled
                s["callShield"] = wanted
                s["callNeedsRole"] = wanted && !enabled
                done(self.json(s))
            }
        }
    }

    /// For lite mode: {lowRam, ramMb, sdk}. iOS has no SDK level (0); "low" means under 3 GB of memory.
    private static func deviceInfo() -> [String: Any] {
        let mb = Int(min(ProcessInfo.processInfo.physicalMemory / (1024 * 1024), UInt64(Int32.max)))
        return ["lowRam": mb > 0 && mb < 3 * 1024, "ramMb": mb, "sdk": 0]
    }

    private func reloadCallDirectory() {
        CXCallDirectoryManager.sharedInstance.reloadExtension(withIdentifier: SLShared.callDirectoryId) { err in
            if let err = err { NSLog("Call directory reload: \(err)") }
        }
    }

    /// An engine that failed to load returns nil: report it as an error instead of an empty result.
    private func reply(_ r: String?, _ result: FlutterResult) {
        if let r = r, r != "undefined" { result(r) } else { result(FlutterError(code: "engine", message: "The checker did not load. Reinstall Second Look.", details: nil)) }
    }

    private func open(_ s: String) {
        guard let u = URL(string: s) else { return }
        UIApplication.shared.open(u)
    }

    // MARK: v1.3 helpers

    /// Up to 6 installed voices for the language, best first: premium, then enhanced, then default quality;
    /// Indian voices before others of the same quality. Novelty and Personal Voice voices are left out.
    static func voices(_ lang: String) -> [AVSpeechSynthesisVoice] {
        let code = ["hi", "kn"].contains(lang) ? lang : "en"
        var seen = Set<String>()
        let list = AVSpeechSynthesisVoice.speechVoices().filter { v in
            let l = v.language.lowercased()
            guard l == code || l.hasPrefix(code + "-"), !seen.contains(v.identifier) else { return false }
            if #available(iOS 17.0, *) {
                if v.voiceTraits.contains(.isNoveltyVoice) || v.voiceTraits.contains(.isPersonalVoice) { return false }
            }
            seen.insert(v.identifier)
            return true
        }
        let sorted = list.sorted { x, y in
            let qx = quality(x), qy = quality(y)
            if qx != qy { return qx > qy }
            let ix = x.language.uppercased().hasSuffix("-IN"), iy = y.language.uppercased().hasSuffix("-IN")
            if ix != iy { return ix }
            return x.identifier < y.identifier
        }
        return Array(sorted.prefix(6))
    }

    /// 1 default, 2 enhanced, 3 premium.
    static func quality(_ v: AVSpeechSynthesisVoice) -> Int { min(3, max(1, v.quality.rawValue)) }

    /// A user's comment: links removed, control characters removed, at most 200 characters.
    static func cleanComment(_ s: String) -> String {
        var t = String(s.prefix(1000))
        t = t.replacingOccurrences(of: "(?i)\\b(?:https?://|www\\.)\\S*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)\\b[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.(?:com|in|net|org|info|top|xyz|io|co|me|ly|link|site|online|app|live|club|shop|biz|cc|tk|ml|ga|cf|gq|buzz|icu|vip|work)\\b(?:/\\S*)?", with: "", options: .regularExpression)
        t = String(t.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f && !(0x202a...0x202e).contains($0.value) && !(0x2066...0x2069).contains($0.value) }.map { Character($0) })
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(200))
    }

    /// SMS preview for history: first 160 characters, one-time codes (4–8 digits on their own) hidden.
    static func preview(_ body: String) -> String {
        String(body.prefix(160)).replacingOccurrences(of: "(?<![0-9])[0-9]{4,8}(?![0-9])", with: "••••", options: .regularExpression)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        let str = { (k: String) -> String in a[k] as? String ?? "" }
        switch call.method {
        case "analyze":
            SLEngine.shared.call("analyzeAuto", [str("text")]) { r in self.remember(r, kind: "check", title: "Checked text"); self.reply(r, result) }
        case "analyzeSms":
            SLEngine.shared.call("analyzeSms", [str("sender"), str("body")]) { r in
                self.remember(r, kind: "sms", title: "SMS from \(str("sender"))", extra: Self.senderFields(str("sender")))
                self.reply(r, result)
            }
        case "analyzeNumber":
            SLEngine.shared.call("analyzeNumber", [str("number"), json(list("reports"))]) { r in
                self.remember(r, kind: "call", title: "Number \(str("number"))", extra: Self.senderFields(str("number")))
                self.reply(r, result)
            }
        case "analyzeUpi":
            let upi = String(str("text").prefix(2048))
            SLEngine.shared.call("analyzeUpi", [upi]) { r in self.remember(r, kind: "upi", title: "UPI ID \(upi.prefix(64))"); self.reply(r, result) }
        case "analyzePayment":
            let opt = { (k: String) -> Any in
                if let v = a[k] as? String { return String(v.prefix(64)) }
                return NSNull()
            }
            let input: [String: Any] = [
                "text": String(str("text").prefix(10000)),
                "expectedAmount": opt("expectedAmount"),
                "myUpi": opt("myUpi"),
                "imageEditor": opt("imageEditor"),
            ]
            SLEngine.shared.call("analyzePayment", [json(input)]) { r in self.remember(r, kind: "payment", title: "Payment screenshot"); self.reply(r, result) }
        case "readImage":
            SLImageReader.read(path: str("path"), layout: a["layout"] as? Bool ?? false) { result($0) }

        // "Check a document" (IDs, passports, statements, letters). Read on the iPhone; results are never saved to
        // history or alerts, and nothing about the document is logged.
        case "pickDocument":
            SLDocPicker.present { result($0) }
        case "readPdf":
            SLDocs.readPdf(path: str("path")) { result($0) }
        case "verifySignature":
            let data = (a["data"] as? FlutterStandardTypedData)?.data
            let sig = (a["signature"] as? FlutterStandardTypedData)?.data
            let certs = (a["certs"] as? [Any] ?? []).compactMap { ($0 as? FlutterStandardTypedData)?.data }
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = SLDocs.verifySignature(data: data, signature: sig, certs: certs)
                DispatchQueue.main.async { result(ok.map { NSNumber(value: $0) } ?? NSNull()) }
            }
        case "analyzeDocument":
            guard let input = SLDocs.capInput(str("input")) else {
                result(FlutterError(code: "engine", message: "Check failed", details: nil)); return
            }
            SLEngine.shared.call("analyzeDocument", [input]) { r in self.reply(r, result) } // never remembered
        case "clearDocCache":
            DispatchQueue.global(qos: .utility).async {
                SLDocs.clear()
                DispatchQueue.main.async { result(nil) }
            }
        case "status":
            status { result($0) }
        case "setSmsShield":
            d.set(a["on"] as? Bool ?? false, forKey: "sms_on")
            status { result($0) }
        case "setCallShield":
            d.set(a["on"] as? Bool ?? false, forKey: "call_on")
            reloadCallDirectory()
            status { result($0) }
        case "setAutoSilence":
            status { result($0) }
        case "setTrusted":
            setSecret("trusted_name", String(str("name").prefix(60)))
            setSecret("trusted_number", SLSecurity.cleanNumber(str("number")))
            status { result($0) }
        case "securityStatus":
            let r: [String: Any] = [
                "encryptedStorage": SLSecurity.decrypt(SLSecurity.encrypt("ok")) == "ok",
                "privateChecks": true,
                "debugger": SLSecurity.debuggerAttached,
                "hooking": SLSecurity.hooking,
                "rooted": SLSecurity.jailbroken,
                "screenCaptured": SLSecurity.screenCaptured,
                "appLock": d.bool(forKey: "app_lock"),
            ]
            result(json(r))
        case "setScreenProtection":
            status { result($0) }
        case "setAppLock":
            let on = a["on"] as? Bool ?? false
            if on && !SLSecurity.deviceHasPasscode {
                result(FlutterError(code: "nolock", message: "Set a passcode on your iPhone first", details: nil)); return
            }
            SLSecurity.authenticate { ok in
                if ok { self.d.set(on, forKey: "app_lock") }
                self.status { result($0) }
            }
        case "authenticate":
            SLSecurity.authenticate { ok in result(ok) }
        case "setOnboarded":
            d.set(true, forKey: "onboarded")
            if let t = a["terms"] as? String { d.set(String(t.prefix(20)), forKey: "terms_version") }
            result(nil)
        case "history":
            result(json(list("history")))
        case "clearHistory":
            d.removeObject(forKey: "history")
            result(nil)
        case "deleteHistory":
            let ids = Set((a["ids"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty })
            var h = list("history")
            let before = h.count
            if !ids.isEmpty {
                h.removeAll { entry in
                    guard let id = entry["id"] as? String else { return false }
                    return ids.contains(id)
                }
            }
            let deleted = before - h.count
            if deleted > 0 { saveList("history", h) }
            result(json(["deleted": deleted]))

        // ---- v1.6: private crash log (on this iPhone only; the user may share it) ----
        case "logCrash":
            SLCrashLog.record(source: str("source"), message: str("message"), stack: str("stack"))
            result(nil)
        case "crashLog":
            SLCrashLog.list { result(self.json($0)) }
        case "clearCrashLog":
            SLCrashLog.clear { result(nil) }
        case "shareCrashLog":
            SLCrashLog.share { result($0) }
        case "reports":
            result(json(list("reports")))
        case "report":
            SLEngine.shared.call("lookupNumber", [str("number")]) { r in
                var e164 = str("number")
                if let r = r, let data = r.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = o["e164"] as? String { e164 = e }
                var reps = self.list("reports").filter { ($0["number"] as? String) != e164 }
                reps.insert(["number": e164, "type": str("type"), "label": str("label"), "kind": str("kind"), "at": Int(Date().timeIntervalSince1970 * 1000)], at: 0)
                self.saveList("reports", reps)
                self.reloadCallDirectory()
                result(nil)
            }
        case "removeReport":
            saveList("reports", list("reports").filter { ($0["number"] as? String) != str("number") })
            reloadCallDirectory()
            result(nil)
        case "deleteAllData":
            for k in ["history", "reports", "number_actions", "sms_on", "call_on", "trusted_name", "trusted_number", "app_lock",
                      "pref_checks_done", "pref_last_ad_at"] { d.removeObject(forKey: k) }
            SLDocs.clear()
            SLCrashLog.clear()
            SLSecurity.wipeKey()
            reloadCallDirectory()
            result(nil)
        case "openUrl":
            guard SLSecurity.urlAllowed(str("url")) else { result(FlutterError(code: "blocked", message: "Link not allowed", details: nil)); return }
            open(str("url")); result(nil)
        case "dial":
            open("tel://" + SLSecurity.cleanNumber(str("number"))); result(nil)
        case "smsTo":
            let body = String(str("body").prefix(500)).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            open("sms:\(SLSecurity.cleanNumber(str("number")))&body=\(body)"); result(nil)
        case "openSystemSettings":
            if str("which") == "call_directory", #available(iOS 13.4, *) {
                CXCallDirectoryManager.sharedInstance.openSettings { _ in }
            } else {
                open(UIApplication.openSettingsURLString)
            }
            result(nil)
        case "setPref":
            let key = str("key")
            guard ["language", "voice", "voice_name", "log_all", "call_popup", "sms_popup", "voice_rate", "community_off", "community_sync", "lite_mode",
                   "checks_done", "last_ad_at"].contains(key) else {
                result(FlutterError(code: "blocked", message: "Unknown setting", details: nil)); return
            }
            // Lite mode: 'auto' (or '' = auto), 'on', 'off'.
            if key == "lite_mode" && !["", "auto", "on", "off"].contains(str("value")) {
                result(FlutterError(code: "blocked", message: "Use auto, on or off", details: nil)); return
            }
            // Ad rules (manual-check counter, last full-screen ad time in ms): digits only, at most 20.
            if ["checks_done", "last_ad_at"].contains(key) && (str("value").count > 20 || !str("value").allSatisfy({ $0.isASCII && $0.isNumber })) {
                result(FlutterError(code: "blocked", message: "Use a number", details: nil)); return
            }
            // Voice ids (e.g. "com.apple.voice.enhanced.en-IN.Rishi") are longer than the other values.
            d.set(String(str("value").prefix(key == "voice_name" ? 200 : 40)), forKey: "pref_" + key)
            if key == "community_off" { reloadCallDirectory() }
            status { result($0) }
        case "listVoices":
            result(json(Self.voices(str("lang")).enumerated().map { i, v -> [String: Any] in
                ["id": v.identifier, "label": "Voice \(i + 1)", "quality": Self.quality(v), "network": false]
            }))
        case "speak":
            // On-device text-to-speech. Returns false when that language's voice isn't installed.
            let code = ["hi", "kn"].contains(str("lang")) ? str("lang") : "en"
            let text = String(str("text").prefix(800))
            // The voice the user picked (passed in, or saved in Settings), if it is still installed and fits the language.
            let wantedId = (a["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? d.string(forKey: "pref_voice_name") ?? ""
            let picked = wantedId.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: wantedId).flatMap { $0.language.lowercased().hasPrefix(code) ? $0 : nil }
            guard !text.isEmpty, let voice = picked ?? AVSpeechSynthesisVoice(language: code + "-IN") ?? (code == "en" ? AVSpeechSynthesisVoice(language: "en-US") : nil) else {
                result(false); return
            }
            // Slightly slower than normal by default (0.92), kept within a sensible range.
            let rate = min(1.5, max(0.5, (a["rate"] as? NSNumber)?.doubleValue ?? 0.92))
            if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
            // Speak even when the ring/silent switch is on, and lower other audio meanwhile.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            let u = AVSpeechUtterance(string: text)
            u.voice = voice
            u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
            speech.speak(u)
            result(true)
        case "stopSpeaking":
            speech.stopSpeaking(at: .immediate)
            result(nil)
        case "setCommunityList":
            let json = str("json")
            DispatchQueue.global(qos: .utility).async {
                var ok = false
                if json.utf8.count < 20 * 1024 * 1024, let data = json.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let nums = o["numbers"] as? [String: Any], let url = SLShared.communityFile {
                    // Keep only well-formed entries: "+<digits>" -> {s: scam count, p: spam count, t: top type}
                    var clean: [String: [String: Any]] = [:]
                    for (k, v) in nums {
                        guard k.range(of: "^\\+[1-9][0-9]{6,14}$", options: .regularExpression) != nil, let m = v as? [String: Any] else { continue }
                        var e: [String: Any] = ["s": max(0, (m["s"] as? Int) ?? 0), "p": max(0, (m["p"] as? Int) ?? 0)]
                        if let t = m["t"] as? String, t.range(of: "^[a-z_]{1,30}$", options: .regularExpression) != nil { e["t"] = t }
                        clean[k] = e
                    }
                    if let out = try? JSONSerialization.data(withJSONObject: ["numbers": clean]) {
                        ok = (try? out.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
                    }
                }
                DispatchQueue.main.async {
                    if ok { self.reloadCallDirectory() }
                    result(ok)
                }
            }

        // ---- v1.3: shield setup, test alert, marking numbers, chat, voices ----
        case "shieldHealth":
            // iOS has no SMS permission, caller-ID role, overlay or battery settings to check.
            result(json(["platform": "ios"]))
        case "openSettings":
            if str("target") == "app", let u = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(u, options: [:]) { ok in result(ok) }
            } else {
                result(false)
            }
        case "testAlert":
            // A built-in sample scam, saved to history like a real alert (marked as a test).
            if str("kind") == "call" {
                let n = "+919000000000"
                SLEngine.shared.call("analyzeNumber", [n, json(list("reports"))]) { r in
                    guard let o = Self.parse(r),
                          let id = self.addHistory(kind: "call", title: "Call from \(n)", result: o,
                                                   extra: ["number": n, "senderType": "number", "firstTime": false, "test": true]) else {
                        self.reply(nil, result); return
                    }
                    result(id)
                }
            } else {
                let sender = "VK-ALERTS"
                let body = "Dear customer your bank account will be blocked today. Update KYC now at http://kyc-verify-update.top/login"
                SLEngine.shared.call("analyzeSms", [sender, body]) { r in
                    guard let o = Self.parse(r),
                          let id = self.addHistory(kind: "sms", title: "SMS from \(sender)", result: o,
                                                   extra: ["number": sender, "senderType": "header", "firstTime": false,
                                                           "preview": Self.preview(body), "test": true]) else {
                        self.reply(nil, result); return
                    }
                    result(id)
                }
            }
        case "markNumber":
            let action = str("action")
            guard ["block", "spam", "fraud", "safe", "comment", "unblock"].contains(action) else {
                result(FlutterError(code: "blocked", message: "Unknown action", details: nil)); return
            }
            let comment = Self.cleanComment(str("comment"))
            let historyId = String(str("historyId").prefix(64))
            if action == "comment" && comment.isEmpty { result(json(["ok": false])); return }
            let raw = str("number")
            normalize(raw) { number in
                guard !number.isEmpty else { result(self.json(["ok": false])); return }
                switch action {
                case "block": self.upsertReport(number, type: "blocked", label: "Blocked", kind: "scam", blocked: true)
                case "spam": self.upsertReport(number, type: "spam", label: "Spam", kind: "spam", blocked: false)
                case "fraud": self.upsertReport(number, type: "fraud", label: "Fraud", kind: "scam", blocked: false)
                case "safe": self.upsertReport(number, type: "safe", label: "Safe", kind: "safe", blocked: false)
                case "unblock":
                    self.saveList("reports", self.list("reports").filter {
                        let n = $0["number"] as? String
                        return n != number && n != raw
                    })
                default: break // comment: only logged
                }
                if action != "comment" { self.reloadCallDirectory() }
                let at = Self.now()
                var log = self.list("number_actions")
                log.insert(["number": number, "action": action, "comment": comment, "at": at,
                            "historyId": historyId.isEmpty ? NSNull() as Any : historyId as Any], at: 0)
                self.saveList("number_actions", Array(log.prefix(Self.maxActions)))
                if !historyId.isEmpty {
                    var h = self.list("history")
                    if let i = h.firstIndex(where: { ($0["id"] as? String) == historyId }) {
                        h[i]["userAction"] = ["action": action, "comment": comment, "at": at]
                        self.saveList("history", h)
                    }
                }
                result(self.json(["ok": true]))
            }
        case "numberActions":
            let all = list("number_actions") // newest first
            let raw = str("number")
            if raw.isEmpty { result(json(all)); return }
            normalize(raw) { number in
                result(self.json(all.filter {
                    let n = $0["number"] as? String
                    return n == number || n == raw
                }))
            }
        case "isAppInstalled":
            // Needs "whatsapp" in LSApplicationQueriesSchemes (tool/setup.sh adds it).
            if str("app") == "whatsapp", let u = URL(string: "whatsapp://") {
                result(UIApplication.shared.canOpenURL(u))
            } else {
                result(false)
            }
        case "openBlockedNumbers":
            // iOS has no public way to open the blocked-contacts list; the app explains the steps instead.
            result(false)
        case "openChat":
            // The only place that may open wa.me. Needs the full number with country code.
            normalize(str("number")) { number in
                let digits = number.filter { $0.isASCII && $0.isNumber }
                guard number.hasPrefix("+"), (8...15).contains(digits.count), let u = URL(string: "https://wa.me/\(digits)") else {
                    result(false); return
                }
                UIApplication.shared.open(u, options: [:]) { ok in result(ok) }
            }

        case "installId":
            // Random id for this install, used only for the deep-check quota and community reports. Not linked to the person.
            var id = secret("install_id")
            if id.isEmpty { id = UUID().uuidString.lowercased(); setSecret("install_id", id) }
            result(id)
        case "consumeSharedText", "consumeSharedImage", "consumeAlertId":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// Gives the audio back to other apps (music, calls) once the read-out ends.
extension SecondLookPlugin: AVSpeechSynthesizerDelegate {
    private func releaseAudio(_ synth: AVSpeechSynthesizer) {
        guard !synth.isSpeaking else { return } // a new read-out already started
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { releaseAudio(synthesizer) }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { releaseAudio(synthesizer) }
}
