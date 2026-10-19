import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../i18n/i18n.dart';
import '../perf.dart';
import '../theme.dart';
import 'ad_rules.dart';
export 'ad_rules.dart';

/// Ads on Android and iPhone (Google AdMob). Second Look is free; these ads pay for it.
///
/// Nothing is requested before Google's consent check (UMP) has run and allows ads. Ads never get SMS, call,
/// document or check content: requests carry no keywords or content, only what the AdMob SDK itself collects.
/// When ads don't load (offline, no fill, no consent), every ad space collapses and the app works as usual.
class Monetize {
  // Real ad unit ids are passed at build time (tool/defines.py, docs/ADS.md); Google's official TEST ids are used
  // otherwise, so test builds never show live ads.
  static const _rewardedAndroid = String.fromEnvironment('ADMOB_REWARDED_ANDROID', defaultValue: 'ca-app-pub-3940256099942544/5224354917');
  static const _rewardedIos = String.fromEnvironment('ADMOB_REWARDED_IOS', defaultValue: 'ca-app-pub-3940256099942544/1712485313');
  static const _bannerAndroid = String.fromEnvironment('ADMOB_BANNER_ANDROID', defaultValue: 'ca-app-pub-3940256099942544/9214589741');
  static const _bannerIos = String.fromEnvironment('ADMOB_BANNER_IOS', defaultValue: 'ca-app-pub-3940256099942544/2435281174');
  static const _interstitialAndroid = String.fromEnvironment('ADMOB_INTERSTITIAL_ANDROID', defaultValue: 'ca-app-pub-3940256099942544/1033173712');
  static const _interstitialIos = String.fromEnvironment('ADMOB_INTERSTITIAL_IOS', defaultValue: 'ca-app-pub-3940256099942544/4411468910');
  static const _nativeAndroid = String.fromEnvironment('ADMOB_NATIVE_ANDROID', defaultValue: 'ca-app-pub-3940256099942544/2247696110');
  static const _nativeIos = String.fromEnvironment('ADMOB_NATIVE_IOS', defaultValue: 'ca-app-pub-3940256099942544/3986624511');

  static String get _rewardedUnit => Platform.isIOS ? _rewardedIos : _rewardedAndroid;
  static String get _bannerUnit => Platform.isIOS ? _bannerIos : _bannerAndroid;
  static String get _interstitialUnit => Platform.isIOS ? _interstitialIos : _interstitialAndroid;
  static String get _nativeUnit => Platform.isIOS ? _nativeIos : _nativeAndroid;

  /// Non-personalised requests with no keywords or content: nothing about the user's checks goes into a request.
  static const _request = AdRequest(nonPersonalizedAds: true);

  static bool get adsSupported => true;

  /// True once ads may be requested (consent given or not needed) and the ads SDK has started.
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  static Future<bool>? _starting;
  static Future<void>? _consent;

  /// Runs Google's consent check (and shows the consent form where the law requires it), then starts the ads SDK.
  /// Safe to call often; a failed start (for example offline) is tried again on the next call.
  static Future<bool> init() {
    if (ready.value) return Future<bool>.value(true);
    return _starting ??= _start().then((ok) {
      if (!ok) _starting = null;
      return ok;
    });
  }

