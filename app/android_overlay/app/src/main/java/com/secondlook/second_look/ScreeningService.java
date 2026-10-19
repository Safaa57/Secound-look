package com.secondlook.second_look;

import android.content.Context;
import android.net.Uri;
import android.telecom.Call;
import android.telecom.CallScreeningService;

import com.secondlook.engine.Json;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/**
 * Call Shield. Android hands us incoming calls from numbers that are NOT in the user's contacts,
 * only after the user picked Second Look as their "Caller ID & spam" app.
 * We classify the caller on the phone and show who it is while it rings (a small on-screen card if the user
 * allowed "Display over other apps", plus a notification). Numbers the user blocked in Second Look are rejected.
 * We never answer, record or listen to calls, and we never read the call log.
 */
public class ScreeningService extends CallScreeningService {
    private static final ExecutorService POOL = Executors.newSingleThreadExecutor();
    /** Logging, notification and the on-screen card run here, after Android already has our answer. */
    private static final ExecutorService AFTER = Executors.newSingleThreadExecutor();
    static final String TEST_NUMBER = "+919000000000";

    /** What the quick part of screening found (engine verdict + whether the user blocked the number). */
    private static final class Verdict {
        final Map<String, Object> result;
        final String key;
        final boolean blocked;

        Verdict(Map<String, Object> result, String key, boolean blocked) {
            this.result = result;
            this.key = key;
            this.blocked = blocked;
        }
    }

    @Override
    public void onCreate() {
        CrashLog.install(this);   // once per process: records native crashes on this phone only
        super.onCreate();
        // Load the engine as soon as Android binds the service, so the first call is checked quickly.
        final Context app = getApplicationContext();
        POOL.submit(() -> EngineHolder.get(app));
    }

    @Override
    public void onScreenCall(Call.Details details) {
        CrashLog.install(this);
        CallResponse allow = new CallResponse.Builder().build();
        if (details.getCallDirection() != Call.Details.DIRECTION_INCOMING || !Store.bool(this, "call_on")) {
            respondToCall(details, allow);
            return;
        }
        Uri handle = details.getHandle();
        final String number = handle == null ? null : handle.getSchemeSpecificPart();
        if (number == null || number.isEmpty()) {
            respondToCall(details, allow);
            return;
        }
        final Context app = getApplicationContext();
        Verdict v = null;
        try {
            // Android expects an answer within a few seconds; never hold the call up for long.
            Future<Verdict> f = POOL.submit(() -> {
                Map<String, Object> r = EngineHolder.analyzeNumber(app, number);
                String key = EngineHolder.senderKey(app, number);
                return new Verdict(r, key, key != null && Store.isBlocked(app, key));
            });
            v = f.get(3, TimeUnit.SECONDS);
        } catch (Exception ignored) {
            // Fall through and let the call ring normally.
        }
        if (v == null) {
            respondToCall(details, allow);
            return;
        }
        @SuppressWarnings("unchecked")
        String level = (String) ((Map<String, Object>) v.result.get("level")).get("key");
        CallResponse.Builder b = new CallResponse.Builder();
        if (v.blocked) {
            // The user blocked this number in Second Look: don't let it ring. It still shows in the call log.
            b.setDisallowCall(true).setRejectCall(true).setSkipNotification(false).setSkipCallLog(false);
        } else if ("danger".equals(level) && Store.bool(this, "auto_silence")) {
            b.setSilenceCall(true);
        }
        respondToCall(details, b.build());

        final Verdict done = v;
        AFTER.execute(() -> {
            try {
                afterCall(app, number, done.result, done.key, done.blocked, false);
            } catch (RuntimeException ignored) {
                // never let logging or display break anything
            }
        });
    }

    /**
     * Everything that happens after Android has our answer: history, the on-screen card and the notification.
     * Also used by "Send test alert". Returns the history id (or a notification-only id). Call off the main thread.
     */
    static String afterCall(Context app, String number, Map<String, Object> result, String key, boolean blocked, boolean test) {
        @SuppressWarnings("unchecked")
        String level = (String) ((Map<String, Object>) result.get("level")).get("key");
        boolean safe = "safe".equals(level);
        boolean firstTime = key != null && Store.firstTimeSender(app, key, !test);
        boolean log = test || blocked || !safe || Store.prefOn(app, "log_all", true);
        String id;
        if (log) {
            long now = System.currentTimeMillis();
            Map<String, Object> extra = Json.map(
                    "number", key != null ? key : number,
                    "senderType", "number",
                    "firstTime", firstTime);
            if (blocked) extra.put("userAction", Store.userAction("block", "", now));
            if (test) extra.put("test", true);
            id = Store.addHistory(app, "call", "Call from " + number, result, extra);
        } else {
            id = "call-" + System.currentTimeMillis();
        }
        if (blocked) return id; // rejected: nothing rang, so nothing to show

        if (Store.prefOn(app, "call_popup", true)) CallPopup.show(app, number, result, id, test);
        try {
            Notifier.call(app, number, result, id, test);
        } catch (RuntimeException ignored) {
            // notifications switched off: the call is still listed in the app
        }
        return id;
    }

    /** "Send test alert" for calls: a sample scam call from a test number, through the same steps as a real one. */
    static String testCall(Context app) {
        List<Map<String, Object>> extra = new ArrayList<>();
        extra.add(Json.map("id", "test_alert", "title", "Test alert: a sample scam call, not a real one",
                "detail", "Second Look made this example so you can see how a warning looks while a call rings.", "weight", 60));
        Map<String, Object> r = EngineHolder.get(app).analyzeNumber(TEST_NUMBER, extra);
        return afterCall(app, TEST_NUMBER, r, TEST_NUMBER, false, true);
    }
}
