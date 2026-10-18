import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'cloud.dart';
import 'community.dart';
import 'i18n/i18n.dart';
import 'i18n/reasons.dart';
import 'legal/legal.dart';
import 'monetize/monetize.dart';
import 'native.dart';
import 'screens/alerts.dart';
import 'screens/check.dart';
import 'screens/home.dart';
import 'screens/lock.dart';
import 'screens/onboarding.dart';
import 'screens/payment_check.dart';
import 'screens/result.dart';
import 'screens/settings.dart';
import 'screens/splash.dart';
import 'theme.dart';
import 'voice.dart';
import 'widgets/alert_card.dart';
import 'widgets/common.dart';

final navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Native.instance.init();
  registerLicences();
  await I18nData.load(); // Hindi and Kannada texts for scam reasons and advice
  L10n.lang.addListener(_relabelAll);
  // Confirms any Plus purchase that finished while the app was closed (phones only; no-op on a laptop).
  if (Cloud.configured) Monetize.start();
  runApp(const SecondLookApp());
}

/// tr() doesn't depend on an InheritedWidget, so screens that are already built (const widgets, open routes,
/// the other tabs) would keep the old language. Rebuild every element when the language changes.
void _relabelAll() {
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(mark);
}

class SecondLookApp extends StatelessWidget {
  const SecondLookApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        // Rebuilds the whole app when the language changes.
        valueListenable: L10n.lang,
        builder: (context, code, _) => MaterialApp(
        title: 'Second Look',
        debugShowCheckedModeBanner: false,
        navigatorKey: navKey,
        theme: SL.dark(),
        darkTheme: SL.dark(),
        themeMode: ThemeMode.dark,
        locale: Locale(code, 'IN'),
        supportedLocales: const [Locale('en', 'IN'), Locale('hi', 'IN'), Locale('kn', 'IN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const Root(),
        // On a laptop, keep the app phone-width and centred so it reads well on a wide screen.
        builder: (context, child) {
          final w = MediaQuery.sizeOf(context).width;
          if (w <= 640 || child == null) return child ?? const SizedBox.shrink();
          return ColoredBox(
            color: SL.bgTop,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Material(elevation: 2, color: SL.bgSolid, child: child),
              ),
            ),
          );
        },
      ),
      );
}