  static Future<bool> _start() async {
    try {
      await (_consent = _gatherConsent());
      if (!await ConsentInformation.instance.canRequestAds()) return false;
      await MobileAds.instance.initialize();
      // Family-safe ads only (also block categories in the AdMob console, see docs/ADS.md). Not child-directed.
      await MobileAds.instance.updateRequestConfiguration(RequestConfiguration(
        maxAdContentRating: MaxAdContentRating.g,
        // Deprecated in google_mobile_ads 9.x (ageRestrictedTreatment), but that doesn't exist in 7.x; still works.
        // ignore: deprecated_member_use
        tagForChildDirectedTreatment: TagForChildDirectedTreatment.no,
      ));
      AdRules.showInterstitial = _showInterstitial;
      AdRules.preloadInterstitial = preloadInterstitial;
      ready.value = true;
      // Someone who already did a manual check may get an ad after the next one: have it ready.
      if (AdRules.checksDone >= 1) preloadInterstitial();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Google UMP: update the consent status, then show the consent form only if it's required and not yet answered.
  static Future<void> _gatherConsent() {
    final done = Completer<void>();
    void finish([Object? _]) {
      if (!done.isCompleted) done.complete();
    }

    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          try {
            await ConsentForm.loadAndShowConsentFormIfRequired(finish);
          } catch (_) {}
          finish();
        },
        finish,
      );
    } catch (_) {
      finish();
    }
    // The form waits for the user; never hold anything else up forever.
    return done.future.timeout(const Duration(minutes: 3), onTimeout: () {});
  }

  /// True if the user's region needs a way to change ad consent (Me → Privacy → Ad choices opens Google's form),
  /// false if not, null if Google couldn't be asked yet (for example offline).
  static Future<bool?> privacyOptionsRequired() async {
    try {
      if (_consent == null) unawaited(init());
      await (_consent ?? Future<void>.value()).timeout(const Duration(seconds: 10), onTimeout: () {});
      final s = await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
      if (s == PrivacyOptionsRequirementStatus.required) return true;
      if (s == PrivacyOptionsRequirementStatus.notRequired) return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Shows Google's privacy options form, where the user can change their ad consent. True if it was shown.
  static Future<bool> showPrivacyOptions() async {
    final shown = Completer<bool>();
    try {
      await ConsentForm.showPrivacyOptionsForm((FormError? e) {
        if (!shown.isCompleted) shown.complete(e == null);
      });
    } catch (_) {
      if (!shown.isCompleted) shown.complete(false);
    }
    final ok = await shown.future;
    // The new choice may allow ads, or stop them.
    try {
      final can = await ConsentInformation.instance.canRequestAds();
      if (!can) {
        ready.value = false;
        AdRules.showInterstitial = null;
        AdRules.preloadInterstitial = null;
        _interstitial?.dispose();
        _interstitial = null;
      } else if (!ready.value) {
        unawaited(init());
      }
    } catch (_) {}
    return ok;
  }

  // ---- loading, one at a time in the battery saver look

  static final _gate = _LoadGate();

  // ---- full-screen ad after a manual check (rules in AdRules)

  static InterstitialAd? _interstitial;
  static DateTime? _interstitialAt;
  static bool _interstitialLoading = false;

  /// Loads the next full-screen ad in the background. Never shown here; [AdRules.leaving] decides.
  static void preloadInterstitial() {
    if (!ready.value || _interstitialLoading) return;
    final at = _interstitialAt;
    if (_interstitial != null && at != null && DateTime.now().difference(at) < const Duration(minutes: 50)) return;
    _interstitial?.dispose();
    _interstitial = null;
    _interstitialLoading = true;
    unawaited(() async {
      final release = await _gate.slot();
      try {
        await InterstitialAd.load(
          adUnitId: _interstitialUnit,
          request: _request,
          adLoadCallback: InterstitialAdLoadCallback(
            onAdLoaded: (ad) {
              release();
              _interstitialLoading = false;
              if (!ready.value) {
                ad.dispose();
                return;
              }
              _interstitial = ad;
              _interstitialAt = DateTime.now();
            },
            onAdFailedToLoad: (_) {
              release();
              _interstitialLoading = false; // tried again after the next manual check
            },
          ),
        );
      } catch (_) {
        release();
        _interstitialLoading = false;
      }
    }());
  }

  /// Shows the loaded full-screen ad, if there is a fresh one. Never waits for a load.
  static Future<bool> _showInterstitial() async {
    final ad = _interstitial, at = _interstitialAt;
    if (!ready.value || ad == null || at == null || DateTime.now().difference(at) > const Duration(minutes: 55)) {
      if (ad != null) {
        ad.dispose();
        _interstitial = null;
      }
      preloadInterstitial();
      return false;
    }
    _interstitial = null;
    final started = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        if (!started.isCompleted) started.complete(true);
      },
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        preloadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        if (!started.isCompleted) started.complete(false);
        preloadInterstitial();
      },
    );
    try {
      await ad.show();
    } catch (_) {
      ad.dispose();
      return false;
    }
    return started.future.timeout(const Duration(seconds: 5), onTimeout: () => false);
  }

  // ---- rewarded ads (always started by the user)

  /// Shows one rewarded ad for an extra deep check. Returns true only if the user watched it to the end.
  /// The deep-check credit itself is granted by the server after Google confirms the reward (server-side verification).
  static Future<bool> showRewardedAd(String installId) => _rewarded(installId: installId);

  /// "Support Second Look": a rewarded ad the user chooses to watch. Nothing is unlocked; true if it was watched.
  static Future<bool> showSupportAd() => _rewarded();

  static Future<bool> _rewarded({String? installId}) async {
    if (!await init()) return false;
    final loaded = Completer<RewardedAd?>();
    try {
      await RewardedAd.load(
        adUnitId: _rewardedUnit,
        request: _request,
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            if (!loaded.isCompleted) {
              loaded.complete(ad);
            } else {
              ad.dispose(); // arrived after the 20 s wait
            }
          },
          onAdFailedToLoad: (_) {
            if (!loaded.isCompleted) loaded.complete(null);
          },
        ),
      );
    } catch (_) {
      if (!loaded.isCompleted) loaded.complete(null);
    }
    final ad = await loaded.future.timeout(const Duration(seconds: 20), onTimeout: () {
      if (!loaded.isCompleted) loaded.complete(null);
      return null;
    });
    if (ad == null) return false;
    // Only the deep-check ad carries the install id; a support ad has none, so the server never credits it.
    if (installId != null) await ad.setServerSideOptions(ServerSideVerificationOptions(userId: installId, customData: 'deep_check'));
    final done = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) => AdRules.markShown(),
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        if (!done.isCompleted) done.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        if (!done.isCompleted) done.complete(false);
      },
    );
    try {
      await ad.show(onUserEarnedReward: (_, __) => earned = true);
    } catch (_) {
      ad.dispose();
      return false;
    }
    return done.future;
  }
}

