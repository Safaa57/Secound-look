package com.secondlook.second_look;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;

import com.secondlook.engine.Json;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Everything Second Look remembers: kept only on the phone, encrypted with a Keystore key, excluded from backups. */
final class Store {
    private static final String FILE = "secondlook";
    private static final int MAX_HISTORY = 300;
    private static final int MAX_ACTIONS = 500;
    private static final int MAX_SEEN = 5000;

    private Store() { }

    static SharedPreferences prefs(Context c) {
        return c.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    static boolean bool(Context c, String k) { return prefs(c).getBoolean(k, false); }

    static void put(Context c, String k, boolean v) { prefs(c).edit().putBoolean(k, v).apply(); }

    /** Text values are always stored encrypted (AES-256-GCM, key in the Android Keystore). */
    static String str(Context c, String k) {
        String v = Security.decrypt(prefs(c).getString(k, null));
        return v == null ? "" : v;
    }

    static void put(Context c, String k, String v) { prefs(c).edit().putString(k, Security.encrypt(v == null ? "" : v)).apply(); }

    /** An 'on'/'off' preference (pref_<key>); anything else (missing, '') means the default. */
    static boolean prefOn(Context c, String key, boolean defaultOn) {
        String v;
        try { v = str(c, "pref_" + key); } catch (RuntimeException e) { v = ""; }
        if ("on".equals(v)) return true;
        if ("off".equals(v)) return false;
        return defaultOn;
    }

    // ---------- history ----------
    static synchronized List<Object> history(Context c) {
        String s = Security.decrypt(prefs(c).getString("history", null));
        if (s == null) return new ArrayList<>();
        try { return Json.arr(Json.parse(s)); } catch (RuntimeException e) { return new ArrayList<>(); }
    }

    private static void saveHistory(Context c, List<Object> h) {
        prefs(c).edit().putString("history", Security.encrypt(Json.stringify(h))).apply();
    }

    /** Saves an alert and returns its id. */
    static String addHistory(Context c, String kind, String title, Map<String, Object> result) {
        return addHistory(c, kind, title, result, null);
    }

    /**
     * Saves an alert and returns its id. extra adds the v1.3 fields (number, senderType, firstTime, preview,
     * userAction, test); null values are left out.
     */
    @SuppressWarnings("unchecked")
    static synchronized String addHistory(Context c, String kind, String title, Map<String, Object> result, Map<String, Object> extra) {
        List<Object> h = history(c);
        String id = UUID.randomUUID().toString();
        Map<String, Object> level = (Map<String, Object>) result.get("level");
        Object reasonList = result.get("reasons");
        String summary = "";
        if (reasonList instanceof List) {
            for (Object o : (List<Object>) reasonList) {
                Map<String, Object> r = Json.obj(o);
                if (r.get("weight") instanceof Number && Json.num(r.get("weight")) > 0) { summary = String.valueOf(r.get("title")); break; }
            }
        }
        Map<String, Object> entry = Json.map("id", id, "at", System.currentTimeMillis(), "kind", kind, "title", title,
                "summary", summary, "level", level == null ? null : level.get("key"), "score", result.get("score"), "result", result);
        if (extra != null) {
            for (Map.Entry<String, Object> e : extra.entrySet()) {
                if (e.getValue() != null && !entry.containsKey(e.getKey())) entry.put(e.getKey(), e.getValue());
            }
        }
        h.add(0, entry);
        while (h.size() > MAX_HISTORY) h.remove(h.size() - 1);
        saveHistory(c, h);
        return id;
    }

    /** Records what the user did with one alert (Block / Spam / Fraud / Safe / comment). False if the alert is gone. */
    static synchronized boolean setUserAction(Context c, String historyId, Map<String, Object> action) {
        if (historyId == null) return false;
        List<Object> h = history(c);
        for (Object o : h) {
            Map<String, Object> m = Json.obj(o);
            if (historyId.equals(m.get("id"))) {
                Object prev = m.get("userAction");
                if ("comment".equals(action.get("action")) && prev instanceof Map) {
                    // A note on its own keeps what the user already chose (Block, Spam...) and adds the comment.
                    Object prevAction = Json.obj(prev).get("action");
                    if (prevAction != null) {
                        action = new LinkedHashMap<>(action);
                        action.put("action", prevAction);
                    }
                }
                m.put("userAction", action);
                saveHistory(c, h);
                return true;
            }
        }
        return false;
    }

    static synchronized void clearHistory(Context c) { prefs(c).edit().remove("history").apply(); }

    /** Removes the alerts with these ids; returns how many were removed. */
    static synchronized int deleteHistory(Context c, java.util.Collection<String> ids) {
        if (ids == null || ids.isEmpty()) return 0;
        java.util.Set<String> want = new java.util.HashSet<>();
        for (String id : ids) if (id != null && !id.isEmpty()) want.add(id);
        if (want.isEmpty()) return 0;
        List<Object> h = history(c);
        int before = h.size();
        h.removeIf(o -> {
            if (!(o instanceof Map)) return false;
            Object id = Json.obj(o).get("id");
            return id instanceof String && want.contains(id);
        });
        int deleted = before - h.size();
        if (deleted > 0) saveHistory(c, h);
        return deleted;
    }

    // ---------- what the user marked (actions log, newest first) ----------
    static synchronized List<Object> actions(Context c) {
        String s = Security.decrypt(prefs(c).getString("actions", null));
        if (s == null) return new ArrayList<>();
        try { return Json.arr(Json.parse(s)); } catch (RuntimeException e) { return new ArrayList<>(); }
    }

    static synchronized void addAction(Context c, Map<String, Object> action) {
        List<Object> a = actions(c);
        a.add(0, action);
        while (a.size() > MAX_ACTIONS) a.remove(a.size() - 1);
        prefs(c).edit().putString("actions", Security.encrypt(Json.stringify(a))).apply();
    }

    // ---------- senders seen before (only salted hashes are kept, never the numbers) ----------
    private static String seenSalt(Context c) {
        String salt = str(c, "seen_salt");
        if (salt.isEmpty()) {
            byte[] b = new byte[16];
            new SecureRandom().nextBytes(b);
            salt = Base64.encodeToString(b, Base64.NO_WRAP);
            put(c, "seen_salt", salt);
        }
        return salt;
    }

    private static LinkedHashSet<String> seenSet(Context c) {
        LinkedHashSet<String> set = new LinkedHashSet<>();
        String s = Security.decrypt(prefs(c).getString("seen_senders", null));
        if (s == null || s.isEmpty()) return set;
        for (String x : s.split(",")) if (!x.isEmpty()) set.add(x);
        return set;
    }

    /**
     * True if Second Look has NOT seen this sender before. With remember = true the sender is added to the set
     * (oldest entries are dropped beyond 5,000).
     */
    static synchronized boolean firstTimeSender(Context c, String sender, boolean remember) {
        if (sender == null || sender.isEmpty()) return false;
        String key;
        try {
            String salt = seenSalt(c);
            // 80 bits of the salted SHA-256 is plenty to tell 5,000 senders apart.
            key = Security.sha256Hex((salt + "|" + sender.toUpperCase(java.util.Locale.ROOT)).getBytes(StandardCharsets.UTF_8));
            if (key.length() < 20) return false;
            key = key.substring(0, 20);
        } catch (RuntimeException e) {
            return false; // secure storage unavailable: don't claim anything
        }
        LinkedHashSet<String> set = seenSet(c);
        boolean first = !set.contains(key);
        if (first && remember) {
            set.add(key);
            Iterator<String> it = set.iterator();
            while (set.size() > MAX_SEEN && it.hasNext()) { it.next(); it.remove(); }
            prefs(c).edit().putString("seen_senders", Security.encrypt(String.join(",", set))).apply();
        }
        return first;
    }

    // ---------- numbers the user reported or trusted ----------
    static synchronized List<Object> reports(Context c) {
        String s = Security.decrypt(prefs(c).getString("reports", null));
        if (s == null) return new ArrayList<>();
        try { return Json.arr(Json.parse(s)); } catch (RuntimeException e) { return new ArrayList<>(); }
    }

    static synchronized void report(Context c, String e164, String type, String label, String kind) {
        report(c, e164, type, label, kind, false);
    }

    /** blocked = true: calls from this number are rejected and its SMS raise no notification. */
    static synchronized void report(Context c, String e164, String type, String label, String kind, boolean blocked) {
        List<Object> r = reports(c);
        r.removeIf(o -> e164.equals(Json.obj(o).get("number")));
        Map<String, Object> m = Json.map("number", e164, "type", type, "label", label, "kind", kind, "at", System.currentTimeMillis());
        if (blocked) m.put("blocked", true);
        r.add(0, m);
        prefs(c).edit().putString("reports", Security.encrypt(Json.stringify(r))).apply();
    }

    static synchronized void removeReport(Context c, String e164) {
        List<Object> r = reports(c);
        r.removeIf(o -> e164.equals(Json.obj(o).get("number")));
        prefs(c).edit().putString("reports", Security.encrypt(Json.stringify(r))).apply();
    }

    static synchronized Map<String, Object> findReport(Context c, String e164) {
        if (e164 == null) return null;
        for (Object o : reports(c)) if (e164.equals(Json.obj(o).get("number"))) return Json.obj(o);
        return null;
    }

    /** True if the user blocked this number / sender in Second Look. */
    static boolean isBlocked(Context c, String key) {
        try {
            Map<String, Object> r = findReport(c, key);
            return r != null && Boolean.TRUE.equals(r.get("blocked"));
        } catch (RuntimeException e) {
            return false;
        }
    }

    /** {action, comment, at} as stored on a history entry. */
    static Map<String, Object> userAction(String action, String comment, long at) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("action", action);
        m.put("comment", comment == null ? "" : comment);
        m.put("at", at);
        return m;
    }

    /** Deletes everything Second Look stored, including the private crash log. */
    static void wipe(Context c) {
        prefs(c).edit().clear().apply();
        CrashLog.clear(c);
    }
}
