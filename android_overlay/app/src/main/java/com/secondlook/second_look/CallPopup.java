package com.secondlook.second_look;

import android.animation.ValueAnimator;
import android.content.Context;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.media.AudioManager;
import android.os.Build;
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

import com.secondlook.engine.Json;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * The card shown over the screen ("Display over other apps", which the user grants in Settings) while an unknown
 * number rings, and when a new SMS looks risky or comes from a phone number seen for the first time. Plain Android
 * views, no Flutter. Full width (12dp side margins), placed at about 28% of the screen height so it sits below the
 * heads-up notification and the phone's own incoming-call banner. It shows the verdict, the number, the kind of caller
 * and one detail line (community reports first, then the top reason or the kind of caller; for SMS a one-line masked
 * preview plus up to two reasons), with buttons Block · Spam · Close (calls) or Open · Block · Close (SMS). Look
 * follows the owner-approved mockup: dark card, 24dp corners, a level-coloured edge with a soft glow that pulses
 * gently, Sora / Manrope from the Flutter assets (system font if they can't be loaded). It hides itself when the call ends (the phone's audio mode returns to normal) or after
 * 45 s for calls / 20 s for SMS. Tapping the card opens the alert in Second Look; it can be dragged up or down.
 * Only one card is on screen at a time (a new one replaces the old). Nothing here may crash the caller: every step
 * is guarded, and the notification still shows if the card can't.
 */
final class CallPopup {
    static final long SHOW_MS = 45_000;
    static final long SMS_SHOW_MS = 20_000;
    private static final long POLL_MS = 1_000;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    // Colours (owner-approved mockup Popup.dc.html: dark card, level-coloured edge with a soft pulsing glow).
    private static final int CARD = 0xFF0B1220;
    private static final int SAFE = 0xFF34D399, WARNING = 0xFFFBBF24, DANGER = 0xFFF87171;
    private static final int SAFE_LIGHT = 0xFFBFF5DE, WARNING_LIGHT = 0xFFFDE68A, DANGER_LIGHT = 0xFFFECACA;
    private static final int SAFE_ON = 0xFF03140D, WARNING_ON = 0xFF1A1203, DANGER_ON = 0xFF1A0507;
    private static final int TEXT = 0xFFEAF2FF, TEXT2 = 0xFFCBD5E1, MUTED = 0xFFA9B8D0;
    private static final int BTN_FILL = 0x0DFFFFFF, BTN_LINE = 0x33FFFFFF, CLOSE_X_BG = 0x0FFFFFFF;
    private static final String FONT_DIR = "flutter_assets/assets/fonts/";

    /** The card on screen now (main thread only). */
    private static Session active;

    private CallPopup() { }

    private static final class Session {
        WindowManager wm;
        View root;
        boolean sawCall;
        Runnable timeout;
        Runnable poll;
        ValueAnimator pulse;
    }

    /** Everything the card shows, prepared off the main thread (texts read the language setting). */
    private static final class Spec {
        boolean sms;
        String level;
        String header;      // "Second Look · Incoming call"
        String verdict;
        String number;      // as received (used for Block / Spam too)
        String detail;      // calls: reports / top reason / caller kind; SMS: the masked preview
        List<String> reasons = Collections.emptyList();   // SMS only (calls fold them into detail)
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
            s.detail = callDetail(app, result);
            s.reasons = Collections.emptyList();
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

