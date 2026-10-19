import 'dart:async';

import 'package:flutter/widgets.dart';

import '../native.dart';

/// One manual check whose result is on screen. [leaving] decides, when the user leaves the result, whether a
/// full-screen ad may follow.
class AdTicket {
  AdTicket._(this.eligible, this.level);

  /// False for the very first manual check ever (it's always ad-free).
  final bool eligible;

  /// The latest result's level key: 'safe' | 'warning' | 'danger'.
  String level;

  /// The user tapped Block, Report or Call 1930 on this result.
  bool acted = false;

  bool _closed = false;
}

/// When Second Look may show a full-screen ad. Second Look is free and paid for by ads, but it never gets in the way
/// of protection:
///
/// - Only after a check the user started (Check anything, paste, and the message, number, payment, UPI/QR and
///   document tools). Never for SMS or Call Shield, the call/SMS popup, Alerts, "Being scammed?", Protection check
///   or onboarding.
/// - The first manual check ever is ad-free. From the second on, the result is shown at once and the ad comes only
///   when the user leaves the result.
/// - No ad after a "Likely scam" result, or when the user tapped Block, Report or Call 1930 on it.
/// - At most one full-screen ad every 2 minutes, and only if one is already loaded: the user never waits for an ad.
///
/// Pure Dart (no ads library), so the web build uses it too; there [showInterstitial] stays null and nothing shows.
class AdRules {
  AdRules._();

  static const gap = Duration(minutes: 2);

  /// Manual checks done on this device (pref 'checks_done').
  static int checksDone = 0;

  /// When the last full-screen ad was shown, in ms since epoch (pref 'last_ad_at').
  static int lastAdAt = 0;

  /// Set by the phone ad code once ads are allowed (consent given or not needed) and the SDK is ready.
  /// Returns true if an ad started showing.
  static Future<bool> Function()? showInterstitial;

  /// Set by the phone ad code: loads the next full-screen ad in the background (no-op if one is ready or loading).
  static void Function()? preloadInterstitial;

  static AdTicket? _current;
  static int _holdUntil = 0;

  static int get _now => DateTime.now().millisecondsSinceEpoch;

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

  /// Reads the saved counter and last-ad time from Native.status(). Keeps the larger value, so an older status
  /// snapshot never undoes a check made in this session.
  static void load(Map<String, dynamic>? status) {
    final p = (status?['prefs'] as Map?) ?? const {};
    final c = _int(p['checks_done']), l = _int(p['last_ad_at']);
    if (c > checksDone) checksDone = c;
    if (l > lastAdAt && l <= _now + 60000) lastAdAt = l;
  }

  static String levelOf(Map<String, dynamic>? result) => '${(result?['level'] as Map?)?['key'] ?? 'safe'}';

  /// A manual check just showed its result. Counts it and returns the ticket for [leaving].
  static AdTicket manualCheck(Map<String, dynamic>? result) {
    checksDone++;
    unawaited(Native.instance.trySetPref('checks_done', '$checksDone'));
    final t = AdTicket._(checksDone >= 2, levelOf(result));
    _current = t;
    // Get the next ad ready in the background, so it can show without any wait when this result is closed.
    preloadInterstitial?.call();
    return t;
  }

  /// A tool screen ran its check again (for example after "Wrong type?"): same visit, newest result.
  static void update(AdTicket t, Map<String, dynamic>? result) {
    t.level = levelOf(result);
    _current = t;
  }

  /// The user tapped Block, Report or Call 1930 on the result that's showing: no ad when they leave it.
  static void acted() => _current?.acted = true;

  /// No ad for a few seconds (for example while the app locks itself and closes every page).
  static void hold([Duration d = const Duration(seconds: 3)]) => _holdUntil = _now + d.inMilliseconds;

  /// The user left a manual result (back or done). Shows a full-screen ad only if every rule allows it.
  static Future<void> leaving(AdTicket? t) async {
    if (t == null || t._closed) return;
    t._closed = true;
    if (identical(_current, t)) _current = null;
    if (!t.eligible || t.acted || t.level == 'danger') return;
    if (_now < _holdUntil || _now - lastAdAt < gap.inMilliseconds) return;
    final show = showInterstitial;
    if (show == null) return;
    // Let the page finish closing first, so the ad comes after the result, never on top of it.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_now < _holdUntil || _now - lastAdAt < gap.inMilliseconds) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    if (await show()) markShown();
  }

  /// "Delete all my data" removed the saved counters: forget them in this session too.
  static void reset() {
    checksDone = 0;
    lastAdAt = 0;
  }

  /// A full-screen ad (or a rewarded ad the user chose) was shown now: starts the 2-minute gap.
  static void markShown() {
    lastAdAt = _now;
    unawaited(Native.instance.trySetPref('last_ad_at', '$lastAdAt'));
  }
}