/// Lets at most 3 ads load at once, or 1 in the battery saver look. A slot frees itself after 60 s even if the
/// SDK never answers.
class _LoadGate {
  int _busy = 0;
  final _waiting = <Completer<void>>[];

  int get _max => Perf.lite.value ? 1 : 3;

  Future<void Function()> slot() async {
    while (_busy >= _max) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _busy++;
    var done = false;
    late final Timer timer;
    void release() {
      if (done) return;
      done = true;
      timer.cancel();
      _busy--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }

    timer = Timer(const Duration(seconds: 60), release);
    return release;
  }
}

/// The tiny "Sponsored" label on every ad space (Manrope 10.5, muted).
class _Sponsored extends StatelessWidget {
  const _Sponsored();
  @override
  Widget build(BuildContext context) => Text(
        tr('Sponsored'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFamily: SL.body, fontSize: 10.5, fontWeight: FontWeight.w600, color: SL.textMuted, height: 1.2),
      );
}

/// The app's ad frame: rounded 16, glass fill, 1 px hairline, "Sponsored" top-left.
class _AdFrame extends StatelessWidget {
  const _AdFrame({required this.child, this.floating = false});
  final Widget child;

  /// The banner floats over scrolling content, so it gets the bottom bar's solid glass instead of the see-through one.
  final bool floating;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(_pad, 6, _pad, _pad),
        decoration: BoxDecoration(
          color: floating ? SL.navFill : SL.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: SL.glassBorder),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _Sponsored(),
          const SizedBox(height: 4),
          ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
        ]),
      );

  static const _pad = 8.0;

  /// Width taken by the frame's padding and border.
  static const inset = 2 * _pad + 2;
}

/// One anchored adaptive banner, framed, for the bottom of Home, Check and Alerts. Zero height until an ad loads,
/// and again if none does. Its ad is disposed with the widget.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});
  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _loading = false;
  int _width = 0;
  int _tries = 0;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    Monetize.ready.addListener(_onReady);
  }

  @override
  void dispose() {
    Monetize.ready.removeListener(_onReady);
    _retry?.cancel();
    _ad?.dispose();
    _ad = null;
    super.dispose();
  }

  void _onReady() {
    if (Monetize.ready.value) {
      _load();
    } else {
      _drop();
    }
  }

  void _drop() {
    _ad?.dispose();
    _ad = null;
    if (mounted && _loaded) setState(() => _loaded = false);
    _loaded = false;
  }

  /// Called after layout with the width the banner can use. A new width (rotation, split screen) loads a new ad.
  void _setWidth(int w) {
    if (w == _width || w < 200) return;
    _width = w;
    _tries = 0;
    _drop();
    _load();
  }

  Future<void> _load() async {
    if (!mounted || _loading || _loaded || _width <= 0 || !Monetize.ready.value) return;
    _loading = true;
    final w = _width;
    final release = await Monetize._gate.slot();
    AnchoredAdaptiveBannerAdSize? size;
    try {
      // ignore: deprecated_member_use
      size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(w);
    } catch (_) {}
    if (!mounted || size == null || w != _width) {
      release();
      _loading = false;
      if (mounted && w != _width) _load(); // the width changed while waiting: load for the new one
      return;
    }
    final ad = BannerAd(
      adUnitId: Monetize._bannerUnit,
      size: size,
      request: Monetize._request,
      listener: BannerAdListener(
        onAdLoaded: (a) {
          release();
          _loading = false;
          if (!mounted || w != _width) {
            a.dispose();
            if (mounted) _load();
            return;
          }
          setState(() {
            _ad = a as BannerAd;
            _loaded = true;
          });
        },
        onAdFailedToLoad: (a, _) {
          release();
          _loading = false;
          a.dispose();
          // No fill or offline: stay collapsed and try again later, a few times at most.
          if (mounted && _tries++ < 3) _retry = Timer(const Duration(seconds: 60), _load);
        },
      ),
    );
    try {
      await ad.load();
    } catch (_) {
      release();
      _loading = false;
      ad.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - _AdFrame.inset).floor();
        if (w != _width) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _setWidth(w) : null);
        final ad = _ad;
        final Widget child = !_loaded || ad == null
            ? const SizedBox(width: double.infinity, height: 0)
            : Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _AdFrame(
                  floating: true,
                  child: SizedBox(width: ad.size.width.toDouble(), height: ad.size.height.toDouble(), child: AdWidget(ad: ad)),
                ),
              );
        return AnimatedSize(
          duration: Duration(milliseconds: Perf.lite.value ? 0 : 220),
          alignment: Alignment.bottomCenter,
          child: child,
        );
      });
}

