import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

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
  external JSString analyzeDocument(JSString inputJson);
}

// ---- "Check a document": a hidden <input type=file>, read in this browser only ----
@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _FileInput createElement(JSString tag);
  external _Body? get body;
}

extension type _Body._(JSObject _) implements JSObject {
  external void appendChild(JSObject child);
}

extension type _FileInput._(JSObject _) implements JSObject {
  external set type(JSString v);
  external set accept(JSString v);
  external _FileList? get files;
  external void setAttribute(JSString name, JSString value);
  external void click();
  external void remove();
  external void addEventListener(JSString type, JSFunction listener);
  external void removeEventListener(JSString type, JSFunction listener);
}

extension type _FileList._(JSObject _) implements JSObject {
  external JSNumber get length;
  external _File? item(JSNumber index);
}

extension type _File._(JSObject _) implements JSObject {
  external JSString get name;
  external JSString get type;
  external JSNumber get size;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

// window.addEventListener / removeEventListener (for "the file dialog closed without a file").
@JS('addEventListener')
external void _windowAddEventListener(JSString type, JSFunction listener);
@JS('removeEventListener')
external void _windowRemoveEventListener(JSString type, JSFunction listener);

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
  external JSString get name;
  external JSString get voiceURI;
  external JSBoolean get localService;
}

@JS('SpeechSynthesisUtterance')
extension type _Utterance._(JSObject _) implements JSObject {
  external factory _Utterance(JSString text);
  external set lang(JSString v);
  external set voice(_SpeechVoice? v);
  external set rate(JSNumber v);
}

