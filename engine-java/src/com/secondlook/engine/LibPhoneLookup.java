package com.secondlook.engine;

import com.google.i18n.phonenumbers.NumberParseException;
import com.google.i18n.phonenumbers.PhoneNumberUtil;
import com.google.i18n.phonenumbers.PhoneNumberUtil.PhoneNumberFormat;
import com.google.i18n.phonenumbers.PhoneNumberUtil.PhoneNumberType;
import com.google.i18n.phonenumbers.Phonenumber.PhoneNumber;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Phone lookup for Android (port of phone.js) using Google's libphonenumber + phone_data.json. Offline. */
public final class LibPhoneLookup implements Engine.PhoneLookup {
    private static final List<String> OFFICIAL_ORGS = Arrays.asList("bank", "police", "telecom", "govt", "courier", "utility", "company");
    private static final Map<PhoneNumberType, String[]> TYPES = new HashMap<>();

    static {
        TYPES.put(PhoneNumberType.MOBILE, new String[]{"MOBILE", "Mobile"});
        TYPES.put(PhoneNumberType.FIXED_LINE, new String[]{"FIXED_LINE", "Landline"});
        TYPES.put(PhoneNumberType.FIXED_LINE_OR_MOBILE, new String[]{"FIXED_LINE_OR_MOBILE", "Mobile or landline"});
        TYPES.put(PhoneNumberType.TOLL_FREE, new String[]{"TOLL_FREE", "Toll-free"});
        TYPES.put(PhoneNumberType.PREMIUM_RATE, new String[]{"PREMIUM_RATE", "Premium-rate"});
        TYPES.put(PhoneNumberType.SHARED_COST, new String[]{"SHARED_COST", "Shared-cost"});
        TYPES.put(PhoneNumberType.VOIP, new String[]{"VOIP", "Internet (VoIP) number"});
        TYPES.put(PhoneNumberType.PERSONAL_NUMBER, new String[]{"PERSONAL_NUMBER", "Personal / forwarding number"});
        TYPES.put(PhoneNumberType.PAGER, new String[]{"PAGER", "Pager"});
        TYPES.put(PhoneNumberType.UAN, new String[]{"UAN", "Company number (UAN)"});
        TYPES.put(PhoneNumberType.VOICEMAIL, new String[]{"VOICEMAIL", "Voicemail"});
    }

    private final PhoneNumberUtil util = PhoneNumberUtil.getInstance();
    private final Map<String, Integer> carriers = new HashMap<>();
    private final List<Object> carrierNames;
    private final Map<String, Object> carrierNotes, geoIN, circleNames;
    private final Map<String, String> circles = new HashMap<>();

    public LibPhoneLookup(String phoneDataJson) {
        Map<String, Object> d = Json.obj(Json.parse(phoneDataJson));
        carrierNames = Json.arr(d.get("carrierNames"));
        carrierNotes = Json.obj(d.get("carrierNotes"));
        geoIN = Json.obj(d.get("geoIN"));
        circleNames = Json.obj(d.get("circleNames"));
        for (String pair : ((String) d.get("carriers")).split(",")) {
            int i = pair.indexOf(':');
            carriers.put(pair.substring(0, i), Integer.parseInt(pair.substring(i + 1)));
        }
        String cs = (String) d.get("circleIN");
        for (int i = 0; i + 6 <= cs.length(); i += 6) circles.put(cs.substring(i, i + 4), cs.substring(i + 4, i + 6));
    }

    private static String cleanup(String raw) {
        String s = raw == null ? "" : raw.trim().replaceAll("[^\\d+]", "");
        return s.startsWith("00") ? "+" + s.substring(2) : s;
    }

    private static Object longest(Map<String, ?> m, String digits) {
        for (int n = Math.min(digits.length(), 12); n >= 2; n--) {
            Object v = m.get(digits.substring(0, n));
            if (v != null) return v;
        }
        return null;
    }

    private static Map<String, Object> sig(String id, String title, String detail, int weight) {
        return Json.map("id", id, "title", title, "detail", detail, "weight", weight);
    }

