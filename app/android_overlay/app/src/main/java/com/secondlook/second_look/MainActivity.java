package com.secondlook.second_look;

import android.Manifest;
import android.app.Activity;
import android.app.KeyguardManager;
import android.app.role.RoleManager;
import android.hardware.biometrics.BiometricManager;
import android.hardware.biometrics.BiometricPrompt;
import android.os.CancellationSignal;
import android.view.MotionEvent;
import android.view.WindowManager;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.InstallSourceInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.os.SystemClock;
import android.provider.Settings;
import android.speech.tts.TextToSpeech;
import android.speech.tts.Voice;
import android.telecom.TelecomManager;

import androidx.annotation.NonNull;

import com.secondlook.engine.Json;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Bridges the Flutter UI to the on-device engine and to Android's SMS/call permissions. */
public class MainActivity extends FlutterActivity {
    private static final int REQ_SMS = 41;
    private static final int REQ_ROLE = 42;
    private static final int REQ_NOTIFY = 43;
    private static final int REQ_DOC = 44;
    private static final int REQ_SMS_FIX = 45;     // Shield health "Fix": asked again, nothing waits for the answer
    private static final int REQ_NOTIFY_FIX = 46;
    private static final int REQ_ROLE_FIX = 47;
    private static final double DEFAULT_RATE = 0.92;

    /** App stores; anything else (a file manager, a browser, adb) counts as sideloaded. */
    private static final Set<String> STORES = new HashSet<>(Arrays.asList(
            "com.android.vending", "com.google.android.feedback", "com.sec.android.app.samsungapps",
            "com.xiaomi.market", "com.xiaomi.mipicks", "com.heytap.market", "com.oppo.market", "com.vivo.appstore",
            "com.huawei.appmarket", "com.hihonor.appmarket", "com.amazon.venezia"));

