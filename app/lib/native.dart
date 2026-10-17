import 'dart:convert';
import 'dart:typed_data';

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

  /// A list result that may come back as a JSON string or as a list, depending on the platform.
  static List<Map<String, dynamic>> _asList(Object? v) {
    Object? d = v;
    if (d is String) {
      if (d.isEmpty) return [];
      d = jsonDecode(d);
    }
    if (d is List) return d.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    return [];
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
  /// With [layout], the words are put back into rows as they appear on the page (for documents and statements).
  Future<Map<String, dynamic>> readImage(String path, {bool layout = false}) =>
      _json('readImage', {'path': path, if (layout) 'layout': true});
  Future<String?> consumeSharedImage() => _call<String>('consumeSharedImage');

  // ---- documents (read on the device; never uploaded or kept) ----

  /// Results may come back as a JSON string or as a map, depending on the platform.
  static Map<String, dynamic>? _asMap(Object? v) {
    if (v == null) return null;
    if (v is String) {
      if (v.isEmpty) return null;
      final d = jsonDecode(v);
      return d is Map ? d.cast<String, dynamic>() : null;
    }
    if (v is Map) return v.cast<String, dynamic>();
    return null;
  }

  /// Lets the user choose a PDF or photo. Phones: {path, name, mime, size} (a copy in the app's cache).
  /// Laptop: {name, mime, size, bytes (base64)}. Null if cancelled.
  /// Throws PlatformException with code 'too_large' or 'unsupported'.
  Future<Map<String, dynamic>?> pickDocument() async => _asMap(await _call<Object>('pickDocument'));

  /// Text of a PDF: {text, pages, pagesRead}. Throws PlatformException 'locked', 'unreadable' or 'unsupported' (laptop).
  Future<Map<String, dynamic>> readPdf(String path) async => _asMap(await _call<Object>('readPdf', {'path': path})) ?? <String, dynamic>{};

  /// Checks an RSA/SHA-256 signature over [data] against any of the DER [certs].
  /// Returns null when it couldn't be checked (for example in the browser).
  Future<bool?> verifySignature(Uint8List data, Uint8List signature, List<Uint8List> certs) async {
    try {
      final v = await _call<Object>('verifySignature', {'data': data, 'signature': signature, 'certs': certs});
      return v is bool ? v : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on UnsupportedError {
      return null;
    }
  }

  Future<Map<String, dynamic>> analyzeDocument(Map<String, dynamic> input) async =>
      _asMap(await _call<Object>('analyzeDocument', {'input': jsonEncode(input)})) ?? <String, dynamic>{};

  /// Deletes any document copies the picker left in the app's cache.
  Future<void> clearDocCache() async {
    try {
      await _call('clearDocCache');
    } catch (_) {}
  }

  /// Small preferences kept on the device: language, voice ('on'|'off', missing = off), voice_name, community_off,
  /// community_sync, log_all ('on'|'off', default on), call_popup ('on'|'off', default on).
  Future<Map<String, dynamic>> setPref(String key, String value) => _json('setPref', {'key': key, 'value': value});

  /// Like [setPref], but never throws (for example when an older build doesn't know the key). Null if not saved.
  Future<Map<String, dynamic>?> trySetPref(String key, String value) async {
    try {
      return await setPref(key, value);
    } catch (_) {
      return null;
    }
  }

  /// Reads text aloud with the device's own text-to-speech. Returns false if that language's voice isn't available.
  /// [voice] is an id from [listVoices] (null = the saved voice or the phone's default); [rate] 1.0 = normal speed.
  Future<bool> speak(String text, String lang, {String? voice, double? rate}) async =>
      (await _call<bool>('speak', {
        'text': text,
        'lang': lang,
        if (voice != null && voice.isNotEmpty) 'voice': voice,
        if (rate != null) 'rate': rate,
      })) ??
      false;

  /// Voices for 'en' | 'hi' | 'kn', best first: [{id, label, quality, network}]. Empty if none or unsupported.
  Future<List<Map<String, dynamic>>> listVoices(String lang) async {
    try {
      return _asList(await _call<Object>('listVoices', {'lang': lang}));
    } catch (_) {
      return [];
    }
  }
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

  /// Android: what could stop the shields from working (permissions, notifications, caller-ID role, battery,
  /// "Display over other apps", sideloading restrictions, autostart). iPhone: {platform:'ios'}. Null if unavailable.
  Future<Map<String, dynamic>?> shieldHealth() async {
    try {
      return _asMap(await _call<Object>('shieldHealth'));
    } catch (_) {
      return null;
    }
  }

  /// Opens a system screen: 'app' | 'notifications' | 'overlay' | 'battery' | 'callRole' | 'autostart' | 'sms'.
  /// True if a screen opened.
  Future<bool> openSettings(String target) async {
    try {
      return (await _call<Object>('openSettings', {'target': target})) == true;
    } catch (_) {
      return false;
    }
  }

  /// Runs a built-in sample scam ('sms' | 'call') through the shield pipeline. Returns the new alert's id, or null.
  Future<String?> testAlert(String kind) async {
    try {
      final v = await _call<Object>('testAlert', {'kind': kind});
      return v == null ? null : '$v';
    } catch (_) {
      return null;
    }
  }

  // ---- history & personal block list (stored only on this phone) ----
  Future<List<Map<String, dynamic>>> history() => _list('history');
  Future<void> clearHistory() => _call('clearHistory');
  Future<List<Map<String, dynamic>>> reports() => _list('reports');
  Future<void> report(String number, String type, String label, String kind) =>
      _call('report', {'number': number, 'type': type, 'label': label, 'kind': kind});
  Future<void> removeReport(String number) => _call('removeReport', {'number': number});
  Future<void> deleteAllData() => _call('deleteAllData');

  /// Marks a number or sender: 'block' | 'spam' | 'fraud' | 'safe' | 'comment' | 'unblock' (unblock also removes a mark).
  /// [historyId] links the mark to that alert. Returns true when saved.
  Future<bool> markNumber(String number, String action, {String? comment, String? historyId}) async {
    try {
      final m = _asMap(await _call<Object>('markNumber', {
        'number': number,
        'action': action,
        if (comment != null) 'comment': comment,
        if (historyId != null) 'historyId': historyId,
      }));
      return m?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// What the user marked (newest first): [{number, action, comment, at, historyId}]. Only for [number] when given.
  Future<List<Map<String, dynamic>>> numberActions({String? number}) async {
    try {
      return _asList(await _call<Object>('numberActions', {if (number != null) 'number': number}));
    } catch (_) {
      return [];
    }
  }

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

  /// Whether a chat app is installed. Only 'whatsapp' is supported.
  Future<bool> isAppInstalled(String app) async {
    try {
      return (await _call<Object>('isAppInstalled', {'app': app})) == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens a chat with [number] in WhatsApp (the app itself says if the number isn't on WhatsApp). True if it opened.
  Future<bool> openChat(String number) async {
    try {
      return (await _call<Object>('openChat', {'number': number})) == true;
    } catch (_) {
      return false;
    }
  }
  Future<String?> consumeSharedText() => _call<String>('consumeSharedText');
  Future<String?> consumeAlertId() => _call<String>('consumeAlertId');
}
