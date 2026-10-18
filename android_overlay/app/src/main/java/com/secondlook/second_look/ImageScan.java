package com.secondlook.second_look;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Rect;
import android.media.ExifInterface;
import android.net.Uri;
import android.provider.OpenableColumns;

import com.google.android.gms.tasks.Tasks;
import com.google.mlkit.vision.barcode.BarcodeScanner;
import com.google.mlkit.vision.barcode.BarcodeScannerOptions;
import com.google.mlkit.vision.barcode.BarcodeScanning;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;
import com.secondlook.engine.Json;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Reads the words in a screenshot and decodes its QR codes, entirely on the phone (Google ML Kit with
 * bundled models: nothing is downloaded or uploaded). Every method here blocks: call it on a background thread.
 */
final class ImageScan {
    static final int MAX_SIDE = 2500;            // longest side handed to ML Kit (avoids running out of memory)
    static final int MAX_TEXT = 10000;
    static final int MAX_QR = 5;
    static final int MAX_QR_LEN = 2048;
    /** Layout (document) mode: Aadhaar's secure QR is a long decimal number, so allow much longer QR values. */
    static final int MAX_QR_LEN_DOC = 16384;
    static final long MAX_FILE_BYTES = 30L * 1024 * 1024; // refuse to even open bigger "images"
    static final long MAX_SHARED_BYTES = 15L * 1024 * 1024;
    private static final long TIMEOUT_S = 30;

    private ImageScan() { }

    // ------------------------------------------------------------------ path restriction
    /**
     * Returns the file only if its real (canonical) location is inside this app's own cache or files folder.
     * image_picker and the share flow copy images there; anything else (other apps' files, symlink tricks,
     * "../" paths) is refused.
     */
    static File allowedFile(Context c, String path) {
        if (path == null || path.isEmpty() || path.length() > 4096 || path.indexOf('\0') >= 0) return null;
        try {
            File f = new File(path).getCanonicalFile();
            if (!f.isFile() || f.length() <= 0 || f.length() > MAX_FILE_BYTES) return null;
            String p = f.getPath();
            for (File root : new File[]{c.getCacheDir(), c.getFilesDir()}) {
                if (root == null) continue;
                String r = root.getCanonicalPath();
                if (!r.endsWith(File.separator)) r += File.separator;
                if (p.startsWith(r)) return f;
            }
        } catch (IOException | SecurityException e) {
            return null;
        }
        return null;
    }

    // ------------------------------------------------------------------ OCR + QR
    /**
     * Returns {"text": String, "qr": [String], "width": int, "height": int, "layout": {checked, lines, odd, samples}}
     * as JSON. Throws on any failure.
     */
    static String read(File f) throws Exception { return read(f, false); }

