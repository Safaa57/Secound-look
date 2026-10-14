package com.secondlook.second_look;

import android.content.Context;
import android.content.SharedPreferences;

import com.secondlook.engine.Json;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Everything Second Look remembers: kept only on the phone, encrypted with a Keystore key, excluded from backups. */
final class Store {
    private static final String FILE = "secondlook";
    private static final int MAX_HISTORY = 100;

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

    // ---------- history ----------
    static synchronized List<Object> history(Context c) {
        String s = Security.decrypt(prefs(c).getString("history", null));
        if (s == null) return new ArrayList<>();
        try { return Json.arr(Json.parse(s)); } catch (RuntimeException e) { return new ArrayList<>(); }
    }

    /** Saves an alert and returns its id. */
    @SuppressWarnings("unchecked")
    static synchronized String addHistory(Context c, String kind, String title, Map<String, Object> result) {
        List<Object> h = history(c);
        String id = UUID.randomUUID().toString();
        Map<String, Object> level = (Map<String, Object>) result.get("level");
        List<Object> reasons = (List<Object>) result.get("reasons");
        String summary = "";
        for (Object o : reasons) {
            Map<String, Object> r = Json.obj(o);
            if (Json.num(r.get("weight")) > 0) { summary = (String) r.get("title"); break; }
        }
        h.add(0, Json.map("id", id, "at", System.currentTimeMillis(), "kind", kind, "title", title,
                "summary", summary, "level", level.get("key"), "score", result.get("score"), "result", result));
        while (h.size() > MAX_HISTORY) h.remove(h.size() - 1);
        prefs(c).edit().putString("history", Security.encrypt(Json.stringify(h))).apply();
        return id;
    }

    static synchronized void clearHistory(Context c) { prefs(c).edit().remove("history").apply(); }

    // ---------- numbers the user reported or trusted ----------
    static synchronized List<Object> reports(Context c) {
        String s = Security.decrypt(prefs(c).getString("reports", null));
        if (s == null) return new ArrayList<>();
        try { return Json.arr(Json.parse(s)); } catch (RuntimeException e) { return new ArrayList<>(); }
    }

    static synchronized void report(Context c, String e164, String type, String label, String kind) {
        List<Object> r = reports(c);
        r.removeIf(o -> e164.equals(Json.obj(o).get("number")));
        r.add(0, Json.map("number", e164, "type", type, "label", label, "kind", kind, "at", System.currentTimeMillis()));
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

    static void wipe(Context c) { prefs(c).edit().clear().apply(); }
}
