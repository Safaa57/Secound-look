package com.secondlook.second_look;

import android.content.Context;

import com.secondlook.engine.Json;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/** Hindi / Kannada texts for notifications, from assets/secondlook/i18n.json (shared with the Flutter UI). English is the fallback. */
final class I18n {
    private static final String ASSET = "secondlook/i18n.json";
    private static volatile Map<String, Object> data;

    private I18n() { }

    /** "hi", "kn", or "" for English. */
    static String lang(Context c) {
        String l = Store.str(c, "pref_language");
        return "hi".equals(l) || "kn".equals(l) ? l : "";
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> data(Context c) {
        Map<String, Object> d = data;
        if (d != null) return d;
        synchronized (I18n.class) {
            if (data != null) return data;
            Map<String, Object> loaded;
            try (InputStream in = c.getApplicationContext().getAssets().open(ASSET)) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[16384];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                Object o = Json.parse(new String(out.toByteArray(), StandardCharsets.UTF_8));
                loaded = o instanceof Map ? (Map<String, Object>) o : java.util.Collections.<String, Object>emptyMap();
            } catch (Exception e) {
                loaded = java.util.Collections.emptyMap(); // English still works
            }
            data = loaded;
            return loaded;
        }
    }

    @SuppressWarnings("unchecked")
    private static Object lookup(Context c, String section, String key) {
        String l = lang(c);
        if (l.isEmpty() || key == null) return null;
        Object sec = data(c).get(section);
        if (!(sec instanceof Map)) return null;
        Object m = ((Map<String, Object>) sec).get(l);
        return m instanceof Map ? ((Map<String, Object>) m).get(key) : null;
    }

    /** Translates an English notification string ("notify" section) and fills {placeholders} given as name, value pairs. */
    static String t(Context c, String english, String... args) {
        Object v = lookup(c, "notify", english);
        String s = v instanceof String && !((String) v).isEmpty() ? (String) v : english;
        for (int i = 0; i + 1 < args.length; i += 2) s = s.replace("{" + args[i] + "}", args[i + 1] == null ? "" : args[i + 1]);
        return s;
    }

    /** Translated reason title by engine reason id (sender_* falls back to the plain id). */
    static String reason(Context c, String id, String fallbackTitle) {
        Object v = lookup(c, "reasons", id);
        if (!(v instanceof List) && id != null && id.startsWith("sender_")) v = lookup(c, "reasons", id.substring(7));
        if (v instanceof List && !((List<?>) v).isEmpty() && ((List<?>) v).get(0) instanceof String) return (String) ((List<?>) v).get(0);
        return fallbackTitle;
    }

    /** Translated caller label by caller kind (person, business, telemarketer, bot, foreign, spoofed, scam, unknown). */
    static String caller(Context c, String kind, String fallback) {
        Object v = lookup(c, "callers", kind);
        return v instanceof String && !((String) v).isEmpty() ? (String) v : fallback;
    }
}
