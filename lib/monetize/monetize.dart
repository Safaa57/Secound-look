// Ads and in-app purchases exist only on Android and iPhone. The laptop (web) version gets a stub,
// so the ad and billing libraries are never included in the web build.
export 'monetize_stub.dart' if (dart.library.io) 'monetize_mobile.dart';
