import 'types.dart';
export 'types.dart';

/// Laptop / web: no ads and no store billing. Plus is linked from a phone with a code.
class Monetize {
  static Future<void> init() async {}
  static bool get adsSupported => false;
  static bool get storeSupported => false;
  static Future<bool> showRewardedAd(String installId) async => false;
  static Future<List<PlusProduct>> products() async => [];
  static Future<void> buy(String productId) async {}
  static Future<void> restore() async {}
  static void listen(void Function(String status, String? message) onUpdate) {}
  static void unlisten() {}
  static void start() {}
}
