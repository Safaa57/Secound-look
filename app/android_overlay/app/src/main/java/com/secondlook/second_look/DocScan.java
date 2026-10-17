package com.secondlook.second_look;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import com.google.android.gms.tasks.Tasks;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;
import com.secondlook.engine.Json;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.PublicKey;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * "Check a document": copies the PDF or photo the user picks into a private cache folder, reads the PDF's words on
 * the phone (Android's PdfRenderer + ML Kit, models bundled), and checks Aadhaar QR signatures. Nothing is uploaded,
 * nothing is stored, nothing is logged, and the cache folder is emptied when the user leaves the screen.
 * Every method here blocks: call it on a background thread.
 */
final class DocScan {
    static final long MAX_DOC_BYTES = 25L * 1024 * 1024;
    static final int MAX_PDF_PAGES = 6;
    static final int PDF_SIDE = 2000;           // longest side of a rendered page, in pixels
    static final int MAX_DOC_TEXT = 50000;
    static final int MAX_INPUT_CHARS = 1_000_000; // analyzeDocument JSON, before parsing
    static final int MAX_NAME = 120;
    static final int MAX_CERTS = 8;
    static final int MAX_CERT_BYTES = 64 * 1024;
    static final int MAX_SIGNED_BYTES = 1024 * 1024;
    static final int MAX_SIGNATURE_BYTES = 2048;
    private static final long TIMEOUT_S = 30;

    private DocScan() { }

    /** A failure the UI can explain: code is one of too_large, unsupported, unreadable, locked. */
    static final class DocError extends Exception {
        final String code;

        DocError(String code, String message) {
            super(message);
            this.code = code;
        }
    }

    static DocError tooLarge() { return new DocError("too_large", "This file is bigger than 25 MB. Choose a smaller file or a photo of the page."); }

    static DocError unsupported() { return new DocError("unsupported", "Choose a PDF or a photo of the document."); }

    static DocError unreadable() { return new DocError("unreadable", "Couldn't open this file. It may be damaged."); }

    static DocError locked() { return new DocError("locked", "This PDF is protected with a password. Open it, save a copy without the password, and try again."); }

    static File docsDir(Context c) { return new File(c.getCacheDir(), "docs"); }

    /** Deletes every copied document. */
    static void clearCache(Context c) {
        File dir = docsDir(c);
        File[] old = dir.listFiles();
        if (old != null) for (File o : old) ImageScan.deleteQuietly(o);
        ImageScan.deleteQuietly(dir);
    }

    // ------------------------------------------------------------------ picking
    /**
     * Copies the document the user picked (ACTION_OPEN_DOCUMENT) into cache/docs/ and returns
     * {"path", "name", "mime", "size"}. Only PDFs and images, at most 25 MB, and the copy must really be one.
     */
    static Map<String, Object> copyPicked(Context c, Uri uri) throws DocError {
        if (uri == null || !ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) throw unsupported();
        String auth = uri.getAuthority();
        if (auth == null || auth.startsWith(c.getPackageName())) throw unsupported(); // never our own files
        ContentResolver cr = c.getContentResolver();
        String mime;
        try {
            mime = cr.getType(uri);
        } catch (RuntimeException e) {
            mime = null;
        }
        if (mime != null) {
            int semi = mime.indexOf(';');
            mime = (semi >= 0 ? mime.substring(0, semi) : mime).trim().toLowerCase(Locale.ROOT);
        }
        String name = displayName(cr, uri);
        // Some providers report PDFs as a generic type; the copy is checked for "%PDF-" below anyway.
        if ((mime == null || "application/octet-stream".equals(mime)) && name.toLowerCase(Locale.ROOT).endsWith(".pdf")) {
            mime = "application/pdf";
        }
        boolean pdf = "application/pdf".equals(mime);
        boolean image = mime != null && mime.startsWith("image/") && mime.length() < 64;
        if (!pdf && !image) throw unsupported();
        if (ImageScan.declaredSize(cr, uri) > MAX_DOC_BYTES) throw tooLarge();

        File dir = docsDir(c);
        clearCache(c); // keep only the latest document
        if (!dir.isDirectory() && !dir.mkdirs()) throw unreadable();
        String ext = pdf ? "pdf" : "image/png".equals(mime) ? "png" : "jpg";
        File out = new File(dir, "doc_" + System.currentTimeMillis() + "." + ext);

        long total = 0;
        boolean ok = false;
        try {
            try (InputStream in = cr.openInputStream(uri); OutputStream os = new FileOutputStream(out)) {
                if (in == null) throw unreadable();
                byte[] buf = new byte[65536];
                int n;
                while ((n = in.read(buf)) > 0) {
                    total += n;
                    if (total > MAX_DOC_BYTES) throw tooLarge();
                    os.write(buf, 0, n);
                }
            }
            if (total == 0) throw unreadable();
            // It must really be what it claims to be.
            if (pdf ? !looksLikePdf(out) : !decodesAsImage(out)) throw unsupported();
            ok = true;
            return Json.map("path", out.getPath(), "name", name, "mime", mime, "size", total);
        } catch (IOException | RuntimeException e) {
            throw unreadable();
        } finally {
            if (!ok) ImageScan.deleteQuietly(out);
        }
    }

    private static boolean looksLikePdf(File f) {
        byte[] head = new byte[1024];
        int n;
        try (InputStream in = new FileInputStream(f)) {
            n = in.read(head);
        } catch (IOException e) {
            return false;
        }
        return n > 4 && new String(head, 0, n, StandardCharsets.ISO_8859_1).contains("%PDF-");
    }

    private static boolean decodesAsImage(File f) {
        BitmapFactory.Options b = new BitmapFactory.Options();
        b.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(f.getPath(), b);
        return b.outWidth > 0 && b.outHeight > 0;
    }

    /** The file's name for display only: control and bidi-override characters and path separators removed. */
    private static String displayName(ContentResolver cr, Uri uri) {
        String n = null;
        try (Cursor q = cr.query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (q != null && q.moveToFirst() && !q.isNull(0)) n = q.getString(0);
        } catch (RuntimeException ignored) {
            // name unknown
        }
        return cleanName(n);
    }

    static String cleanName(String n) {
        if (n == null) return "document";
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < n.length() && b.length() < MAX_NAME; i++) {
            char ch = n.charAt(i);
            if (ch < 0x20 || ch == 0x7f || ch == '/' || ch == '\\') continue;
            if ((ch >= 0x202a && ch <= 0x202e) || (ch >= 0x2066 && ch <= 0x2069) || ch == 0x200e || ch == 0x200f) continue;
            b.append(ch);
        }
        String s = capText(b.toString().trim(), MAX_NAME);
        return s.isEmpty() ? "document" : s;
    }

    // ------------------------------------------------------------------ reading a PDF
    /** Returns {"text", "pages", "pagesRead", "ocr": true}. Text is rebuilt in reading rows, at most 50,000 characters. */
    static String readPdf(File f) throws DocError {
        ParcelFileDescriptor pfd = null;
        PdfRenderer renderer = null;
        TextRecognizer tr = null;
        try {
            try {
                pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
                renderer = new PdfRenderer(pfd);
            } catch (SecurityException e) {
                throw locked(); // PdfRenderer refuses password-protected PDFs this way
            } catch (IOException | RuntimeException e) {
                throw unreadable();
            }
            int pages = renderer.getPageCount();
            if (pages <= 0) throw unreadable();
            int toRead = Math.min(pages, MAX_PDF_PAGES);
            tr = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
            StringBuilder sb = new StringBuilder();
            int read = 0;
            for (int i = 0; i < toRead && sb.length() < MAX_DOC_TEXT; i++) {
                String pageText;
                try {
                    pageText = readPage(renderer, i, tr);
                } catch (Exception | OutOfMemoryError e) {
                    if (read == 0) throw unreadable();
                    break; // keep what the earlier pages gave
                }
                read++;
                if (!pageText.isEmpty()) {
                    if (sb.length() > 0) sb.append("\n\n");
                    sb.append(pageText);
                }
            }
            return Json.stringify(Json.map("text", capText(sb.toString(), MAX_DOC_TEXT), "pages", pages, "pagesRead", read, "ocr", true));
        } catch (DocError e) {
            throw e;
        } catch (RuntimeException | OutOfMemoryError e) {
            throw unreadable();
        } finally {
            if (tr != null) tr.close();
            if (renderer != null) {
                try { renderer.close(); } catch (RuntimeException ignored) { /* closing anyway */ }
            }
            if (pfd != null) {
                try { pfd.close(); } catch (IOException ignored) { /* closing anyway */ }
            }
        }
    }

    private static String readPage(PdfRenderer renderer, int index, TextRecognizer tr) throws Exception {
        Bitmap bmp;
        try (PdfRenderer.Page page = renderer.openPage(index)) {
            int pw = Math.max(1, page.getWidth()), ph = Math.max(1, page.getHeight());
            float k = (float) PDF_SIDE / Math.max(pw, ph);
            int bw = Math.max(1, Math.min(PDF_SIDE, Math.round(pw * k)));
            int bh = Math.max(1, Math.min(PDF_SIDE, Math.round(ph * k)));
            bmp = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888);
            bmp.eraseColor(Color.WHITE); // PDFs draw on a transparent page; OCR needs dark text on white
            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
        }
        try {
            Text text = Tasks.await(tr.process(InputImage.fromBitmap(bmp, 0)), TIMEOUT_S, TimeUnit.SECONDS);
            return TextRows.build(ImageScan.lines(text));
        } finally {
            bmp.recycle();
        }
    }

    // ------------------------------------------------------------------ analyzeDocument input
    /** Parses the Dart side's JSON for Engine.analyzeDocument and caps its text. Throws on bad input. */
    static Map<String, Object> documentInput(String json) {
        if (json == null || json.length() > MAX_INPUT_CHARS) throw new IllegalArgumentException("input");
        Map<String, Object> in = Json.obj(Json.parse(json));
        if (in == null) throw new IllegalArgumentException("input");
        Object t = in.get("text");
        in.put("text", t instanceof String ? capText((String) t, MAX_DOC_TEXT) : "");
        return in;
    }

    // ------------------------------------------------------------------ signatures (Aadhaar secure QR)
    /**
     * True if signature is a valid SHA256withRSA (PKCS#1 v1.5) signature of data under the public key of ANY of the
     * DER X.509 certificates. Never throws: bad input is simply false. Certificate dates are not checked (UIDAI keeps
     * using older keys for QR codes printed years ago).
     */
    /** TRUE = valid, FALSE = checked against a usable RSA key and failed, null = no usable key ("not checked"). */
    static Boolean verifySignature(Object data, Object signature, Object certs) {
        if (!(data instanceof byte[]) || !(signature instanceof byte[]) || !(certs instanceof List)) return false;
        byte[] d = (byte[]) data, s = (byte[]) signature;
        if (d.length == 0 || d.length > MAX_SIGNED_BYTES || s.length == 0 || s.length > MAX_SIGNATURE_BYTES) return false;
        CertificateFactory cf;
        try {
            cf = CertificateFactory.getInstance("X.509");
        } catch (GeneralSecurityException | RuntimeException e) {
            return false;
        }
        int tried = 0;
        boolean usable = false;
        for (Object o : (List<?>) certs) {
            if (tried++ >= MAX_CERTS) break;
            if (!(o instanceof byte[])) continue;
            byte[] der = (byte[]) o;
            if (der.length == 0 || der.length > MAX_CERT_BYTES) continue;
            try {
                X509Certificate cert = (X509Certificate) cf.generateCertificate(new ByteArrayInputStream(der));
                PublicKey key = cert.getPublicKey();
                if (key == null || !"RSA".equalsIgnoreCase(key.getAlgorithm())) continue;
                java.security.Signature v = java.security.Signature.getInstance("SHA256withRSA");
                v.initVerify(key);
                usable = true;
                v.update(d);
                if (v.verify(s)) return true;
            } catch (GeneralSecurityException | RuntimeException e) {
                // not a usable certificate or a malformed signature: try the next one
            }
        }
        return usable ? Boolean.FALSE : null;
    }

    /** Caps text without cutting a character in half. */
    static String capText(String s, int max) {
        if (s == null || s.length() <= max) return s;
        int end = max;
        if (end > 0 && Character.isHighSurrogate(s.charAt(end - 1))) end--;
        return s.substring(0, end);
    }
}
