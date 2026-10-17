import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import 'pdf_forensics.dart';

/// PDF content forensics, run off the UI thread (in the browser it runs inline; compressed pages can't be
/// read there, so fonts.checked is false). Never throws.
///
///     Future<Map<String, dynamic>> pdfForensics(Uint8List bytes)
///
/// Returns `{'fonts': {'checked': bool, 'count': int, 'rare': [{'name': String, 'chars': int, 'digitShare': double}]},
///           'whiteBoxes': int}` — pass both as file.fonts / file.whiteBoxes to analyzeDocument.
Future<Map<String, dynamic>> pdfForensics(Uint8List bytes) async {
  try {
    return await compute(PdfForensics.analyze, bytes);
  } catch (_) {
    return PdfForensics.analyze(bytes);
  }
}

/// Reads the details a PDF records about itself: which program made it, when it was created and changed,
/// and how many times it was saved. Pure Dart, so it also works in the browser. Nothing is uploaded.
///
/// Only the first 2 MB and the last 1 MB are searched for these details, which is where PDF writers put them.
class PdfMeta {
  PdfMeta._();

  static const _head = 2 * 1024 * 1024, _tail = 1024 * 1024;

  /// Returns {producer, creator, created, modified, revisions, encrypted}. Dates are UTC ISO-8601
  /// ("2026-10-17T05:30:00Z"); unknown values are null.
  static Map<String, dynamic> parse(Uint8List bytes) {
    final out = <String, dynamic>{
      'producer': null,
      'creator': null,
      'created': null,
      'modified': null,
      'revisions': 1,
      'encrypted': false,
    };
    if (bytes.isEmpty) return out;

    final String s;
    if (bytes.length <= _head + _tail) {
      s = latin1.decode(bytes, allowInvalid: true);
    } else {
      s = '${latin1.decode(Uint8List.sublistView(bytes, 0, _head), allowInvalid: true)}\n'
          '${latin1.decode(Uint8List.sublistView(bytes, bytes.length - _tail), allowInvalid: true)}';
    }

    final encrypted = s.contains('/Encrypt');
    out['encrypted'] = encrypted;

    // Saves: each save (first save or later incremental update) ends with %%EOF. Count over the whole file.
    var eofs = _count(bytes, const [0x25, 0x25, 0x45, 0x4F, 0x46]); // %%EOF
    // Linearized ("fast web view") files have two %%EOF marks from a single save.
    final head = bytes.length > 4096 ? latin1.decode(Uint8List.sublistView(bytes, 0, 4096), allowInvalid: true) : s;
    if (head.contains('/Linearized') && eofs >= 2) eofs -= 1;
    out['revisions'] = eofs < 1 ? 1 : eofs;

    // Info dictionary (strings are encrypted in password-protected files, so skip them there).
    if (!encrypted) {
      out['producer'] = _clean(_info(s, 'Producer'));
      out['creator'] = _clean(_info(s, 'Creator'));
      out['created'] = _pdfDate(_info(s, 'CreationDate'));
      out['modified'] = _pdfDate(_info(s, 'ModDate'));
    }

    // XMP metadata (plain XML inside the file) fills any gaps.
    out['creator'] ??= _clean(_xmp(s, 'xmp:CreatorTool'));
    out['producer'] ??= _clean(_xmp(s, 'pdf:Producer'));
    out['created'] ??= _isoDate(_xmp(s, 'xmp:CreateDate'));
    out['modified'] ??= _isoDate(_xmp(s, 'xmp:ModifyDate'));
    return out;
  }

  static int _count(Uint8List b, List<int> pat) {
    var n = 0;
    final last = b.length - pat.length;
    for (var i = 0; i <= last; i++) {
      if (b[i] != pat[0]) continue;
      var ok = true;
      for (var j = 1; j < pat.length; j++) {
        if (b[i + j] != pat[j]) {
          ok = false;
          break;
        }
      }
      if (ok) {
        n++;
        i += pat.length - 1;
      }
    }
    return n;
  }

