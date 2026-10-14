import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'web/bridge.dart';

/// Bridge to the on-device engine and system features (Java on Android, Swift + JavaScriptCore on iOS,
/// and the same JavaScript engine in the browser on a laptop). Nothing in here sends data off the device.
class Native {
  Native._();
  static final Native instance = Native._();

  static const _ch = MethodChannel('secondlook/native');

  /// Called when the system hands us text (Share → Second Look) or the user taps an alert notification.
  void Function(String text)? onShared;
  void Function(String alertId)? onAlertOpened;
  /// Android: a screenshot shared to Second Look (path inside the app's cache).
  void Function(String path)? onSharedImage;
  /// iPhone: fires when screen recording or screen sharing starts or stops.
  void Function(bool captured)? onScreenCaptured;

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    if (kIsWeb) return (await WebBridge.call(method, args)) as T?;
    return _ch.invokeMethod<T>(method, args);
  }

  bool get isWeb => kIsWeb;

  void init() {
    if (kIsWeb) return;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onShared':
          onShared?.call(call.arguments as String);
          break;
        case 'onSharedImage':
          onSharedImage?.call(call.arguments as String);
          break;
        case 'onAlertOpened':
          onAlertOpened?.call(call.arguments as String);
          break;
        case 'onScreenCaptured':
          onScreenCaptured?.call(call.arguments == true);
          break;
      }
      return null;
    });
  }

  Future<Map<String, dynamic>> _json(String method, [Map<String, dynamic>? args]) async {
    final s = await _call<String>(method, args);
    return s == null ? <String, dynamic>{} : (jsonDecode(s) as Map).cast<String, dynamic>();
  }

  Future<List<Map<String, dynamic>>> _list(String method) async {
    final s = await _call<String>(method);
    if (s == null) return [];
    return (jsonDecode(s) as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  // ---- checks (run on the device) ----
  Future<Map<String, dynamic>> analyze(String text) => _json('analyze', {'text': text});
  Future<Map<String, dynamic>> analyzeSms(String sender, String body) => _json('analyzeSms', {'sender': sender, 'body': body});
  Future<Map<String, dynamic>> analyzeNumber(String number) => _json('analyzeNumber', {'number': number});
  Future<Map<String, dynamic>> analyzeUpi(String text) => _json('analyzeUpi', {'text': text});
  Future<Map<String, dynamic>> analyzePayment({required String text, String? expectedAmount, String? myUpi, String? imageEditor}) =>
      _json('analyzePayment', {'text': text, 'expectedAmount': expectedAmount, 'myUpi': myUpi, 'imageEditor': imageEditor});

  /// Reads the words and QR codes in an image, on the device (Android ML Kit / iPhone Vision). Not available on a laptop.
  Future<Map<String, dynamic>> readImage(String path) => _json('readImage', {'path': path});
  Future<String?> consumeSharedImage() => _call<String>('consumeSharedImage');

  /// Small preferences kept on the device: language, voice, community_off, community_sync.
  Future<Map<String, dynamic>> setPref(String key, String value) => _json('setPref', {'key': key, 'value': value});

  /// Reads text aloud with the device's own text-to-speech. Returns false if that language's voice isn't available.
  Future<bool> speak(String text, String lang) async => (await _call<bool>('speak', {'text': text, 'lang': lang})) ?? false;
  Future<void> stopSpeaking() => _call('stopSpeaking');

  /// Saves the downloaded community scam list on the device, for Call Shield to match offline.
  Future<bool> setCommunityList(String json) async => (await _call<bool>('setCommunityList', {'json': json})) ?? false;

  // ---- protection switches ----
  Future<Map<String, dynamic>> status() => _json('status');
  Future<Map<String, dynamic>> setSmsShield(bool on) => _json('setSmsShield', {'on': on});
  Future<Map<String, dynamic>> setCallShield(bool on) => _json('setCallShield', {'on': on});
  Future<Map<String, dynamic>> setAutoSilence(bool on) => _json('setAutoSilence', {'on': on});
  Future<Map<String, dynamic>> setTrusted(String name, String number) => _json('setTrusted', {'name': name, 'number': number});
  /// Marks onboarding done and records which version of the Terms/Privacy Policy the user accepted.
  Future<void> setOnboarded(String termsVersion) => _call('setOnboarded', {'terms': termsVersion});
  Future<void> openSystemSettings(String which) => _call('openSystemSettings', {'which': which});

  // ---- history & personal block list (stored only on this phone) ----
  Future<List<Map<String, dynamic>>> history() => _list('history');
  Future<void> clearHistory() => _call('clearHistory');
  Future<List<Map<String, dynamic>>> reports() => _list('reports');
  Future<void> report(String number, String type, String label, String kind) =>
      _call('report', {'number': number, 'type': type, 'label': label, 'kind': kind});
  Future<void> removeReport(String number) => _call('removeReport', {'number': number});
  Future<void> deleteAllData() => _call('deleteAllData');

  // ---- security ----
  Future<Map<String, dynamic>> securityStatus() => _json('securityStatus');
  Future<Map<String, dynamic>> setScreenProtection(bool on) => _json('setScreenProtection', {'on': on});

  /// Turns the app lock on or off. Returns an error message if it couldn't (for example no screen lock on the phone).
  Future<String?> setAppLock(bool on) async {
    try {
      await _json('setAppLock', {'on': on});
      return null;
    } on PlatformException catch (e) {
      return e.message ?? 'Could not change the app lock';
    }
  }

  Future<bool> authenticate() async => (await _call<bool>('authenticate')) ?? false;

  /// Random id for this install (no personal data). Used only for the deep-check quota and Plus.
  Future<String> installId() async => (await _call<String>('installId')) ?? '';

  // ---- actions ----
  Future<void> openUrl(String url) => _call('openUrl', {'url': url});
  Future<void> dial(String number) => _call('dial', {'number': number});
  Future<void> smsTo(String number, String body) => _call('smsTo', {'number': number, 'body': body});
  Future<String?> consumeSharedText() => _call<String>('consumeSharedText');
  Future<String?> consumeAlertId() => _call<String>('consumeAlertId');
}
