// On a laptop (Flutter web) the app talks to the JavaScript engine in the page instead of native code.
export 'bridge_stub.dart' if (dart.library.js_interop) 'bridge_web.dart';
