import 'package:flutter/widgets.dart';

import 'native.dart';

/// "Battery saver look": a lighter app for low-memory phones or when the user wants it. In lite mode every
/// looping animation (Home radar, scan line, result ring, intro, illustrations) holds a still frame.
///
/// Lite = pref 'lite_mode' is 'on', or it's 'auto' (the default) and the phone is low on memory
/// (status.device.lowRam or under 4 GB) or the phone asks for reduced motion.
/// When not lite, looping animations still pause while the app is in the background ([active]).
class Perf with WidgetsBindingObserver {
  Perf._();
  static final Perf _observer = Perf._();
  static bool _started = false;

  /// True when the battery saver look is in effect. Screens with looping animations listen to this.
  static final ValueNotifier<bool> lite = ValueNotifier<bool>(false);

  /// False while the app is in the background (looping animations pause).
  static final ValueNotifier<bool> active = ValueNotifier<bool>(true);

  /// 'auto' | 'on' | 'off'.
  static String mode = 'auto';

  /// status.device: {lowRam, ramMb, sdk}. Null on a laptop or older builds.
  static Map<String, dynamic>? device;

  /// Starts listening for the app going to the background and for accessibility changes. Call once, after
  /// WidgetsFlutterBinding.ensureInitialized().
  static void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(_observer);
    _recompute();
  }

  /// Reads the saved choice and the phone's memory facts from Native.status().
  static void update(Map<String, dynamic>? status) {
    mode = Native.liteModeOf(status);
    device = Native.deviceOf(status);
    _recompute();
  }

  /// Saves 'auto' | 'on' | 'off'. Returns the new status, or null if it couldn't be saved.
  static Future<Map<String, dynamic>?> setMode(String m) async {
    final v = m == 'on' || m == 'off' ? m : 'auto';
    final st = await Native.instance.setLiteMode(v);
    if (st == null) return null;
    device = Native.deviceOf(st) ?? device;
    mode = v; // even if this build's status doesn't echo the pref back
    _recompute();
    return st;
  }

  /// The phone asks for reduced motion (accessibility setting).
  static bool get systemNoMotion {
    try {
      return WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    } catch (_) {
      return false;
    }
  }

  /// A low-memory phone (Android "low RAM" device, or under 4 GB).
  static bool get weakDevice {
    final d = device;
    if (d == null) return false;
    if (d['lowRam'] == true) return true;
    final v = d['ramMb'];
    final mb = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return mb > 0 && mb < 4096;
  }

  /// Total memory in MB, or 0 if unknown.
  static int get ramMb {
    final v = device?['ramMb'];
    return v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  }

  static void _recompute() {
    lite.value = mode == 'on' || (mode == 'auto' && (weakDevice || systemNoMotion));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 'inactive' is still on screen (for example the notification shade is pulled down).
    active.value = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  }

  @override
  void didChangeAccessibilityFeatures() => _recompute();
}

/// For States that run looping AnimationControllers. Calls [applyMotion] whenever the battery saver look,
/// reduced motion, the app being in the background or the tab being hidden (TickerMode) changes.
/// Use it after the ticker mixin: `with SingleTickerProviderStateMixin, LoopMotion<MyWidget>`.
mixin LoopMotion<T extends StatefulWidget> on State<T> {
  bool _sysStill = false;
  bool _tickerOn = true;
  bool? _lastStill;
  bool? _lastRun;

  /// True when this widget should show a still frame (battery saver look or reduced motion).
  bool get motionStill => Perf.lite.value || _sysStill;

  /// Start, stop or reset the looping controllers. [still]: show the still frame (stop for good);
  /// otherwise [run] says whether to loop now (false = pause where it is).
  void applyMotion({required bool still, required bool run});

  @override
  void initState() {
    super.initState();
    Perf.lite.addListener(_onPerf);
    Perf.active.addListener(_onPerf);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sysStill = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _tickerOn = TickerMode.of(context);
    _syncMotion(rebuild: false);
  }

  void _onPerf() => _syncMotion(rebuild: true);

  void _syncMotion({required bool rebuild}) {
    if (!mounted) return;
    final still = motionStill;
    final run = !still && Perf.active.value && _tickerOn;
    if (still == _lastStill && run == _lastRun) return;
    final stillChanged = _lastStill != null && still != _lastStill;
    _lastStill = still;
    _lastRun = run;
    applyMotion(still: still, run: run);
    if (rebuild && stillChanged) setState(() {});
  }

  @override
  void dispose() {
    Perf.lite.removeListener(_onPerf);
    Perf.active.removeListener(_onPerf);
    super.dispose();
  }
}

/// True when screens should skip decorative motion (battery saver look or the phone's reduced-motion setting).
bool liteMotion(BuildContext context) => Perf.lite.value || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);