/// Shows onboarding the first time, then the main app.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  Map<String, dynamic>? status;
  bool unlocked = false;
  bool _agreedNow = false;
  bool _langReady = false;
  bool _splashDone = false;
  DateTime? leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    Native.instance.onShared = (text) => _openShared(text);
    Native.instance.onSharedImage = (path) => _openSharedImage(path);
    Native.instance.onAlertOpened = (id) => _openAlert(id);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-lock after the app has been in the background for more than 30 seconds.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) leftAt = DateTime.now();
    if (state == AppLifecycleState.resumed && leftAt != null && DateTime.now().difference(leftAt!).inSeconds > 30) {
      leftAt = null;
      // Lock first (synchronously) so app content is never shown while the status reloads.
      navKey.currentState?.popUntil((r) => r.isFirst);
      setState(() => unlocked = false);
      _load();
    }
  }

  /// True while the lock screen is (or may be about to be) shown. Unknown status counts as locked.
  /// Onboarding and the consent-update screen also count: nothing shared is opened before the user has agreed.
  bool get _locked {
    final s = status;
    return s == null || s['onboarded'] != true || (s['termsVersion'] != kLegalVersion && !_agreedNow) || (s['appLock'] == true && !unlocked);
  }

  // Shared text / tapped alerts that arrived while locked; opened after unlocking.
  String? _pendingShared;
  String? _pendingAlert;
  String? _pendingImage;

  Future<void> _load() async {
    final s = await Native.instance.status();
    if (!mounted) return;
    if (!_langReady) {
      _langReady = true;
      L10n.init(s);
      Voice.init(s);
    }
    setState(() => status = s);
    Community.syncIfDue(s); // background download of the community scam list for Call Shield
    final shared = await Native.instance.consumeSharedText();
    if (shared != null && shared.trim().isNotEmpty) _pendingShared = shared;
    final img = await Native.instance.consumeSharedImage();
    if (img != null && img.isNotEmpty) _pendingImage = img;
    final alertId = await Native.instance.consumeAlertId();
    if (alertId != null) _pendingAlert = alertId;
    _flushPending();
  }

  void _flushPending() {
    if (!mounted || _locked) return;
    final t = _pendingShared, a = _pendingAlert, img = _pendingImage;
    _pendingShared = null;
    _pendingAlert = null;
    _pendingImage = null;
    if (t != null) _openShared(t);
    if (img != null) _openSharedImage(img);
    if (a != null) _openAlert(a);
  }

  void _unlock() {
    leftAt = null; // the PIN screen itself pauses the app; don't count that as "left"
    setState(() => unlocked = true);
    _flushPending();
  }

  void _openSharedImage(String path) {
    if (_locked) {
      _pendingImage = path;
      return;
    }
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => PaymentCheckScreen(sharedPath: path)));
  }

  // Never push content over the lock screen: queue it until the user unlocks.
  Future<void> _openShared(String text) async {
    if (_locked) {
      _pendingShared = text;
      return;
    }
    final r = await Native.instance.analyze(text);
    if (!mounted) return;
    if (_locked) {
      _pendingShared = text;
      return;
    }
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => ResultScreen(result: r, title: 'Shared with Second Look')));
  }

  Future<void> _openAlert(String id) async {
    if (_locked) {
      _pendingAlert = id;
      return;
    }
    final h = await Native.instance.history();
    if (!mounted) return;
    if (_locked) {
      _pendingAlert = id;
      return;
    }
    final item = h.where((e) => e['id'] == id).toList();
    if (item.isEmpty) return;
    final r = (item.first['result'] as Map?)?.cast<String, dynamic>();
    if (r == null) return;
    navKey.currentState?.push(MaterialPageRoute(builder: (_) => ResultScreen(result: r, title: item.first['title'] as String? ?? 'Alert')));
  }

  /// The short intro on every launch, then a fade into the app (onboarding, lock screen or the app itself).
  @override
  Widget build(BuildContext context) {
    final noMotion = MediaQuery.of(context).disableAnimations;
    return AnimatedSwitcher(
      duration: Duration(milliseconds: noMotion ? 0 : 420),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _splashDone
          ? KeyedSubtree(key: const ValueKey('app'), child: _content(context))
          : SplashScreen(
              key: const ValueKey('splash'),
              status: status,
              onDone: () {
                if (mounted) setState(() => _splashDone = true);
              },
            ),
    );
  }

  Widget _content(BuildContext context) {
    final s = status;
    if (s == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (s['onboarded'] != true) {
      return OnboardingScreen(onDone: () async {
        _agreedNow = true;
        await Native.instance.setOnboarded(kLegalVersion);
        await _load();
      });
    }
    // The Terms or Privacy Policy changed since the user last agreed: ask again before continuing.
    if (s['termsVersion'] != kLegalVersion && !_agreedNow) {
      return ConsentUpdateScreen(onAccepted: () async {
        _agreedNow = true; // even if saving the version fails, don't ask again in this session
        try {
          await Native.instance.setOnboarded(kLegalVersion);
        } catch (_) {}
        await _load();
      });
    }
    if (s['appLock'] == true && !unlocked) {
      return LockScreen(onUnlocked: _unlock);
    }
    return const Shell();
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  final _homeKey = GlobalKey<HomeScreenState>();

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(key: _homeKey, onCheck: () => setState(() => tab = 1), onAlerts: () => setState(() => tab = 2)),
      const CheckScreen(),
      const AlertsScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      backgroundColor: SL.bgBottom,
      body: Backdrop(child: IndexedStack(index: tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) {
          setState(() => tab = i);
          if (i == 0) _homeKey.currentState?.refresh();
          if (i == 2) notifyAlertsChanged(); // new SMS/calls may have been checked while the app was open
        },
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: tr('Home')),
          NavigationDestination(icon: const Icon(Icons.search_rounded), selectedIcon: const Icon(Icons.manage_search_rounded), label: tr('Check')),
          NavigationDestination(icon: const Icon(Icons.notifications_none_rounded), selectedIcon: const Icon(Icons.notifications_rounded), label: tr('Alerts')),
          NavigationDestination(icon: const Icon(Icons.settings_outlined), selectedIcon: const Icon(Icons.settings_rounded), label: tr('Settings')),
        ],
      ),
    );
  }
}
