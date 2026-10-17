package com.secondlook.second_look;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;

import com.secondlook.engine.Json;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * SMS Shield. Runs only while the user has it switched ON (the component is disabled otherwise).
 * Checks each new SMS on the phone. Every checked SMS is listed in Alerts (unless the user turned "log all" off,
 * then only warnings): the verdict, the sender and a short preview with one-time codes masked. The SMS is never
 * sent anywhere. Warnings raise a notification; a normal-looking SMS from a phone number seen for the first time
 * raises a quiet one; numbers the user blocked raise none.
 */
public class SmsReceiver extends BroadcastReceiver {
    static final int PREVIEW_CHARS = 160;
    static final String TEST_SENDER = "VK-ALERTS";
    static final String TEST_BODY = "Dear customer your bank account will be blocked today. Update KYC now at http://kyc-verify-update.top/login";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) return;
        if (!Store.bool(context, "sms_on")) return;
        SmsMessage[] parts;
        try {
            parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        } catch (RuntimeException e) {
            return; // malformed broadcast
        }
        if (parts == null || parts.length == 0) return;

        // Long SMS arrive in parts: join them per sender.
        Map<String, StringBuilder> bySender = new LinkedHashMap<>();
        for (SmsMessage m : parts) {
            if (m == null) continue;
            String from = m.getDisplayOriginatingAddress();
            String body = m.getDisplayMessageBody();
            bySender.computeIfAbsent(from == null ? "Unknown" : from, k -> new StringBuilder()).append(body == null ? "" : body);
        }

        final PendingResult pending = goAsync();
        final Context app = context.getApplicationContext();
        new Thread(() -> {
            try {
                for (Map.Entry<String, StringBuilder> e : bySender.entrySet()) {
                    try {
                        process(app, e.getKey(), e.getValue().toString(), false);
                    } catch (RuntimeException ex) {
                        // One bad message must not stop the others.
                    }
                }
            } finally {
                pending.finish();
            }
        }, "sl-sms").start();
    }

    /**
     * Checks one SMS, logs it and notifies as the rules say. Returns the history id (or a notification-only id when
     * it wasn't logged). test = the built-in sample from "Send test alert". Call off the main thread.
     */
    @SuppressWarnings("unchecked")
    static String process(Context app, String sender, String body, boolean test) {
        Map<String, Object> r = EngineHolder.get(app).analyzeSms(sender, body);
        String level = (String) ((Map<String, Object>) r.get("level")).get("key");
        boolean phone = EngineHolder.isPhoneSender(sender);
        String key = EngineHolder.senderKey(app, sender);
        boolean firstTime = !test && key != null && Store.firstTimeSender(app, key, true);
        boolean blocked = !test && key != null && Store.isBlocked(app, key);
        boolean safe = "safe".equals(level);
        boolean log = test || blocked || !safe || Store.prefOn(app, "log_all", true);

        String id;
        if (log) {
            long now = System.currentTimeMillis();
            Map<String, Object> extra = Json.map(
                    "number", phone && key != null ? key : sender,
                    "senderType", phone ? "number" : "header",
                    "firstTime", firstTime,
                    "preview", preview(body));
            if (blocked) extra.put("userAction", Store.userAction("block", "", now));
            if (test) extra.put("test", true);
            id = Store.addHistory(app, "sms", "SMS from " + sender, r, extra);
        } else {
            id = "sms-" + System.currentTimeMillis();
        }

        if (blocked) return id;                       // the user blocked this sender: list it, stay quiet
        try {
            if (!safe) Notifier.sms(app, sender, r, id, test);
            else if (firstTime && phone) Notifier.newSender(app, sender, id);
        } catch (RuntimeException ignored) {
            // notifications switched off or the channel was removed: the alert is still listed in the app
        }
        return id;
    }

    /** First 160 characters with one-time codes (standalone runs of 4–8 digits) hidden. */
    static String preview(String body) {
        if (body == null) return "";
        String masked = body.replaceAll("(?<![0-9])[0-9]{4,8}(?![0-9])", "••••").replaceAll("\\s+", " ").trim();
        if (masked.length() <= PREVIEW_CHARS) return masked;
        int end = PREVIEW_CHARS;
        if (Character.isHighSurrogate(masked.charAt(end - 1))) end--;
        return masked.substring(0, end);
    }
}
