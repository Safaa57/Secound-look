/// Used on Android and iPhone, where the native bridge handles every call.
class WebBridge {
  static Future<Object?> call(String method, [Map<String, dynamic>? args]) =>
      throw UnsupportedError('WebBridge is only used in the browser');
}
