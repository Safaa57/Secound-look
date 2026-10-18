import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../native.dart';
import 'gunzip_stub.dart' if (dart.library.io) 'gunzip_io.dart';

/// Reads the QR code printed on an Aadhaar card or e-Aadhaar, on the device.
///
/// - Old cards: an unsigned XML QR (easy to fake).
/// - Secure QR: a long number that holds compressed details plus UIDAI's digital signature.
///
/// Aadhaar details are only kept in memory while the check runs. They are never logged, saved or uploaded.
class AadhaarQr {
  AadhaarQr._();

  static const certAsset = 'assets/certs/uidai_secure_qr.pem';
  static const _sigLen = 256;

  /// Decodes [qr]. Returns null if it isn't an Aadhaar QR, or {decoded: false} if it looks like a secure QR
  /// that couldn't be opened here (for example in the browser).
  static Map<String, dynamic>? decode(String qr) {
    final t = qr.trim();
    if (t.startsWith('<?xml') || t.contains('PrintLetterBarcodeData')) return _oldXml(t);
    if (t.length >= 200 && RegExp(r'^\d+$').hasMatch(t)) return _secure(t);
    return null;
  }

  /// Decodes [qr] and, for a secure QR, checks its signature against UIDAI's certificates.
  /// The result holds only what the document check needs; the raw signed bytes are dropped.
  static Future<Map<String, dynamic>?> read(String qr) async {
    final d = decode(qr);
    if (d == null) return null;
    final out = <String, dynamic>{
      'decoded': d['decoded'] == true,
      'oldXml': d['oldXml'] == true,
      'signatureChecked': false,
      'signatureValid': null,
      'name': d['name'],
      'dob': d['dob'],
      'gender': d['gender'],
      'last4': d['last4'],
    };
    final data = d['signedData'], sig = d['signature'];
    if (d['decoded'] == true && d['oldXml'] != true && data is Uint8List && sig is Uint8List) {
      final certs = await _certs();
      if (certs.isNotEmpty) {
        final ok = await Native.instance.verifySignature(data, sig, certs);
        if (ok != null) {
          out['signatureChecked'] = true;
          out['signatureValid'] = ok;
        }
      }
    }
    return out;
  }

  // ---- old XML QR: <PrintLetterBarcodeData uid="..." name="..." gender="M" yob="1990" .../>
  static Map<String, dynamic> _oldXml(String x) {
    String? attr(String a) {
      final m = RegExp('(?:^|[\\s<])$a\\s*=\\s*["\']([^"\']*)["\']').firstMatch(x);
      final v = m?.group(1)?.trim();
      if (v == null || v.isEmpty) return null;
      return v.replaceAll('&apos;', "'").replaceAll('&quot;', '"').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');
    }

    final uid = (attr('uid') ?? '').replaceAll(RegExp(r'\D'), '');
    return {
      'decoded': true,
      'oldXml': true,
      'name': attr('name'),
      'dob': attr('dob') ?? attr('yob'),
      'gender': _gender(attr('gender')),
      'last4': uid.length >= 4 ? uid.substring(uid.length - 4) : null,
    };
  }

  // ---- secure QR: decimal number → bytes → GZIP → fields separated by 255, then a 256-byte signature
  static Map<String, dynamic> _secure(String digits) {
    const fail = <String, dynamic>{'decoded': false, 'oldXml': false};
    Uint8List? raw;
    try {
      raw = _bigIntBytes(BigInt.parse(digits));
    } catch (_) {
      raw = null;
    }
    if (raw == null) return fail;
    final unz = gunzip(raw);
    if (unz == null || unz.length <= _sigLen + 10) return fail;
    final all = Uint8List.fromList(unz);
    final signed = Uint8List.sublistView(all, 0, all.length - _sigLen);
    final signature = Uint8List.fromList(all.sublist(all.length - _sigLen));

    // Text fields, up to the first binary one (the photo).
    final fields = <String>[];
    var start = 0;
    for (var i = 0; i <= signed.length && fields.length < 20; i++) {
      if (i == signed.length || signed[i] == 0xFF) {
        final part = Uint8List.sublistView(signed, start, i);
        if (_looksBinary(part)) break;
        fields.add(utf8.decode(part, allowMalformed: true).trim());
        start = i + 1;
      }
    }
    var f = fields;
    if (f.isNotEmpty && RegExp(r'^V\d{1,2}$').hasMatch(f.first)) f = f.sublist(1);
    if (f.length < 5) return fail;
    // [0] email/mobile indicator, [1] reference id, [2] name, [3] date of birth, [4] gender
    final ref = f[1];
    final last4 = ref.length >= 4 && RegExp(r'^\d{4}').hasMatch(ref) ? ref.substring(0, 4) : null;
    return {
      'decoded': true,
      'oldXml': false,
      'name': f[2].isEmpty ? null : f[2],
      'dob': f[3].isEmpty ? null : f[3],
      'gender': _gender(f[4]),
      'last4': last4,
      'signedData': Uint8List.fromList(signed),
      'signature': signature,
    };
  }

  static String? _gender(String? g) {
    final v = (g ?? '').trim().toUpperCase();
    if (v.isEmpty) return null;
    if (v.startsWith('M')) return 'M';
    if (v.startsWith('F')) return 'F';
    if (v.startsWith('T')) return 'T';
    return null;
  }

  /// True if the bytes don't look like text (control characters or invalid UTF-8): the photo has started.
  static bool _looksBinary(List<int> b) {
    if (b.isEmpty) return false;
    var bad = 0;
    for (final c in b) {
      if (c < 0x09 || (c > 0x0D && c < 0x20)) bad++;
    }
    if (bad > 0) return true;
    try {
      utf8.decode(b);
      return false;
    } on FormatException {
      return true;
    }
  }

  static Uint8List _bigIntBytes(BigInt n) {
    var h = n.toRadixString(16);
    if (h.length.isOdd) h = '0$h';
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static List<Uint8List>? _cached;

  /// UIDAI certificates (DER) from the PEM asset. Empty if none were added.
  static Future<List<Uint8List>> _certs() async {
    final c = _cached;
    if (c != null) return c;
    final out = <Uint8List>[];
    try {
      final pem = await rootBundle.loadString(certAsset);
      final re = RegExp(r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----');
      for (final m in re.allMatches(pem)) {
        final b64 = m.group(1)!.replaceAll(RegExp(r'\s'), '');
        // Skip anything that isn't a real certificate body (for example the BEGIN/END words in the file's
        // instructions): a garbage "certificate" would make every QR look forged instead of "not checked".
        if (b64.length < 200 || !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(b64)) continue;
        try {
          out.add(base64.decode(b64));
        } on FormatException {
          // skip a damaged block
        }
      }
    } catch (_) {
      // no asset: signature can't be checked
    }
    _cached = out;
    return out;
  }
}
