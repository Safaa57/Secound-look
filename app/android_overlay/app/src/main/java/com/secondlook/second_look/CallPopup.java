package com.secondlook.second_look;

import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
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

import java.util.List;
import java.util.Map;

/**
 * The small card shown over the screen while an unknown number rings ("Display over other apps", which the user
 * grants in Settings). Plain Android views, no Flutter. It shows the verdict, the number, the kind of caller and up
 * to two reasons, and hides itself when the call ends (the phone's audio mode returns to normal), after 45 seconds,
 * or when the user taps X. Tapping the card opens the alert in Second Look. It can be dragged up or down.
 * No extra permission is used to notice the end of the call.
 */
final class CallPopup {
    static final long SHOW_MS = 45_000;
    private static final long POLL_MS = 1_000;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

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

    /** True if the user allowed Second Look to display over other apps. */
    static boolean allowed(Context c) {
        try {
            return Settings.canDrawOverlays(c);
        } catch (RuntimeException e) {
            return false;
        }
    }

    /** Shows the card for this call (replacing any card still on screen). Safe to call from any thread. */
    @SuppressWarnings("unchecked")
    static void show(Context ctx, String number, Map<String, Object> result, String alertId, boolean test) {
        final Context app = ctx.getApplicationContext();
        if (!allowed(app)) return;
        // Texts are prepared here (they read the language setting), the views are built on the main thread.
        final String level;
        try {
            level = String.valueOf(((Map<String, Object>) result.get("level")).get("key"));
        } catch (RuntimeException e) {
            return;
        }
        final String verdict = "danger".equals(level) ? I18n.t(app, "Likely scam")
                : "warning".equals(level) ? I18n.t(app, "Be careful")
                : I18n.t(app, "Looks normal — unknown number");
        final String kind = Notifier.callerLabel(app, result);
        final List<String> reasons = Notifier.reasonTitles(app, result, 2);
        final String brand = "Second Look" + (test ? " · " + I18n.t(app, "Test alert") : "");
        final String close = I18n.t(app, "Close");
        MAIN.post(() -> {
            try {
                showNow(app, brand, number == null ? "" : number, verdict, kind, reasons, level, close, alertId);
            } catch (RuntimeException ignored) {
                // permission withdrawn a moment ago, or the phone refused the window: the notification still shows
            }
        });
    }

    /** Removes the card, if one is showing. Safe to call from any thread. */
    static void dismiss() { MAIN.post(() -> close(active)); }

    private static void close(Session s) {
        if (s == null) return;
        if (s.timeout != null) MAIN.removeCallbacks(s.timeout);
        if (s.poll != null) MAIN.removeCallbacks(s.poll);
        try {
            if (s.root != null) s.wm.removeView(s.root);
        } catch (RuntimeException ignored) {
            // already gone
        }
        if (active == s) active = null;
    }

    private static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
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

    private static void showNow(Context app, String brand, String number, String verdict, String kind, List<String> reasons,
                                String level, String closeLabel, String alertId) {
        close(active);
        final WindowManager wm = app.getSystemService(WindowManager.class);
        if (wm == null) return;
        final Session s = new Session();
        s.wm = wm;

        int accent = "danger".equals(level) ? 0xFFC0262D : "warning".equals(level) ? 0xFF9A5B00 : 0xFF2346E0;
        int accentText = "danger".equals(level) ? 0xFFFF8A80 : "warning".equals(level) ? 0xFFFFC266 : 0xFFA9BCFF;

        // ---- card
        LinearLayout card = new LinearLayout(app);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.TOP);
        card.setPadding(dp(app, 14), dp(app, 12), dp(app, 4), dp(app, 12));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xF51C1D22);
        bg.setCornerRadius(dp(app, 18));
        bg.setStroke(dp(app, 2), accent);
        card.setBackground(bg);
        card.setElevation(dp(app, 8));

        ImageView icon = new ImageView(app);
        icon.setImageResource(R.drawable.ic_stat_shield);
        icon.setColorFilter(Color.WHITE);
        GradientDrawable circle = new GradientDrawable();
        circle.setShape(GradientDrawable.OVAL);
        circle.setColor(accent);
        icon.setBackground(circle);
        int ip = dp(app, 9);
        icon.setPadding(ip, ip, ip, ip);
        icon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(dp(app, 42), dp(app, 42));
        iconLp.setMargins(0, dp(app, 2), dp(app, 12), 0);
        card.addView(icon, iconLp);

        LinearLayout texts = new LinearLayout(app);
        texts.setOrientation(LinearLayout.VERTICAL);
        texts.addView(text(app, brand, 12, 0xFFB8BCC6, false, 1));
        texts.addView(text(app, number, 18, Color.WHITE, true, 1));
        texts.addView(text(app, verdict, 15, accentText, true, 2));
        if (kind != null && !kind.isEmpty()) texts.addView(text(app, kind, 13, 0xFFD6D9E0, false, 1));
        for (String r : reasons) {
            TextView t = text(app, "• " + r, 13, 0xFFD6D9E0, false, 2);
            t.setPadding(0, dp(app, 3), 0, 0);
            texts.addView(t);
        }
        card.addView(texts, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView x = text(app, "✕", 20, 0xFFE6E8EE, false, 1);
        x.setGravity(Gravity.CENTER);
        x.setContentDescription(closeLabel);
        x.setClickable(true);
        x.setFocusable(true);
        x.setOnClickListener(v -> close(s));
        card.addView(x, new LinearLayout.LayoutParams(dp(app, 44), dp(app, 44)));

        FrameLayout root = new FrameLayout(app);
        int m = dp(app, 12);
        root.setPadding(m, 0, m, 0);
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
        // Below the status bar and the phone's own incoming-call banner, so its Answer / Decline stay visible.
        lp.y = dp(app, 140);
        lp.setTitle("Second Look caller card");

        // Tap = open the alert in the app; drag = move the card up or down.
        card.setOnClickListener(v -> {
            close(s);
            if (!Security.isAlertId(alertId)) return;
            try {
                Intent i = new Intent(app, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        .putExtra("alertId", alertId);
                app.startActivity(i);
            } catch (RuntimeException ignored) {
                // the phone refused to open the app from the background: the notification still works
            }
        });
        final int slop = ViewConfiguration.get(app).getScaledTouchSlop();
        card.setOnTouchListener(new View.OnTouchListener() {
            private float downY;
            private int startY;
            private boolean moved;

            @Override
            public boolean onTouch(View v, MotionEvent e) {
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
                            lp.y = Math.max(0, startY + Math.round(dy));
                            try { wm.updateViewLayout(root, lp); } catch (RuntimeException ignored) { /* gone */ }
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
            }
        });

        wm.addView(root, lp);
        active = s;

        s.timeout = () -> close(s);
        MAIN.postDelayed(s.timeout, SHOW_MS);

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
