import com.secondlook.engine.Engine;
import com.secondlook.engine.Json;
import java.nio.file.*;
import java.util.*;

public class EngineTest {
    /** Compares score, level key and label, sorted reason ids, advice and every reason (id, title, detail, weight); for documents also info and input. */
    @SuppressWarnings("unchecked")
    static String checkFull(Engine e, Map<String, Object> c) {
        String kind = (String) c.get("kind");
        Map<String, Object> r;
        if (kind.equals("payment")) r = e.analyzePayment(new LinkedHashMap<>(Json.obj(c.get("input"))));
        else if (kind.equals("document")) r = e.analyzeDocument(new LinkedHashMap<>(Json.obj(c.get("input"))));
        else if (kind.equals("auto")) r = e.analyzeAuto((String) c.get("input"));
        else r = e.analyzeMessage((String) c.get("input"));
        Map<String, Object> lv = Json.obj(r.get("level"));
        List<String> ids = new ArrayList<>();
        List<Object> reasons = new ArrayList<>();
        for (Object x : Json.arr(r.get("reasons"))) {
            Map<String, Object> m = Json.obj(x);
            ids.add((String) m.get("id"));
            reasons.add(Arrays.asList(m.get("id"), m.get("title"), m.get("detail"), Json.num(m.get("weight"))));
        }
        Collections.sort(ids);
        List<Object> want = new ArrayList<>();
        for (Object x : Json.arr(c.get("reasons"))) {
            List<Object> l = Json.arr(x);
            want.add(Arrays.asList(l.get(0), l.get(1), l.get(2), Json.num(l.get(3))));
        }
        if (Json.num(r.get("score")) != Json.num(c.get("score"))) return "score java " + r.get("score") + " js " + c.get("score") + " " + ids + " vs " + c.get("ids");
        if (!lv.get("key").equals(c.get("level")) || !lv.get("label").equals(c.get("label"))) return "level java " + lv + " js " + c.get("level") + "/" + c.get("label");
        if (!ids.equals(Json.arr(c.get("ids")))) return "ids java " + ids + " js " + c.get("ids");
        if (!r.get("advice").equals(c.get("advice"))) return "advice java " + r.get("advice") + "\n  js " + c.get("advice");
        if (!reasons.equals(want)) return "reasons java " + reasons + "\n  js " + want;
        if (kind.equals("document")) {  // info fields and the echoed input, compared as JSON text
            Map<String, Object> info = Json.obj(r.get("info")), picked = new LinkedHashMap<>();
            for (String k : new String[]{"docType", "ids", "statement", "file", "passport", "qr"}) if (info.containsKey(k)) picked.put(k, info.get(k));
            String got = Json.stringify(picked), exp = Json.stringify(c.get("info"));
            if (!got.equals(exp)) return "info java " + got + "\n  js " + exp;
            if (!Json.stringify(r.get("input")).equals(Json.stringify(c.get("echo")))) return "input java " + Json.stringify(r.get("input")) + "\n  js " + Json.stringify(c.get("echo"));
        }
        return null;
    }

    public static void main(String[] a) throws Exception {
        String root = "../..";
        Map<String, Object> fx = Json.obj(Json.parse(Files.readString(Path.of("test/phone_fixtures.json"))));
        Map<String, Object> lk = Json.obj(fx.get("lookup")), ex = Json.obj(fx.get("extract"));
        Engine.PhoneLookup fake = new Engine.PhoneLookup() {
            public Map<String, Object> lookup(String raw, String home, String org, String label) {
                String k = raw + "|" + org;
                if (!lk.containsKey(k)) return null;
                return lk.get(k) == null ? null : Json.obj(lk.get(k));
            }
            @SuppressWarnings("unchecked")
            public List<String> extract(String text, String home) {
                if (!ex.containsKey(text)) return new ArrayList<>();
                return (List<String>) (List<?>) Json.arr(ex.get(text));
            }
        };
        Engine e = new Engine(Files.readString(Path.of(root, "rules.json")), fake, "IN");
        int fail = 0, n = 0;
        for (Object o : Json.arr(Json.parse(Files.readString(Path.of("test/expected.json"))))) {
            Map<String, Object> c = Json.obj(o);
            String kind = (String) c.get("kind");
            if (kind.equals("helper")) {  // verhoeffOk / gstinOk
                n++;
                String arg = (String) c.get("input");
                boolean got = c.get("method").equals("verhoeffOk") ? Engine.verhoeffOk(arg) : Engine.gstinOk(arg);
                if (got != (Boolean) c.get("result")) { fail++; System.out.println("FAIL " + c.get("method") + " " + Json.stringify(arg) + " java " + got); }
                continue;
            }
            if (c.containsKey("advice")) {  // UPI / payment / rules-1.1 cases: full comparison
                n++;
                String why = checkFull(e, c);
                if (why != null) { fail++; System.out.println("FAIL " + kind + " " + Json.stringify(c.get("input")) + "\n  " + why); }
                continue;
            }
            String in = (String) c.get("input");
            Map<String, Object> r;
            switch (kind) {
                case "link": r = e.analyzeLink(in); break;
                case "sms": r = e.analyzeSms((String) c.get("sender"), in); break;
                case "number": r = e.analyzeNumber(in, null); break;
                case "auto": r = e.analyzeAuto(in); break;
                default: r = e.analyzeMessage(in);
            }
            List<String> ids = new ArrayList<>();
            for (Object x : Json.arr(r.get("reasons"))) ids.add((String) Json.obj(x).get("id"));
            Collections.sort(ids);
            boolean ok = Json.num(r.get("score")) == Json.num(c.get("score")) && ids.equals(Json.arr(c.get("ids")));
            if (c.containsKey("senderKind")) ok &= c.get("senderKind").equals(Json.obj(Json.obj(r.get("info")).get("sender")).get("kind"));
            if (c.containsKey("caller")) ok &= c.get("caller").equals(Json.obj(Json.obj(r.get("info")).get("caller")).get("kind"));
            n++;
            if (!ok) { fail++; System.out.println("FAIL " + kind + " " + in + "\n  java " + r.get("score") + " " + ids + "\n  js   " + c.get("score") + " " + c.get("ids")); }
        }
        // payment defaults: no "now" means the current time
        Map<String, Object> pr = e.analyzePayment(Json.map("text", "Payment Successful Rs 500 UPI Ref No 628612345678"));
        if (!"payment".equals(pr.get("kind"))) { fail++; System.out.println("FAIL analyzePayment without now"); }
        // documents: no "now", null and nested values
        Map<String, Object> dr = e.analyzeDocument(Json.map("text", "Opening balance 1.00", "docType", null, "file", null, "aadhaarQr", null));
        if (!"document".equals(dr.get("kind")) || !"statement".equals(Json.obj(dr.get("info")).get("docType"))) { fail++; System.out.println("FAIL analyzeDocument defaults"); }
        Json.parse(Json.stringify(e.analyzeDocument(null)));
        // round-trip JSON
        String js = Json.stringify(e.analyzeSms("+919812345678", "Your SBI account will be blocked. Update KYC: http://sbi-kyc.top"));
        Json.parse(js);
        String rt = Json.stringify(e.analyzePayment(Json.map("text", "Paid Rs 5,000 to shop@okaxis 13 Oct 2026", "expectedAmount", 5000, "now", 1.7e12)));
        Json.parse(rt);
        System.out.println((n - fail) + "/" + n + " match the JS engine");
        System.exit(fail == 0 ? 0 : 1);
    }
}