    /** One line for a call: community reports first, then other warning signs, topped up with the kind of caller. */
    private static String callDetail(Context app, Map<String, Object> result) {
        List<String> community = new ArrayList<>(), other = new ArrayList<>();
        try {
            Object list = result.get("reasons");
            if (list instanceof List) {
                for (Object o : (List<?>) list) {
                    if (!(o instanceof Map)) continue;
                    Map<String, Object> r = Json.obj(o);
                    Object id = r.get("id"), title = r.get("title"), w = r.get("weight");
                    String sid = id == null ? "" : String.valueOf(id);
                    boolean isCommunity = sid.startsWith("community_");
                    if (!isCommunity && !(w instanceof Number && ((Number) w).doubleValue() > 0)) continue;
                    String en = title == null ? "" : String.valueOf(title);
                    String t = id == null ? en : I18n.reason(app, sid, en);
                    if (t == null || t.isEmpty()) continue;
                    (isCommunity ? community : other).add(t);
                }
            }
        } catch (RuntimeException ignored) {
            // odd shape: fall back to the caller kind below
        }
        List<String> parts = new ArrayList<>(community);
        parts.addAll(other);
        if (parts.size() > 2) parts = parts.subList(0, 2);
        if (parts.size() < 2) {
            String kind = null;
            try { kind = Notifier.callerLabel(app, result); } catch (RuntimeException ignored) { /* no label */ }
            if (kind != null && !kind.isEmpty() && !parts.contains(kind)) parts.add(0, kind);
        }
        return TextUtils.join(" · ", parts);
    }

    // ---- fonts (Flutter bundles assets/fonts/ under flutter_assets/ in the APK). Cached; null = use the system font.
    private static final Map<String, Typeface> FONTS = new HashMap<>();