    /** Phone makers' "autostart" screens (package, activity). Each is checked before it's opened. */
    private static final String[][] AUTOSTART = {
            {"com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"},
            {"com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"},
            {"com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"},
            {"com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"},
            {"com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"},
            {"com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"},
    };

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private TextToSpeech tts;
    private boolean ttsReady;
    private MethodChannel channel;
    private MethodChannel.Result pending;
    private MethodChannel.Result docPending;   // "Check a document": waiting for the system file picker
    private String sharedText;
    private String pendingImagePath;   // a screenshot shared to us, copied into cache/shared/
    private boolean imageAsked;        // Dart already polled consumeSharedImage (cold start)
    private String alertId;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        applyScreenProtection();
        // Documents are never kept: remove any copy left behind if the app was closed mid-check.
        if (savedInstanceState == null) {
            Context app = getApplicationContext();
            worker.execute(() -> DocScan.clearCache(app));
        }
        readIntent(getIntent(), false);
    }

    /** Blocks screenshots, screen recording and screen-sharing apps (like AnyDesk) from seeing the app. */
    private void applyScreenProtection() {
        if (Store.bool(this, "screen_unprotected")) getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
        else getWindow().setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE);
    }

    /** Tapjacking guard: ignore taps while another app draws over us (fake overlays that trick you into switching things). */
    private long lastOverlayWarning;

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        if ((ev.getFlags() & MotionEvent.FLAG_WINDOW_IS_OBSCURED) != 0) {
            long now = System.currentTimeMillis();
            if (now - lastOverlayWarning > 8000) {
                lastOverlayWarning = now;
                android.widget.Toast.makeText(this, "Another app is drawing over Second Look, so taps are blocked for your safety. Close screen overlays and try again.", android.widget.Toast.LENGTH_LONG).show();
            }
            return false;
        }
        return super.dispatchTouchEvent(ev);
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        readIntent(intent, true);
    }

    private void readIntent(Intent i, boolean live) {
        if (i == null) return;
        if (Intent.ACTION_SEND.equals(i.getAction())) {
            Uri stream = sharedStream(i);
            String type = i.getType();
            if (stream != null && type != null && type.startsWith("image/")) {
                receiveImage(stream, live);
            } else if (i.getStringExtra(Intent.EXTRA_TEXT) != null) {
                String t = Security.capText(i.getStringExtra(Intent.EXTRA_TEXT), 10000);
                if (live && channel != null) channel.invokeMethod("onShared", t);
                else sharedText = t;
            }
        }
        String a = i.getStringExtra("alertId");
        if (Security.isAlertId(a)) {
            if (live && channel != null) channel.invokeMethod("onAlertOpened", a);
            else alertId = a;
        }
    }

    @SuppressWarnings("deprecation")
    private static Uri sharedStream(Intent i) {
        try {
            if (Build.VERSION.SDK_INT >= 33) return i.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class);
            Object o = i.getParcelableExtra(Intent.EXTRA_STREAM);
            return o instanceof Uri ? (Uri) o : null;
        } catch (RuntimeException e) {
            return null; // malformed extras from the sending app
        }
    }

    /** Share → Second Look with a screenshot: copy it off the UI thread (type and size checked), then hand the path to Dart. */
    private void receiveImage(Uri uri, boolean live) {
        worker.execute(() -> {
            String path = ImageScan.copyShared(getApplicationContext(), uri);
            runOnUiThread(() -> {
                if (path == null) {
                    android.widget.Toast.makeText(this, "Second Look couldn't open that image. Share a screenshot or photo under 15 MB.", android.widget.Toast.LENGTH_LONG).show();
                    return;
                }
                if ((live || imageAsked) && channel != null) channel.invokeMethod("onSharedImage", path);
                else pendingImagePath = path;
            });
        });
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        channel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "secondlook/native");
        channel.setMethodCallHandler(this::onCall);
    }

    private void onCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            // ---- checks run in the background so the UI never stutters ----
            case "analyze": bg(result, () -> EngineHolder.get(this).analyzeAuto(Security.capText(call.argument("text"), 10000))); return;
            case "analyzeSms": bg(result, () -> EngineHolder.get(this).analyzeSms(call.argument("sender"), call.argument("body"))); return;
            case "analyzeNumber": bg(result, () -> EngineHolder.analyzeNumber(this, call.argument("number"))); return;
            case "analyzeUpi": {
                String t = Security.capText(call.argument("text"), 2048);
                bg(result, () -> EngineHolder.get(this).analyzeUpi(t == null ? "" : t));
                return;
            }
            case "analyzePayment": {
                String t = Security.capText(call.argument("text"), 10000);
                Map<String, Object> in = new HashMap<>();
                in.put("text", t == null ? "" : t);
                in.put("expectedAmount", Security.capText(call.argument("expectedAmount"), 64));
                in.put("myUpi", Security.capText(call.argument("myUpi"), 64));
                in.put("imageEditor", Security.capText(call.argument("imageEditor"), 64));
                bg(result, () -> EngineHolder.get(this).analyzePayment(in));
                return;
            }
            // On-device OCR + QR decoding of a screenshot. Only files inside our own cache/files folders.
            // layout: true rebuilds the text in reading rows (tables such as bank statements stay row by row).
            case "readImage": {
                String path = call.argument("path");
                boolean layout = Boolean.TRUE.equals(call.argument("layout"));
                worker.execute(() -> {
                    File f = ImageScan.allowedFile(this, path);
                    if (f == null) { runOnUiThread(() -> result.error("blocked", "This image can't be opened", null)); return; }
                    try {
                        String out = ImageScan.read(f, layout);
                        runOnUiThread(() -> result.success(out));
                    } catch (Exception | OutOfMemoryError e) {
                        runOnUiThread(() -> result.error("image", "Couldn't read this image", null));
                    }
                });
                return;
            }

            // ---- "Check a document" (IDs, passports, statements, letters). Read on the phone; results are never
            //      saved to history or alerts, and nothing about the document is logged. ----
            case "pickDocument": pickDocument(result); return;
            case "readPdf": {
                String path = call.argument("path");
                worker.execute(() -> {
                    File f = ImageScan.allowedFile(this, path);
                    if (f == null) { runOnUiThread(() -> result.error("blocked", "This file can't be opened", null)); return; }
                    try {
                        String out = DocScan.readPdf(f);
                        runOnUiThread(() -> result.success(out));
                    } catch (DocScan.DocError e) {
                        runOnUiThread(() -> result.error(e.code, e.getMessage(), null));
                    } catch (RuntimeException | OutOfMemoryError e) {
                        runOnUiThread(() -> result.error("unreadable", "Couldn't open this file. It may be damaged.", null));
                    }
                });
                return;
            }
            case "verifySignature": {
                Object data = call.argument("data"), sig = call.argument("signature"), certs = call.argument("certs");
                worker.execute(() -> {
                    Boolean ok;
                    try { ok = DocScan.verifySignature(data, sig, certs); } catch (RuntimeException e) { ok = null; }
                    Boolean answer = ok;
                    runOnUiThread(() -> result.success(answer));
                });
                return;
            }
            case "analyzeDocument": {
                String input = call.argument("input");
                bg(result, () -> EngineHolder.get(this).analyzeDocument(DocScan.documentInput(input)));
                return;
            }
            case "clearDocCache": {
                Context app = getApplicationContext();
                worker.execute(() -> {
                    DocScan.clearCache(app);
                    runOnUiThread(() -> result.success(null));
                });
                return;
            }

            // ---- status and switches ----
            case "status": result.success(Json.stringify(status())); return;
            case "setSmsShield": setSmsShield(Boolean.TRUE.equals(call.argument("on")), result); return;
            case "setCallShield": setCallShield(Boolean.TRUE.equals(call.argument("on")), result); return;
            case "setAutoSilence":
                Store.put(this, "auto_silence", Boolean.TRUE.equals(call.argument("on")));
                result.success(Json.stringify(status()));
                return;
            case "setTrusted":
                try {
                    Store.put(this, "trusted_name", Security.capText((String) call.argument("name"), 60));
                    Store.put(this, "trusted_number", Security.cleanNumber(call.argument("number")));
                    result.success(Json.stringify(status()));
                } catch (RuntimeException e) {
                    result.error("storage", "Couldn't save securely on this phone", null);
                }
                return;
            case "setOnboarded": {
                String terms = call.argument("terms");
                try {
                    if (terms != null) Store.put(this, "terms_version", Security.capText(terms, 20));
                } catch (RuntimeException e) {
                    // Secure storage unavailable: still let the user in; they'll be asked again next time.
                }
                Store.put(this, "onboarded", true);
                result.success(null);
                return;
            }

            // ---- local data ----
            case "history": result.success(Json.stringify(Store.history(this))); return;
            case "clearHistory": Store.clearHistory(this); result.success(null); return;
            case "reports": result.success(Json.stringify(Store.reports(this))); return;
            case "report": {
                String num = call.argument("number"), type = call.argument("type"), label = call.argument("label"), kind = call.argument("kind");
                bg(result, () -> {
                    String e = EngineHolder.e164(this, num);
                    if (e != null) Store.report(this, e, Security.capText(type, 40), Security.capText(label, 80), "safe".equals(kind) ? "safe" : "spam".equals(kind) ? "spam" : "scam");
                    return Json.map("ok", e != null);
                });
                return;
            }
            case "removeReport": {
                String num = call.argument("number");
                if (num != null) Store.removeReport(this, num);
                result.success(null);
                return;
            }
            case "deleteAllData":
                Store.wipe(this);
                DocScan.clearCache(this);
                Security.wipeKey();
                enableSmsReceiver(false);
                result.success(null);
                return;

            // ---- actions ----
            case "openUrl": {
                String url = call.argument("url");
                if (!Security.urlAllowed(url)) { result.error("blocked", "Link not allowed", null); return; }
                start(new Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE));
                result.success(null);
                return;
            }
            case "dial": start(new Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Security.cleanNumber(call.argument("number"))))); result.success(null); return;
            case "smsTo":
                start(new Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Security.cleanNumber(call.argument("number"))))
                        .putExtra("sms_body", Security.capText((String) call.argument("body"), 500)));
                result.success(null);
                return;

            // ---- security ----
            case "securityStatus": bg(result, () -> Security.report(this)); return;
            case "setScreenProtection": {
                boolean on = Boolean.TRUE.equals(call.argument("on"));
                // Turning protection OFF needs the owner's fingerprint/PIN, so a scammer can't talk someone into it remotely.
                if (on) {
                    Store.put(this, "screen_unprotected", false);
                    applyScreenProtection();
                    result.success(Json.stringify(status()));
                } else {
                    authenticate(ok -> {
                        if (ok) { Store.put(this, "screen_unprotected", true); applyScreenProtection(); }
                        result.success(Json.stringify(status()));
                    });
                }
                return;
            }
            case "setAppLock": {
                boolean on = Boolean.TRUE.equals(call.argument("on"));
                if (!on) { authenticate(ok -> { if (ok) Store.put(this, "app_lock", false); result.success(Json.stringify(status())); }); return; }
                KeyguardManager km = getSystemService(KeyguardManager.class);
                if (km == null || !km.isDeviceSecure()) { result.error("nolock", "Set a screen lock on your phone first", null); return; }
                authenticate(ok -> { if (ok) Store.put(this, "app_lock", true); result.success(Json.stringify(status())); });
                return;
            }
            case "authenticate": authenticate(result::success); return;
            case "openSystemSettings":
                start(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
                result.success(null);
                return;
            case "setPref": {
                // Small user preferences only (language, voice read-out and voice, community protection,
                // listing every checked SMS/call, the on-screen caller card).
                String key = call.argument("key"), value = call.argument("value");
                if (key == null || !PREF_KEYS.contains(key)) {
                    result.error("blocked", "Unknown setting", null);
                    return;
                }
                if (ON_OFF_KEYS.contains(key) && !"on".equals(value) && !"off".equals(value)) {
                    result.error("blocked", "Use on or off", null);
                    return;
                }
                try {
                    Store.put(this, "pref_" + key, Security.capText(value == null ? "" : value, "voice_name".equals(key) ? 120 : 40));
                } catch (RuntimeException e) {
                    result.error("storage", "Couldn't save securely on this phone", null);
                    return;
                }
                result.success(Json.stringify(status()));
                return;
            }
            case "speak": {
                String voice = call.argument("voice");
                if (voice == null || voice.isEmpty()) voice = Store.str(this, "pref_voice_name");
                Object rateArg = call.argument("rate");
                double rate = rateArg instanceof Number ? ((Number) rateArg).doubleValue() : DEFAULT_RATE;
                if (Double.isNaN(rate)) rate = DEFAULT_RATE;
                rate = Math.max(0.5, Math.min(1.5, rate));
                speak(Security.capText(call.argument("text"), 800), call.argument("lang"), Security.capText(voice, 120), (float) rate, result);
                return;
            }
            case "stopSpeaking":
                if (ttsIniting) ttsStopped = true;
                else if (tts != null && ttsReady) tts.stop();
                result.success(null);
                return;
            case "setCommunityList": {
                String json = call.argument("json");
                worker.execute(() -> {
                    boolean ok = EngineHolder.saveCommunity(getApplicationContext(), json);
                    runOnUiThread(() -> result.success(ok));
                });
                return;
            }
            case "installId": {
                // Random id for this install, used only for the deep-check quota and Plus. Not linked to the person.
                String id = Store.str(this, "install_id");
                if (id == null || id.isEmpty()) { id = java.util.UUID.randomUUID().toString(); Store.put(this, "install_id", id); }
                result.success(id);
                return;
            }
            case "consumeSharedText": result.success(sharedText); sharedText = null; return;
            case "consumeSharedImage": imageAsked = true; result.success(pendingImagePath); pendingImagePath = null; return;
            case "consumeAlertId": result.success(alertId); alertId = null; return;

            // ---- Shield health / setup checker ----
            case "shieldHealth": bg(result, this::shieldHealth); return;
            case "openSettings": {
                boolean opened;
                try { opened = openSettings(call.argument("target")); } catch (RuntimeException e) { opened = false; }
                result.success(opened);
                return;
            }
            case "testAlert": {
                String kind = call.argument("kind");
                Context app = getApplicationContext();
                worker.execute(() -> {
                    String id;
                    try {
                        id = "call".equals(kind) ? ScreeningService.testCall(app)
                                : SmsReceiver.process(app, SmsReceiver.TEST_SENDER, SmsReceiver.TEST_BODY, true);
                    } catch (RuntimeException e) {
                        id = null;
                    }
                    String out = id;
                    runOnUiThread(() -> {
                        if (out == null) result.error("engine", "Check failed", null);
                        else result.success(out);
                    });
                });
                return;
            }

            // ---- what the user marks on an alert / number ----
            case "markNumber": {
                String num = call.argument("number"), action = call.argument("action");
                String comment = call.argument("comment"), historyId = call.argument("historyId");
                bg(result, () -> markNumber(this, num, action, comment, historyId));
                return;
            }
            case "openBlockedNumbers": result.success(openBlockedNumbers(call.argument("number"))); return;
            case "numberActions": {
                String num = call.argument("number");
                bg(result, () -> numberActions(num));
                return;
            }
            case "isAppInstalled":
                result.success("whatsapp".equals(call.argument("app")) && (installed("com.whatsapp") || installed("com.whatsapp.w4b")));
                return;
            case "openChat": {
                String num = call.argument("number");
                Context app = getApplicationContext();
                worker.execute(() -> {
                    String e;
                    try { e = EngineHolder.e164(app, num); } catch (RuntimeException ex) { e = null; }
                    String digits = e != null && e.matches("^\\+[1-9]\\d{7,14}$") ? e.substring(1) : null;
                    runOnUiThread(() -> {
                        boolean ok = false;
                        if (digits != null) {
                            // Only this method may open wa.me (it isn't in the general link allowlist).
                            ok = tryStart(new Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/" + digits)).addCategory(Intent.CATEGORY_BROWSABLE));
                        }
                        result.success(ok);
                    });
                });
                return;
            }
            case "listVoices": listVoices(call.argument("lang"), result); return;
            default: result.notImplemented();
        }
    }

    private interface Job { Object run(); }

    /** System file picker (no storage permission): PDFs and images only. One request at a time. */
    private void pickDocument(MethodChannel.Result result) {
        if (docPending != null) { result.error("busy", "A file is already being chosen", null); return; }
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
                .putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"application/pdf", "image/*"});
        docPending = result;
        try {
            startActivityForResult(i, REQ_DOC);
        } catch (ActivityNotFoundException | SecurityException e) {
            docPending = null;
            result.error("unsupported", "This phone has no file picker", null);
        }
    }

    private void onDocumentPicked(int resultCode, Intent data) {
        MethodChannel.Result r = docPending;
        docPending = null;
        if (r == null) return;
        Uri uri = resultCode == Activity.RESULT_OK && data != null ? data.getData() : null;
        if (uri == null) { r.success(null); return; } // the user backed out
        Context app = getApplicationContext();
        worker.execute(() -> {
            try {
                String out = Json.stringify(DocScan.copyPicked(app, uri));
                runOnUiThread(() -> r.success(out));
            } catch (DocScan.DocError e) {
                runOnUiThread(() -> r.error(e.code, e.getMessage(), null));
            } catch (RuntimeException | OutOfMemoryError e) {
                runOnUiThread(() -> r.error("unreadable", "Couldn't open this file. It may be damaged.", null));
            }
        });
    }

    private interface AuthDone { void done(boolean ok); }

    /** Fingerprint / face / phone PIN, using Android's own secure prompt. */
    private void authenticate(AuthDone cb) {
        KeyguardManager km = getSystemService(KeyguardManager.class);
        if (km == null || !km.isDeviceSecure()) { cb.done(true); return; } // no screen lock set: nothing to check against
        BiometricPrompt.Builder b = new BiometricPrompt.Builder(this)
                .setTitle("Unlock Second Look")
                .setSubtitle("Confirm it's you");
        if (Build.VERSION.SDK_INT >= 30) {
            b.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG | BiometricManager.Authenticators.DEVICE_CREDENTIAL);
        } else {
            b.setDeviceCredentialAllowed(true);
        }
        AtomicBoolean answered = new AtomicBoolean(false);
        b.build().authenticate(new CancellationSignal(), getMainExecutor(), new BiometricPrompt.AuthenticationCallback() {
            @Override
            public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult r) {
                if (answered.compareAndSet(false, true)) cb.done(true);
            }

            @Override
            public void onAuthenticationError(int code, CharSequence msg) {
                if (answered.compareAndSet(false, true)) cb.done(false);
            }
        });
    }

    private void bg(MethodChannel.Result result, Job job) {
        worker.execute(() -> {
            try {
                String out = Json.stringify(job.run());
                runOnUiThread(() -> result.success(out));
            } catch (SecurityException e) {
                runOnUiThread(() -> result.error("tampered", e.getMessage(), null));
            } catch (RuntimeException e) {
                runOnUiThread(() -> result.error("engine", "Check failed", null));
            }
        });
    }

    private void start(Intent i) {
        try { startActivity(i); } catch (RuntimeException ignored) { /* no app can handle it */ }
    }

    // ------------------------------------------------------------------ status
    private boolean smsGranted() { return checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED; }

    private boolean roleHeld() {
        RoleManager rm = getSystemService(RoleManager.class);
        return rm != null && rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING);
    }

    // ------------------------------------------------------------------ voice (on-device text-to-speech)
    private boolean ttsIniting;
    private final List<Runnable> ttsQueue = new ArrayList<>();   // requests that arrived while the engine was starting
    private boolean ttsStopped;                                   // "Stop" was tapped before the engine was ready

    private static String ttsLang(String lang) { return "hi".equals(lang) || "kn".equals(lang) ? lang : "en"; }

    /** Runs r once the phone's text-to-speech engine is ready (starting it if needed). r must check ttsReady. */
    private void withTts(Runnable r) {
        if (ttsIniting) { ttsQueue.add(r); return; }
        if (tts == null || !ttsReady) {
            // First use, or the last start failed: (re)start the engine and run once it's ready.
            if (tts != null) tts.shutdown();
            ttsIniting = true;
            ttsQueue.add(r);
            tts = new TextToSpeech(getApplicationContext(), status -> runOnUiThread(() -> {
                ttsIniting = false;
                ttsReady = status == TextToSpeech.SUCCESS;
                List<Runnable> q = new ArrayList<>(ttsQueue);
                ttsQueue.clear();
                for (Runnable x : q) x.run();
            }));
        } else {
            r.run();
        }
    }

    private void speak(String text, String lang, String voiceId, float rate, MethodChannel.Result result) {
        if (text == null || text.isEmpty()) { result.success(false); return; }
        String code = ttsLang(lang);
        ttsStopped = false;
        withTts(() -> speakNow(text, code, voiceId, rate, result));
    }

    private static boolean voiceFor(Voice v, String code) {
        if (v == null || v.getLocale() == null) return false;
        Locale l = v.getLocale();
        if (code.equals(l.getLanguage())) return true;
        try {
            String iso3 = l.getISO3Language();
            return ("en".equals(code) && "eng".equals(iso3)) || ("hi".equals(code) && "hin".equals(iso3)) || ("kn".equals(code) && "kan".equals(iso3));
        } catch (RuntimeException e) {
            return false;
        }
    }

    private void speakNow(String text, String code, String voiceId, float rate, MethodChannel.Result result) {
        if (ttsStopped) { result.success(true); return; } // cancelled by the user, not a missing voice
        if (!ttsReady || tts == null) { result.success(false); return; }
        Locale loc = new Locale(code, "IN");
        int avail = tts.isLanguageAvailable(loc);
        if (avail < TextToSpeech.LANG_AVAILABLE) {
            if (!"en".equals(code)) { result.success(false); return; }
            loc = Locale.ENGLISH;
        }
        tts.setLanguage(loc);
        // The voice the user picked in Settings (setLanguage resets it, so it's applied after).
        if (voiceId != null && !voiceId.isEmpty()) {
            try {
                Set<Voice> all = tts.getVoices();
                if (all != null) {
                    for (Voice v : all) {
                        if (v != null && voiceId.equals(v.getName()) && voiceFor(v, code)) { tts.setVoice(v); break; }
                    }
                }
            } catch (RuntimeException ignored) {
                // the engine can't list voices: keep its default
            }
        }
        tts.setSpeechRate(rate);
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "secondlook");
        result.success(true);
    }

    /** Installed voices for a language, best first (Indian voices, then quality, then on-device), at most 6. */
    private void listVoices(String lang, MethodChannel.Result result) {
        String code = ttsLang(lang);
        withTts(() -> {
            List<Object> out = new ArrayList<>();
            if (ttsReady && tts != null) {
                List<Voice> pick = new ArrayList<>();
                try {
                    Set<Voice> all = tts.getVoices();
                    if (all != null) {
                        for (Voice v : all) {
                            if (!voiceFor(v, code)) continue;
                            Set<String> f = v.getFeatures();
                            if (f != null && f.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) continue;
                            if (v.getName() == null) continue;
                            pick.add(v);
                        }
                    }
                } catch (RuntimeException ignored) {
                    // the engine can't list voices
                }
                pick.sort((a, b) -> {
                    int ia = "IN".equals(a.getLocale().getCountry()) ? 0 : 1, ib = "IN".equals(b.getLocale().getCountry()) ? 0 : 1;
                    if (ia != ib) return ia - ib;
                    if (a.getQuality() != b.getQuality()) return b.getQuality() - a.getQuality();
                    if (a.isNetworkConnectionRequired() != b.isNetworkConnectionRequired()) return a.isNetworkConnectionRequired() ? 1 : -1;
                    return a.getName().compareTo(b.getName());
                });
                for (Voice v : pick) {
                    if (out.size() >= 6) break;
                    out.add(Json.map("id", v.getName(), "label", "Voice " + (out.size() + 1), "quality", v.getQuality(),
                            "network", v.isNetworkConnectionRequired()));
                }
            }
            result.success(Json.stringify(out));
        });
    }

    @Override
    protected void onDestroy() {
        if (tts != null) { tts.shutdown(); tts = null; ttsReady = false; }
        if (isFinishing()) {
            Context app = getApplicationContext();
            worker.execute(() -> DocScan.clearCache(app)); // never leave a document copy behind
        }
        super.onDestroy();
    }

    @Override
    protected void onResume() {
        super.onResume();
        // The user may have allowed SMS access in Settings (for example after "Allow restricted settings").
        if (Store.bool(this, "sms_on") && !smsReceiverEnabled()) enableSmsReceiver(true);
    }

    // ------------------------------------------------------------------ Shield health / setup checker
    private static final Set<String> PREF_KEYS = new HashSet<>(Arrays.asList(
            "language", "voice", "community_off", "community_sync", "voice_name", "log_all", "call_popup", "voice_rate", "sms_popup"));
    private static final Set<String> ON_OFF_KEYS = new HashSet<>(Arrays.asList("voice", "log_all", "call_popup", "sms_popup"));
    private static final Set<String> MARK_ACTIONS = new HashSet<>(Arrays.asList("block", "spam", "fraud", "safe", "comment", "unblock"));
    private long roleAskedAt;

    /** Requests permissions and remembers that each was asked (to tell "never asked" from "permanently denied"). */
    private void askPermissions(String[] perms, int code) {
        for (String p : perms) Store.put(this, "asked_" + p, true);
        requestPermissions(perms, code);
    }

    /** Installed from a file / browser / adb rather than an app store. */
    @SuppressWarnings("deprecation")
    private boolean sideloaded() {
        String installer;
        try {
            PackageManager pm = getPackageManager();
            if (Build.VERSION.SDK_INT >= 30) {
                InstallSourceInfo info = pm.getInstallSourceInfo(getPackageName());
                installer = info.getInstallingPackageName();
            } else {
                installer = pm.getInstallerPackageName(getPackageName());
            }
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            installer = null;
        }
        return installer == null || !STORES.contains(installer);
    }

    private boolean smsReceiverEnabled() {
        try {
            return getPackageManager().getComponentEnabledSetting(new ComponentName(this, SmsReceiver.class))
                    == PackageManager.COMPONENT_ENABLED_STATE_ENABLED;
        } catch (RuntimeException e) {
            return false;
        }
    }

    private boolean batteryUnrestricted() {
        boolean ignoring = false, restricted = false;
        try {
            PowerManager pm = getSystemService(PowerManager.class);
            ignoring = pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
        } catch (RuntimeException ignored) {
            // unknown
        }
        try {
            android.app.ActivityManager am = getSystemService(android.app.ActivityManager.class);
            restricted = am != null && am.isBackgroundRestricted();
        } catch (RuntimeException ignored) {
            // unknown
        }
        return ignoring && !restricted;
    }

    private boolean batteryOptimized() {
        try {
            PowerManager pm = getSystemService(PowerManager.class);
            return pm == null || !pm.isIgnoringBatteryOptimizations(getPackageName());
        } catch (RuntimeException e) {
            return true;
        }
    }

    private boolean backgroundRestricted() {
        try {
            android.app.ActivityManager am = getSystemService(android.app.ActivityManager.class);
            return am != null && am.isBackgroundRestricted();
        } catch (RuntimeException e) {
            return false;
        }
    }

    private boolean isSamsung() {
        String m = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER.toLowerCase(Locale.ROOT);
        return m.contains("samsung");
    }

    /** The phone maker's autostart screen, if this phone has one (Samsung: its battery page for this app). */
    private Intent autostartIntent() {
        PackageManager pm = getPackageManager();
        for (String[] a : AUTOSTART) {
            try {
                Intent i = new Intent().setComponent(new ComponentName(a[0], a[1]));
                if (i.resolveActivity(pm) != null) return i;
            } catch (RuntimeException ignored) {
                // not on this phone
            }
        }
        if (isSamsung()) return appDetails();
        return null;
    }

    private Intent appDetails() {
        return new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()));
    }

    private Intent appNotificationSettings() {
        return new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName());
    }

    /** Starts a screen; false if this phone has no such screen or refuses to open it. */
    private boolean tryStart(Intent i) {
        if (i == null) return false;
        try {
            startActivity(i);
            return true;
        } catch (RuntimeException e) {
            return false;
        }
    }

    private Map<String, Object> shieldHealth() {
        boolean smsPermission = smsGranted();
        boolean smsWanted = Store.bool(this, "sms_on");
        boolean sideloaded = sideloaded();
        int sdk = Build.VERSION.SDK_INT;
        return Json.map(
                "sdk", sdk,
                "manufacturer", Build.MANUFACTURER == null ? "" : Build.MANUFACTURER,
                "sideloaded", sideloaded,
                "smsPermission", smsPermission,
                "smsWanted", smsWanted,
                "smsReceiverEnabled", smsReceiverEnabled(),
                "notificationsAllowed", Notifier.allowed(this),
                "alertChannelOn", Notifier.alertChannelOn(this),
                "callRoleHeld", roleHeld(),
                "callWanted", Store.bool(this, "call_on"),
                "overlayAllowed", CallPopup.allowed(this),
                "batteryUnrestricted", batteryUnrestricted(),
                "batteryOptimized", batteryOptimized(),
                "backgroundRestricted", backgroundRestricted(),
                "restrictedSettingsLikely", sdk >= 33 && sideloaded && smsWanted && !smsPermission,
                "autostartPage", autostartIntent() != null);
    }

    /** Opens the screen that fixes one Shield health item. True if a screen (or a permission prompt) opened. */
    private boolean openSettings(String target) {
        if (target == null) return false;
        String pkg = getPackageName();
        switch (target) {
            case "app":
                return tryStart(appDetails());
            case "notifications":
                return fixNotifications();
            case "overlay": {
                if (tryStart(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + pkg)))) return true;
                // Some Xiaomi phones keep "Display pop-up windows" in their own permission editor.
                Intent miui = new Intent("miui.intent.action.APP_PERM_EDITOR").putExtra("extra_pkgname", pkg);
                return tryStart(miui) || tryStart(appDetails());
            }
            case "battery":
                // Android 12+: App info → Battery → Unrestricted is the clearest place. No special permission used.
                if (Build.VERSION.SDK_INT >= 31 && tryStart(appDetails())) return true;
                return tryStart(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) || tryStart(appDetails());
            case "callRole":
                return fixCallRole();
            case "autostart": {
                Intent a = autostartIntent();
                return (a != null && tryStart(a)) || tryStart(appDetails());
            }
            case "sms":
                return fixSms();
            default:
                return false;
        }
    }

    private boolean fixNotifications() {
        String perm = Manifest.permission.POST_NOTIFICATIONS;
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) {
            if (!Store.bool(this, "asked_" + perm) || shouldShowRequestPermissionRationale(perm)) {
                askPermissions(new String[]{perm}, REQ_NOTIFY_FIX);
                return true;
            }
        }
        if (Notifier.allowed(this) && !Notifier.alertChannelOn(this)) {
            Intent ch = new Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName())
                    .putExtra(Settings.EXTRA_CHANNEL_ID, Notifier.CH_ALERTS);
            if (tryStart(ch)) return true;
        }
        return tryStart(appNotificationSettings()) || tryStart(appDetails());
    }

    private boolean fixSms() {
        Store.put(this, "sms_on", true);
        enableSmsReceiver(true);
        String perm = Manifest.permission.RECEIVE_SMS;
        if (smsGranted()) return false; // nothing to fix
        boolean asked = Store.bool(this, "asked_" + perm);
        boolean restricted = Build.VERSION.SDK_INT >= 33 && sideloaded();
        if (!asked || (!restricted && shouldShowRequestPermissionRationale(perm))) {
            askPermissions(new String[]{perm}, REQ_SMS_FIX);
            return true;
        }
        // Permanently denied, or blocked as a restricted setting: App info (⋮ → Allow restricted settings, then Permissions → SMS).
        return tryStart(appDetails());
    }

    private boolean fixCallRole() {
        Store.put(this, "call_on", true);
        RoleManager rm = getSystemService(RoleManager.class);
        try {
            if (rm != null && rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING) && !rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING)) {
                roleAskedAt = SystemClock.elapsedRealtime();
                startActivityForResult(rm.createRequestRoleIntent(RoleManager.ROLE_CALL_SCREENING), REQ_ROLE_FIX);
                return true;
            }
        } catch (RuntimeException ignored) {
            // fall back to the Default apps screen
        }
        return tryStart(new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)) || tryStart(appDetails());
    }

    @SuppressWarnings("deprecation")
    private boolean installed(String pkg) {
        try {
            getPackageManager().getPackageInfo(pkg, 0);
            return true;
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            return false;
        }
    }

    /**
     * Block / Spam / Fraud / Safe / comment / unblock for a number or sender header. Works from any Context (the
     * method channel and the on-screen card both use it). Call off the main thread.
     */
    static Map<String, Object> markNumber(Context ctx, String number, String action, String comment, String historyId) {
        if (action == null || !MARK_ACTIONS.contains(action)) return Json.map("ok", false);
        Context c = ctx.getApplicationContext();
        String key = EngineHolder.senderKey(c, number);
        if (key == null) return Json.map("ok", false);
        String note = Security.cleanComment(comment);
        switch (action) {
            case "block": Store.report(c, key, "blocked", "Blocked", "scam", true); break;
            case "spam": Store.report(c, key, "spam", "Spam", "spam"); break;
            case "fraud": Store.report(c, key, "fraud", "Fraud", "scam"); break;
            case "safe": Store.report(c, key, "safe", "Safe", "safe"); break;
            case "unblock": Store.removeReport(c, key); break;
            default: break; // comment: only noted
        }
        long now = System.currentTimeMillis();
        String hid = Security.isAlertId(historyId) ? historyId : null;
        Map<String, Object> entry = Json.map("number", key, "action", action, "comment", note, "at", now);
        if (hid != null) entry.put("historyId", hid);
        Store.addAction(c, entry);
        if (hid != null) Store.setUserAction(c, hid, Store.userAction(action, note, now));
        return Json.map("ok", true);
    }

    /**
     * Opens the phone's own blocked-numbers screen (blocks calls AND SMS phone-wide, and keeps working even if Second
     * Look is removed), with the number copied to the clipboard so the user can paste it. Falls back to the dialer
     * with the number filled in (the user blocks it from the dialer's menu). True if a screen opened.
     */
    private boolean openBlockedNumbers(String number) {
        String n = Security.cleanNumber(number);
        if (!n.isEmpty()) {
            try {
                ClipboardManager cm = getSystemService(ClipboardManager.class);
                if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("Number", n));
            } catch (RuntimeException ignored) {
                // clipboard unavailable: the screen still opens
            }
        }
        try {
            TelecomManager tm = getSystemService(TelecomManager.class);
            if (tm != null && tryStart(tm.createManageBlockedNumbersIntent())) return true;
        } catch (RuntimeException ignored) {
            // not available on this phone: use the dialer
        }
        return tryStart(new Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + n)));
    }

    /** The user's marks, newest first; only those for one number when given. */
    private List<Object> numberActions(String number) {
        List<Object> all = Store.actions(this);
        if (number == null || number.trim().isEmpty()) return all;
        String key = EngineHolder.senderKey(this, number);
        List<Object> out = new ArrayList<>();
        if (key == null) return out;
        for (Object o : all) {
            if (o instanceof Map && key.equals(Json.obj(o).get("number"))) out.add(o);
        }
        return out;
    }

    private Map<String, Object> status() {
        boolean smsWanted = Store.bool(this, "sms_on"), callWanted = Store.bool(this, "call_on");
        return Json.map(
                "platform", "android",
                "onboarded", Store.bool(this, "onboarded"),
                "termsVersion", Store.str(this, "terms_version"),
                "prefs", Json.map(
                        "language", Store.str(this, "pref_language"),
                        // Read-out is OFF unless the user switched it on (missing / '' = off).
                        "voice", "on".equals(Store.str(this, "pref_voice")) ? "on" : "off",
                        "voice_name", Store.str(this, "pref_voice_name"),
                        "voice_rate", Store.str(this, "pref_voice_rate"),
                        "log_all", Store.prefOn(this, "log_all", true) ? "on" : "off",
                        "call_popup", Store.prefOn(this, "call_popup", true) ? "on" : "off",
                        "sms_popup", Store.prefOn(this, "sms_popup", true) ? "on" : "off",
                        "community_off", Store.str(this, "pref_community_off"),
                        "community_sync", Store.str(this, "pref_community_sync")),
                "communityCount", EngineHolder.communityCount(this),
                "smsShield", smsWanted && smsGranted(),
                "smsNeedsPermission", smsWanted && !smsGranted(),
                "callShield", callWanted && roleHeld(),
                "callNeedsRole", callWanted && !roleHeld(),
                "autoSilence", Store.bool(this, "auto_silence"),
                "appLock", Store.bool(this, "app_lock"),
                "screenProtection", !Store.bool(this, "screen_unprotected"),
                "trustedName", Store.str(this, "trusted_name"),
                "trustedNumber", Store.str(this, "trusted_number"),
                "overlayAllowed", CallPopup.allowed(this));
    }

    private void enableSmsReceiver(boolean on) {
        getPackageManager().setComponentEnabledSetting(new ComponentName(this, SmsReceiver.class),
                on ? PackageManager.COMPONENT_ENABLED_STATE_ENABLED : PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP);
    }

    // ------------------------------------------------------------------ SMS Shield ON/OFF
    private void setSmsShield(boolean on, MethodChannel.Result result) {
        Store.put(this, "sms_on", on);
        enableSmsReceiver(on);
        if (on) {
            List<String> ask = new ArrayList<>();
            if (!smsGranted()) ask.add(Manifest.permission.RECEIVE_SMS);
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                ask.add(Manifest.permission.POST_NOTIFICATIONS);
            if (!ask.isEmpty()) {
                pending = result;
                askPermissions(ask.toArray(new String[0]), REQ_SMS);
                return;
            }
        }
        result.success(Json.stringify(status()));
    }

    // ------------------------------------------------------------------ Call Shield ON/OFF
    private void setCallShield(boolean on, MethodChannel.Result result) {
        Store.put(this, "call_on", on);
        if (on && !roleHeld()) {
            RoleManager rm = getSystemService(RoleManager.class);
            if (rm != null && rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING)) {
                pending = result;
                startActivityForResult(rm.createRequestRoleIntent(RoleManager.ROLE_CALL_SCREENING), REQ_ROLE);
                return;
            }
        }
        if (on && Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            pending = result;
            askPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
            return;
        }
        // Turning OFF: the service ignores calls from now on. The user can also remove the role in system settings.
        result.success(Json.stringify(status()));
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_SMS && !smsGranted()) {
            if (Build.VERSION.SDK_INT >= 33 && sideloaded()) {
                // Android 13+ silently refuses SMS access to apps installed from a file until "Allow restricted
                // settings" is turned on in App info. Keep the shield wanted so Shield health can explain the fix.
            } else {
                // The user said no: respect it and switch the shield back off.
                Store.put(this, "sms_on", false);
                enableSmsReceiver(false);
            }
        }
        if (requestCode == REQ_SMS || requestCode == REQ_NOTIFY) finishPending();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_DOC) { onDocumentPicked(resultCode, data); return; }
        if (requestCode == REQ_ROLE_FIX) {
            // Android answers "no" at once (without asking) after the user declined twice: open Default apps instead.
            if (!roleHeld() && SystemClock.elapsedRealtime() - roleAskedAt < 700) {
                tryStart(new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS));
            }
            return;
        }
        if (requestCode == REQ_ROLE) {
            if (!roleHeld()) Store.put(this, "call_on", false);
            else if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                askPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
                return;
            }
            finishPending();
        }
    }

    private void finishPending() {
        if (pending != null) {
            pending.success(Json.stringify(status()));
            pending = null;
        }
    }
}
