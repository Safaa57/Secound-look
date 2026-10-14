import AVFoundation
import CallKit
import Flutter
import ImageIO
import JavaScriptCore
import UIKit
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
    static func read(path: String, done: @escaping (Any?) -> Void) {
        queue.async {
            let out: Any? = autoreleasepool { () -> Any? in
                guard let url = SLImageReader.allowedURL(path) else {
                    return FlutterError(code: "blocked", message: "This image can't be opened", details: nil)
                }
                if let json = SLImageReader.scan(url) { return json }
                return FlutterError(code: "image", message: "Couldn't read this image", details: nil)
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    private static func scan(_ url: URL) -> String? {
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

        var text = (textReq.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        if text.count > maxText { text = String(text.prefix(maxText)) }
        var qr: [String] = []
        for o in qrReq.results ?? [] {
            if qr.count >= maxQr { break }
            guard var v = o.payloadStringValue, !v.isEmpty else { continue }
            if v.count > maxQrLen { v = String(v.prefix(maxQrLen)) }
            if !qr.contains(v) { qr.append(v) }
        }
        let o: [String: Any] = ["text": text, "qr": qr, "width": w, "height": h]
        guard let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
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

    /// "history" is encrypted; "reports" stays readable by the Call Directory extension (it holds only numbers you marked).
    private func list(_ key: String) -> [[String: Any]] {
        let raw = d.string(forKey: key)
        let text = key == "history" ? SLSecurity.decrypt(raw) : raw
        guard let s = text, let data = s.data(using: .utf8),
              let a = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return a
    }

    private func saveList(_ key: String, _ a: [[String: Any]]) {
        let text = json(a)
        if key == "history" {
            guard let enc = SLSecurity.encrypt(text) else { return } // never store history unencrypted
            d.set(enc, forKey: key)
        } else {
            d.set(text, forKey: key)
        }
    }

    private func secret(_ key: String) -> String { SLSecurity.decrypt(d.string(forKey: key)) ?? "" }
    private func setSecret(_ key: String, _ v: String) { d.set(SLSecurity.encrypt(v), forKey: key) }

    // Keep flagged results from checks the user runs, so Home and Alerts can show them.
    private func remember(_ resultJson: String?, kind: String, title: String) {
        guard let s = resultJson, let data = s.data(using: .utf8),
              let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let level = (r["level"] as? [String: Any])?["key"] as? String, level != "safe" else { return }
        let reasons = (r["reasons"] as? [[String: Any]]) ?? []
        let summary = reasons.first(where: { (($0["weight"] as? NSNumber)?.intValue ?? 0) > 0 })?["title"] as? String ?? ""
        var h = list("history")
        h.insert(["id": UUID().uuidString, "at": Int(Date().timeIntervalSince1970 * 1000), "kind": kind, "title": title,
                  "summary": summary, "level": level, "score": r["score"] ?? 0, "result": r], at: 0)
        saveList("history", Array(h.prefix(100)))
    }

    private func status(_ done: @escaping (String) -> Void) {
        var s: [String: Any] = [
            "platform": "ios",
            "onboarded": d.bool(forKey: "onboarded"),
            "termsVersion": d.string(forKey: "terms_version") ?? "",
            "prefs": [
                "language": d.string(forKey: "pref_language") ?? "",
                "voice": d.string(forKey: "pref_voice") ?? "",
                "community_off": d.string(forKey: "pref_community_off") ?? "",
                "community_sync": d.string(forKey: "pref_community_sync") ?? "",
            ],
            "smsShield": d.bool(forKey: "sms_on"),
            "smsNeedsPermission": false,
            "autoSilence": false,
            "appLock": d.bool(forKey: "app_lock"),
            "screenCaptured": UIScreen.main.isCaptured,
            "trustedName": secret("trusted_name"),
            "trustedNumber": secret("trusted_number"),
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

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        let str = { (k: String) -> String in a[k] as? String ?? "" }
        switch call.method {
        case "analyze":
            SLEngine.shared.call("analyzeAuto", [str("text")]) { r in self.remember(r, kind: "check", title: "Checked text"); self.reply(r, result) }
        case "analyzeSms":
            SLEngine.shared.call("analyzeSms", [str("sender"), str("body")]) { r in self.remember(r, kind: "sms", title: "SMS from \(str("sender"))"); self.reply(r, result) }
        case "analyzeNumber":
            SLEngine.shared.call("analyzeNumber", [str("number"), json(list("reports"))]) { r in self.remember(r, kind: "call", title: "Number \(str("number"))"); self.reply(r, result) }
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
            SLImageReader.read(path: str("path")) { result($0) }
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
            for k in ["history", "reports", "sms_on", "call_on", "trusted_name", "trusted_number", "app_lock"] { d.removeObject(forKey: k) }
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
            guard ["language", "voice", "community_off", "community_sync"].contains(key) else {
                result(FlutterError(code: "blocked", message: "Unknown setting", details: nil)); return
            }
            d.set(String(str("value").prefix(40)), forKey: "pref_" + key)
            if key == "community_off" { reloadCallDirectory() }
            status { result($0) }
        case "speak":
            // On-device text-to-speech. Returns false when that language's voice isn't installed.
            let code = ["hi", "kn"].contains(str("lang")) ? str("lang") : "en"
            let text = String(str("text").prefix(800))
            guard !text.isEmpty, let voice = AVSpeechSynthesisVoice(language: code + "-IN") ?? (code == "en" ? AVSpeechSynthesisVoice(language: "en-US") : nil) else {
                result(false); return
            }
            if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
            // Speak even when the ring/silent switch is on, and lower other audio meanwhile.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            let u = AVSpeechUtterance(string: text)
            u.voice = voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
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
        case "installId":
            // Random id for this install, used only for the deep-check quota and Plus. Not linked to the person.
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
