// Ads exist only on Android and iPhone. The laptop (web) version gets a stub, so the ads library is never included
// in the web build; there Second Look is simply free with no ads.
export 'monetize_stub.dart' if (dart.library.io) 'monetize_mobile.dart';
