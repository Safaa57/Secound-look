package com.secondlook.second_look;

import android.content.Context;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * The card shown over the screen ("Display over other apps", which the user grants in Settings) while an unknown
 * number rings, and when a new SMS looks risky or comes from a phone number seen for the first time. Plain Android
 * views, no Flutter. Full width (12dp side margins), placed at about 28% of the screen height so it sits below the
 * heads-up notification and the phone's own incoming-call banner. It shows the verdict, the number, the kind of caller
 * (or a one-line masked SMS preview) and up to two reasons, with buttons Block · Spam · Close (calls) or
 * Open · Block · Close (SMS). It hides itself when the call ends (the phone's audio mode returns to normal) or after
 * 45 s for calls / 20 s for SMS. Tapping the card opens the alert in Second Look; it can be dragged up or down.
 * Only one card is on screen at a time (a new one replaces the old). Nothing here may crash the caller: every step
 * is guarded, and the notification still shows if the card can't.
 */
final class CallPopup {
    static final long SHOW_MS = 45_000;
    static final long SMS_SHOW_MS = 20_000;
    private static final long POLL_MS = 1_000;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    // Colours (dark "premium" card).
    private static final int CARD = 0xFF0B1220;
    private static final int SAFE = 0xFF22C55E, WARNING = 0xFFF59E0B, DANGER = 0xFFEF4444;
    private static final int TEXT = 0xFFF8FAFC, TEXT2 = 0xFFCBD5E1, MUTED = 0xFF94A3B8;
    private static final int BTN_BG = 0xFF1E293B, BTN_LINE = 0xFF334155, OPEN = 0xFF2563EB;

    /** The card on screen now (main thread only). */
    private static Session active;

    private CallPopup() { }

    private static final class Session {
        WindowManager wm;
        View root;
        boolean sawCall;
        Runnable timeout;
        Runnable poll;
    }

    /** Everything the card shows, prepared off the main thread (texts read the language setting). */
    private static final class Spec {
        boolean sms;
        String level;
        String header;      // "Second Look · Incoming call"
        String verdict;
        String number;      // as received (used for Block / Spam too)
        String detail;      // caller kind, or the masked SMS preview
        List<String> reasons = Collections.emptyList();
        String alertId;
        String block, spam, open, close;
        String blocked, spammed, failed;
    }

    /** True if the user allowed Second Look to display over other apps. */
    static boolean allowed(Context c) {
        try {
            return Settings.canDrawOverlays(c);
        } catch (RuntimeException e) {
            return false;
        }
    }

    /** Shows the card for this call (replacing any card still on screen). Safe to call from any thread; never throws. */
    static void show(Context ctx, String number, Map<String, Object> result, String alertId, boolean test) {
        try {
            Context app = ctx.getApplicationContext();
            if (!allowed(app)) return;
            Spec s = base(app, number, result, alertId, test, false);
            if (s == null) return;
            s.verdict = "danger".equals(s.level) ? I18n.t(app, "Likely scam")
                    : "warning".equals(s.level) ? I18n.t(app, "Be careful")
                    : I18n.t(app, "Looks normal — unknown number");
            s.detail = Notifier.callerLabel(app, result);
            post(app, s);
        } catch (RuntimeException ignored) {
            // the notification still shows
        }
    }

    /** Shows the card for a new SMS (replacing any card still on screen). Safe to call from any thread; never throws. */
    static void showSms(Context ctx, String sender, Map<String, Object> result, String alertId, String preview, boolean test) {
        try {
            Context app = ctx.getApplicationContext();
            if (!allowed(app)) return;
            Spec s = base(app, sender, result, alertId, test, true);
            if (s == null) return;
            s.verdict = "danger".equals(s.level) ? I18n.t(app, "Likely scam SMS")
                    : "warning".equals(s.level) ? I18n.t(app, "Suspicious SMS")
                    : I18n.t(app, "Looks normal — new sender");
            s.detail = preview == null ? "" : preview;
            post(app, s);
        } catch (RuntimeException ignored) {
            // the notification still shows
        }
    }

    @SuppressWarnings("unchecked")
    private static Spec base(Context app, String number, Map<String, Object> result, String alertId, boolean test, boolean sms) {
        Spec s = new Spec();
        try {
            s.level = String.valueOf(((Map<String, Object>) result.get("level")).get("key"));
        } catch (RuntimeException e) {
            return null;
        }
        s.sms = sms;
        s.number = number == null ? "" : number;
        s.alertId = alertId;
        s.header = "Second Look · " + I18n.t(app, sms ? "New SMS" : "Incoming call")
                + (test ? " · " + I18n.t(app, "Test alert") : "");
        try {
            s.reasons = Notifier.reasonTitles(app, result, 2);
        } catch (RuntimeException e) {
            s.reasons = Collections.emptyList();
        }
        s.block = I18n.t(app, "Block");
        s.spam = I18n.t(app, "Spam");
        s.open = I18n.t(app, "Open");
        s.close = I18n.t(app, "Close");
        s.blocked = I18n.t(app, "Blocked in Second Look");
        s.spammed = I18n.t(app, "Marked as spam");
        s.failed = I18n.t(app, "Couldn't save. Open Second Look and try again.");
        return s;
    }

    private static void post(Context app, Spec spec) {
        MAIN.post(() -> {
            try {
                showNow(app, spec);
            } catch (RuntimeException ignored) {
                // permission withdrawn a moment ago, or the phone refused the window: the notification still shows
            }
        });
    }

    /** Removes the card, if one is showing. Safe to call from any thread. */
    static void dismiss() { MAIN.post(() -> close(active)); }

    private static void close(Session s) {
        if (s == null) return;
        try {
            if (s.timeout != null) MAIN.removeCallbacks(s.timeout);
            if (s.poll != null) MAIN.removeCallbacks(s.poll);
            if (s.root != null) s.wm.removeView(s.root);
        } catch (RuntimeException ignored) {
            // already gone
        }
        if (active == s) active = null;
    }

    private static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    private static int levelColor(String level) {
        return "danger".equals(level) ? DANGER : "warning".equals(level) ? WARNING : SAFE;
    }

    private static TextView text(Context c, String s, float sp, int color, boolean bold, int maxLines) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setMaxLines(maxLines);
        t.setEllipsize(TextUtils.TruncateAt.END);
        return t;
    }

    /** A rounded button: filled (fill != 0) or outlined, with a touch ripple. */
    private static TextView button(Context c, String label, int fill, int line, int textColor) {
        TextView b = text(c, label, 16, textColor, true, 1);
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(c, 8), 0, dp(c, 8), 0);
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(c, 14));
        bg.setColor(fill);
        if (line != 0) bg.setStroke(dp(c, 1), line);
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(0x40FFFFFF), bg, null));
        b.setClickable(true);
        b.setFocusable(true);
        b.setContentDescription(label);
        return b;
    }

    private static void openAlert(Context app, String alertId) {
        if (!Security.isAlertId(alertId)) return;
        try {
            Intent i = new Intent(app, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra("alertId", alertId);
            app.startActivity(i);
        } catch (RuntimeException ignored) {
            // the phone refused to open the app from the background: the notification still works
        }
    }

    /** Block / Spam from the card: the same steps as markNumber, off the main thread, then a short toast. */
    private static void mark(Context app, Spec spec, String action) {
        final String number = spec.number, alertId = spec.alertId;
        final String ok = "block".equals(action) ? spec.blocked : spec.spammed;
        final String failed = spec.failed;
        try {
            new Thread(() -> {
                boolean done;
                try {
                    Map<String, Object> r = MainActivity.markNumber(app, number, action, null, alertId);
                    done = Boolean.TRUE.equals(r.get("ok"));
                } catch (RuntimeException e) {
                    done = false;
                }
                final String msg = done ? ok : failed;
                MAIN.post(() -> {
                    try { Toast.makeText(app, msg, Toast.LENGTH_SHORT).show(); } catch (RuntimeException ignored) { /* no toast */ }
                });
            }, "sl-popup-mark").start();
        } catch (RuntimeException ignored) {
            // could not start the worker: nothing saved, nothing shown
        }
    }

    private static void showNow(Context app, Spec spec) {
        close(active);
        final WindowManager wm = app.getSystemService(WindowManager.class);
        if (wm == null) return;
        final Session s = new Session();
        s.wm = wm;
        final int accent = levelColor(spec.level);

        // ---- card
        LinearLayout card = new LinearLayout(app);
        card.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(app, 18);
        card.setPadding(pad, dp(app, 16), pad, dp(app, 16));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD);
        bg.setCornerRadius(dp(app, 20));
        bg.setStroke(dp(app, 1), accent);
        card.setBackground(bg);
        card.setElevation(dp(app, 12));

        // header: shield badge + "Second Look · Incoming call"
        LinearLayout head = new LinearLayout(app);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon = new ImageView(app);
        icon.setImageResource(R.drawable.ic_stat_shield);
        icon.setColorFilter(accent);
        GradientDrawable badge = new GradientDrawable();
        badge.setShape(GradientDrawable.OVAL);
        badge.setColor((accent & 0x00FFFFFF) | 0x2E000000);   // the level colour, faint
        icon.setBackground(badge);
        int ip = dp(app, 7);
        icon.setPadding(ip, ip, ip, ip);
        icon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(dp(app, 34), dp(app, 34));
        iconLp.setMargins(0, 0, dp(app, 10), 0);
        head.addView(icon, iconLp);
        head.addView(text(app, spec.header, 13, MUTED, false, 1),
                new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        card.addView(head);

        TextView verdict = text(app, spec.verdict, 22, accent, true, 2);
        verdict.setPadding(0, dp(app, 12), 0, 0);
        card.addView(verdict);
        TextView num = text(app, spec.number, 18, TEXT, true, 1);
        num.setPadding(0, dp(app, 2), 0, 0);
        card.addView(num);
        if (spec.detail != null && !spec.detail.isEmpty()) {
            TextView d = text(app, spec.detail, 14, TEXT2, false, 1);
            d.setPadding(0, dp(app, 4), 0, 0);
            card.addView(d);
        }
        for (String r : spec.reasons) {
            TextView t = text(app, "• " + r, 14, TEXT2, false, 2);
            t.setPadding(0, dp(app, 4), 0, 0);
            card.addView(t);
        }

        // buttons: calls Block · Spam · Close, SMS Open · Block · Close
        LinearLayout row = new LinearLayout(app);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(app, 16), 0, 0);
        TextView first, second;
        if (spec.sms) {
            first = button(app, spec.open, OPEN, 0, TEXT);
            first.setOnClickListener(v -> { close(s); openAlert(app, spec.alertId); });
            second = button(app, spec.block, DANGER, 0, TEXT);
            second.setOnClickListener(v -> { close(s); mark(app, spec, "block"); });
        } else {
            first = button(app, spec.block, DANGER, 0, TEXT);
            first.setOnClickListener(v -> { close(s); mark(app, spec, "block"); });
            second = button(app, spec.spam, BTN_BG, WARNING, WARNING);
            second.setOnClickListener(v -> { close(s); mark(app, spec, "spam"); });
        }
        TextView closeBtn = button(app, spec.close, BTN_BG, BTN_LINE, TEXT2);
        closeBtn.setOnClickListener(v -> close(s));
        int h = dp(app, 48), gap = dp(app, 8);
        LinearLayout.LayoutParams l1 = new LinearLayout.LayoutParams(0, h, 1f);
        LinearLayout.LayoutParams l2 = new LinearLayout.LayoutParams(0, h, 1f);
        LinearLayout.LayoutParams l3 = new LinearLayout.LayoutParams(0, h, 1f);
        l2.setMargins(gap, 0, gap, 0);
        row.addView(first, l1);
        row.addView(second, l2);
        row.addView(closeBtn, l3);
        card.addView(row);

        // Side margins 12dp; a little room above / below so the shadow isn't cut off.
        final FrameLayout root = new FrameLayout(app);
        int m = dp(app, 12);
        root.setPadding(m, dp(app, 8), m, dp(app, 16));
        root.addView(card, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        s.root = root;

        // ---- window: not focusable, so the phone's own call screen keeps the keyboard and the buttons
        final WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        // ~28% down the screen: below the status bar, the heads-up notification and the incoming-call banner.
        final int screenH = Math.max(app.getResources().getDisplayMetrics().heightPixels, dp(app, 400));
        lp.y = Math.round(screenH * 0.28f);
        lp.setTitle("Second Look alert card");

        // Tap = open the alert in the app; drag = move the card up or down.
        card.setOnClickListener(v -> { close(s); openAlert(app, spec.alertId); });
        final int slop = ViewConfiguration.get(app).getScaledTouchSlop();
        final int maxY = Math.max(0, screenH - dp(app, 160));
        card.setOnTouchListener(new View.OnTouchListener() {
            private float downY;
            private int startY;
            private boolean moved;

            @Override
            public boolean onTouch(View v, MotionEvent e) {
                try {
                    switch (e.getActionMasked()) {
                        case MotionEvent.ACTION_DOWN:
                            downY = e.getRawY();
                            startY = lp.y;
                            moved = false;
                            return true;
                        case MotionEvent.ACTION_MOVE: {
                            float dy = e.getRawY() - downY;
                            if (!moved && Math.abs(dy) > slop) moved = true;
                            if (moved) {
                                lp.y = Math.min(maxY, Math.max(0, startY + Math.round(dy)));
                                wm.updateViewLayout(root, lp);
                            }
                            return true;
                        }
                        case MotionEvent.ACTION_UP:
                            if (!moved) v.performClick();
                            return true;
                        case MotionEvent.ACTION_CANCEL:
                            return true;
                        default:
                            return false;
                    }
                } catch (RuntimeException ignored) {
                    return true; // card already gone
                }
            }
        });

        wm.addView(root, lp);
        active = s;

        s.timeout = () -> close(s);
        MAIN.postDelayed(s.timeout, spec.sms ? SMS_SHOW_MS : SHOW_MS);
        if (spec.sms) return;

        // Hide when the call ends: the audio mode is "ringtone" / "in call" while it rings or is answered, and
        // returns to "normal" when it ends. (Reading the mode needs no permission.)
        final AudioManager am = app.getSystemService(AudioManager.class);
        if (am != null) {
            s.poll = new Runnable() {
                @Override
                public void run() {
                    if (active != s) return;
                    int mode;
                    try { mode = am.getMode(); } catch (RuntimeException e) { return; }
                    if (mode == AudioManager.MODE_RINGTONE || mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION) {
                        s.sawCall = true;
                    } else if (mode == AudioManager.MODE_NORMAL && s.sawCall) {
                        close(s);
                        return;
                    }
                    MAIN.postDelayed(this, POLL_MS);
                }
            };
            MAIN.post(s.poll);
        }
    }
}
