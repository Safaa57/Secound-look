package com.secondlook.second_look;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Build;
import android.os.Debug;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Self-protection for Second Look:
 * - AES-256-GCM encryption of everything stored, with a key that lives in the Android Keystore
 *   (hardware-backed on most phones) and can't be copied off the device.
 * - Tamper checks: signing certificate, rules/data file hashes, debugger, hooking frameworks, root.
 * - Strict validation of anything that arrives from outside the app (URLs, numbers, ids).
 */
final class Security {
    private static final String KEY_ALIAS = "secondlook.storage.v1";
    private static final String PREFIX = "enc1:";

    private Security() { }

    // ------------------------------------------------------------------ encrypted storage
    private static synchronized SecretKey key() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (ks.containsAlias(KEY_ALIAS)) return ((KeyStore.SecretKeyEntry) ks.getEntry(KEY_ALIAS, null)).getSecretKey();
        KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        kg.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build());
        return kg.generateKey();
    }

    static String encrypt(String plain) {
        if (plain == null) return null;
        try {
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, key());
            byte[] iv = c.getIV();
            byte[] ct = c.doFinal(plain.getBytes(StandardCharsets.UTF_8));
            byte[] out = new byte[1 + iv.length + ct.length];
            out[0] = (byte) iv.length;
            System.arraycopy(iv, 0, out, 1, iv.length);
            System.arraycopy(ct, 0, out, 1 + iv.length, ct.length);
            return PREFIX + Base64.encodeToString(out, Base64.NO_WRAP);
        } catch (Exception e) {
            // Never fall back to storing plain text.
            throw new IllegalStateException("Secure storage unavailable", e);
        }
    }

    /** Returns null if the value can't be decrypted (for example it was tampered with). */
    static String decrypt(String stored) {
        if (stored == null || !stored.startsWith(PREFIX)) return null;
        try {
            byte[] in = Base64.decode(stored.substring(PREFIX.length()), Base64.NO_WRAP);
            int ivLen = in[0];
            if (ivLen < 12 || ivLen > 16 || in.length < 1 + ivLen + 16) return null;
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, in, 1, ivLen));
            byte[] pt = c.doFinal(in, 1 + ivLen, in.length - 1 - ivLen);
            return new String(pt, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return null;
        }
    }

    /** Destroys the storage key: everything encrypted with it becomes unreadable for good. */
    static synchronized void wipeKey() {
        try {
            KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
            ks.load(null);
            if (ks.containsAlias(KEY_ALIAS)) ks.deleteEntry(KEY_ALIAS);
        } catch (Exception ignored) {
            // nothing to delete
        }
    }

    // ------------------------------------------------------------------ integrity
    static String sha256Hex(byte[] data) {
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(data);
            StringBuilder b = new StringBuilder();
            for (byte x : d) b.append(String.format("%02x", x));
            return b.toString();
        } catch (Exception e) {
            return "";
        }
    }

    static String assetHash(Context c, String name) {
        try (InputStream in = c.getAssets().open(name)) {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            StringBuilder b = new StringBuilder();
            for (byte x : md.digest()) b.append(String.format("%02x", x));
            return b.toString();
        } catch (Exception e) {
            return "";
        }
    }

    /** True when the scam rules and number data are exactly the files we shipped. */
    static boolean assetsIntact(Context c) {
        if (Integrity.RULES_SHA256.isEmpty()) return true; // not configured (development build)
        return Integrity.RULES_SHA256.equals(assetHash(c, "secondlook/rules.json"))
                && Integrity.PHONE_DATA_SHA256.equals(assetHash(c, "secondlook/phone_data.json"));
    }

    @SuppressWarnings("deprecation")
    static String signingCertSha256(Context c) {
        try {
            PackageManager pm = c.getPackageManager();
            Signature[] sigs;
            if (Build.VERSION.SDK_INT >= 28) {
                PackageInfo pi = pm.getPackageInfo(c.getPackageName(), PackageManager.GET_SIGNING_CERTIFICATES);
                sigs = pi.signingInfo.hasMultipleSigners() ? pi.signingInfo.getApkContentsSigners() : pi.signingInfo.getSigningCertificateHistory();
            } else {
                sigs = pm.getPackageInfo(c.getPackageName(), PackageManager.GET_SIGNATURES).signatures;
            }
            return sigs == null || sigs.length == 0 ? "" : sha256Hex(sigs[0].toByteArray());
        } catch (Exception e) {
            return "";
        }
    }

    /** True when the app is signed with our release key (skipped until a key is configured). */
    static boolean signatureOk(Context c) {
        if (Integrity.SIGNING_CERT_SHA256.isEmpty()) return true;
        return Integrity.SIGNING_CERT_SHA256.equalsIgnoreCase(signingCertSha256(c));
    }

    static boolean debuggerAttached(Context c) {
        boolean debuggable = (c.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        return !debuggable && (Debug.isDebuggerConnected() || Debug.waitingForDebugger());
    }

    /** Looks for Frida/Xposed-style hooking tools inside our own process. */
    static boolean hookingDetected() {
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/self/maps"))) {
            String line;
            while ((line = r.readLine()) != null) {
                String l = line.toLowerCase();
                if (l.contains("frida") || l.contains("gadget") || l.contains("xposed") || l.contains("lsposed") || l.contains("substrate")) return true;
            }
        } catch (Exception ignored) {
            // unreadable: no evidence
        }
        for (String cls : new String[]{"de.robv.android.xposed.XposedBridge", "com.saurik.substrate.MS"}) {
            try { Class.forName(cls); return true; } catch (Throwable ignored) { /* not present */ }
        }
        return false;
    }

    static boolean rooted() {
        if (Build.TAGS != null && Build.TAGS.contains("test-keys")) return true;
        String[] paths = {"/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su", "/system/app/Superuser.apk",
                "/data/adb/magisk", "/data/adb/ksu", "/system/bin/.ext/su", "/vendor/bin/su"};
        for (String p : paths) if (new File(p).exists()) return true;
        return false;
    }

    /** Snapshot for the in-app Security check. Call off the main thread. */
    static Map<String, Object> report(Context c) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("encryptedStorage", storageWorks());
        m.put("privateChecks", true); // messages, numbers and contacts are never sent; only links the user chooses to deep check
        m.put("signatureOk", signatureOk(c));
        m.put("signatureConfigured", !Integrity.SIGNING_CERT_SHA256.isEmpty());
        m.put("rulesIntact", assetsIntact(c));
        m.put("debugger", debuggerAttached(c));
        m.put("hooking", hookingDetected());
        m.put("rooted", rooted());
        m.put("screenProtection", !Store.bool(c, "screen_unprotected"));
        m.put("appLock", Store.bool(c, "app_lock"));
        return m;
    }

    private static boolean storageWorks() {
        try { return "ok".equals(decrypt(encrypt("ok"))); } catch (RuntimeException e) { return false; }
    }

    // ------------------------------------------------------------------ input validation
    private static final Pattern SAFE_URLS = Pattern.compile(
            "^https://(docs\\.cloud\\.google\\.com/web-risk/docs/advisory"
            + "|www\\.antiphishing\\.org/?"
            + "|www\\.google\\.com/search\\?q=[A-Za-z0-9%+._-]{1,200}"
            + "|cybercrime\\.gov\\.in/?"
            + "|sancharsaathi\\.gov\\.in/?)$");

    /** Only our own fixed https destinations may be opened from the app. */
    static boolean urlAllowed(String url) { return url != null && url.length() < 600 && SAFE_URLS.matcher(url).matches(); }

    /** Keeps only characters that belong in a phone number. */
    static String cleanNumber(String n) {
        if (n == null) return "";
        String s = n.replaceAll("[^0-9+]", "");
        return s.length() > 20 ? s.substring(0, 20) : s;
    }

    static boolean isAlertId(String id) {
        return id != null && id.matches("^(call-\\d{1,20}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$");
    }

    static String capText(String s, int max) { return s == null ? null : (s.length() > max ? s.substring(0, max) : s); }
}