    @Override
    public Map<String, Object> lookup(String raw, String home, String claimedOrg, String claimedLabel) {
        String s = cleanup(raw);
        if (s.replaceAll("\\D", "").length() < 3) return null;
        Map<String, Object> res = new LinkedHashMap<>();
        List<Object> signals = new ArrayList<>();
        res.put("input", raw == null ? "" : raw);
        res.put("valid", false);
        PhoneNumber p;
        try {
            p = util.parse(s, home);
        } catch (NumberParseException e) {
            res.put("e164", s);
            res.put("typeLabel", "Unknown");
            signals.add(sig("unparsed", "Not a recognisable phone number", "This doesn't match any country's numbering plan. Caller ID can be faked, so treat it with suspicion.", 15));
            res.put("signals", signals);
            return res;
        }
        boolean valid = util.isValidNumber(p);
        String e164 = util.format(p, PhoneNumberFormat.E164);
        String digits = e164.replaceAll("\\D", "");
        String region = util.getRegionCodeForNumber(p);
        if (region == null || "ZZ".equals(region) || "001".equals(region)) {
            String r2 = util.getRegionCodeForCountryCode(p.getCountryCode());
            region = (r2 == null || "ZZ".equals(r2) || "001".equals(r2)) ? null : r2;
        }
        res.put("valid", valid);
        res.put("possible", util.isPossibleNumber(p));
        res.put("e164", e164);
        res.put("international", util.format(p, PhoneNumberFormat.INTERNATIONAL));
        res.put("national", util.format(p, PhoneNumberFormat.NATIONAL));
        res.put("callingCode", "+" + p.getCountryCode());
        res.put("country", region);
        res.put("countryName", region == null ? null : new Locale("", region).getDisplayCountry(Locale.ENGLISH));
        String[] t = valid ? TYPES.get(util.getNumberType(p)) : null;
        String type = t == null ? null : t[0];
        res.put("type", type);
        res.put("typeLabel", t != null ? t[1] : (valid ? "Phone number" : "Invalid"));
        Object ci = longest(carriers, digits);
        if (ci != null) {
            String name = (String) carrierNames.get((Integer) ci);
            res.put("carrier", name);
            res.put("carrierNote", carrierNotes.get(name));
        }
        String nsn = String.valueOf(p.getNationalNumber());
        if ("IN".equals(region)) {
            Object loc = longest(geoIN, digits);
            if (loc != null && !"India".equals(loc)) res.put("location", loc);
            if (nsn.matches("^[6-9]\\d{9}$") && !"FIXED_LINE".equals(type)) {
                String cc = circles.get(nsn.substring(0, 4));
                if (cc != null) { res.put("circleCode", cc); res.put("circle", circleNames.containsKey(cc) ? circleNames.get(cc) : cc); }
            }
        }
        boolean isHome = home.equals(region);
        boolean official = OFFICIAL_ORGS.contains(claimedOrg);
        if ("IN".equals(region)) {
            if (nsn.matches("^1600\\d{6}$")) {
                res.put("series", "1600 series: registered service calls from banks, financial firms and government (TRAI)");
                res.put("typeLabel", "Official service-call number (1600)");
                signals.add(sig("series_1600", "Calling from the official 1600 service-call series", "TRAI reserves 1600 numbers for service and transaction calls from regulated banks, insurers, financial firms and government. Still, never share an OTP or PIN on any call.", -15));
            } else if (nsn.startsWith("140")) {
                res.put("series", "140 series: registered promotional telemarketing");
                res.put("typeLabel", "Telemarketing number (140)");
                signals.add(sig("series_140", official ? "Telemarketing (140) number claiming to be official" : "Promotional telemarketing number (140 series)",
                        official ? "140 numbers are only for advertising calls. Banks and government make service calls from 1600 numbers, so this caller isn't who they say." : "This is a registered advertising caller. It's a sales call, not your bank or a government office.",
                        official ? 20 : 0));
            } else if (nsn.matches("^18[06]0.*")) {
                res.put("series", "Toll-free / customer-care number");
                signals.add(sig("tollfree_caller", "Caller ID shows a toll-free number", "Toll-free numbers are mostly used to receive calls, not make them, and caller ID can be faked to look like a helpline. Hang up and call the helpline yourself.", 10));
            }
        }
        Object cn = res.get("countryName");
        String where = cn != null ? (String) cn : (String) res.get("callingCode");
        if (!valid) signals.add(sig("invalid", "Not a valid number" + (cn != null ? " for " + cn : ""), "The number doesn't fit that country's numbering plan. Scammers often fake (spoof) caller ID, which can produce impossible numbers.", 20));
        if (region != null && !isHome) {
            if (official) signals.add(sig("intl_number", "Foreign number (" + where + ") claiming to be a local organisation", "The caller said they were from a local " + claimedLabel + ", but the number is from " + where + ". Local offices don't call from abroad.", 30));
            else signals.add(sig("intl_unknown", "International number (" + where + ")", "Unexpected calls and missed calls from abroad are often scams. Don't call back: some numbers charge you a lot per minute.", 20));
        }
        if ("PREMIUM_RATE".equals(type)) signals.add(sig("premium", "Premium-rate number", "Calling this number back can cost a lot per minute.", 25));
        if ("VOIP".equals(type)) signals.add(sig("voip", "Internet (VoIP) number", "VoIP numbers are cheap and easy to create anonymously, which makes them popular for scam calls.", 15));
        if (isHome && official && "MOBILE".equals(type) && "IN".equals(home))
            signals.add(sig("personal_mobile", "Official-sounding caller using an ordinary mobile number", "Banks, police and government offices don't normally call from personal 10-digit mobile numbers.", 25));
        res.put("signals", signals);
        return res;
    }

    private static final Pattern NUM_RE = Pattern.compile("(?:\\+|\\b00)?\\d[\\d\\s().-]{7,16}\\d");

    @Override
    public List<String> extract(String text, String home) {
        List<String> out = new ArrayList<>();
        Matcher m = NUM_RE.matcher(text == null ? "" : text);
        while (m.find() && out.size() < 5) {
            String raw = m.group().trim();
            int len = raw.replaceAll("\\D", "").length();
            if (len < 8 || len > 15 || raw.matches("^\\d{1,2}[./-]\\d{1,2}[./-]\\d{2,4}$")) continue;
            try {
                PhoneNumber p = util.parse(cleanup(raw), home);
                String e = util.format(p, PhoneNumberFormat.E164);
                if (util.isPossibleNumber(p) && !out.contains(e)) out.add(e);
            } catch (NumberParseException ignored) {
                // not a number
            }
        }
        return out;
    }
}
