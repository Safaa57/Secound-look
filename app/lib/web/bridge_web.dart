import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

import 'package:flutter/services.dart';

// ---- JavaScript the page provides ----
// secondlook_engine.js defines a global `SL` (the same engine the web app, extension and iPhone use).
@JS('SL')
external _Engine? get _engine;

extension type _Engine._(JSObject _) implements JSObject {
  external JSString analyzeAuto(JSString text);
  external JSString analyzeSms(JSString sender, JSString body);
  external JSString analyzeNumber(JSString number, JSString blockedJson);
  external JSString lookupNumber(JSString number);
  external JSString analyzeUpi(JSString text);
  external JSString analyzePayment(JSString inputJson);
}

@JS('localStorage')
external _Storage get _storage;

extension type _Storage._(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
  external void setItem(JSString key, JSString value);
  external void removeItem(JSString key);
}

@JS('open')
external JSAny? _windowOpen(JSString url, JSString target, JSString features);

// Browser text-to-speech (works offline with the computer's own voices).
@JS('speechSynthesis')
external _Synth? get _synth;

extension type _Synth._(JSObject _) implements JSObject {
  external void speak(_Utterance u);
  external void cancel();
  external JSArray<_SpeechVoice> getVoices();
}

extension type _SpeechVoice._(JSObject _) implements JSObject {
  external JSString get lang;
}

@JS('SpeechSynthesisUtterance')
extension type _Utterance._(JSObject _) implements JSObject {
  external factory _Utterance(JSString text);
  external set lang(JSString v);
  external set voice(_SpeechVoice? v);
}

/// Laptop version of the native bridge. Everything stays in this browser (localStorage);
/// nothing is sent anywhere. SMS and Call Shield need a phone, so they're reported as off.
class WebBridge {
  static const _prefix = 'secondlook.';
  static const _maxText = 10000, _maxHistory = 100;
  static final _allowed = RegExp(
      r'^https://(docs\.cloud\.google\.com/web-risk/docs/advisory|www\.antiphishing\.org/?|www\.google\.com/search\?q=[A-Za-z0-9%+._-]{1,200}|cybercrime\.gov\.in/?|sancharsaathi\.gov\.in/?)$');

  static String? _get(String k) {
    try {
      return _storage.getItem('$_prefix$k'.toJS)?.toDart;
    } catch (_) {
      return null; // private window or storage blocked: work without saving
    }
  }

  static void _set(String k, String v) {
    try {
      _storage.setItem('$_prefix$k'.toJS, v.toJS);
    } catch (_) {}
  }

  static void _remove(String k) {
    try {
      _storage.removeItem('$_prefix$k'.toJS);
    } catch (_) {}
  }