    /** Sora or Manrope at this weight, or null. Both files are variable fonts, so the weight is set as a variation
     *  (API 26+). Below that only Sora is used (its default instance is regular, made bold by the system); Manrope's
     *  default instance is too thin to read, so the system font is used instead. */
    private static Typeface font(Context c, String name, int weight) {
        String key = name + weight;
        synchronized (FONTS) {
            if (FONTS.containsKey(key)) return FONTS.get(key);
        }
        Typeface tf = null;
        String path = FONT_DIR + name + ".ttf";
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                tf = new Typeface.Builder(c.getAssets(), path).setFontVariationSettings("'wght' " + weight).build();
            }
            if (tf == null && "Sora".equals(name)) tf = Typeface.createFromAsset(c.getAssets(), path);
        } catch (RuntimeException e) {
            tf = null;   // file missing from this build or unreadable
        }
        synchronized (FONTS) {
            FONTS.put(key, tf);
        }
        return tf;
    }

    private static void face(TextView t, String name, int weight) {
        try {
            Typeface tf = font(t.getContext(), name, weight);
            if (tf == null) {
                t.setTypeface(weight >= 600 ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
            } else if (Build.VERSION.SDK_INT < 26 && weight >= 600) {
                t.setTypeface(tf, Typeface.BOLD);
            } else {
                t.setTypeface(tf);
            }
        } catch (RuntimeException e) {
            t.setTypeface(Typeface.DEFAULT_BOLD);
        }
    }

    private static void warmFonts(Context app) {
        try {
            font(app, "Sora", 700);
            font(app, "Manrope", 700);
            font(app, "Manrope", 500);
        } catch (RuntimeException ignored) {
            // loaded (or not) again when the card is built
        }
    }

    private static void post(Context app, Spec spec) {
        warmFonts(app);
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
            if (s.pulse != null) s.pulse.cancel();
        } catch (RuntimeException ignored) {
            // animation already stopped
        }
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

    private static int levelColor(String level) {
        return "danger".equals(level) ? DANGER : "warning".equals(level) ? WARNING : SAFE;
    }

    private static int lightColor(String level) {
        return "danger".equals(level) ? DANGER_LIGHT : "warning".equals(level) ? WARNING_LIGHT : SAFE_LIGHT;
    }

    private static int onColor(String level) {
        return "danger".equals(level) ? DANGER_ON : "warning".equals(level) ? WARNING_ON : SAFE_ON;
    }

    /** The colour c with this alpha (0..1). */
    private static int alpha(int c, float a) {
        return (c & 0x00FFFFFF) | (Math.round(Math.max(0f, Math.min(1f, a)) * 255) << 24);
    }

    private static TextView text(Context c, String s, float sp, int color, String font, int weight, int maxLines) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        face(t, font, weight);
        t.setMaxLines(maxLines);
        t.setEllipsize(TextUtils.TruncateAt.END);
        return t;
    }

    /** A rounded button: filled (fill opaque) or outlined, with a touch ripple. */
    private static TextView button(Context c, String label, int fill, int line, int textColor) {
        TextView b = text(c, label, 15, textColor, "Manrope", 700, 1);
        b.setGravity(Gravity.CENTER);
        b.setPadding(dp(c, 6), 0, dp(c, 6), 0);
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

    private static TextView outlined(Context c, String label) {
        return button(c, label, BTN_FILL, BTN_LINE, TEXT);
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
        final boolean safe = !"danger".equals(spec.level) && !"warning".equals(spec.level);

        // ---- card: #0B1220, 24dp corners, 1dp edge in the level colour (pulses with the glow below)
        LinearLayout card = new LinearLayout(app);
        card.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(app, 18);
        card.setPadding(pad, dp(app, 18), pad, dp(app, 16));
        final GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD);
        bg.setCornerRadius(dp(app, 24));
        final int edge = dp(app, 1);
        bg.setStroke(edge, alpha(accent, 0.7f));
        card.setBackground(bg);
        card.setElevation(dp(app, 12));
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                card.setOutlineSpotShadowColor(accent);
                card.setOutlineAmbientShadowColor(accent);
            } catch (RuntimeException ignored) {
                // plain grey shadow
            }
        }

        // header: shield badge · "SECOND LOOK · INCOMING CALL" · close X
        LinearLayout head = new LinearLayout(app);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView icon = new ImageView(app);
        icon.setImageResource(R.drawable.ic_stat_shield);
        icon.setColorFilter(accent);
        GradientDrawable badge = new GradientDrawable();
        badge.setShape(GradientDrawable.OVAL);
        badge.setColor(alpha(accent, 0.15f));
        icon.setBackground(badge);
        int ip = dp(app, 9);   // 22dp glyph in a 40dp circle
        icon.setPadding(ip, ip, ip, ip);
        icon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(dp(app, 40), dp(app, 40));
        iconLp.setMargins(0, 0, dp(app, 10), 0);
        head.addView(icon, iconLp);
        TextView label = text(app, spec.header.toUpperCase(Locale.getDefault()), 13, MUTED, "Manrope", 700, 1);
        try { label.setLetterSpacing(0.04f); } catch (RuntimeException ignored) { /* default spacing */ }
        head.addView(label, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView x = text(app, "\u2715", 18, TEXT, "Manrope", 700, 1);
        x.setTypeface(Typeface.DEFAULT);   // the glyph comes from the system font
        x.setGravity(Gravity.CENTER);
        GradientDrawable xbg = new GradientDrawable();
        xbg.setShape(GradientDrawable.OVAL);
        xbg.setColor(CLOSE_X_BG);
        x.setBackground(new RippleDrawable(ColorStateList.valueOf(0x40FFFFFF), xbg, null));
        x.setClickable(true);
        x.setFocusable(true);
        x.setContentDescription(spec.close);
        x.setOnClickListener(v -> close(s));
        LinearLayout.LayoutParams xLp = new LinearLayout.LayoutParams(dp(app, 44), dp(app, 44));
        xLp.setMargins(dp(app, 8), 0, 0, 0);
        head.addView(x, xLp);
        card.addView(head);

        // verdict (Sora 26sp, light level colour), number, detail
        TextView verdict = text(app, spec.verdict, 26, lightColor(spec.level), "Sora", 700, 2);
        verdict.setPadding(0, dp(app, 12), 0, 0);
        card.addView(verdict);
        TextView num = text(app, spec.number, 19, TEXT, "Manrope", 700, 1);
        num.setPadding(0, dp(app, 2), 0, 0);
        card.addView(num);
        if (spec.detail != null && !spec.detail.isEmpty()) {
            TextView d = text(app, spec.detail, 14.5f, TEXT2, "Manrope", 500, spec.sms ? 1 : 3);
            d.setPadding(0, dp(app, 6), 0, 0);
            try { d.setLineSpacing(0f, 1.15f); } catch (RuntimeException ignored) { /* default */ }
            card.addView(d);
        }
        if (!spec.reasons.isEmpty()) {
            TextView t = text(app, TextUtils.join(" · ", spec.reasons), 14.5f, TEXT2, "Manrope", 500, 2);
            t.setPadding(0, dp(app, 4), 0, 0);
            try { t.setLineSpacing(0f, 1.15f); } catch (RuntimeException ignored) { /* default */ }
            card.addView(t);
        }

        // buttons: calls Block · Spam · Close, SMS Open · Block · Close. The first is filled in the level colour,
        // except Block on a safe-looking call, which stays outlined like the others.
        LinearLayout row = new LinearLayout(app);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(app, 14), 0, 0);
        TextView first, second;
        if (spec.sms) {
            first = button(app, spec.open, accent, 0, onColor(spec.level));
            first.setOnClickListener(v -> { close(s); openAlert(app, spec.alertId); });
            second = outlined(app, spec.block);
            second.setOnClickListener(v -> { close(s); mark(app, spec, "block"); });
        } else {
            first = safe ? outlined(app, spec.block) : button(app, spec.block, accent, 0, onColor(spec.level));
            first.setOnClickListener(v -> { close(s); mark(app, spec, "block"); });
            second = outlined(app, spec.spam);
            second.setOnClickListener(v -> { close(s); mark(app, spec, "spam"); });
        }
        TextView closeBtn = outlined(app, spec.close);
        closeBtn.setOnClickListener(v -> close(s));
        int h = dp(app, 50), gap = dp(app, 8);
        LinearLayout.LayoutParams l1 = new LinearLayout.LayoutParams(0, h, 1f);
        LinearLayout.LayoutParams l2 = new LinearLayout.LayoutParams(0, h, 1f);
        LinearLayout.LayoutParams l3 = new LinearLayout.LayoutParams(0, h, 1f);
        l2.setMargins(gap, 0, gap, 0);
        row.addView(first, l1);
        row.addView(second, l2);
        row.addView(closeBtn, l3);
        card.addView(row);

        // Soft glow: two slightly larger rounded layers in the level colour at low alpha behind the card.
        final GradientDrawable glowOuter = new GradientDrawable();
        glowOuter.setCornerRadius(dp(app, 30));
        glowOuter.setColor(alpha(accent, 0.10f));
        final GradientDrawable glowInner = new GradientDrawable();
        glowInner.setCornerRadius(dp(app, 27));
        glowInner.setColor(alpha(accent, 0.18f));
        FrameLayout haloOuter = new FrameLayout(app);
        int hp = dp(app, 3);
        haloOuter.setPadding(hp, hp, hp, hp);
        haloOuter.setBackground(glowOuter);
        FrameLayout haloInner = new FrameLayout(app);
        haloInner.setPadding(hp, hp, hp, hp);
        haloInner.setBackground(glowInner);
        haloInner.addView(card, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        haloOuter.addView(haloInner, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // Card edge 12dp from the screen sides (6dp padding + 6dp glow); room above / below for the shadow.
        final FrameLayout root = new FrameLayout(app);
        int m = dp(app, 6);
        root.setPadding(m, dp(app, 4), m, dp(app, 16));
        root.addView(haloOuter, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        s.root = root;

        // Gentle pulse, 2 s per cycle: glow and edge brighten and fade. Cancelled in close().
        try {
            ValueAnimator pulse = ValueAnimator.ofFloat(0f, 1f);
            pulse.setDuration(1_000);
            pulse.setRepeatCount(ValueAnimator.INFINITE);
            pulse.setRepeatMode(ValueAnimator.REVERSE);
            pulse.addUpdateListener(a -> {
                try {
                    float f = (Float) a.getAnimatedValue();
                    glowOuter.setAlpha(Math.round(255 * (0.45f + 0.55f * f)));
                    glowInner.setAlpha(Math.round(255 * (0.55f + 0.45f * f)));
                    bg.setStroke(edge, alpha(accent, 0.7f + 0.3f * f));
                } catch (RuntimeException ignored) {
                    // card going away
                }
            });
            s.pulse = pulse;
        } catch (RuntimeException ignored) {
            s.pulse = null;   // static glow
        }

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
        final int maxY = Math.max(0, screenH - dp(app, 180));
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
        if (s.pulse != null) {
            try { s.pulse.start(); } catch (RuntimeException ignored) { s.pulse = null; }
        }

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
