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
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.speech.tts.TextToSpeech;

import androidx.annotation.NonNull;

import com.secondlook.engine.Json;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
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
                // Small user preferences only (language, voice read-out, community protection).
                String key = call.argument("key"), value = call.argument("value");
                if (!"language".equals(key) && !"voice".equals(key) && !"community_off".equals(key) && !"community_sync".equals(key)) {
                    result.error("blocked", "Unknown setting", null);
                    return;
                }
                Store.put(this, "pref_" + key, Security.capText(value == null ? "" : value, 40));
                result.success(Json.stringify(status()));
                return;
            }
            case "speak": {
                speak(Security.capText(call.argument("text"), 800), call.argument("lang"), result);
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
            default: result.notImplemented();
        }
    }

    private interface Job { Map<String, Object> run(); }

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

    private void speak(String text, String lang, MethodChannel.Result result) {
        if (text == null || text.isEmpty()) { result.success(false); return; }
        String code = "hi".equals(lang) || "kn".equals(lang) ? lang : "en";
        ttsStopped = false;
        if (ttsIniting) { ttsQueue.add(() -> speakNow(text, code, result)); return; }
        if (tts == null || !ttsReady) {
            // First use, or the last start failed: (re)start the engine and speak once it's ready.
            if (tts != null) tts.shutdown();
            ttsIniting = true;
            ttsQueue.add(() -> speakNow(text, code, result));
            tts = new TextToSpeech(getApplicationContext(), status -> runOnUiThread(() -> {
                ttsIniting = false;
                ttsReady = status == TextToSpeech.SUCCESS;
                List<Runnable> q = new ArrayList<>(ttsQueue);
                ttsQueue.clear();
                for (Runnable r : q) r.run();
            }));
        } else {
            speakNow(text, code, result);
        }
    }

    private void speakNow(String text, String code, MethodChannel.Result result) {
        if (ttsStopped) { result.success(true); return; } // cancelled by the user, not a missing voice
        if (!ttsReady || tts == null) { result.success(false); return; }
        Locale loc = new Locale(code, "IN");
        int avail = tts.isLanguageAvailable(loc);
        if (avail < TextToSpeech.LANG_AVAILABLE) {
            if (!"en".equals(code)) { result.success(false); return; }
            loc = Locale.ENGLISH;
        }
        tts.setLanguage(loc);
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "secondlook");
        result.success(true);
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

    private Map<String, Object> status() {
        boolean smsWanted = Store.bool(this, "sms_on"), callWanted = Store.bool(this, "call_on");
        return Json.map(
                "platform", "android",
                "onboarded", Store.bool(this, "onboarded"),
                "termsVersion", Store.str(this, "terms_version"),
                "prefs", Json.map(
                        "language", Store.str(this, "pref_language"),
                        "voice", Store.str(this, "pref_voice"),
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
                "trustedNumber", Store.str(this, "trusted_number"));
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
                requestPermissions(ask.toArray(new String[0]), REQ_SMS);
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
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
            return;
        }
        // Turning OFF: the service ignores calls from now on. The user can also remove the role in system settings.
        result.success(Json.stringify(status()));
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_SMS && !smsGranted()) {
            // The user said no: respect it and switch the shield back off.
            Store.put(this, "sms_on", false);
            enableSmsReceiver(false);
        }
        finishPending();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_DOC) { onDocumentPicked(resultCode, data); return; }
        if (requestCode == REQ_ROLE) {
            if (!roleHeld()) Store.put(this, "call_on", false);
            else if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFY);
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