  static String? _clean(String? v) {
    if (v == null) return null;
    final t = v.replaceAll(RegExp(r'[\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return null;
    return t.length > 120 ? t.substring(0, 120) : t;
  }

  /// The value of /Key in the most recent Info dictionary: a literal string, a hex string, or an indirect object.
  static String? _info(String s, String key) {
    final re = RegExp('/$key(?![A-Za-z])\\s*');
    String? found;
    for (final m in re.allMatches(s)) {
      final v = _valueAt(s, m.end, 0);
      if (v != null) found = v; // the last one is the latest save
    }
    return found;
  }

  static String? _valueAt(String s, int i, int depth) {
    if (i >= s.length) return null;
    final c = s[i];
    if (c == '(') return _literal(s, i + 1);
    if (c == '<' && (i + 1 >= s.length || s[i + 1] != '<')) return _hex(s, i + 1);
    // Indirect reference: "12 0 R"
    if (depth == 0) {
      // No "^": matchAsPrefix already anchors at i, and "^" would only match at the very start of the string.
      final m = RegExp(r'(\d+)\s+(\d+)\s+R\b').matchAsPrefix(s, i);
      if (m != null) {
        final obj = RegExp('(?:^|[^0-9])${m.group(1)}\\s+${m.group(2)}\\s+obj\\s*');
        String? v;
        for (final o in obj.allMatches(s)) {
          final x = _valueAt(s, o.end, 1);
          if (x != null) v = x;
        }
        return v;
      }
    }
    return null;
  }

  /// A PDF literal string starting just after "(".
  static String? _literal(String s, int i) {
    final b = <int>[];
    var depth = 1;
    while (i < s.length && b.length < 4000) {
      final c = s.codeUnitAt(i);
      if (c == 0x5C) {
        // backslash
        i++;
        if (i >= s.length) break;
        final e = s[i];
        switch (e) {
          case 'n':
            b.add(10);
            break;
          case 'r':
            b.add(13);
            break;
          case 't':
            b.add(9);
            break;
          case 'b':
            b.add(8);
            break;
          case 'f':
            b.add(12);
            break;
          case '(':
          case ')':
          case '\\':
            b.add(e.codeUnitAt(0));
            break;
          case '\r':
            if (i + 1 < s.length && s[i + 1] == '\n') i++;
            break; // line continuation
          case '\n':
            break;
          default:
            if (e.codeUnitAt(0) >= 0x30 && e.codeUnitAt(0) <= 0x37) {
              var v = 0, k = 0;
              while (k < 3 && i < s.length && s.codeUnitAt(i) >= 0x30 && s.codeUnitAt(i) <= 0x37) {
                v = v * 8 + (s.codeUnitAt(i) - 0x30);
                i++;
                k++;
              }
              i--;
              b.add(v & 0xFF);
            } else {
              b.add(e.codeUnitAt(0) & 0xFF);
            }
        }
        i++;
        continue;
      }
      if (c == 0x28) depth++;
      if (c == 0x29) {
        depth--;
        if (depth == 0) return _text(b);
      }
      b.add(c & 0xFF);
      i++;
    }
    return null;
  }

  /// A PDF hex string starting just after "<".
  static String? _hex(String s, int i) {
    final end = s.indexOf('>', i);
    if (end < 0 || end - i > 8000) return null;
    final h = s.substring(i, end).replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9A-Fa-f]*$').hasMatch(h)) return null;
    final p = h.length.isOdd ? '${h}0' : h;
    final b = <int>[for (var k = 0; k < p.length; k += 2) int.parse(p.substring(k, k + 2), radix: 16)];
    return _text(b);
  }

  /// Bytes of a PDF text string: UTF-16BE with a byte-order mark, UTF-8 with a BOM, or PDFDocEncoding (close to Latin-1).
  static String _text(List<int> b) {
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      final u = <int>[];
      for (var k = 2; k + 1 < b.length; k += 2) {
        u.add((b[k] << 8) | b[k + 1]);
      }
      return String.fromCharCodes(u);
    }
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return utf8.decode(b.sublist(3), allowMalformed: true);
    return String.fromCharCodes(b);
  }

  static String? _xmp(String s, String tag) {
    final esc = RegExp.escape(tag);
    final m = RegExp('<$esc>([^<]{1,300})</$esc>').firstMatch(s) ?? RegExp('$esc\\s*=\\s*"([^"]{1,300})"').firstMatch(s);
    if (m == null) return null;
    final raw = utf8.decode(latin1.encode(m.group(1)!), allowMalformed: true);
    return raw.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');
  }

  /// D:YYYYMMDDHHmmSSOHH'mm' → "YYYY-MM-DDTHH:MM:SSZ" (UTC).
  static String? _pdfDate(String? v) {
    if (v == null) return null;
    final m = RegExp(r"^\s*(?:D:)?(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?\s*([Zz+\-])?\s*(\d{2})?'?\s*(\d{2})?'?").firstMatch(v);
    if (m == null) return null;
    int g(int i, int dflt) => m.group(i) == null ? dflt : int.parse(m.group(i)!);
    final y = g(1, 0), mo = g(2, 1), d = g(3, 1), h = g(4, 0), mi = g(5, 0), se = g(6, 0);
    if (y < 1980 || y > 2100 || mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 59) return null;
    var t = DateTime.utc(y, mo, d, h, mi, se);
    final sign = m.group(7);
    if (sign == '+' || sign == '-') {
      final off = Duration(hours: g(8, 0), minutes: g(9, 0));
      t = sign == '+' ? t.subtract(off) : t.add(off);
    }
    return _iso(t);
  }

  /// XMP dates: "2026-10-17T11:00:00+05:30", with or without seconds, fraction or zone.
  static String? _isoDate(String? v) {
    if (v == null) return null;
    var x = v.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(x)) return null;
    // A time without seconds ("T11:00+05:30") isn't accepted by DateTime.parse.
    x = x.replaceFirstMapped(RegExp(r'T(\d{2}):(\d{2})(?=$|[Zz+\-])'), (m) => 'T${m[1]}:${m[2]}:00');
    final hasZone = RegExp(r'(Z|z|[+\-]\d{2}:?\d{2})$').hasMatch(x) && x.contains('T');
    final t = DateTime.tryParse(hasZone ? x : (x.contains('T') ? '${x}Z' : '${x.substring(0, 10)}T00:00:00Z'));
    if (t == null) return null;
    return _iso(t.toUtc());
  }

  static String _iso(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
  }
}
