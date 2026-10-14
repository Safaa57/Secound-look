package com.secondlook.engine;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.net.IDN;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Second Look rules engine — Java port of engine.js (same rules.json, same scores).
 * Runs fully on the device: nothing here touches the network.
 */
public final class Engine {
    public interface PhoneLookup {
        /** Same shape as phone.js lookup(); null when not a phone number. */
        Map<String, Object> lookup(String raw, String home, String claimedOrg, String claimedLabel);

        List<String> extract(String text, String home);
    }

    /**
     * JS /i on our (ASCII-letter) patterns. Not UNICODE_CASE: with it Java also folds "\u212A" (Kelvin sign) to "k" and
     * "\u017F" (long s) to "s", which JavaScript's non-unicode /i does not.
     */
    private static final int CI = Pattern.CASE_INSENSITIVE;
    /** Hard limits so a giant or crafted input can never freeze the phone. */
    static final int MAX_TEXT = 10000, MAX_URL = 2048, MAX_SENDER = 64;

    private static String cap(String s, int n) { return s == null ? "" : (s.length() > n ? s.substring(0, n) : s); }

    private final Map<String, Object> R;
    private final PhoneLookup phone;
    private final String home;
    private final Set<String> second, shorteners, riskyTlds, dangerousExt, brandSuffixes, critical;
    private final List<String> brandKeys;
    private final Map<String, Object> brands;
    private final List<Map<String, Object>> msgRules = new ArrayList<>();
    private final Map<String, List<Pattern>> msgPatterns = new HashMap<>();
    private final Map<String, Map<String, Object>> ruleById = new HashMap<>();
    private final Map<String, Object> upiHandles, payApps;
    private final List<String> upiBait, upiOfficial, upiReceive;
    private final Pattern payPrank, payPending, payFailed, paySuccess;
    private final int dangerT, warningT;

    public Engine(String rulesJson, PhoneLookup phone, String homeRegion) {
        this.R = Json.obj(Json.parse(rulesJson));
        this.phone = phone;
        this.home = homeRegion == null ? "IN" : homeRegion;
        second = strSet("secondLevel");
        shorteners = strSet("shorteners");
        riskyTlds = strSet("riskyTlds");
        dangerousExt = strSet("dangerousExtensions");
        brandSuffixes = strSet("brandSuffixes");
        critical = strSet("criticalIds");
        brands = Json.obj(R.get("brands"));
        brandKeys = new ArrayList<>(brands.keySet());
        for (Object o : Json.arr(R.get("messageRules"))) {
            Map<String, Object> r = Json.obj(o);
            msgRules.add(r);
            List<Pattern> ps = new ArrayList<>();
            for (Object p : Json.arr(r.get("patterns"))) ps.add(Pattern.compile(jsRe((String) p), CI));
            msgPatterns.put((String) r.get("id"), ps);
            ruleById.put((String) r.get("id"), r);
        }
        Map<String, Object> U = R.get("upi") == null ? new HashMap<>() : Json.obj(R.get("upi"));
        upiHandles = U.get("handles") == null ? new HashMap<>() : Json.obj(U.get("handles"));
        upiBait = strList(U.get("baitWords"));
        upiOfficial = strList(U.get("officialWords"));
        upiReceive = strList(U.get("receiveWords"));
        Map<String, Object> P = R.get("payment") == null ? new HashMap<>() : Json.obj(R.get("payment"));
        payApps = P.get("apps") == null ? new HashMap<>() : Json.obj(P.get("apps"));
        payPrank = reP(P.get("prankWords"));
        payPending = reP(P.get("pendingWords"));
        payFailed = reP(P.get("failedWords"));
        paySuccess = reP(P.get("successWords"));
        Map<String, Object> t = Json.obj(R.get("thresholds"));
        dangerT = Json.num(t.get("danger"));
        warningT = Json.num(t.get("warning"));
    }

    public Map<String, Object> rules() { return R; }

    private Set<String> strSet(String key) {
        Set<String> s = new HashSet<>();
        for (Object o : Json.arr(R.get(key))) s.add((String) o);
        return s;
    }

    private static List<String> strList(Object o) {
        List<String> l = new ArrayList<>();
        if (o != null) for (Object x : Json.arr(o)) l.add((String) x);
        return l;
    }

    private static Pattern reP(Object s) {
        String p = s == null || "".equals(s) ? "a^" : (String) s;
        return Pattern.compile(jsRe(p), CI);
    }

    // ------------------------------------------------------------------ JS regex/string compatibility
    /** Characters JavaScript's \s matches (Java's own \s is ASCII-only). */
    private static final String WS_CHARS = "\\t\\n\\x0B\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff";
    private static final String WC = "[A-Za-z0-9_]";
    private static final String WORD_B = "(?:(?<=" + WC + ")(?!" + WC + ")|(?<!" + WC + ")(?=" + WC + "))";
    private static final String NOT_WORD_B = "(?:(?<=" + WC + ")(?=" + WC + ")|(?<!" + WC + ")(?!" + WC + "))";

    /**
     * Rewrites a JS regex source so \s \d \w \b (and their negations) mean exactly what they mean in JavaScript
     * (\d \w \b ASCII-only, \s Unicode spaces), on the JVM and on Android's ICU-based regex alike.
     */
    static String jsRe(String p) {
        StringBuilder b = new StringBuilder();
        boolean inClass = false;
        for (int i = 0; i < p.length(); i++) {
            char c = p.charAt(i);
            if (c == '\\' && i + 1 < p.length()) {
                char n = p.charAt(++i);
                String rep = null;
                if (inClass) {
                    if (n == 's') rep = WS_CHARS;
                    else if (n == 'd') rep = "0-9";
                    else if (n == 'w') rep = "A-Za-z0-9_";
                    else if (n == 'b') rep = "\\x08";
                } else {
                    switch (n) {
                        case 's': rep = "[" + WS_CHARS + "]"; break;
                        case 'S': rep = "[^" + WS_CHARS + "]"; break;
                        case 'd': rep = "[0-9]"; break;
                        case 'D': rep = "[^0-9]"; break;
                        case 'w': rep = WC; break;
                        case 'W': rep = "[^A-Za-z0-9_]"; break;
                        case 'b': rep = WORD_B; break;
                        case 'B': rep = NOT_WORD_B; break;
                        default: break;
                    }
                }
                b.append(rep != null ? rep : "\\" + n);
                continue;
            }
            if (c == '[' && !inClass) inClass = true;
            else if (c == ']' && inClass) inClass = false;
            b.append(c);
        }
        return b.toString();
    }

    private static boolean jsSpace(char c) {
        return (c >= 9 && c <= 13) || c == ' ' || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029
                || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff;
    }

    /** String.prototype.trim(). */
    static String jsTrim(String s) {
        int a = 0, z = s.length();
        while (a < z && jsSpace(s.charAt(a))) a++;
        while (z > a && jsSpace(s.charAt(z - 1))) z--;
        return s.substring(a, z);
    }

