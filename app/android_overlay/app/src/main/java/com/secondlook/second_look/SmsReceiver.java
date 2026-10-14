package com.secondlook.second_look;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * SMS Shield. Runs only while the user has it switched ON (the component is disabled otherwise).
 * Checks each new SMS on the phone and shows a notification when it looks like a scam.
 * The SMS is never stored in full or sent anywhere; only flagged messages are kept in local history.
 */
public class SmsReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) return;
        if (!Store.bool(context, "sms_on")) return;
        SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (parts == null || parts.length == 0) return;

        // Long SMS arrive in parts: join them per sender.
        Map<String, StringBuilder> bySender = new LinkedHashMap<>();
        for (SmsMessage m : parts) {
            if (m == null) continue;
            String from = m.getDisplayOriginatingAddress();
            bySender.computeIfAbsent(from == null ? "Unknown" : from, k -> new StringBuilder()).append(m.getDisplayMessageBody());
        }

        final PendingResult pending = goAsync();
        final Context app = context.getApplicationContext();
        new Thread(() -> {
            try {
                for (Map.Entry<String, StringBuilder> e : bySender.entrySet()) {
                    Map<String, Object> r = EngineHolder.get(app).analyzeSms(e.getKey(), e.getValue().toString());
                    @SuppressWarnings("unchecked")
                    String level = (String) ((Map<String, Object>) r.get("level")).get("key");
                    if ("safe".equals(level)) continue;
                    String id = Store.addHistory(app, "sms", "SMS from " + e.getKey(), r);
                    Notifier.sms(app, e.getKey(), r, id);
                }
            } catch (RuntimeException ex) {
                // Never crash the phone's SMS flow; the message itself is unaffected.
            } finally {
                pending.finish();
            }
        }, "sl-sms").start();
    }
}