/// Laptop version of the native bridge. Everything stays in this browser (localStorage);
/// nothing is sent anywhere. SMS and Call Shield need a phone, so they're reported as off.
class WebBridge {
  static const _prefix = 'secondlook.';
  static const _maxText = 10000, _maxHistory = 300, _maxActions = 500;
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
  static String _remember(String resultJson, String kind, String title, [Map<String, Object?> extra = const {}]) {
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
        ...extra,
      });
      _set('history', jsonEncode(h.take(_maxHistory).toList()));
    } catch (_) {}
    return resultJson;
  }

  /// The sender fields of a history entry: phone numbers vs. SMS headers such as "VK-HDFCBK".
  static Map<String, Object?> _senderFields(String sender) => {
        'number': sender,
        'senderType': !sender.contains(RegExp(r'[A-Za-z]')) && sender.replaceAll(RegExp(r'[^0-9]'), '').length >= 3 ? 'number' : 'header',
      };

  static String _status() => jsonEncode({
        'platform': 'web',
        'onboarded': _get('onboarded') == '1',
        'termsVersion': _get('terms_version') ?? '',
        'prefs': {
          // 'voice' missing / '' means off: the read-out plays only when the user taps Listen.
          for (final k in _prefKeys) k: _get('pref_$k') ?? '',
        },
        'overlayAllowed': false,
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

  static const _prefKeys = ['language', 'voice', 'voice_name', 'log_all', 'call_popup', 'voice_rate', 'community_off', 'community_sync'];

  static String _langCode(Object? lang) => lang == 'hi' || lang == 'kn' ? lang as String : 'en';

  static String _voiceLang(_SpeechVoice v) => v.lang.toDart.toLowerCase().replaceAll('_', '-');

  /// This browser's voices for the language, best first: voices on this computer before online ones, then
  /// higher-quality ones (judged from the voice's name, used only for sorting), then Indian ones. At most 6.
  static Future<List<_SpeechVoice>> _voices(String code) async {
    final synth = _synth;
    if (synth == null) return [];
    try {
      var all = synth.getVoices().toDart;
      // Voices load lazily in some browsers: wait up to about a second for the list.
      for (var i = 0; all.isEmpty && i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        all = synth.getVoices().toDart;
      }
      final seen = <String>{};
      final list = all.where((v) {
        final l = _voiceLang(v);
        return (l == code || l.startsWith('$code-')) && seen.add(v.voiceURI.toDart);
      }).toList();
      int local(_SpeechVoice v) => v.localService.toDart ? 1 : 0;
      int india(_SpeechVoice v) => _voiceLang(v).endsWith('-in') ? 1 : 0;
      list.sort((a, b) {
        if (local(a) != local(b)) return local(b) - local(a);
        if (_quality(a) != _quality(b)) return _quality(b) - _quality(a);
        if (india(a) != india(b)) return india(b) - india(a);
        return a.voiceURI.toDart.compareTo(b.voiceURI.toDart);
      });
      return list.take(6).toList();
    } catch (_) {
      return [];
    }
  }

  /// 1 default, 2 enhanced, 3 premium (natural / neural voices).
  static int _quality(_SpeechVoice v) {
    final n = v.name.toDart.toLowerCase();
    if (n.contains('natural') || n.contains('neural') || n.contains('premium')) return 3;
    if (n.contains('enhanced') || n.contains('google')) return 2;
    return 1;
  }

  static Future<String> _listVoices(Object? lang) async {
    final vs = await _voices(_langCode(lang));
    return jsonEncode([
      for (var i = 0; i < vs.length; i++)
        {'id': vs[i].voiceURI.toDart, 'label': 'Voice ${i + 1}', 'quality': _quality(vs[i]), 'network': !vs[i].localService.toDart},
    ]);
  }

  static bool _speak(String text, String lang, {String? voiceId, double rate = 0.92}) {
    final synth = _synth;
    if (synth == null || text.isEmpty) return false;
    try {
      final code = _langCode(lang);
      final voices = synth.getVoices().toDart;
      _SpeechVoice? match;
      // The voice the user picked (passed in, or saved in Settings), if this browser still has it for this language.
      final wanted = (voiceId == null || voiceId.isEmpty) ? (_get('pref_voice_name') ?? '') : voiceId;
      if (wanted.isNotEmpty) {
        for (final v in voices) {
          final l = _voiceLang(v);
          if (v.voiceURI.toDart == wanted && (l == code || l.startsWith('$code-'))) {
            match = v;
            break;
          }
        }
      }
      for (final v in match == null ? voices : const <_SpeechVoice>[]) {
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
      final u = _Utterance(text.toJS)
        ..lang = '$code-IN'.toJS
        ..rate = rate.clamp(0.5, 1.5).toDouble().toJS; // slightly slower than normal by default
      if (match != null) u.voice = match;
      synth.speak(u);
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _maxDocBytes = 25 * 1024 * 1024, _maxDocText = 50000, _maxDocInput = 1000000;

  /// Opens the browser's file dialog (PDF or image) and returns {"name","mime","size","bytes": base64} as JSON,
  /// or null if the user closed the dialog. The file is read in this browser only and never uploaded or saved.
  /// Must be called straight from a tap (browsers only open file dialogs during a user gesture).
  static Future<String?> _pickDocument() async {
    final input = _document.createElement('input'.toJS)
      ..type = 'file'.toJS
      ..accept = 'application/pdf,image/*'.toJS;
    input.setAttribute('style'.toJS, 'display:none'.toJS);
    final picked = Completer<_File?>();
    Timer? focusTimer;
    void settle(_File? f) {
      if (!picked.isCompleted) picked.complete(f);
    }

    _File? first() {
      final files = input.files;
      if (files == null || files.length.toDartInt == 0) return null;
      return files.item(0.toJS);
    }

    final onChange = ((JSAny? _) => settle(first())).toJS;
    final onCancel = ((JSAny? _) => settle(null)).toJS; // modern browsers fire "cancel" when the dialog is closed
    // Fallback for browsers without "cancel": the page gets focus back when the dialog closes. "change" can arrive
    // a little after that, so wait before treating it as a cancel.
    final onFocus = ((JSAny? _) {
      focusTimer?.cancel();
      focusTimer = Timer(const Duration(milliseconds: 1000), () => settle(first()));
    }).toJS;
    input.addEventListener('change'.toJS, onChange);
    input.addEventListener('cancel'.toJS, onCancel);
    _document.body?.appendChild(input);
    try {
      input.click();
      // Register after click() so the focus change caused by opening the dialog itself doesn't count.
      _windowAddEventListener('focus'.toJS, onFocus);
      final file = await picked.future;
      if (file == null) return null;
      var mime = file.type.toDart.toLowerCase();
      if (mime.isEmpty && file.name.toDart.toLowerCase().endsWith('.pdf')) mime = 'application/pdf';
      if (mime != 'application/pdf' && !mime.startsWith('image/')) {
        throw PlatformException(code: 'unsupported', message: 'Choose a PDF or a photo of the document.');
      }
      final size = file.size.toDartDouble;
      if (size > _maxDocBytes) {
        throw PlatformException(code: 'too_large', message: 'This file is bigger than 25 MB. Choose a smaller file or a photo of the page.');
      }
      final Uint8List bytes = await file.arrayBuffer().toDart.then((b) => b.toDart.asUint8List(), onError: (Object _) => Uint8List(0));
      if (bytes.isEmpty) throw PlatformException(code: 'unreadable', message: "Couldn't open this file. It may be damaged.");
      if (bytes.length > _maxDocBytes) {
        throw PlatformException(code: 'too_large', message: 'This file is bigger than 25 MB. Choose a smaller file or a photo of the page.');
      }
      var name = file.name.toDart.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\\u200e\u200f\u202a-\u202e\u2066-\u2069]'), '').trim();
      if (name.length > 120) name = name.substring(0, 120);
      return jsonEncode({'name': name.isEmpty ? 'document' : name, 'mime': mime, 'size': bytes.length, 'bytes': base64Encode(bytes)});
    } finally {
      focusTimer?.cancel();
      _windowRemoveEventListener('focus'.toJS, onFocus);
      input.removeEventListener('change'.toJS, onChange);
      input.removeEventListener('cancel'.toJS, onCancel);
      input.remove();
    }
  }

  /// Caps the text inside the Dart side's JSON before it reaches the engine.
  static String _docInput(Object? raw) {
    final s = (raw as String?) ?? '';
    if (s.length > _maxDocInput) throw PlatformException(code: 'engine', message: 'Check failed');
    Object? o;
    try {
      o = jsonDecode(s);
    } catch (_) {
      o = null;
    }
    if (o is! Map) throw PlatformException(code: 'engine', message: 'Check failed');
    final m = o.cast<String, dynamic>();
    final t = m['text'];
    m['text'] = t is String ? _cap(t, _maxDocText) : '';
    return jsonEncode(m);
  }

  /// E.164 for phone numbers (via the engine); otherwise the digits, or a cleaned SMS header.
  static String _normalize(String raw) {
    try {
      final d = jsonDecode(_sl.lookupNumber(raw.toJS).toDart);
      if (d is Map && d['e164'] is String && (d['e164'] as String).isNotEmpty) return d['e164'] as String;
    } catch (_) {}
    final digits = _clean(raw);
    if (digits.replaceAll('+', '').length >= 3) return digits;
    final h = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9-]'), '');
    return h.length > 20 ? h.substring(0, 20) : h;
  }

  /// A user's comment: links and control characters removed, at most 200 characters.
  static String _cleanComment(Object? s) {
    var t = _cap(s, 1000);
    t = t.replaceAll(RegExp(r'\b(?:https?://|www\.)\S*', caseSensitive: false), '');
    t = t.replaceAll(
        RegExp(
            r'\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|in|net|org|info|top|xyz|io|co|me|ly|link|site|online|app|live|club|shop|biz|cc|tk|ml|ga|cf|gq|buzz|icu|vip|work)\b(?:/\S*)?',
            caseSensitive: false),
        '');
    t = t.replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), '');
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t.length > 200 ? t.substring(0, 200) : t;
  }

  /// Block / Spam / Fraud / Safe / Comment / Unblock, kept in this browser like "report".
  static String _markNumber(Map<String, dynamic> a) {
    final action = a['action'];
    const actions = {'block', 'spam', 'fraud', 'safe', 'comment', 'unblock'};
    if (action is! String || !actions.contains(action)) throw PlatformException(code: 'blocked', message: 'Unknown action');
    final comment = _cleanComment(a['comment']);
    final historyId = _cap(a['historyId'], 64);
    if (action == 'comment' && comment.isEmpty) return jsonEncode({'ok': false});
    final raw = _cap(a['number'], 64);
    final number = _normalize(raw);
    if (number.isEmpty) return jsonEncode({'ok': false});
    final now = DateTime.now().millisecondsSinceEpoch;
    const marks = {
      'block': ['blocked', 'Blocked', 'scam'],
      'spam': ['spam', 'Spam', 'spam'],
      'fraud': ['fraud', 'Fraud', 'scam'],
      'safe': ['safe', 'Safe', 'safe'],
    };
    final reps = _list('reports');
    final m = marks[action];
    if (m != null) {
      reps.removeWhere((r) => r['number'] == number);
      reps.insert(0, {
        'number': number,
        'type': m[0],
        'label': m[1],
        'kind': m[2],
        'at': now,
        if (action == 'block') 'blocked': true,
      });
      _set('reports', jsonEncode(reps.take(500).toList()));
    } else if (action == 'unblock') {
      reps.removeWhere((r) => r['number'] == number || r['number'] == raw);
      _set('reports', jsonEncode(reps));
    }
    final log = _list('number_actions');
    log.insert(0, {'number': number, 'action': action, 'comment': comment, 'at': now, 'historyId': historyId.isEmpty ? null : historyId});
    _set('number_actions', jsonEncode(log.take(_maxActions).toList()));
    if (historyId.isNotEmpty) {
      final h = _list('history');
      final i = h.indexWhere((e) => e['id'] == historyId);
      if (i >= 0) {
        h[i]['userAction'] = {'action': action, 'comment': comment, 'at': now};
        _set('history', jsonEncode(h));
      }
    }
    return jsonEncode({'ok': true});
  }

  static void _open(String url) => _windowOpen(url.toJS, '_blank'.toJS, 'noopener,noreferrer'.toJS);

  static Future<Object?> call(String method, [Map<String, dynamic>? args]) async {
    final a = args ?? const <String, dynamic>{};
    switch (method) {
      case 'analyze':
        return _remember(_sl.analyzeAuto(_cap(a['text'], _maxText).toJS).toDart, 'check', 'Checked text');
      case 'analyzeSms':
        final sender = _cap(a['sender'], 64);
        return _remember(_sl.analyzeSms(sender.toJS, _cap(a['body'], _maxText).toJS).toDart, 'sms', 'SMS from $sender', _senderFields(sender));
      case 'analyzeNumber':
        final n = _cap(a['number'], 64);
        return _remember(_sl.analyzeNumber(n.toJS, jsonEncode(_list('reports')).toJS).toDart, 'call', 'Number $n', _senderFields(n));

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

      // "Check a document": read in this browser, never uploaded, never saved to history.
      case 'pickDocument':
        return _pickDocument();
      case 'readPdf':
        throw PlatformException(code: 'unsupported', message: 'Reading PDF text works in the phone app. Paste the text instead.');
      case 'verifySignature':
        return null; // not checked in the browser (QR codes are read only in the phone app)
      case 'analyzeDocument':
        return _sl.analyzeDocument(_docInput(a['input']).toJS).toDart; // deliberately not _remember()ed
      case 'clearDocCache':
        return null; // nothing is kept in the browser
      case 'setPref':
        if (!_prefKeys.contains(a['key'])) throw PlatformException(code: 'blocked', message: 'Unknown setting');
        _set('pref_${a['key']}', _cap(a['value'], a['key'] == 'voice_name' ? 300 : 40));
        return _status();
      case 'setCommunityList':
        return false; // laptop: no call or SMS shields to use it
      case 'speak':
        return _speak(_cap(a['text'], 800), '${a['lang'] ?? 'en'}',
            voiceId: a['voice'] is String ? _cap(a['voice'], 300) : null, rate: a['rate'] is num ? (a['rate'] as num).toDouble() : 0.92);
      case 'listVoices':
        return _listVoices(a['lang']);
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
        for (final k in ['history', 'reports', 'number_actions', 'trusted_name', 'trusted_number', 'install_id']) {
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

      // ---- v1.3: shields need the phone app; marking numbers is kept in this browser ----
      case 'shieldHealth':
        return null;
      case 'openSettings':
        return false;
      case 'testAlert':
        return null;
      case 'markNumber':
        return _markNumber(a);
      case 'numberActions':
        final all = _list('number_actions'); // newest first
        final raw = _cap(a['number'], 64);
        if (raw.isEmpty) return jsonEncode(all);
        final n = _normalize(raw);
        return jsonEncode(all.where((e) => e['number'] == n || e['number'] == raw).toList());
      case 'isAppInstalled':
        return false; // a browser can't tell
      case 'openChat':
        // The only place that may open wa.me. Needs the full number with country code.
        final n = _normalize(_cap(a['number'], 64));
        final digits = n.replaceAll(RegExp(r'[^0-9]'), '');
        if (!n.startsWith('+') || digits.length < 8 || digits.length > 15) return false;
        _open('https://wa.me/$digits');
        return true;
    }
    throw PlatformException(code: 'unimplemented', message: method);
  }
}