    /** decodeURIComponent(); null when JS would throw. */
    static String decodeURIComponent(String s) {
        if (s.indexOf('%') < 0) return s;
        StringBuilder out = new StringBuilder();
        java.io.ByteArrayOutputStream buf = new java.io.ByteArrayOutputStream();
        for (int i = 0; i <= s.length(); i++) {
            if (i < s.length() && s.charAt(i) == '%') {
                if (i + 3 > s.length()) return null;
                int hi = Character.digit(s.charAt(i + 1), 16), lo = Character.digit(s.charAt(i + 2), 16);
                if (hi < 0 || lo < 0 || s.charAt(i + 1) > 0x7f || s.charAt(i + 2) > 0x7f) return null;
                buf.write(hi * 16 + lo);
                i += 2;
                continue;
            }
            if (buf.size() > 0) {
                try {
                    out.append(StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(buf.toByteArray())));
                } catch (CharacterCodingException e) {
                    return null;
                }
                buf.reset();
            }
            if (i < s.length()) out.append(s.charAt(i));
        }
        return out.toString();
    }

    /** A number the way JSON.stringify would print it: whole numbers without ".0". */
    private static Object jsNum(double d) {
        if (d == Math.rint(d) && Math.abs(d) < 9.2e18 && !(d == 0 && 1 / d < 0)) return (long) d;
        return d;
    }

    /** Number(String(x).replace(/,/g, "")), or null when the result isn't finite (NaN or Infinity). */
    static Double parseAmount(Object o) {
        if (o instanceof Number) {
            double d = ((Number) o).doubleValue();
            return Double.isFinite(d) ? d : null;
        }
        String s = jsTrim(String.valueOf(o).replace(",", ""));
        if (s.isEmpty()) return 0.0;
        double d;
        if (s.matches("[+-]?(Infinity|([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?)")) {
            if (s.contains("Infinity")) return null;
            d = Double.parseDouble(s);
        } else if (s.matches("0[xX][0-9a-fA-F]+")) d = new BigInteger(s.substring(2), 16).doubleValue();
        else if (s.matches("0[oO][0-7]+")) d = new BigInteger(s.substring(2), 8).doubleValue();
        else if (s.matches("0[bB][01]+")) d = new BigInteger(s.substring(2), 2).doubleValue();
        else return null;
        return Double.isFinite(d) ? d : null;
    }

    /** Number.prototype.toLocaleString("en-IN"): Indian digit grouping (12,34,567), at most 3 decimals. */
    static String formatInr(double v) {
        if (Double.isNaN(v)) return "NaN";
        boolean neg = v < 0 || (v == 0 && 1 / v < 0);
        if (Double.isInfinite(v)) return neg ? "-∞" : "∞";
        String plain = new BigDecimal(Double.toString(Math.abs(v))).setScale(3, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString();
        int dot = plain.indexOf('.');
        String ip = dot < 0 ? plain : plain.substring(0, dot), fp = dot < 0 ? "" : plain.substring(dot);
        StringBuilder g = new StringBuilder();
        if (ip.length() <= 3) g.append(ip);
        else {
            String head = ip.substring(0, ip.length() - 3);
            int first = head.length() % 2 == 0 ? 2 : 1;
            g.append(head, 0, first);
            for (int k = first; k < head.length(); k += 2) g.append(',').append(head, k, k + 2);
            g.append(',').append(ip.substring(ip.length() - 3));
        }
        return (neg ? "-" : "") + g + fp;
    }

    private static Map<String, Object> reason(String id, String title, String detail, int weight) {
        return Json.map("id", id, "title", title, "detail", detail, "weight", weight);
    }

    private static int w(Map<String, Object> r) { return Json.num(r.get("weight")); }

    // ------------------------------------------------------------------ levels
    public Map<String, Object> level(int score) {
        if (score >= dangerT) return Json.map("key", "danger", "label", "Likely scam");
        if (score >= warningT) return Json.map("key", "warning", "label", "Suspicious");
        return Json.map("key", "safe", "label", "No strong warning signs");
    }

    // ------------------------------------------------------------------ helpers
    static int lev(String a, String b) {
        if (a.equals(b)) return 0;
        if (Math.abs(a.length() - b.length()) > 2) return 9;
        int[] dp = new int[b.length() + 1];
        for (int j = 0; j <= b.length(); j++) dp[j] = j;
        for (int i = 1; i <= a.length(); i++) {
            int prev = dp[0];
            dp[0] = i;
            for (int j = 1; j <= b.length(); j++) {
                int tmp = dp[j];
                dp[j] = Math.min(Math.min(dp[j] + 1, dp[j - 1] + 1), prev + (a.charAt(i - 1) == b.charAt(j - 1) ? 0 : 1));
                prev = tmp;
            }
        }
        return dp[b.length()];
    }

    static String deHomoglyph(String s, String oneAs) {
        return s.replace("rn", "m").replace("vv", "w").replace("0", "o").replace("1", oneAs).replace("3", "e")
                .replace("4", "a").replace("5", "s").replace("7", "t").replace("8", "b").replace("@", "a").replace("$", "s");
    }

    public String registrable(String host) {
        String[] parts = host.split("\\.");
        if (parts.length <= 2) return host;
        String tld = parts[parts.length - 1], sl = parts[parts.length - 2];
        if (tld.length() == 2 && second.contains(sl)) return parts[parts.length - 3] + "." + sl + "." + tld;
        return sl + "." + tld;
    }

    private static boolean matchesDomain(String host, String d) { return host.equals(d) || host.endsWith("." + d); }

    private String officialBrandFor(String host) {
        for (String k : brandKeys)
            for (Object d : Json.arr(Json.obj(brands.get(k)).get("domains")))
                if (matchesDomain(host, (String) d)) return k;
        return null;
    }

    private String brandName(String k) { return (String) Json.obj(brands.get(k)).get("name"); }

    private String brandDomain0(String k) { return (String) Json.arr(Json.obj(brands.get(k)).get("domains")).get(0); }

    private static String pctDecode(String s) {
        try {
            byte[] out = new byte[s.length()];
            int n = 0;
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '%' && i + 2 < s.length()) {
                    out[n++] = (byte) Integer.parseInt(s.substring(i + 1, i + 3), 16);
                    i += 2;
                } else {
                    byte[] b = String.valueOf(c).getBytes(java.nio.charset.StandardCharsets.UTF_8);
                    if (n + b.length > out.length) out = Arrays.copyOf(out, out.length + b.length + 16);
                    for (byte x : b) out[n++] = x;
                }
            }
            return new String(out, 0, n, java.nio.charset.StandardCharsets.UTF_8);
        } catch (RuntimeException e) {
            return s;
        }
    }

    /** Minimal WHATWG-like URL split good enough for risk checks. */
    static final class Url {
        String scheme, username = "", host, port = "", path = "/", search = "", href;
    }

    static Url parseUrl(String s) {
        Matcher m = Pattern.compile("^([a-zA-Z][a-zA-Z0-9+.-]*):\\/\\/([^/?#]*)([^?#]*)(\\?[^#]*)?(#.*)?$").matcher(s);
        if (!m.find()) return null;
        Url u = new Url();
        u.scheme = m.group(1).toLowerCase();
        String auth = m.group(2);
        int at = auth.lastIndexOf('@');
        if (at >= 0) { u.username = auth.substring(0, at); auth = auth.substring(at + 1); }
        String host = auth;
        if (!auth.startsWith("[")) {
            int c = auth.lastIndexOf(':');
            if (c >= 0) { u.port = auth.substring(c + 1); host = auth.substring(0, c); }
        }
        if (host.isEmpty()) return null;
        host = host.toLowerCase();
        if (!host.startsWith("[")) {
            try { host = IDN.toASCII(host, IDN.ALLOW_UNASSIGNED).toLowerCase(); } catch (RuntimeException e) { return null; }
        }
        if (host.endsWith(".")) host = host.substring(0, host.length() - 1);
        u.host = host;
        if (("http".equals(u.scheme) && "80".equals(u.port)) || ("https".equals(u.scheme) && "443".equals(u.port))) u.port = "";
        String p = m.group(3);
        u.path = p == null || p.isEmpty() ? "/" : p;
        u.search = m.group(4) == null || "?".equals(m.group(4)) ? "" : m.group(4);
        u.href = u.scheme + "://" + (at >= 0 ? auth.substring(0, 0) : "") + (u.username.isEmpty() ? "" : u.username + "@") + host
                + (u.port.isEmpty() ? "" : ":" + u.port) + u.path + u.search + (m.group(5) == null ? "" : m.group(5));
        return u;
    }

    // ------------------------------------------------------------------ links
    public Map<String, Object> analyzeLink(String rawIn) {
        List<Map<String, Object>> reasons = new ArrayList<>();
        String raw = cap(rawIn, MAX_URL);
        String s = raw.trim().replaceAll("^[<(\"'\\[]+|[>)\"'\\].,;:!?]+$", "");
        Map<String, Object> unparse = reason("unparseable", "This doesn't look like a valid web address", "Check that you copied the whole link.", 0);
        if (s.isEmpty()) return finish("link", raw, new ArrayList<>(java.util.Collections.singletonList(unparse)), new LinkedHashMap<>());
        Matcher sm = Pattern.compile("^(javascript|data|vbscript):", CI).matcher(s);
        if (sm.find()) {
            reasons.add(reason("script_scheme", "Link runs code instead of opening a page", "Links starting with \"" + sm.group(1).toLowerCase() + ":\" can run code in your browser. Real websites don't send these.", 60));
            return finish("link", raw, reasons, new LinkedHashMap<>());
        }
        if (!Pattern.compile("^[a-z][a-z0-9+.-]*:\\/\\/", CI).matcher(s).find()) s = "http://" + s;
        Url u = parseUrl(s);
        if (u == null) return finish("link", raw, new ArrayList<>(java.util.Collections.singletonList(unparse)), new LinkedHashMap<>());
        String host = u.host;
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("url", u.href);
        info.put("host", host);

        if (!u.scheme.equals("http") && !u.scheme.equals("https")) reasons.add(reason("odd_scheme", "Unusual link type (" + u.scheme + ":)", "This isn't a normal web link.", 15));
        if (Pattern.compile("^http://", CI).matcher(raw.trim()).find()) reasons.add(reason("no_https", "Not a secure (https) link", "The connection isn't encrypted. Banks and shops always use https.", 10));
        String[] segs = raw.split("[/?#]", -1);
        String head3 = String.join("/", Arrays.copyOf(segs, Math.min(3, segs.length)));
        if (Pattern.compile("[^\\x00-\\x7f]").matcher(head3).find() || host.contains("xn--"))
            reasons.add(reason("punycode", "Web address uses look-alike characters", "The address contains special letters that can look identical to normal ones (for example a Cyrillic \"а\" instead of \"a\"). This is a common way to fake a famous site.", 35));
        if (host.matches("^\\d{1,3}(\\.\\d{1,3}){3}$") || host.startsWith("["))
            reasons.add(reason("ip_host", "Link points to a bare number (IP address), not a website name", "Real companies use named websites. Raw IP addresses are often used for short-lived scam pages.", 30));
        if (!u.username.isEmpty() || Pattern.compile("^[^/]*@").matcher(raw.replaceFirst("(?i)^[a-z]+://", "")).find())
            reasons.add(reason("at_sign", "Hidden real destination (uses \"@\" in the address)", "Everything before \"@\" in a link is ignored. Scammers put a trusted name there to fool you.", 40));
        if (!u.port.isEmpty()) reasons.add(reason("port", "Uses an unusual port number (:" + u.port + ")", "Normal websites don't need a port number in the address.", 10));

        String domain = registrable(host);
        info.put("domain", domain);
        String[] hp = host.split("\\.");
        String tld = hp[hp.length - 1];
        String official = officialBrandFor(host);

        if (shorteners.contains(domain) || shorteners.contains(host))
            reasons.add(reason("shortener", "Shortened link hides where it really goes", "Link shorteners (" + domain + ") are often used to hide scam websites. Don't open it unless you trust the sender, and check the full address first.", 20));
        String freeHost = null;
        for (Object d : Json.arr(R.get("freeHosts"))) if (matchesDomain(host, (String) d)) { freeHost = (String) d; break; }
        if (freeHost != null) reasons.add(reason("free_host", "Hosted on a free website builder (" + freeHost + ")", "Anyone can make a page here in minutes. Banks and big companies don't run their login pages on free hosting.", 15));
        if (riskyTlds.contains(tld)) reasons.add(reason("risky_tld", "Uses a web ending often linked to scams (." + tld + ")", "Cheap web endings like ." + tld + " are popular with scammers. Not every site using it is bad, but be careful.", 15));

        List<String> tokens = new ArrayList<>();
        for (String t : host.split("[.\\-]")) if (!t.isEmpty()) tokens.add(t);
        String brandHit = null;
        if (official == null) {
            for (String k : brandKeys) {
                boolean hit = false;
                for (String t : tokens) {
                    if (t.equals(k)) hit = true;
                    else if (k.length() >= 6) hit = t.contains(k);
                    else if (t.startsWith(k)) hit = brandSuffixes.contains(t.substring(k.length())) || (k.length() >= 4 && t.length() - k.length() <= 6);
                    else if (t.endsWith(k) && k.length() >= 4) hit = brandSuffixes.contains(t.substring(0, t.length() - k.length()));
                    if (hit) break;
                }
                if (hit) { brandHit = k; break; }
            }
            if (brandHit != null) {
                reasons.add(reason("brand_impersonation", "Uses the name \"" + brandName(brandHit) + "\" but isn't their real website", brandName(brandHit) + "'s real website is " + brandDomain0(brandHit) + ". This link goes to " + domain + " instead.", 45));
            } else {
                String label = domain.split("\\.")[0];
                Set<String> cands = new LinkedHashSet<>(Arrays.asList(label.split("-")));
                cands.add(label.replace("-", ""));
                outer:
                for (String t : cands) {
                    for (String k : brandKeys) {
                        if (k.length() < 4 || t.equals(k)) continue;
                        String nA = deHomoglyph(t, "l"), nB = deHomoglyph(t, "i");
                        int d = lev(t, k);
                        if (nA.equals(k) || nB.equals(k) || (d == 1 && k.length() >= 5) || (d == 2 && k.length() >= 8)
                                || (t.length() > k.length() && (nA.contains(k) || nB.contains(k)) && !t.contains(k))) {
                            reasons.add(reason("lookalike", "Misspelled copy of \"" + brandName(k) + "\"", "\"" + domain + "\" is made to look like " + brandDomain0(k) + " but is a different website.", 45));
                            brandHit = k;
                            break outer;
                        }
                    }
                }
            }
            boolean govTok = tokens.contains("gov") || tokens.contains("govt") || tokens.contains("gov-in") || tokens.contains("govin");
            if (govTok && !host.matches(".*\\.(gov|gov\\.in|nic\\.in)$") && !host.endsWith(".gov.in"))
                reasons.add(reason("fake_gov", "Pretends to be a government website", "Indian government sites end in .gov.in or .nic.in. This one doesn't.", 35));
        }

        if (official == null && brandHit == null && hasAny(reasons, "ip_host", "free_host", "risky_tld", "shortener")) {
            List<String> ptoks = Arrays.asList((u.path + " " + u.search).toLowerCase().split("[^a-z0-9]+"));
            for (String k : brandKeys) {
                if (k.length() >= 3 && ptoks.contains(k)) {
                    reasons.add(reason("brand_in_path", "Mentions \"" + brandName(k) + "\" on a website that isn't theirs", "The link uses " + brandName(k) + "'s name in the address but is hosted somewhere else.", 25));
                    break;
                }
            }
        }

        String path = pctDecode(u.path.toLowerCase());
        Matcher em = Pattern.compile("\\.([a-z0-9]{1,5})$").matcher(path);
        if (em.find() && dangerousExt.contains(em.group(1))) {
            String ext = em.group(1);
            reasons.add(reason("dangerous_file", "Downloads an app or program file (." + ext + ")", ext.startsWith("apk") || ext.equals("xapk")
                    ? "APK files install apps from outside your phone's official app store. Fake bank, challan and delivery apps are spread this way and steal your SMS and OTPs."
                    : "This link downloads a program that can take control of your device.", 45));
        }

        String hay = (host + " " + path + " " + u.search).toLowerCase();
        List<String> kws = new ArrayList<>();
        for (Object k : Json.arr(R.get("linkKeywords")))
            if (Pattern.compile("(^|[^a-z])" + Pattern.quote((String) k), CI).matcher(hay).find()) kws.add((String) k);
        if (!kws.isEmpty())
            reasons.add(reason("keywords", "Contains bait words: " + String.join(", ", kws.subList(0, Math.min(4, kws.size()))), "Words like these in an address are used to make a fake page feel official or urgent.", Math.min(20, kws.size() * 6)));
        if (host.split("\\.").length - domain.split("\\.").length >= 3)
            reasons.add(reason("deep_subdomains", "Unusually long chain of sub-addresses", "Long addresses like this push the real website name out of view on a phone screen.", 10));
        if (domain.split("\\.")[0].chars().filter(c -> c == '-').count() >= 2)
            reasons.add(reason("hyphens", "Website name stuffed with hyphens", "Names like \"secure-login-verify\" are typical of throwaway scam sites.", 10));
        if (u.href.length() > 160) reasons.add(reason("long_url", "Very long, cluttered link", "Long links can hide where they really go.", 5));
        if (Pattern.compile("(https?://|www\\.)", CI).matcher(u.path + u.search).find())
            reasons.add(reason("redirect", "Link contains another link inside it", "It may forward you to a different, hidden website.", 10));
        if (official != null)
            reasons.add(reason("official", "Goes to " + brandName(official) + "'s official website (" + domain + ")", "This address matches a known official domain. Still never share an OTP or PIN, even on a real site, if someone asked you to.", -30));
        info.put("official", official == null ? null : brandName(official));
        info.put("impersonating", brandHit == null ? null : brandName(brandHit));
        return finish("link", raw, reasons, info);
    }

    private static boolean hasAny(List<Map<String, Object>> reasons, String... ids) {
        Set<String> want = new HashSet<>(Arrays.asList(ids));
        for (Map<String, Object> r : reasons) if (want.contains((String) r.get("id"))) return true;
        return false;
    }

    private static final Pattern URL_RE = Pattern.compile(jsRe("\\b((?:https?://|www\\.)[^\\s<>\"'`]+|[a-z0-9][a-z0-9-]{0,62}(?:\\.[a-z0-9-]{1,63}){0,8}\\.(?:com|in|net|org|co|io|info|xyz|top|click|me|ly|gl|gd|at|link|site|online|shop|live|app|icu|buzz|cc|tk|ml|ga|cf|gq|club|store|vip|sbs|cfd|bank|sbi|gov|ru|cn|us|uk|de|dev|page|cyou|bond|win|loan|support|help|cam|su|pw|ws|biz|tv|to|lol|rest|work|zip|mov)(?::\\d+)?(?:/[^\\s<>\"'`]*)?)"), CI);

    public List<String> extractUrls(String text) {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        String s = text == null ? "" : text;
        Matcher m = URL_RE.matcher(s);
        while (m.find()) {
            if (m.start() > 0 && s.charAt(m.start() - 1) == '@') continue;
            out.add(m.group(1).replaceAll("[)\\].,;:!?'\"]+$", ""));
        }
        List<String> l = new ArrayList<>(out);
        return l.subList(0, Math.min(10, l.size()));
    }

    // ------------------------------------------------------------------ messages
    @SuppressWarnings("unchecked")
    public Map<String, Object> analyzeMessage(String textIn) {
        String t = cap(textIn, MAX_TEXT);
        List<Map<String, Object>> reasons = new ArrayList<>();
        int bonusStep = Json.num(R.get("extraPatternBonus")), bonusMax = Json.num(R.get("extraPatternMax"));
        for (Map<String, Object> r : msgRules) {
            String first = null;
            int hits = 0;
            for (Pattern p : msgPatterns.get((String) r.get("id"))) {
                Matcher m = p.matcher(t);
                if (m.find()) { hits++; if (first == null) first = m.group(); }
            }
            if (hits > 0) {
                Map<String, Object> x = reason((String) r.get("id"), (String) r.get("title"), (String) r.get("detail"), Json.num(r.get("weight")) + Math.min(bonusMax, (hits - 1) * bonusStep));
                x.put("evidence", first.length() > 80 ? first.substring(0, 80) : first);
                reasons.add(x);
            }
        }
        String letters = t.replaceAll("[^A-Za-z]", "");
        if (letters.length() > 30 && (double) t.replaceAll("[^A-Z]", "").length() / letters.length() > 0.5)
            reasons.add(reason("shouting", "Written mostly in CAPITAL LETTERS", "Shouting text is used to create alarm.", 5));
        List<Object> links = new ArrayList<>();
        Map<String, Object> worst = null;
        for (String u : extractUrls(t)) {
            Map<String, Object> lr = analyzeLink(u);
            links.add(lr);
            if (worst == null || Json.num(lr.get("score")) > Json.num(worst.get("score"))) worst = lr;
        }
        if (worst != null && Json.num(worst.get("score")) > 0) {
            List<String> titles = new ArrayList<>();
            for (Object o : Json.arr(worst.get("reasons"))) if (w(Json.obj(o)) > 0) titles.add((String) Json.obj(o).get("title"));
            if (!titles.isEmpty()) {
                Object h = Json.obj(worst.get("info")).get("host");
                reasons.add(reason("bad_link", "Contains a risky link: " + (h != null ? h : worst.get("input")), String.join(" · ", titles), (int) Math.round(Json.num(worst.get("score")) * 0.8)));
            }
        }
        if (!links.isEmpty() && reasons.stream().anyMatch(r -> w(r) >= 25) && !hasAny(reasons, "bad_link"))
            reasons.add(reason("link_with_bait", "Pairs a pressure message with a link", "Even if the link looks normal, don't log in or pay through a link sent like this. Open the official app or type the address yourself.", 10));
        // UPI IDs and upi:// payment links inside the message
        List<Object> upis = new ArrayList<>();
        Map<String, Object> worstUpi = null;
        for (String u : extractUpi(t)) {
            Map<String, Object> ur = analyzeUpi(u);
            upis.add(ur);
            if (worstUpi == null || Json.num(ur.get("score")) > Json.num(worstUpi.get("score"))) worstUpi = ur;
        }
        if (worstUpi != null && Json.num(worstUpi.get("score")) >= warningT) {
            List<String> titles = new ArrayList<>();
            for (Object o : Json.arr(worstUpi.get("reasons"))) if (w(Json.obj(o)) > 0) titles.add((String) Json.obj(o).get("title"));
            Object vpa = Json.obj(worstUpi.get("info")).get("vpa");
            reasons.add(reason("bad_upi", "Contains a risky UPI ID: " + (vpa != null && !"".equals(vpa) ? vpa : "payment link"), String.join(" · ", titles), (int) Math.round(Json.num(worstUpi.get("score")) * 0.8)));
        }
        List<Object> phones = new ArrayList<>();
        if (phone != null) {
            for (String n : phone.extract(t, home)) {
                Map<String, Object> ph = phone.lookup(n, home, "none", "organisation");
                if (ph == null) continue;
                phones.add(ph);
                Object c = ph.get("country");
                if (c != null && !home.equals(c) && !hasAny(reasons, "intl_in_message")) {
                    Object cn = ph.get("countryName");
                    reasons.add(reason("intl_in_message", "Asks you to contact a foreign number (" + (cn != null ? cn : ph.get("callingCode")) + ")", "A local bank, office or company wouldn't ask you to call or message a number in another country.", 15));
                }
            }
        }
        return finish("message", t, reasons, Json.map("links", links, "phones", phones, "upis", upis));
    }

    // ------------------------------------------------------------------ UPI IDs and payment links
    private static final Pattern VPA_RE = Pattern.compile("^([a-z0-9][a-z0-9._-]{1,63})@([a-z][a-z0-9]{1,30})\\z");
    private static final Pattern VPA_IN_TEXT = Pattern.compile("(^|[^a-z0-9._@-])([a-z0-9][a-z0-9._-]{1,63}@[a-z][a-z0-9]{1,30})(?![a-z0-9.@-])", CI);
    private static final Pattern UPI_LINK_IN_TEXT = Pattern.compile(jsRe("upi://pay\\?[^\\s<>\"']{3,600}"), CI);
    private static final Pattern UPI_LINK = Pattern.compile("^upi:(//)?pay\\?", CI);

    public List<String> extractUpi(String text) {
        String s = text == null ? "" : text;
        List<String> out = new ArrayList<>();
        Matcher m = UPI_LINK_IN_TEXT.matcher(s);
        while (m.find()) out.add(m.group());
        m = VPA_IN_TEXT.matcher(s);
        while (m.find()) {
            String v = m.group(2).toLowerCase(Locale.ROOT);
            boolean seen = false;
            for (String u : out) if (u.toLowerCase(Locale.ROOT).contains(v)) { seen = true; break; }
            if (!seen) out.add(m.group(2));
        }
        List<String> l = new ArrayList<>(new LinkedHashSet<>(out));
        return l.subList(0, Math.min(5, l.size()));
    }

    private static Map<String, String> queryParams(String q) {
        Map<String, String> out = new LinkedHashMap<>();
        for (String part : (q == null ? "" : q).split("&", -1)) {
            if (part.isEmpty()) continue;
            int i = part.indexOf('=');
            String k = (i < 0 ? part : part.substring(0, i)).toLowerCase(Locale.ROOT);
            String v = i < 0 ? "" : part.substring(i + 1).replace('+', ' ');
            String d = decodeURIComponent(v);
            if (d != null) v = d;
            if (!out.containsKey(k)) out.put(k, cap(v, 200));
        }
        return out;
    }

    private static List<String> words(String s) {
        List<String> out = new ArrayList<>();
        for (String x : (s == null ? "" : s).toLowerCase(Locale.ROOT).split("[^a-z]+")) if (!x.isEmpty()) out.add(x);
        return out;
    }

    private static String hasWord(List<String> list, String s) {
        List<String> w = words(s);
        String joined = (s == null ? "" : s).toLowerCase(Locale.ROOT).replaceAll("[^a-z]", "");
        for (String x : list) if (w.contains(x) || (x.length() >= 5 && joined.contains(x))) return x;
        return null;
    }

    public static boolean isVpa(String s) {
        return VPA_RE.matcher(jsTrim(s == null ? "" : s).toLowerCase(Locale.ROOT)).find();
    }

    public static boolean isUpiLink(String s) {
        return UPI_LINK.matcher(jsTrim(s == null ? "" : s)).find();
    }

    /** Checks a UPI ID (name@bank) or a upi://pay?... payment link. */
    public Map<String, Object> analyzeUpi(String raw) {
        String input = cap(jsTrim(raw == null ? "" : raw), MAX_URL);
        List<Map<String, Object>> reasons = new ArrayList<>();
        Map<String, String> params = new HashMap<>();
        String vpa = input.toLowerCase(Locale.ROOT);
        if (isUpiLink(input)) {
            params = queryParams(input.substring(input.indexOf('?') + 1));
            vpa = jsTrim(params.getOrDefault("pa", "")).toLowerCase(Locale.ROOT);
        }
        Matcher m = VPA_RE.matcher(vpa);
        if (!m.find()) {
            List<Map<String, Object>> r = new ArrayList<>();
            r.add(reason("unparseable", "This doesn't look like a valid UPI ID", "A UPI ID looks like name@bank, for example 9876543210@ybl.", 0));
            return finish("upi", input, r, Json.map("vpa", vpa.isEmpty() ? null : vpa));
        }
        String name = m.group(1), handle = m.group(2);
        String app = (String) upiHandles.get(handle);
        String payee = jsTrim(params.getOrDefault("pn", ""));
        String note = jsTrim(params.getOrDefault("tn", ""));
        String am = params.get("am");
        Double amount = am != null && !am.isEmpty() && am.matches("[0-9]{1,9}(\\.[0-9]{1,2})?") ? Double.valueOf(Double.parseDouble(am)) : null;
        boolean personal = name.replaceFirst("^0+|^91", "").matches("[6-9][0-9]{9}");
        Map<String, Object> info = Json.map("vpa", vpa, "handle", handle, "app", app, "payee", payee.isEmpty() ? null : payee,
                "note", note.isEmpty() ? null : note, "amount", amount == null ? null : jsNum(amount), "personal", personal);

        if (app == null) reasons.add(reason("upi_unknown_handle", "Unfamiliar UPI app (@" + handle + ")", "We don't recognise the bank or app behind @" + handle + ". It may still be genuine; check the name your UPI app shows before paying.", 5));
        String bait = hasWord(upiBait, name);
        String official = hasWord(upiOfficial, name);
        if (official != null) reasons.add(reason("upi_fake_official", "UPI ID pretends to be official (\"" + official + "\")", "Banks, police and government offices don't collect money through UPI IDs like this. Anyone can create a UPI ID with any name in it.", 35));
        else if (bait != null) reasons.add(reason("upi_bait_name", "UPI ID uses bait words (\"" + bait + "\")", "Words like refund, reward, KYC or helpdesk in a UPI ID are typical of scam collection accounts.", 30));
        List<String> payeeWords = new ArrayList<>(upiOfficial);
        payeeWords.addAll(Arrays.asList("customer care", "helpline", "refund", "kyc"));
        String payeeOfficial = hasWord(payeeWords, payee);
        if (!payee.isEmpty() && payeeOfficial != null && (personal || official == null)) reasons.add(reason("upi_payee_claims_official", "Payee name claims to be official (\"" + cap(payee, 40) + "\")", "The name in a payment link is typed by whoever made it. It proves nothing.", 30));
        String recv = hasWord(upiReceive, note);
        if (recv != null) reasons.add(reason("upi_receive_note", "Payment note says \"" + cap(note, 40) + "\"", "Paying or scanning this sends money FROM your account. You never pay, scan a QR code or enter a PIN to receive money, a refund or a prize.", 45));
        if (amount != null && amount >= 1) info.put("amountText", "₹" + formatInr(amount));
        reasons.add(reason("upi_check_name", "Check the name before you pay", "Your UPI app shows the registered name of the person or shop after you enter the ID or scan the code. If it isn't who you expected, stop.", 0));
        return finish("upi", input, reasons, info);
    }

    // ------------------------------------------------------------------ payment screenshots
    private static final String WS = "[" + WS_CHARS + "]";
    private static final String[] MONTHS = {"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"};
    private static final Pattern AMT_RE = Pattern.compile(jsRe("(?:\\u20b9|\\brs\\.?|\\binr)\\s*([0-9][0-9,]*(?:\\.[0-9]{1,2})?)"), CI);
    private static final Pattern REF_RE = Pattern.compile(jsRe("\\b(utr|rrn|upi\\s*ref(?:erence)?(?:\\s*(?:no\\.?|number|id))?|upi\\s*transaction\\s*id|upi\\s*txn\\s*id|ref(?:erence)?\\s*(?:no\\.?|number)|bank\\s*reference\\s*(?:no\\.?|number))\\s*[:#.-]?\\s*((?:\\d{4} \\d{4} \\d{4})|\\d{6,22})(?![0-9])"), CI);
    private static final Pattern LONE_REF = Pattern.compile("(^|[^0-9])([0-9]{12})(?![0-9])");
    private static final Pattern TXN_RE = Pattern.compile(jsRe("\\b(transaction\\s*id|txn\\s*id|order\\s*id)\\s*[:#.-]?\\s*([a-z0-9]{8,40})"), CI);
    private static final Pattern UPI_TAIL = Pattern.compile(jsRe("upi\\s*\\z"), CI);
    private static final Pattern TIME_RE = Pattern.compile(jsRe("\\b(\\d{1,2}):(\\d{2})(?::\\d{2})?\\s*(am|pm)?\\b"), CI);
    private static final Pattern DATE1 = Pattern.compile(jsRe("\\b(\\d{1,2})(?:st|nd|rd|th)?[\\s-]+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?,?[\\s-]+(\\d{4}|\\d{2})\\b"), CI);
    private static final Pattern DATE2 = Pattern.compile(jsRe("\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b"), CI);
    private static final Pattern DATE3 = Pattern.compile(jsRe("\\b(\\d{1,2})[/.-](\\d{1,2})[/.-](\\d{4}|\\d{2})\\b"));
    private static final Pattern DATE4 = Pattern.compile(jsRe("\\b(\\d{4})-(\\d{2})-(\\d{2})\\b"));

    private static boolean validAmountFormat(String s) {
        return s.matches("[0-9]+(\\.[0-9]{1,2})?") || s.matches("[0-9]{1,3}(,[0-9]{3})+(\\.[0-9]{1,2})?") || s.matches("[0-9]{1,2}(,[0-9]{2})*,[0-9]{3}(\\.[0-9]{1,2})?");
    }

    private static int month(String m) { return Arrays.asList(MONTHS).indexOf(m.toLowerCase(Locale.ROOT)) + 1; }

    /** {y, mo, d, invalid(0/1)} or null, like findDate() in engine.js. */
    private static int[] findDate(String t) {
        Matcher m = DATE1.matcher(t);
        if (m.find()) return mkDate(Integer.parseInt(m.group(3)), month(m.group(2)), Integer.parseInt(m.group(1)));
        m = DATE2.matcher(t);
        if (m.find()) return mkDate(Integer.parseInt(m.group(3)), month(m.group(1)), Integer.parseInt(m.group(2)));
        m = DATE3.matcher(t);
        if (m.find()) return mkDate(Integer.parseInt(m.group(3)), Integer.parseInt(m.group(2)), Integer.parseInt(m.group(1)));
        m = DATE4.matcher(t);
        if (m.find()) return mkDate(Integer.parseInt(m.group(1)), Integer.parseInt(m.group(2)), Integer.parseInt(m.group(3)));
        return null;
    }

    private static int[] mkDate(int y, int mo, int d) {
        if (y < 100) y += 2000;
        if (mo == 0 || mo > 12 || d < 1 || d > 31 || y < 2010 || y > 2100) return null;
        if (d > java.time.YearMonth.of(y, mo).lengthOfMonth()) return new int[]{y, mo, d, 1};
        return new int[]{y, mo, d, 0};
    }

    private static String pad2(int n) { return (n < 10 ? "0" : "") + n; }

    /**
     * Checks a payment screenshot or "payment done" message.
     * input: text (words read from the screenshot), expectedAmount (String or Number, optional), myUpi, imageEditor
     * (app name found in the file), now (epoch ms as a Number, optional; defaults to the current time).
     */
    public Map<String, Object> analyzePayment(Map<String, Object> input) {
        if (input == null) input = new HashMap<>();
        Object textO = input.get("text");
        String t = cap(textO == null ? "" : String.valueOf(textO), MAX_TEXT);
        String low = t.toLowerCase(Locale.ROOT);
        Object nowO = input.get("now");
        double now = nowO instanceof Number ? ((Number) nowO).doubleValue() : (double) System.currentTimeMillis();
        List<Map<String, Object>> reasons = new ArrayList<>();
        Map<String, Object> info = new LinkedHashMap<>();

        // --- read the fields ---
        List<String> amts = new ArrayList<>();
        Matcher m = AMT_RE.matcher(t);
        while (amts.size() < 6 && m.find()) amts.add(m.group(1));
        Double amount = null;
        if (!amts.isEmpty()) { amount = parseAmount(amts.get(0)); info.put("amountText", amts.get(0)); info.put("amount", amount == null ? null : jsNum(amount)); }
        String ref = null, refLabel = null;
        m = REF_RE.matcher(t);
        if (m.find()) { ref = m.group(2).replace(" ", ""); refLabel = m.group(1).toLowerCase(Locale.ROOT); }
        else { Matcher lone = LONE_REF.matcher(t); if (lone.find()) ref = lone.group(2); }
        if (ref != null) info.put("ref", ref);
        m = TXN_RE.matcher(t);
        if (m.find() && !UPI_TAIL.matcher(t.substring(Math.max(0, m.start() - 5), m.start())).find()) info.put("txnId", m.group(2));
        int[] date = findDate(t);
        boolean dateOk = date != null && date[3] == 0;
        if (dateOk) info.put("date", date[0] + "-" + pad2(date[1]) + "-" + pad2(date[2]));
        m = TIME_RE.matcher(t);
        if (m.find()) info.put("time", m.group());
        for (String k : payApps.keySet())
            if (Pattern.compile("(^|[^a-z])" + k.replace(".", "\\.") + "([^a-z]|\\z)").matcher(low).find()) { info.put("app", payApps.get(k)); break; }
        List<String> vpas = new ArrayList<>();
        m = VPA_IN_TEXT.matcher(t);
        while (vpas.size() < 4 && m.find()) vpas.add(m.group(2).toLowerCase(Locale.ROOT));
        if (!vpas.isEmpty()) info.put("upiIds", new ArrayList<Object>(vpas));
        boolean pending = payPending.matcher(t).find(), failed = payFailed.matcher(t).find(), success = paySuccess.matcher(t).find();
        String status = failed ? "failed" : pending ? "pending" : success ? "successful" : null;
        info.put("status", status);

        // --- checks ---
        boolean hasText = jsTrim(t).length() > 20;
        if (payPrank.matcher(t).find()) reasons.add(reason("pay_prank_app", "Made with a fake \"prank\" payment app", "The screenshot contains words used by apps that create fake payment receipts. No money was sent.", 60));
        if (failed || pending) reasons.add(reason("pay_not_complete", "The screenshot itself says the payment isn't complete (" + status + ")", "Only a completed payment moves money. A pending or failed screen shared as \"proof\" is a common trick.", 35));
        else if (!success && hasText) reasons.add(reason("pay_no_success", "Doesn't clearly say the payment was successful", "Real payment screens say \"Payment successful\", \"Paid\" or similar.", 10));
        if (ref == null && hasText) reasons.add(reason("pay_no_ref", "No UPI reference (UTR) number", "Every real UPI payment has a 12-digit reference number. Without it, the payment can't be traced.", 20));
        boolean upiLabel = refLabel != null && Pattern.compile("upi|rrn|utr").matcher(refLabel).find();
        boolean ref12 = ref != null && ref.matches("[0-9]{12}");
        if (ref != null && upiLabel && !ref12) reasons.add(reason("pay_bad_ref", "UPI reference has " + ref.length() + " digits instead of 12", "Real UPI reference numbers are exactly 12 digits. A wrong length usually means the screenshot was edited.", 30));
        if (ref12 && dateOk) {
            int yd = ref.charAt(0) - '0', jd = Integer.parseInt(ref.substring(1, 4));
            int exp = LocalDate.of(date[0], date[1], date[2]).getDayOfYear();
            int diff = Math.abs(jd - exp);
            if (jd < 1 || jd > 366 || yd != date[0] % 10 || (diff > 1 && diff < 364))
                reasons.add(reason("pay_ref_date_mismatch", "Reference number doesn't match the date shown", "UPI reference numbers usually begin with the last digit of the year and the day of the year (for " + info.get("date") + " that would be " + (date[0] % 10) + String.format(Locale.ROOT, "%03d", exp) + "…). This one doesn't, which often happens when a screenshot is edited. Some banks number differently, so confirm in your bank app.", 15));
        }
        if (date != null && !dateOk) reasons.add(reason("pay_bad_date", "The date on the screenshot doesn't exist", date[2] + "/" + date[1] + "/" + date[0] + " isn't a real calendar date, so the screenshot was edited.", 45));
        if (dateOk) {
            double ts = LocalDate.of(date[0], date[1], date[2]).toEpochDay() * 86400000.0;
            if (ts > now + 36 * 3600000.0) reasons.add(reason("pay_future_date", "The payment date is in the future (" + info.get("date") + ")", "A real payment can't be dated in the future. The screenshot was edited.", 45));
            else if (ts < now - 3 * 86400000.0) reasons.add(reason("pay_old_date", "This payment is from " + info.get("date") + ", not today", "Scammers reuse old screenshots of someone else's payment.", 20));
        }
        for (String a : amts) if (!validAmountFormat(a)) { reasons.add(reason("pay_amount_format", "Amount is written oddly (" + a + ")", "Commas or decimals in the wrong place are a sign the amount was typed over.", 20)); break; }
        Object expO = input.get("expectedAmount");
        Double exp = expO != null && !"".equals(expO) ? parseAmount(expO) : null;
        if (exp != null && amount != null && Math.abs(exp - amount) >= 0.01) reasons.add(reason("pay_amount_mismatch", "Amount is ₹" + info.get("amountText") + ", not the ₹" + formatInr(exp) + " you expected", "Check the exact amount in your own bank app.", 30));
        Object mineO = input.get("myUpi");
        String mine = jsTrim(mineO == null ? "" : String.valueOf(mineO)).toLowerCase(Locale.ROOT);
        if (!mine.isEmpty() && isVpa(mine) && !vpas.isEmpty() && !vpas.contains(mine)) reasons.add(reason("pay_wrong_payee", "Your UPI ID isn't on the screenshot", "It shows " + String.join(", ", vpas) + ", not your UPI ID " + mine + ". The money may have gone to someone else, or the screenshot is from another payment.", 35));
        Object edO = input.get("imageEditor");
        String editor = jsTrim(edO == null ? "" : String.valueOf(edO));
        if (!editor.isEmpty()) reasons.add(reason("pay_edited_image", "The image file shows it was saved by a photo-editing app", "Genuine payment screenshots come straight from the phone. This one passed through a photo editor.", 35));

        // Message tricks in the same text ("sent by mistake", "will reflect in 24 hours")
        Map<String, Object> msg = analyzeMessage(t);
        Set<String> have = new HashSet<>();
        for (Map<String, Object> r : reasons) have.add((String) r.get("id"));
        for (Object o : Json.arr(msg.get("reasons"))) {
            Map<String, Object> r = Json.obj(o);
            if (!have.contains((String) r.get("id")) && !"shouting".equals(r.get("id"))) reasons.add(r);
        }

        reasons.add(reason("pay_screenshot_not_proof", "A screenshot is never proof of payment", "Anyone can edit a screenshot or use a fake payment app. The only proof is the money in your own bank or UPI app: check the balance or find this reference number in your transaction history.", 0));
        Map<String, Object> in = Json.map("text", cap(t, 2000), "expectedAmount", exp == null ? null : jsNum(exp), "myUpi", mine.isEmpty() ? null : mine);
        Map<String, Object> res = finish("payment", in, reasons, info);
        if ("safe".equals(Json.obj(res.get("level")).get("key"))) res.put("level", Json.map("key", "safe", "label", "No red flags found. Confirm in your bank app"));
        return res;
    }

    // ------------------------------------------------------------------ SMS sender (Indian DLT headers)
    public Map<String, Object> analyzeSender(String senderIn, String body) {
        Map<String, Object> S = Json.obj(R.get("senderRules"));
        String raw = senderIn == null ? "" : senderIn.trim();
        String up = raw.toUpperCase();
        String text = body == null ? "" : body;
        List<Map<String, Object>> reasons = new ArrayList<>();
        Map<String, Object> info = Json.map("raw", raw, "kind", "unknown");
        Map<String, Object> out = Json.map("reasons", reasons, "info", info);
        if (raw.isEmpty()) return out;
        Matcher m = Pattern.compile((String) S.get("headerPattern")).matcher(up);
        boolean claimsOfficial = Pattern.compile((String) S.get("officialClaim"), CI).matcher(text).find();
        boolean claimsOtp = Pattern.compile((String) S.get("otpClaim"), CI).matcher(text).find();
        Map<String, Object> suffixes = Json.obj(S.get("suffixes"));
        if (m.find()) {
            String brand = up.split("-")[1];
            String suffix = m.group(1);
            info.put("kind", "business");
            info.put("brandCode", brand);
            info.put("type", suffix == null ? null : suffixes.get(suffix));
            info.put("label", "Registered business sender" + (suffix == null ? "" : " · " + suffixes.get(suffix)));
            if ("G".equals(suffix)) reasons.add(reason("gov_header", "Sent from a registered government header (-G)", "Messages ending in -G come from government departments registered with TRAI. Still check any link before you open it.", -10));
            if ("P".equals(suffix) && claimsOtp) reasons.add(reason("promo_claims_txn", "Promotional sender (-P) talking about OTPs or transactions", "Real OTPs and bank alerts come from transactional (-T) or service (-S) headers. A promotional header sending them is unusual.", 15));
            for (Map.Entry<String, Object> e : Json.obj(S.get("bankClaims")).entrySet()) {
                String claim = e.getKey();
                boolean match = false;
                for (Object c : Json.arr(e.getValue())) if (brand.toLowerCase().contains((String) c)) match = true;
                if (Pattern.compile("\\b" + claim + "\\b", CI).matcher(text).find()
                        && Pattern.compile("\\b(bank|account|a/c|kyc|card|upi|otp)\\b", CI).matcher(text).find() && !match) {
                    reasons.add(reason("header_mismatch", "Sender name doesn't match the company in the message", "The message talks about " + claim.toUpperCase() + " but was sent by \"" + brand + "\". Banks send from their own registered headers.", 20));
                    break;
                }
            }
        } else if (phone != null && raw.matches("^[+\\d][\\d\\s-]{6,}$")) {
            Map<String, Object> d = phone.lookup(raw, home, "none", "organisation");
            info.put("kind", "person");
            info.put("label", "Sent from a phone number" + (d != null && d.get("countryName") != null ? " (" + d.get("countryName") + ")" : ""));
            info.put("number", d);
            if (claimsOfficial) reasons.add(reason("mobile_sender_official", "Official-sounding SMS sent from an ordinary phone number", "In India, banks, government and companies must send SMS from registered sender names like VM-SBIINB-T. A message about your bank, KYC, bill or parcel from a 10-digit number is almost always fake.", 35));
            if (d != null) for (Object o : Json.arr(d.get("signals"))) {
                Map<String, Object> sg = Json.obj(o);
                String id = (String) sg.get("id");
                if (Arrays.asList("intl_unknown", "invalid", "voip", "premium").contains(id))
                    reasons.add(reason("sender_" + id, "Sender: " + sg.get("title"), (String) sg.get("detail"), w(sg)));
            }
        } else if (raw.contains("@")) {
            info.put("kind", "email");
            info.put("label", "Sent from an e-mail address");
            if (claimsOfficial) reasons.add(reason("email_sender_official", "Official-sounding message sent from an e-mail address", "Banks and government offices in India don't send account or KYC alerts as SMS from e-mail addresses.", 25));
        } else {
            info.put("label", "Sender name not in the registered format");
            if (claimsOfficial) reasons.add(reason("odd_sender", "Sender name isn't in India's registered business format", "Business SMS in India come from headers like AB-BRAND-T. This sender doesn't follow that pattern.", 10));
        }
        return out;
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> analyzeSms(String sender, String body) {
        sender = cap(sender, MAX_SENDER);
        body = cap(body, MAX_TEXT);
        Map<String, Object> base = analyzeMessage(body);
        Map<String, Object> snd = analyzeSender(sender, body);
        List<Map<String, Object>> reasons = new ArrayList<>();
        for (Object o : Json.arr(base.get("reasons"))) reasons.add(Json.obj(o));
        reasons.addAll((List<Map<String, Object>>) snd.get("reasons"));
        Map<String, Object> info = new LinkedHashMap<>(Json.obj(base.get("info")));
        info.put("sender", snd.get("info"));
        return finish("sms", Json.map("sender", sender, "body", body), reasons, info);
    }

    // ------------------------------------------------------------------ calls and numbers
    public Map<String, Object> callerKind(Map<String, Object> d, boolean communityScam) {
        if (d == null) return Json.map("kind", "unknown", "label", "Unknown caller");
        if (communityScam) return Json.map("kind", "scam", "label", "Reported scam number");
        if (!Boolean.TRUE.equals(d.get("valid"))) return Json.map("kind", "spoofed", "label", "Fake-looking number", "detail", "This number can't exist, so the caller ID was probably faked.");
        String t = (String) d.get("type");
        String s = d.get("series") == null ? "" : (String) d.get("series");
        if (s.startsWith("1600")) return Json.map("kind", "business", "label", "Registered bank / government service line", "detail", "1600 numbers are reserved for regulated banks, financial firms and government service calls.");
        if (s.startsWith("140")) return Json.map("kind", "telemarketer", "label", "Telemarketer (often automated)", "detail", "140 numbers are registered for advertising calls. Many are recorded or robotic messages.");
        if ("TOLL_FREE".equals(t) || "SHARED_COST".equals(t) || "UAN".equals(t)) return Json.map("kind", "business", "label", "Company helpline number", "detail", "Helplines rarely make outgoing calls, and caller ID can be faked. Call back on the official number to be sure.");
        if ("VOIP".equals(t)) return Json.map("kind", "bot", "label", "Internet number (could be a bot or call centre)", "detail", "Internet (VoIP) numbers are cheap to create and often used for automated or mass calls.");
        if ("PREMIUM_RATE".equals(t)) return Json.map("kind", "bot", "label", "Premium-rate line", "detail", "Calling back can cost a lot per minute.");
        Object c = d.get("country");
        if (c != null && !home.equals(c)) return Json.map("kind", "foreign", "label", "International caller", "detail", "Unexpected calls from abroad are a common scam pattern. Don't call back.");
        if ("FIXED_LINE".equals(t)) return Json.map("kind", "business", "label", "Landline (office or business)", "detail", d.get("location") != null ? "Landline in " + d.get("location") + "." : "A fixed landline.");
        if ("MOBILE".equals(t) || "FIXED_LINE_OR_MOBILE".equals(t)) return Json.map("kind", "person", "label", "Personal mobile number", "detail", "An ordinary mobile number, usually used by a person." + (d.get("circle") != null ? " Issued in " + d.get("circle") + "." : ""));
        return Json.map("kind", "unknown", "label", d.get("typeLabel") != null ? d.get("typeLabel") : "Unknown");
    }

    /** Incoming call / number check. extra = community or local-block reasons (may be empty). */
    public Map<String, Object> analyzeNumber(String number, List<Map<String, Object>> extra) {
        number = cap(number, 40);
        List<Map<String, Object>> reasons = new ArrayList<>();
        Map<String, Object> d = phone == null ? null : phone.lookup(number, home, "none", "organisation");
        if (d != null) for (Object o : Json.arr(d.get("signals"))) reasons.add(new LinkedHashMap<>(Json.obj(o)));
        boolean communityScam = false;
        if (extra != null) for (Map<String, Object> x : extra) { reasons.add(x); if (((String) x.get("id")).startsWith("community_scam") || "blocked_by_you".equals(x.get("id"))) communityScam = true; }
        Map<String, Object> info = Json.map("number", number == null ? null : number.replaceAll("[^\\d+]", ""), "numberDetails", d, "caller", callerKind(d, communityScam));
        return finish("number", number, reasons, info);
    }

    public Map<String, Object> analyzeAuto(String text) {
        String s = cap(text, MAX_TEXT).trim();
        if (isUpiLink(s) || isVpa(s)) return analyzeUpi(s);
        if (phone != null && s.matches("^[+\\d][\\d\\s().-]{6,20}$") && s.replaceAll("\\D", "").length() >= 7) return analyzeNumber(s, null);
        if (!s.matches(".*\\s.*") && (extractUrls(s).size() == 1 || Pattern.compile("^(https?|javascript|data):", CI).matcher(s).find())) return analyzeLink(s);
        return analyzeMessage(s);
    }

    // ------------------------------------------------------------------ community reports
    public List<Map<String, Object>> communityReasons(Map<String, Integer> byType) {
        List<Map<String, Object>> out = new ArrayList<>();
        if (byType == null || byType.isEmpty()) return out;
        Map<String, Map<String, Object>> types = new HashMap<>();
        for (Object o : Json.arr(R.get("reportTypes"))) types.put((String) Json.obj(o).get("id"), Json.obj(o));
        int scam = 0, spam = 0, safe = 0, topN = 0;
        String top = null;
        for (Map.Entry<String, Integer> e : byType.entrySet()) {
            Map<String, Object> t = types.get(e.getKey());
            String k = t == null ? "scam" : (String) t.get("kind");
            int n = e.getValue();
            if (k.equals("scam")) { scam += n; if (n > topN) { top = e.getKey(); topN = n; } }
            else if (k.equals("spam")) spam += n;
            else safe += n;
        }
        if (scam > 0) {
            String lbl = types.containsKey(top) ? ((String) types.get(top).get("label")).toLowerCase() : top;
            out.add(reason(scam >= 3 ? "community_scam_many" : "community_scam", "Reported as a scam by " + people(scam), "Most common report: " + lbl + ". Reports come from other users of this tool and aren't verified.", Math.min(50, 25 + 10 * (scam - 1))));
        }
        if (spam > 0) out.add(reason("community_spam", "Reported as spam by " + people(spam), "Other users said this number makes sales or nuisance calls.", 10));
        if (safe > 0 && scam == 0) out.add(reason("community_safe", people(safe) + " marked this number as genuine", "Reports aren't verified. A genuine-looking number can still be spoofed, so never share OTPs or PINs.", -10));
        return out;
    }

    private static String people(int n) { return n + (n == 1 ? " person" : " people"); }

    // ------------------------------------------------------------------ scoring
    private Map<String, Object> finish(String kind, Object input, List<Map<String, Object>> reasons, Map<String, Object> info) {
        reasons.sort((a, b) -> w(b) - w(a));
        int score = 0, strong = 0;
        boolean crit = false;
        for (Map<String, Object> r : reasons) {
            score += w(r);
            if (w(r) >= 25) strong++;
            if (critical.contains((String) r.get("id"))) crit = true;
        }
        if (strong >= 2) score += 10;
        if (crit) score = Math.max(score, Json.num(R.get("criticalFloor")));
        score = Math.max(0, Math.min(100, score));
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("kind", kind);
        out.put("input", input);
        out.put("score", score);
        out.put("level", level(score));
        out.put("reasons", new ArrayList<Object>(reasons));
        out.put("info", info);
        out.put("advice", advice(kind, reasons, score));
        return out;
    }

    private List<Object> advice(String kind, List<Map<String, Object>> reasons, int score) {
        Set<String> ids = new HashSet<>();
        for (Map<String, Object> r : reasons) ids.add((String) r.get("id"));
        List<Object> a = new ArrayList<>();
        if (score >= warningT) {
            switch (kind) {
                case "link": a.add("Don't open the link, and don't enter any details if you already did."); break;
                case "message": a.add("Don't reply, click links or call numbers in the message."); break;
                case "sms": a.add("Don't tap links, call back or reply to this SMS. Delete it after reporting."); break;
                case "number": a.add("Don't call back or reply to this number. If it calls again, don't share any details."); break;
                case "call": a.add("Hang up. Call the organisation back on the number printed on your card, bill or their official website."); break;
                case "upi": a.add("Don't pay or approve this request. If someone said you'd receive money this way, it's a scam."); break;
                case "payment": a.add("Don't hand over goods, services or any \"refund\" until the money shows in your own bank or UPI app."); break;
                default: break;
            }
            for (Map<String, Object> r : reasons) {
                Map<String, Object> rule = ruleById.get((String) r.get("id"));
                Object adv = rule == null ? null : rule.get("advice");
                if (adv instanceof String && !((String) adv).isEmpty() && !a.contains(adv)) a.add(adv);
            }
            if (ids.contains("otp_request") || ids.contains("asked_otp") || ids.contains("sensitive_data") || ids.contains("asked_personal")) a.add("Never share OTPs, PINs, CVV or passwords. If you already did, call your bank now to block your card or account.");
            if (ids.contains("remote_access") || ids.contains("asked_app") || ids.contains("dangerous_file") || ids.contains("apk_install")) a.add("If you installed an app they asked for, turn on flight mode, uninstall it and change your banking passwords from another device.");
            if (ids.contains("upi_receive_trick") || ids.contains("qr_collect")) a.add("Remember: you never enter a UPI PIN or scan a QR code to receive money.");
            if (ids.contains("authority_threat") || ids.contains("threat_arrest") || ids.contains("video_uniform")) a.add("There is no such thing as a \"digital arrest\". Disconnect and tell a family member.");
            if (ids.contains("impersonation_family") || ids.contains("family_emergency")) a.add("Call your relative on the number you already have for them before sending anything.");
            if (ids.contains("sextortion")) a.add("Don't pay. Stop replying, save screenshots and report it.");
            a.add("Lost money? Call 1930 (India's cyber-crime helpline) as fast as possible. Quick reports can freeze the stolen money.");
            a.add("Report it at cybercrime.gov.in, and report fraud calls or SMS on the Chakshu page of sancharsaathi.gov.in.");
        } else {
            if ("payment".equals(kind)) a.add("Open your own bank or UPI app and look for this payment before you hand anything over. A screenshot or SMS isn't enough.");
            else if ("upi".equals(kind)) a.add("Before paying, check the name your UPI app shows for this ID. Remember: you never pay or enter a PIN to receive money.");
            a.add("No strong warning signs were found, but rules can't catch everything. If it asks for money, OTPs or personal details, treat it as a scam.");
            a.add("When in doubt, contact the organisation using the official app or the number on your card, not the one in the message.");
        }
        return a;
    }
}
