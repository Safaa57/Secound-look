import 'package:flutter/widgets.dart';

import 'ad_rules.dart';
export 'ad_rules.dart';

/// Laptop / web: no ads at all, and Second Look is simply free. Same API as the phone version, doing nothing.
class Monetize {
  static bool get adsSupported => false;
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);
  static Future<bool> init() async => false;
  static Future<bool?> privacyOptionsRequired() async => false;
  static Future<bool> showPrivacyOptions() async => false;
  static void preloadInterstitial() {}
  static Future<bool> showRewardedAd(String installId) async => false;
  static Future<bool> showSupportAd() async => false;
}

class AdBanner extends StatelessWidget {
  const AdBanner({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class NativeAdCard extends StatelessWidget {
  const NativeAdCard({super.key, this.medium = false, this.margin = EdgeInsets.zero, this.onResult});
  final bool medium;
  final EdgeInsets margin;
  final ValueChanged<bool>? onResult;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