/// A native ad card (Google's template, styled dark to match the app) with the "Sponsored" label.
/// Small in lists, medium on Offers. Loads only once its tab is showing; takes no space until an ad loads.
class NativeAdCard extends StatefulWidget {
  const NativeAdCard({super.key, this.medium = false, this.margin = EdgeInsets.zero, this.onResult});
  final bool medium;

  /// Space around the card, only when it shows.
  final EdgeInsets margin;

  /// Called once: true when an ad loaded, false when none could (for the Offers empty state).
  final ValueChanged<bool>? onResult;

  @override
  State<NativeAdCard> createState() => _NativeAdCardState();
}

class _NativeAdCardState extends State<NativeAdCard> with AutomaticKeepAliveClientMixin {
  NativeAd? _ad;
  bool _loaded = false;
  bool _started = false;
  bool _reported = false;
  bool _visible = false;

  // Kept alive in scrolling lists: an ad view can't be put back once it has left the screen.
  @override
  bool get wantKeepAlive => _loaded;

  @override
  void initState() {
    super.initState();
    Monetize.ready.addListener(_onReady);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.of(context);
    _maybeLoad();
  }

  @override
  void dispose() {
    Monetize.ready.removeListener(_onReady);
    _ad?.dispose();
    _ad = null;
    super.dispose();
  }

  void _onReady() {
    if (Monetize.ready.value) {
      _maybeLoad();
    } else {
      _ad?.dispose();
      _ad = null;
      if (mounted && _loaded) {
        setState(() => _loaded = false);
        updateKeepAlive();
      }
    }
  }

  void _report(bool ok) {
    if (_reported) return;
    _reported = true;
    widget.onResult?.call(ok);
  }

  /// Loads once, when ads are allowed and this card's tab is on screen (hidden tabs don't load ads).
  Future<void> _maybeLoad() async {
    if (_started || !mounted || !Monetize.ready.value || !_visible) return;
    _started = true;
    final release = await Monetize._gate.slot();
    if (!mounted) {
      release();
      return;
    }
    const text = NativeTemplateFontStyle.normal;
    final ad = NativeAd(
      adUnitId: Monetize._nativeUnit,
      request: Monetize._request,
      nativeTemplateStyle: NativeTemplateStyle(
        templateType: widget.medium ? TemplateType.medium : TemplateType.small,
        mainBackgroundColor: const Color(0xFF0B1220),
        cornerRadius: 16,
        callToActionTextStyle: NativeTemplateTextStyle(
          textColor: const Color(0xFF04121A),
          backgroundColor: const Color(0xFF38E1FF),
          style: NativeTemplateFontStyle.bold,
          size: 15,
        ),
        primaryTextStyle: NativeTemplateTextStyle(textColor: const Color(0xFFEAF2FF), backgroundColor: const Color(0xFF0B1220), style: NativeTemplateFontStyle.bold, size: 15),
        secondaryTextStyle: NativeTemplateTextStyle(textColor: const Color(0xFFA9B8D0), backgroundColor: const Color(0xFF0B1220), style: text, size: 13),
        tertiaryTextStyle: NativeTemplateTextStyle(textColor: const Color(0xFFA9B8D0), backgroundColor: const Color(0xFF0B1220), style: text, size: 13),
      ),
      listener: NativeAdListener(
        onAdLoaded: (a) {
          release();
          if (!mounted) {
            a.dispose();
            return;
          }
          setState(() {
            _ad = a as NativeAd;
            _loaded = true;
          });
          updateKeepAlive();
          _report(true);
        },
        onAdFailedToLoad: (a, _) {
          release();
          a.dispose();
          if (mounted) _report(false);
        },
      ),
    );
    try {
      await ad.load();
    } catch (_) {
      release();
      ad.dispose();
      if (mounted) _report(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ad = _ad;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return Padding(
      padding: widget.margin,
      child: _AdFrame(
        child: ConstrainedBox(
          // Google's template sizes: small 90–200 px tall, medium 320–400 px; both 320–400 px wide where possible.
          constraints: BoxConstraints(maxWidth: 400, minHeight: widget.medium ? 320 : 90),
          child: SizedBox(width: double.infinity, height: widget.medium ? 340 : 116, child: AdWidget(ad: ad)),
        ),
      ),
    );
  }
}