  static List<Map<String, dynamic>> _list(String k) {
    try {
      return (jsonDecode(_get(k) ?? '[]') as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  static _Engine get _sl {
    final e = _engine;
    if (e == null) throw PlatformException(code: 'engine', message: 'The checker did not load. Refresh the page.');
    return e;
  }

  static String _cap(Object? s, int max) {
    final t = (s as String?) ?? '';
    return t.length > max ? t.substring(0, max) : t;
  }

  static String _clean(Object? s) => _cap(((s as String?) ?? '').replaceAll(RegExp(r'[^+0-9]'), ''), 20);

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  // Keep flagged results from checks, so Home and Alerts can show them (same as the iPhone app).
  static String _remember(String resultJson, String kind, String title) {
    try {
      final r = (jsonDecode(resultJson) as Map).cast<String, dynamic>();
      final level = (r['level'] as Map?)?['key'];
      if (level == null || level == 'safe') return resultJson;
      final reasons = ((r['reasons'] as List?) ?? []).cast<Map>();
      final first = reasons.where((x) => ((x['weight'] as num?) ?? 0) > 0);
      final h = _list('history');
      h.insert(0, {
        'id': _uuid(),
        'at': DateTime.now().millisecondsSinceEpoch,
        'kind': kind,
        'title': title,
        'summary': first.isEmpty ? '' : first.first['title'],
        'level': level,
        'score': r['score'] ?? 0,
        'result': r,
      });
      _set('history', jsonEncode(h.take(_maxHistory).toList()));
    } catch (_) {}
    return resultJson;
  }

  static String _status() => jsonEncode({
        'platform': 'web',
        'onboarded': _get('onboarded') == '1',
        'termsVersion': _get('terms_version') ?? '',
        'prefs': {
          for (final k in ['language', 'voice', 'community_off', 'community_sync']) k: _get('pref_$k') ?? '',
        },
        'smsShield': false,
        'smsNeedsPermission': false,
        'callShield': false,
        'callNeedsRole': false,
        'autoSilence': false,
        'appLock': false,
        'screenProtection': false,
        'trustedName': _get('trusted_name') ?? '',
        'trustedNumber': _get('trusted_number') ?? '',
      });

  static bool _speak(String text, String lang) {
    final synth = _synth;
    if (synth == null || text.isEmpty) return false;
    try {
      final code = lang == 'hi' || lang == 'kn' ? lang : 'en';
      final voices = synth.getVoices().toDart;
      _SpeechVoice? match;
      for (final v in voices) {
        final l = v.lang.toDart.toLowerCase();
        if (l == '$code-in') {
          match = v;
          break;
        }
        if (match == null && l.startsWith(code)) match = v;
      }
      // Voices load lazily in some browsers; if the list is empty, let the browser choose by language.
      if (match == null && voices.isNotEmpty && code != 'en') return false;
      synth.cancel();
      final u = _Utterance(text.toJS)..lang = '$code-IN'.toJS;
      if (match != null) u.voice = match;
      synth.speak(u);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void _open(String url) => _windowOpen(url.toJS, '_blank'.toJS, 'noopener,noreferrer'.toJS);

  static Future<Object?> call(String method, [Map<String, dynamic>? args]) async {
    final a = args ?? const <String, dynamic>{};
    switch (method) {
      case 'analyze':
        return _remember(_sl.analyzeAuto(_cap(a['text'], _maxText).toJS).toDart, 'check', 'Checked text');
      case 'analyzeSms':
        final sender = _cap(a['sender'], 64);
        return _remember(_sl.analyzeSms(sender.toJS, _cap(a['body'], _maxText).toJS).toDart, 'sms', 'SMS from $sender');
      case 'analyzeNumber':
        final n = _cap(a['number'], 64);
        return _remember(_sl.analyzeNumber(n.toJS, jsonEncode(_list('reports')).toJS).toDart, 'call', 'Number $n');

      case 'analyzeUpi':
        final u = _cap(a['text'], 2048);
        return _remember(_sl.analyzeUpi(u.toJS).toDart, 'upi', 'UPI ID ${_cap(u, 64)}');
      case 'analyzePayment':
        final input = jsonEncode({
          'text': _cap(a['text'], _maxText),
          'expectedAmount': a['expectedAmount'] == null ? null : _cap(a['expectedAmount'], 64),
          'myUpi': a['myUpi'] == null ? null : _cap(a['myUpi'], 64),
          'imageEditor': a['imageEditor'] == null ? null : _cap(a['imageEditor'], 64),
        });
        return _remember(_sl.analyzePayment(input.toJS).toDart, 'payment', 'Payment screenshot');
      case 'readImage':
        throw PlatformException(code: 'unsupported', message: 'Reading screenshots works in the phone app. Type the details instead.');
      case 'consumeSharedImage':
        return null;
      case 'setPref':
        const allowed = {'language', 'voice', 'community_off', 'community_sync'};
        if (!allowed.contains(a['key'])) throw PlatformException(code: 'blocked', message: 'Unknown setting');
        _set('pref_${a['key']}', _cap(a['value'], 40));
        return _status();
      case 'setCommunityList':
        return false; // laptop: no call or SMS shields to use it
      case 'speak':
        return _speak(_cap(a['text'], 800), '${a['lang'] ?? 'en'}');
      case 'stopSpeaking':
        try {
          _synth?.cancel();
        } catch (_) {}
        return null;

      case 'status':
      case 'setSmsShield':
      case 'setCallShield':
      case 'setAutoSilence':
      case 'setScreenProtection':
        return _status();
      case 'setTrusted':
        _set('trusted_name', _cap(a['name'], 60));
        _set('trusted_number', _clean(a['number']));
        return _status();
      case 'setOnboarded':
        _set('onboarded', '1');
        _set('terms_version', _cap(a['terms'], 20));
        return null;
      case 'setAppLock':
        if (a['on'] == true) {
          throw PlatformException(code: 'unsupported', message: 'App lock is available in the phone app.');
        }
        return _status();
      case 'authenticate':
        return true;
      case 'openSystemSettings':
        return null;

      case 'history':
        return jsonEncode(_list('history'));
      case 'clearHistory':
        _remove('history');
        return null;
      case 'reports':
        return jsonEncode(_list('reports'));
      case 'report':
        String e164 = _clean(a['number']);
        try {
          final d = jsonDecode(_sl.lookupNumber(_cap(a['number'], 64).toJS).toDart);
          if (d is Map && d['e164'] is String) e164 = d['e164'] as String;
        } catch (_) {}
        if (e164.isEmpty) return null;
        final kind = a['kind'] == 'safe' ? 'safe' : a['kind'] == 'spam' ? 'spam' : 'scam';
        final reps = _list('reports')..removeWhere((r) => r['number'] == e164);
        reps.insert(0, {
          'number': e164,
          'type': _cap(a['type'], 40),
          'label': _cap(a['label'], 80),
          'kind': kind,
          'at': DateTime.now().millisecondsSinceEpoch,
        });
        _set('reports', jsonEncode(reps.take(500).toList()));
        return null;
      case 'removeReport':
        _set('reports', jsonEncode(_list('reports')..removeWhere((r) => r['number'] == a['number'])));
        return null;
      case 'deleteAllData':
        for (final k in ['history', 'reports', 'trusted_name', 'trusted_number', 'install_id']) {
          _remove(k);
        }
        return null;

      case 'securityStatus':
        return jsonEncode({
          'platform': 'web',
          'checks': [
            {'id': 'local', 'ok': true, 'title': 'Checks run in this browser', 'detail': 'Messages, links and numbers you check are never uploaded.'},
            {'id': 'phone', 'ok': false, 'title': 'Shields need the phone app', 'detail': 'SMS Shield, Call Shield and app lock work in the Android and iPhone app.'},
          ],
        });
      case 'installId':
        var id = _get('install_id') ?? '';
        if (id.isEmpty) {
          id = _uuid();
          _set('install_id', id);
        }
        return id;

      case 'openUrl':
        final url = _cap(a['url'], 600);
        if (!_allowed.hasMatch(url)) throw PlatformException(code: 'blocked', message: 'Link not allowed');
        _open(url);
        return null;
      case 'dial':
        _open('tel:${_clean(a['number'])}');
        return null;
      case 'smsTo':
        _open('sms:${_clean(a['number'])}?body=${Uri.encodeComponent(_cap(a['body'], 500))}');
        return null;
      case 'consumeSharedText':
      case 'consumeAlertId':
        return null;
    }
    throw PlatformException(code: 'unimplemented', message: method);
  }
}
