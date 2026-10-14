package com.secondlook.second_look;

import android.net.Uri;
import android.telecom.Call;
import android.telecom.CallScreeningService;

import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/**
 * Call Shield. Android hands us incoming calls from numbers that are NOT in the user's contacts,
 * only after the user picked Second Look as their "Caller ID & spam" app.
 * We classify the caller on the phone and show who it is while it rings. We never answer,
 * record or listen to calls, and we never read the call log.
 */
public class ScreeningService extends CallScreeningService {
    private static final ExecutorService POOL = Executors.newSingleThreadExecutor();

    @Override
    public void onCreate() {
        super.onCreate();
        // Load the engine as soon as Android binds the service, so the first call is checked quickly.
        POOL.submit(() -> EngineHolder.get(getApplicationContext()));
    }

    @Override
    public void onScreenCall(Call.Details details) {
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
        Map<String, Object> result = null;
        try {
            // Android expects an answer within a few seconds; never hold the call up for long.
            Future<Map<String, Object>> f = POOL.submit(() -> EngineHolder.analyzeNumber(getApplicationContext(), number));
            result = f.get(3, TimeUnit.SECONDS);
        } catch (Exception ignored) {
            // Fall through and let the call ring normally.
        }
        if (result == null) {
            respondToCall(details, allow);
            return;
        }
        @SuppressWarnings("unchecked")
        String level = (String) ((Map<String, Object>) result.get("level")).get("key");
        CallResponse.Builder b = new CallResponse.Builder();
        if ("danger".equals(level) && Store.bool(this, "auto_silence")) b.setSilenceCall(true);
        respondToCall(details, b.build());

        String id = "safe".equals(level) ? "call-" + System.currentTimeMillis()
                : Store.addHistory(getApplicationContext(), "call", "Call from " + number, result);
        Notifier.call(getApplicationContext(), number, result, id);
    }
}
