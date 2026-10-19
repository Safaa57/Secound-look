package com.secondlook.second_look;

import android.content.Context;
import android.content.Intent;
import android.os.Build;

import com.secondlook.engine.Json;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Pattern;

/**
 * Private crash log (v1.6). Kept only on this phone in getFilesDir()/crash_log.json (newest 20 entries), never
 * uploaded; the user can share it themselves from Settings. Messages and stacks are cleaned before they are stored:
 * links, e-mail addresses, phone-like numbers and any run of 6+ digits are replaced, so no SMS text, codes or numbers
 * end up in the report. Nothing in this class may ever throw: every entry point swallows all errors.
 */
final class CrashLog {
    static final String APP_VERSION = "1.6.0";
    private static final String FILE = "crash_log.json";
    private static final String TMP = "crash_log.json.tmp";
    private static final int MAX_ENTRIES = 20;
    private static final int MAX_MESSAGE = 500;
    private static final int MAX_STACK = 6000;
    private static final int MAX_FILE_BYTES = 512 * 1024;

    private static final Object LOCK = new Object();
    private static final AtomicBoolean INSTALLED = new AtomicBoolean(false);
    /** Set while the handler is recording, so a failure inside it can't loop. */
    private static final AtomicBoolean RECORDING = new AtomicBoolean(false);

    private static final Pattern URL = Pattern.compile(
            "(?i)\\b(?:[a-z][a-z0-9+.-]{1,15}://|www\\.)[^\\s\"'<>()\\[\\]{}]+");
    /** Bare web addresses ("kyc-verify-update.top/login"). Lower-case only, and io/app/me/co/net are left out, so class and package names in stacks (java.io, java.net, Store.java) stay readable. */
    private static final Pattern DOMAIN = Pattern.compile(
            "\\b[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.(?:com|in|org|info|top|xyz|online|site|live|club|shop|link|ly|biz|cc|tk|ml|ga|cf|gq|icu|vip|buzz|cn|ru|store|website|space|fun|click|page|co\\.in|org\\.in|net\\.in)\\b(?:/[^\\s\"'<>]*)?");
    private static final Pattern EMAIL = Pattern.compile("(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}");
    /** Phone numbers written with spaces/dashes ("+91 98765 43210"): 8+ digits with separators in between. */
    private static final Pattern PHONE = Pattern.compile("\\+?\\d(?:[ \\-().]{0,2}\\d){7,}");
    private static final Pattern DIGITS = Pattern.compile("\\d{6,}");

    private CrashLog() { }

