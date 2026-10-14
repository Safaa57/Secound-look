import 'dart:async';
import 'dart:io' show Platform;

import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../cloud.dart';
import '../i18n/i18n.dart';
import 'types.dart';
export 'types.dart';

/// Rewarded ads (optional, user-started only) and Plus subscriptions on Android and iPhone.
class Monetize {
  // Real ad unit ids are passed at build time; Google's official TEST ids are used otherwise,
  // so test builds never show live ads.
  static const _androidUnit = String.fromEnvironment('ADMOB_REWARDED_ANDROID', defaultValue: 'ca-app-pub-3940256099942544/5224354917');
  static const _iosUnit = String.fromEnvironment('ADMOB_REWARDED_IOS', defaultValue: 'ca-app-pub-3940256099942544/1712485313');

  static bool _ready = false;
  static StreamSubscription<List<PurchaseDetails>>? _sub;

  static Future<void> init() async {
    if (_ready) return;
    _ready = true;
    await MobileAds.instance.initialize();
    // Family-safe ads only. Also block categories in the AdMob console (see docs/ADS_AND_PLUS.md).
    await MobileAds.instance.updateRequestConfiguration(RequestConfiguration(maxAdContentRating: MaxAdContentRating.g));
  }

  static bool get adsSupported => true;
  static bool get storeSupported => true;

  /// Shows one rewarded ad. Returns true only if the user watched it to the end.
  /// The deep-check credit itself is granted by the server after Google confirms the reward (server-side verification).
  static Future<bool> showRewardedAd(String installId) async {
    await init();
    final loaded = Completer<RewardedAd?>();
    RewardedAd.load(
      adUnitId: Platform.isIOS ? _iosUnit : _androidUnit,
      request: const AdRequest(nonPersonalizedAds: true),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => loaded.complete(ad),
        onAdFailedToLoad: (_) => loaded.complete(null),
      ),
    );
    final ad = await loaded.future.timeout(const Duration(seconds: 20), onTimeout: () => null);
    if (ad == null) return false;
    await ad.setServerSideOptions(ServerSideVerificationOptions(userId: installId, customData: 'deep_check'));
    final done = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        if (!done.isCompleted) done.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        if (!done.isCompleted) done.complete(false);
      },
    );
    await ad.show(onUserEarnedReward: (_, __) => earned = true);
    return done.future;
  }

  static Future<List<PlusProduct>> products() async {
    if (!await InAppPurchase.instance.isAvailable()) return [];
    final res = await InAppPurchase.instance.queryProductDetails(plusProductIds);
    // Google Play returns one entry per subscription offer, so keep one per product id.
    final seen = <String>{};
    final list = res.productDetails.where((p) => seen.add(p.id)).map((p) => PlusProduct(p.id, p.title, p.price)).toList();
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  static Future<void> buy(String productId) async {
    final res = await InAppPurchase.instance.queryProductDetails({productId});
    if (res.productDetails.isEmpty) throw StateError(tr('This plan isn\'t available in the store yet.'));
    // Subscriptions are bought with buyNonConsumable.
    await InAppPurchase.instance.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: res.productDetails.first));
  }

  static Future<void> restore() => InAppPurchase.instance.restorePurchases();

  static void Function(String status, String? message)? _onUpdate;

  /// Shows purchase progress on the Plus screen while it's open.
  static void listen(void Function(String status, String? message) onUpdate) {
    _onUpdate = onUpdate;
    start();
  }

  static void unlisten() => _onUpdate = null;

  /// Started when the app opens, so a purchase that finished while the app was closed is still confirmed.
  /// Each purchase is verified by our server with Google/Apple before it's marked complete; if that fails
  /// (for example offline), the store delivers it again next time.
  static void start() {
    _sub ??= InAppPurchase.instance.purchaseStream.listen((purchases) async {
      for (final p in purchases) {
        if (p.status == PurchaseStatus.pending) {
          _onUpdate?.call('pending', tr('Waiting for the store to confirm your payment…'));
          continue;
        }
        var finish = true;
        if (p.status == PurchaseStatus.error) _onUpdate?.call('error', p.error?.message ?? tr('The purchase didn\'t go through.'));
        if (p.status == PurchaseStatus.canceled) _onUpdate?.call('canceled', null);
        if (p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored) {
          try {
            await Cloud.instance.verifyPlus(
              platform: Platform.isIOS ? 'ios' : 'android',
              productId: p.productID,
              token: Platform.isIOS ? (p.purchaseID ?? '') : p.verificationData.serverVerificationData,
            );
            _onUpdate?.call('active', tr('Second Look Plus is active. Thank you!'));
          } catch (e) {
            finish = false;
            _onUpdate?.call('error', tr('We couldn\'t confirm the purchase yet. It will be checked again automatically. ({error})', {'error': e}));
          }
        }
        if (finish && p.pendingCompletePurchase) await InAppPurchase.instance.completePurchase(p);
      }
    }, onError: (_) {});
  }
}
