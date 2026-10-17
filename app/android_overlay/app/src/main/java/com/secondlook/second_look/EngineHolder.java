package com.secondlook.second_look;

import android.content.Context;

import com.secondlook.engine.Engine;
import com.secondlook.engine.Json;
import com.secondlook.engine.LibPhoneLookup;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** One shared, lazily loaded engine for the app, the SMS receiver and the call screening service. */
final class EngineHolder {
    private static volatile Engine engine;
    private static volatile LibPhoneLookup phone;

    /** Numbers many Second Look users reported (downloaded list, matched on the phone; caller numbers never leave it). */
    private static volatile Map<String, Object> community;
    private static final long MAX_LIST_BYTES = 20L * 1024 * 1024;

    private EngineHolder() { }

    private static File communityFile(Context c) { return new File(c.getFilesDir(), "community.json"); }

    /** Saves a new community list from our server. Rejects anything that isn't the expected shape. */
    static boolean saveCommunity(Context c, String json) {
        if (json == null || json.length() > MAX_LIST_BYTES) return false;
        try {
            Map<String, Object> o = Json.obj(Json.parse(json));
            Map<String, Object> nums = Json.obj(o.get("numbers"));
            Map<String, Object> clean = new HashMap<>();
            for (Map.Entry<String, Object> e : nums.entrySet()) {
                if (!e.getKey().matches("^\\+[1-9]\\d{6,14}$")) continue;
                Map<String, Object> v = Json.obj(e.getValue());
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("s", (int) Math.max(0, Math.min(1_000_000, n(v.get("s")))));
                m.put("p", (int) Math.max(0, Math.min(1_000_000, n(v.get("p")))));
                Object t = v.get("t");
                if (t instanceof String && ((String) t).matches("^[a-z_]{1,30}$")) m.put("t", t);
                clean.put(e.getKey(), m);
            }
            File f = communityFile(c), tmp = new File(c.getFilesDir(), "community.json.tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(Json.stringify(Json.map("numbers", clean)).getBytes(StandardCharsets.UTF_8));
            }
            if (!tmp.renameTo(f)) return false;
            community = clean;
            return true;
        } catch (RuntimeException | IOException e) {
            return false;
        }
    }

    private static Map<String, Object> community(Context c) {
        if (community == null) {
            synchronized (EngineHolder.class) {
                if (community == null) {
                    Map<String, Object> m = Collections.emptyMap();
                    File f = communityFile(c);
                    if (f.exists() && f.length() < MAX_LIST_BYTES) {
                        try (InputStream in = new FileInputStream(f)) {
                            ByteArrayOutputStream out = new ByteArrayOutputStream();
                            byte[] buf = new byte[65536];
                            int n;
                            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                            m = Json.obj(Json.obj(Json.parse(out.toString("UTF-8"))).get("numbers"));
                        } catch (RuntimeException | IOException e) {
                            m = Collections.emptyMap();
                        }
                    }
                    community = m;
                }
            }
        }
        return community;
    }

    private static int n(Object o) { return o instanceof Number ? ((Number) o).intValue() : 0; }

    static int communityCount(Context c) { return community(c).size(); }

    static Engine get(Context c) {
        if (engine == null) {
            synchronized (EngineHolder.class) {
                if (engine == null) {
                    // Refuse to run with modified rules or a re-signed copy of the app.
                    if (!Security.assetsIntact(c) || !Security.signatureOk(c)) {
                        throw new SecurityException("This copy of Second Look has been modified. Install it again from the official store.");
                    }
                    phone = new LibPhoneLookup(asset(c, "secondlook/phone_data.json"));
                    engine = new Engine(asset(c, "secondlook/rules.json"), phone, "IN");
                }
            }
        }
        return engine;
    }

    static String e164(Context c, String number) {
        get(c);
        Map<String, Object> d = phone.lookup(number, "IN", "none", "organisation");
        return d == null ? null : (String) d.get("e164");
    }

    /** True when an SMS sender / caller looks like a phone number (not a business header such as VK-HDFCBK). */
    static boolean isPhoneSender(String raw) {
        return raw != null && raw.trim().matches("^[+\\d][\\d\\s()-]{6,}$");
    }

    /**
     * The key Second Look files a sender under: E.164 for phone numbers (digits only if it can't be parsed),
     * the cleaned upper-case header for business senders. Null when there is nothing usable.
     */
    static String senderKey(Context c, String raw) {
        if (raw == null) return null;
        String s = raw.trim();
        if (s.isEmpty() || s.length() > 64) return null;
        if (isPhoneSender(s)) {
            String e = null;
            try { e = e164(c, s); } catch (RuntimeException ignored) { /* fall back to the digits */ }
            if (e == null || e.isEmpty()) e = Security.cleanNumber(s);
            return e.isEmpty() ? null : e;
        }
        String h = s.toUpperCase(java.util.Locale.ROOT).replaceAll("[^A-Z0-9-]", "");
        if (h.length() > 20) h = h.substring(0, 20);
        return h.isEmpty() ? null : h;
    }

    /** Number check plus the user's own reports (kept on the phone). */
    @SuppressWarnings("unchecked")
    static Map<String, Object> analyzeNumber(Context c, String number) {
        Engine e = get(c);
        List<Map<String, Object>> extra = new ArrayList<>();
        Map<String, Object> rep = Store.findReport(c, e164(c, number));
        if (rep != null) {
            boolean safe = "safe".equals(rep.get("kind"));
            extra.add(Json.map("id", "blocked_by_you", "title", "You marked this number (" + rep.get("label") + ")",
                    "detail", "You marked this number earlier. Second Look keeps that list only on this phone.", "weight", safe ? -20 : 50));
        }
        String n164 = e164(c, number);
        if (n164 != null && !"1".equals(Store.str(c, "pref_community_off"))) {
            Object hit = community(c).get(n164);
            if (hit != null) {
                Map<String, Object> v = Json.obj(hit);
                Map<String, Integer> byType = new HashMap<>();
                int scam = (int) n(v.get("s")), spam = (int) n(v.get("p"));
                if (scam > 0) byType.put(v.get("t") instanceof String ? (String) v.get("t") : "scam", scam);
                if (spam > 0) byType.put("spam", spam);
                extra.addAll(e.communityReasons(byType));
            }
        }
        return e.analyzeNumber(number, extra);
    }

    private static String asset(Context c, String name) {
        try (InputStream in = c.getAssets().open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException ex) {
            throw new IllegalStateException("Missing asset " + name + " — run tool/setup.sh", ex);
        }
    }
}