    // ------------------------------------------------------------------ uncaught exception handler
    /**
     * Installs (once per process) a default uncaught exception handler that records the crash as source 'native'
     * and then hands it to the previous handler (so Android still shows / reports it as before).
     */
    static void install(Context context) {
        try {
            if (context == null || !INSTALLED.compareAndSet(false, true)) return;
            final Context app = appContext(context);
            final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
            Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
                try {
                    if (RECORDING.compareAndSet(false, true)) {
                        try {
                            String where = thread == null ? "" : " (thread " + safeThreadName(thread) + ")";
                            record(app, "native", describe(error) + where, stackOf(error));
                        } finally {
                            RECORDING.set(false);
                        }
                    }
                } catch (Throwable ignored) {
                    // never let the logger hide the real crash
                }
                if (previous != null) {
                    previous.uncaughtException(thread, error);
                } else {
                    // No previous handler (unusual on Android): end the process as the platform would.
                    try { android.os.Process.killProcess(android.os.Process.myPid()); } catch (Throwable ignored) { }
                    System.exit(10);
                }
            });
        } catch (Throwable ignored) {
            // e.g. a SecurityManager refusing the handler: run without it
        }
    }

    private static String safeThreadName(Thread t) {
        try {
            // Thread names are ours or the platform's; still clean them like everything else.
            return redact(t.getName());
        } catch (Throwable e) {
            return "?";
        }
    }

    private static Context appContext(Context c) {
        try {
            Context a = c.getApplicationContext();
            return a == null ? c : a;
        } catch (Throwable e) {
            return c;
        }
    }

    // ------------------------------------------------------------------ public API (all never throw)
    /** Adds one entry (source 'dart' or 'native'). */
    static void record(Context context, String source, String message, String stack) {
        try {
            if (context == null) return;
            Context app = appContext(context);
            Map<String, Object> e = new LinkedHashMap<>();
            e.put("at", System.currentTimeMillis());
            e.put("source", "dart".equals(source) ? "dart" : "native");
            e.put("message", cap(redact(message), MAX_MESSAGE));
            e.put("stack", cap(redact(stack), MAX_STACK));
            e.put("app", APP_VERSION);
            e.put("os", osLabel());
            e.put("device", deviceLabel());
            synchronized (LOCK) {
                List<Object> list = readList(app);
                list.add(0, e);
                while (list.size() > MAX_ENTRIES) list.remove(list.size() - 1);
                writeAtomic(app, Json.stringify(list));
            }
        } catch (Throwable ignored) {
            // the crash log is best effort
        }
    }

    /** Entries, newest first ([] if none or unreadable). */
    static List<Object> list(Context context) {
        try {
            if (context == null) return new ArrayList<>();
            synchronized (LOCK) { return readList(appContext(context)); }
        } catch (Throwable e) {
            return new ArrayList<>();
        }
    }

    static String listJson(Context context) {
        try {
            return Json.stringify(list(context));
        } catch (Throwable e) {
            return "[]";
        }
    }

    /** Removes the log (and any half-written temp file). */
    static void clear(Context context) {
        try {
            if (context == null) return;
            synchronized (LOCK) {
                File dir = appContext(context).getFilesDir();
                if (dir == null) return;
                deleteQuietly(new File(dir, FILE));
                deleteQuietly(new File(dir, TMP));
            }
        } catch (Throwable ignored) {
            // nothing to do
        }
    }

    /** Plain-text report for the user to share (already redacted; cleaned again here to be safe). */
    static String report(Context context) {
        StringBuilder b = new StringBuilder();
        try {
            List<Object> entries = list(context);
            b.append("Second Look crash report\n");
            b.append("App ").append(APP_VERSION).append(" | ").append(osLabel()).append(" | ").append(deviceLabel()).append('\n');
            b.append("Entries: ").append(entries.size()).append(" (newest first)\n");
            b.append("This report contains no messages, numbers or links.\n");
            SimpleDateFormat fmt = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss 'UTC'", Locale.ROOT);
            fmt.setTimeZone(TimeZone.getTimeZone("UTC"));
            int n = 0;
            for (Object o : entries) {
                if (!(o instanceof Map)) continue;
                Map<?, ?> m = (Map<?, ?>) o;
                n++;
                String when = "?";
                Object at = m.get("at");
                if (at instanceof Number) {
                    try { when = fmt.format(new Date(((Number) at).longValue())); } catch (Throwable ignored) { }
                }
                b.append("\n#").append(n).append(" | ").append(when)
                        .append(" | ").append(redact(str(m.get("source"))))
                        .append(" · app ").append(redact(str(m.get("app"))))
                        .append(" | ").append(redact(str(m.get("os"))))
                        .append(" | ").append(redact(str(m.get("device")))).append('\n');
                b.append(cap(redact(str(m.get("message"))), MAX_MESSAGE)).append('\n');
                String stack = cap(redact(str(m.get("stack"))), MAX_STACK);
                if (!stack.isEmpty()) b.append(stack).append('\n');
            }
        } catch (Throwable ignored) {
            // return what we have
        }
        return b.toString();
    }

    /** Opens the system share sheet with the report. False if there's nothing to share or no app can take it. */
    static boolean share(Context context) {
        try {
            if (context == null || list(context).isEmpty()) return false;
            Intent send = new Intent(Intent.ACTION_SEND);
            send.setType("text/plain");
            send.putExtra(Intent.EXTRA_SUBJECT, "Second Look crash report");
            send.putExtra(Intent.EXTRA_TEXT, report(context));
            Intent chooser = Intent.createChooser(send, "Share crash report");
            if (!(context instanceof android.app.Activity)) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(chooser);
            return true;
        } catch (Throwable e) {
            return false;
        }
    }

    // ------------------------------------------------------------------ redaction / formatting
    /** Removes links, e-mail addresses, phone-like numbers and runs of 6+ digits. */
    static String redact(String s) {
        if (s == null || s.isEmpty()) return "";
        try {
            String out = URL.matcher(s).replaceAll("[link]");
            out = EMAIL.matcher(out).replaceAll("[email]");
            out = DOMAIN.matcher(out).replaceAll("[link]");
            out = PHONE.matcher(out).replaceAll("[number]");
            out = DIGITS.matcher(out).replaceAll("[number]");
            return out;
        } catch (Throwable e) {
            // Regex trouble (e.g. a huge input): fall back to masking every digit and dropping the text after "://".
            try {
                StringBuilder b = new StringBuilder(Math.min(s.length(), MAX_STACK));
                for (int i = 0; i < s.length() && b.length() < MAX_STACK; i++) {
                    char c = s.charAt(i);
                    b.append(c >= '0' && c <= '9' ? '#' : c);
                }
                String t = b.toString();
                int k = t.indexOf("://");
                return k >= 0 ? t.substring(0, k) + "[link]" : t;
            } catch (Throwable e2) {
                return "";
            }
        }
    }

    private static String cap(String s, int max) {
        if (s == null) return "";
        if (s.length() <= max) return s;
        int end = max;
        if (end > 0 && Character.isHighSurrogate(s.charAt(end - 1))) end--;
        return s.substring(0, end);
    }

    private static String str(Object o) { return o == null ? "" : String.valueOf(o); }

    private static String describe(Throwable t) {
        try {
            if (t == null) return "Unknown error";
            String msg = t.getMessage();
            return t.getClass().getName() + (msg == null ? "" : ": " + msg);
        } catch (Throwable e) {
            return "Unknown error";
        }
    }

    private static String stackOf(Throwable t) {
        if (t == null) return "";
        try {
            StringWriter w = new StringWriter();
            PrintWriter p = new PrintWriter(w);
            t.printStackTrace(p);
            p.flush();
            // Cut early: cleaning a huge trace costs time while the process is going down.
            String s = w.toString();
            return s.length() > MAX_STACK * 2 ? s.substring(0, MAX_STACK * 2) : s;
        } catch (Throwable e) {
            return "";
        }
    }

    static String osLabel() {
        try {
            String release = Build.VERSION.RELEASE;
            return "Android " + (release == null ? "?" : release) + " / SDK " + Build.VERSION.SDK_INT;
        } catch (Throwable e) {
            return "Android";
        }
    }

    static String deviceLabel() {
        try {
            String maker = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER.trim();
            String model = Build.MODEL == null ? "" : Build.MODEL.trim();
            String d = (maker + " " + model).trim();
            return d.isEmpty() ? "unknown" : cap(d, 80);
        } catch (Throwable e) {
            return "unknown";
        }
    }

    // ------------------------------------------------------------------ file I/O (private app storage)
    private static List<Object> readList(Context app) {
        List<Object> out = new ArrayList<>();
        try {
            File dir = app.getFilesDir();
            if (dir == null) return out;
            File f = new File(dir, FILE);
            if (!f.isFile() || f.length() <= 0 || f.length() > MAX_FILE_BYTES) return out;
            String text;
            try (InputStream in = new FileInputStream(f)) {
                ByteArrayOutputStream buf = new ByteArrayOutputStream((int) f.length());
                byte[] chunk = new byte[8192];
                int r;
                while ((r = in.read(chunk)) > 0) {
                    buf.write(chunk, 0, r);
                    if (buf.size() > MAX_FILE_BYTES) return out;
                }
                text = new String(buf.toByteArray(), StandardCharsets.UTF_8);
            }
            Object parsed = Json.parse(text);
            if (!(parsed instanceof List)) return out;
            for (Object o : (List<?>) parsed) {
                if (o instanceof Map && out.size() < MAX_ENTRIES) out.add(o);
            }
        } catch (Throwable e) {
            // corrupt or unreadable: start over
            return new ArrayList<>();
        }
        return out;
    }

    /** Writes crash_log.json.tmp, syncs it, then renames it over crash_log.json (atomic on the same filesystem). */
    private static void writeAtomic(Context app, String json) {
        File dir;
        try { dir = app.getFilesDir(); } catch (Throwable e) { return; }
        if (dir == null) return;
        File tmp = new File(dir, TMP);
        File target = new File(dir, FILE);
        boolean ok = false;
        try {
            try (FileOutputStream out = new FileOutputStream(tmp, false)) {
                out.write(json.getBytes(StandardCharsets.UTF_8));
                out.flush();
                try { out.getFD().sync(); } catch (Throwable ignored) { /* best effort */ }
            }
            ok = tmp.renameTo(target);
        } catch (Throwable ignored) {
            ok = false;
        } finally {
            if (!ok) deleteQuietly(tmp);
        }
    }

    private static void deleteQuietly(File f) {
        try { if (f != null && f.exists()) f.delete(); } catch (Throwable ignored) { }
    }
}
