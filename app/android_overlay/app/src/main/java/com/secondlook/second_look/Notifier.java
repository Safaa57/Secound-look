package com.secondlook.second_look;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

import com.secondlook.engine.Json;

import java.util.List;
import java.util.Map;

/** Heads-up notifications for SMS and call verdicts. */
final class Notifier {
    static final String CH_ALERTS = "sl_alerts";
    static final String CH_CALLER = "sl_caller";

    private Notifier() { }

    static void ensureChannels(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        // Re-creating a channel only updates its name and description, so these follow the chosen language.
        NotificationChannel a = new NotificationChannel(CH_ALERTS, I18n.t(c, "Scam alerts"), NotificationManager.IMPORTANCE_HIGH);
        a.setDescription(I18n.t(c, "Warnings about suspicious SMS and calls"));
        NotificationChannel b = new NotificationChannel(CH_CALLER, I18n.t(c, "Who's calling"), NotificationManager.IMPORTANCE_HIGH);
        b.setDescription(I18n.t(c, "Shows what kind of caller is ringing (person, business, telemarketer, bot or scam)"));
        nm.createNotificationChannel(a);
        nm.createNotificationChannel(b);
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> firstReason(Map<String, Object> result) {
        Object list = result.get("reasons");
        if (!(list instanceof List)) return null;
        for (Object o : (List<Object>) list) {
            Map<String, Object> r = Json.obj(o);
            if (r.get("weight") instanceof Number && Json.num(r.get("weight")) > 0) return r;
        }
        return null;
    }

    /** Title of the first warning sign, in the chosen language (English engine text as fallback). */
    private static String firstReasonTitle(Context c, Map<String, Object> result) {
        Map<String, Object> r = firstReason(result);
        if (r == null) return null;
        Object id = r.get("id"), title = r.get("title");
        String en = title == null ? null : String.valueOf(title);
        return id == null ? en : I18n.reason(c, String.valueOf(id), en);
    }

    private static PendingIntent openApp(Context c, String alertId) {
        Intent i = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra("alertId", alertId);
        return PendingIntent.getActivity(c, alertId.hashCode(), i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private static Notification.Action tellTrusted(Context c, String what) {
        String num = Store.str(c, "trusted_number");
        if (num.isEmpty()) return null;
        String name = Store.str(c, "trusted_name");
        Intent sms = new Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + num))
                .putExtra("sms_body", I18n.t(c, "Second Look flagged {what} on my phone as a likely scam. Can you check it with me before I do anything?", "what", what))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent pi = PendingIntent.getActivity(c, ("tell" + num).hashCode(), sms, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Action.Builder(null, I18n.t(c, "Ask {name}", "name", name.isEmpty() ? I18n.t(c, "trusted person") : name), pi).build();
    }

    @SuppressWarnings("unchecked")
    static void sms(Context c, String sender, Map<String, Object> result, String alertId) {
        ensureChannels(c);
        Map<String, Object> level = (Map<String, Object>) result.get("level");
        String key = (String) level.get("key");
        String reason = firstReasonTitle(c, result);
        Notification.Builder b = new Notification.Builder(c, CH_ALERTS)
                .setSmallIcon(R.drawable.ic_stat_shield)
                .setContentTitle(I18n.t(c, "danger".equals(key) ? "Likely scam SMS" : "Suspicious SMS") + " " + I18n.t(c, "from") + " " + sender)
                .setContentText(reason != null ? reason : I18n.t(c, "Tap to see why"))
                .setStyle(new Notification.BigTextStyle().bigText((reason != null ? reason + "\n" : "") + I18n.t(c, "Don't tap links or share OTPs. Tap to see why.")))
                .setColor("danger".equals(key) ? 0xFFC0262D : 0xFF9A5B00)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setContentIntent(openApp(c, alertId))
                .setAutoCancel(true);
        Notification.Action tell = tellTrusted(c, I18n.t(c, "an SMS from {who}", "who", sender));
        if (tell != null && "danger".equals(key)) b.addAction(tell);
        c.getSystemService(NotificationManager.class).notify(alertId.hashCode(), b.build());
    }

    @SuppressWarnings("unchecked")
    static void call(Context c, String number, Map<String, Object> result, String alertId) {
        ensureChannels(c);
        Map<String, Object> info = (Map<String, Object>) result.get("info");
        Map<String, Object> caller = (Map<String, Object>) info.get("caller");
        Map<String, Object> d = (Map<String, Object>) info.get("numberDetails");
        String key = (String) ((Map<String, Object>) result.get("level")).get("key");
        StringBuilder facts = new StringBuilder();
        if (d != null) {
            for (String k : new String[]{"circle", "location", "carrier"}) {
                Object v = d.get(k);
                if (v != null) facts.append(facts.length() > 0 ? " · " : "").append(v);
            }
            if (facts.length() == 0 && d.get("countryName") != null) facts.append(d.get("countryName"));
        }
        String verdict = "danger".equals(key) ? I18n.t(c, "Likely scam") : "warning".equals(key) ? I18n.t(c, "Be careful") : null;
        Object enLabel = caller != null ? caller.get("label") : null;
        String label = caller != null && caller.get("kind") != null
                ? I18n.caller(c, String.valueOf(caller.get("kind")), enLabel == null ? "" : String.valueOf(enLabel))
                : (enLabel == null ? "" : String.valueOf(enLabel));
        String title = (verdict != null ? verdict + " · " : "") + label;
        String reason = firstReasonTitle(c, result);
        Notification.Builder b = new Notification.Builder(c, "safe".equals(key) ? CH_CALLER : CH_ALERTS)
                .setSmallIcon(R.drawable.ic_stat_shield)
                .setContentTitle(title)
                .setContentText(number + (facts.length() > 0 ? " · " + facts : ""))
                .setStyle(new Notification.BigTextStyle().bigText(number + (facts.length() > 0 ? "\n" + facts : "") + (reason != null ? "\n" + reason : "")
                        + ("safe".equals(key) ? "" : "\n" + I18n.t(c, "Never share OTPs or PINs on a call."))))
                .setColor("danger".equals(key) ? 0xFFC0262D : "warning".equals(key) ? 0xFF9A5B00 : 0xFF2346E0)
                .setCategory(Notification.CATEGORY_CALL)
                .setTimeoutAfter(120_000)
                .setContentIntent(openApp(c, alertId))
                .setAutoCancel(true);
        c.getSystemService(NotificationManager.class).notify(alertId.hashCode(), b.build());
    }
}