    /**
     * Same as {@link #read(File)}; with layout = true the text is rebuilt in reading rows (see {@link TextRows}),
     * which keeps table rows such as bank statement lines together, and longer QR values are kept.
     */
    static String read(File f, boolean layout) throws Exception {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(f.getPath(), bounds);
        int w = bounds.outWidth, h = bounds.outHeight;
        if (w <= 0 || h <= 0) throw new IOException("not an image");

        int rotation = rotationOf(f);
        int longest = Math.max(w, h);
        int sample = 1;
        while (longest / (sample * 2) >= MAX_SIDE) sample *= 2;
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inSampleSize = sample;
        opts.inPreferredConfig = Bitmap.Config.ARGB_8888;
        Bitmap bmp = BitmapFactory.decodeFile(f.getPath(), opts);
        if (bmp == null) throw new IOException("decode failed");
        int bl = Math.max(bmp.getWidth(), bmp.getHeight());
        if (bl > MAX_SIDE) {
            float k = (float) MAX_SIDE / bl;
            Bitmap scaled = Bitmap.createScaledBitmap(bmp, Math.max(1, Math.round(bmp.getWidth() * k)), Math.max(1, Math.round(bmp.getHeight() * k)), true);
            if (scaled != bmp) bmp.recycle();
            bmp = scaled;
        }

        TextRecognizer tr = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
        BarcodeScanner bs = BarcodeScanning.getClient(new BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE).build());
        try {
            InputImage img = InputImage.fromBitmap(bmp, rotation);
            Text text = Tasks.await(tr.process(img), TIMEOUT_S, TimeUnit.SECONDS);
            List<Barcode> codes = Tasks.await(bs.process(img), TIMEOUT_S, TimeUnit.SECONDS);

            String t = text == null ? "" : layout ? TextRows.build(lines(text)) : text.getText();
            if (t == null) t = "";
            if (t.length() > MAX_TEXT) t = t.substring(0, MAX_TEXT);
            List<Object> qr = new ArrayList<>();
            if (codes != null) {
                for (Barcode b : codes) {
                    if (qr.size() >= MAX_QR) break;
                    String v = b.getRawValue();
                    if (v == null || v.isEmpty()) continue;
                    int maxQr = layout ? MAX_QR_LEN_DOC : MAX_QR_LEN;
                    if (v.length() > maxQr) v = v.substring(0, maxQr);
                    if (!qr.contains(v)) qr.add(v);
                }
            }
            TextRows.LayoutCheck lc = new TextRows.LayoutCheck();
            layout(text, lc);
            boolean swap = rotation == 90 || rotation == 270;
            return Json.stringify(Json.map("text", t, "qr", qr, "width", swap ? h : w, "height", swap ? w : h, "layout", lc.toMap()));
        } finally {
            tr.close();
            bs.close();
            bmp.recycle();
        }
    }

    /** Every recognised line with its box (in the upright image's pixels), for {@link TextRows}. */
    static List<TextRows.Line> lines(Text text) {
        List<TextRows.Line> out = new ArrayList<>();
        if (text == null) return out;
        for (Text.TextBlock b : text.getTextBlocks()) {
            for (Text.Line l : b.getLines()) {
                String s = l.getText();
                if (s == null || s.trim().isEmpty()) continue;
                Rect r = l.getBoundingBox();
                out.add(r == null ? new TextRows.Line(s) : new TextRows.Line(s, r.left, r.top, r.right, r.bottom));
            }
        }
        return out;
    }

    /** Text-geometry check from the OCR word boxes (see {@link TextRows.LayoutCheck}). */
    static void layout(Text text, TextRows.LayoutCheck lc) {
        if (text == null) return;
        lc.checked = true;
        for (Text.TextBlock b : text.getTextBlocks()) {
            for (Text.Line l : b.getLines()) {
                List<TextRows.Word> words = new ArrayList<>();
                for (Text.Element e : l.getElements()) {
                    Rect r = e.getBoundingBox();
                    if (r == null) continue;
                    words.add(new TextRows.Word(e.getText(), r.top, r.bottom));
                }
                lc.addLine(words);
            }
        }
    }

    private static int rotationOf(File f) {
        try {
            switch (new ExifInterface(f.getPath()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                case ExifInterface.ORIENTATION_ROTATE_90: return 90;
                case ExifInterface.ORIENTATION_ROTATE_180: return 180;
                case ExifInterface.ORIENTATION_ROTATE_270: return 270;
                default: return 0;
            }
        } catch (IOException | RuntimeException e) {
            return 0; // PNG screenshots have no EXIF
        }
    }

    // ------------------------------------------------------------------ Share → Second Look (images)
    /**
     * Copies a shared image into cache/shared/ and returns its path, or null if it isn't an acceptable image.
     * Only content:// URIs from other apps are accepted, the system-reported type must be image/*, and the copy
     * stops at 15 MB. Older shared images are deleted first.
     */
    static String copyShared(Context c, Uri uri) {
        if (uri == null || !ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) return null;
        String auth = uri.getAuthority();
        // Never let another app make us copy out our OWN private files through one of our providers.
        if (auth == null || auth.startsWith(c.getPackageName())) return null;
        ContentResolver cr = c.getContentResolver();
        File out = null;
        try {
            String type = cr.getType(uri);
            if (type == null || !type.toLowerCase(java.util.Locale.ROOT).startsWith("image/")) return null;
            long declared = declaredSize(cr, uri);
            if (declared > MAX_SHARED_BYTES) return null;

            File dir = new File(c.getCacheDir(), "shared");
            if (!dir.isDirectory() && !dir.mkdirs()) return null;
            File[] old = dir.listFiles();
            if (old != null) {
                for (File o : old) deleteQuietly(o);
            }
            out = new File(dir, "shared_image_" + System.currentTimeMillis() + ".img");

            long total = 0;
            try (InputStream in = cr.openInputStream(uri); OutputStream os = new FileOutputStream(out)) {
                if (in == null) throw new IOException("no stream");
                byte[] buf = new byte[16384];
                int n;
                while ((n = in.read(buf)) > 0) {
                    total += n;
                    if (total > MAX_SHARED_BYTES) throw new IOException("too big");
                    os.write(buf, 0, n);
                }
            }
            // Must really decode as an image (not just claim to be one).
            BitmapFactory.Options b = new BitmapFactory.Options();
            b.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(out.getPath(), b);
            if (total == 0 || b.outWidth <= 0 || b.outHeight <= 0) throw new IOException("not an image");
            return out.getPath();
        } catch (Exception e) {
            if (out != null) deleteQuietly(out);
            return null;
        }
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    static void deleteQuietly(File f) {
        try { f.delete(); } catch (SecurityException ignored) { /* nothing more we can do */ }
    }

    static long declaredSize(ContentResolver cr, Uri uri) {
        try (Cursor q = cr.query(uri, new String[]{OpenableColumns.SIZE}, null, null, null)) {
            if (q != null && q.moveToFirst() && !q.isNull(0)) return q.getLong(0);
        } catch (RuntimeException ignored) {
            // size unknown: the copy loop still enforces the cap
        }
        return -1;
    }
}
