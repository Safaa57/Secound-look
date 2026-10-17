import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'inflate_stub.dart' if (dart.library.io) 'inflate_io.dart';

/// PDF content forensics: looks inside the page drawing instructions for two common signs of editing.
///
/// * A font used for only a few characters that are mostly digits (an amount or date typed in after the
///   document was made) → `fonts.rare`.
/// * White rectangles painted over text that was already drawn (hiding the original numbers) → `whiteBoxes`.
///
/// Pure Dart apart from zlib (dart:io on phones; in the browser compressed pages can't be read, so
/// `fonts.checked` is false there). Work is capped: at most [maxStreams] streams, [maxOut] bytes each.
/// The web page (web/template.html) has the same logic in JavaScript; keep them in step.
class PdfForensics {
  PdfForensics._();

  static const maxStreams = 40, maxOut = 2 * 1024 * 1024, _maxObj = 4000, _tokenCap = 3000000;

  /// Returns `{'fonts': {'checked': bool, 'count': int, 'rare': [{'name': String, 'chars': int, 'digitShare': double}]},
  /// 'whiteBoxes': int}`. Never throws.
  static Map<String, dynamic> analyze(Uint8List bytes) {
    final out = <String, dynamic>{
      'fonts': <String, dynamic>{'checked': false, 'count': 0, 'rare': <Map<String, dynamic>>[]},
      'whiteBoxes': 0,
    };
    try {
      _run(bytes, out);
    } catch (_) {
      // damaged file: report what was found so far
    }
    return out;
  }

  static final _objRe = RegExp(r'(\d+)\s+\d+\s+obj\b');
  static final _lengthRe = RegExp(r'/Length\s+(\d+)(?!\s+\d+\s+R)');
  static final _endstreamAhead = RegExp(r'^\s*endstream');
  static final _skipDict = RegExp(r'/Subtype\s*/(Image|XML|Type1C|CIDFontType0C|OpenType)|/FontFile|/Length[123]\b|/Type\s*/(XRef|Metadata|EmbeddedFile)|/Predictor');
  static final _filterRe = RegExp(r'/Filter\s*(\[[^\]]*\]|/[A-Za-z0-9]+)');
  static final _nameRe = RegExp(r'/[A-Za-z0-9]+');
  static final _subset = RegExp(r'^[A-Z]{6}\+');

  static void _run(Uint8List bytes, Map<String, dynamic> out) {
    final s = latin1.decode(bytes, allowInvalid: true);
    if (RegExp(r'/Encrypt\b').hasMatch(s)) return;
    final objText = <int, String>{};
    final cmaps = <int, _CMap>{};
    final contents = <String>[];
    final objStms = <List<String>>[];
    var decoded = 0;
    var pos = 0;
    while (true) {
      final it = _objRe.allMatches(s, pos).iterator;
      if (!it.moveNext()) break;
      final mm = it.current;
      final num = int.parse(mm.group(1)!), start = mm.end;
      pos = start;
      final endobj = s.indexOf('endobj', start), stm = s.indexOf('stream', start);
      if (stm < 0 || (endobj >= 0 && endobj < stm)) {
        if (endobj > 0) objText[num] = s.substring(start, math.min(endobj, start + _maxObj));
        continue;
      }
      final dict = s.substring(start, stm);
      var ds = stm + 6;
      if (ds < s.length && s[ds] == '\r') ds++;
      if (ds < s.length && s[ds] == '\n') ds++;
      final lm = _lengthRe.firstMatch(dict);
      var de = -1;
      if (lm != null) {
        final l = int.parse(lm.group(1)!);
        if (ds + l <= s.length && _endstreamAhead.hasMatch(s.substring(ds + l, math.min(s.length, ds + l + 20)))) de = ds + l;
      }
      if (de < 0) de = s.indexOf('endstream', ds);
      if (de < 0) break;
      pos = de + 9;
      objText[num] = dict.length > _maxObj ? dict.substring(0, _maxObj) : dict;
      if (decoded >= maxStreams) continue;
      if (_skipDict.hasMatch(dict)) continue;
      final fl = _filterRe.firstMatch(dict);
      final filters = fl == null ? const <String>[] : _nameRe.allMatches(fl.group(1)!).map((x) => x.group(0)!).toList();
      if (filters.any((f) => f != '/FlateDecode' && f != '/Fl' && f != '/ASCII85Decode' && f != '/A85')) continue;
      Uint8List? data = Uint8List.sublistView(bytes, ds, de);
      for (final f in filters) {
        if (data == null) break;
        data = (f == '/ASCII85Decode' || f == '/A85') ? _a85(data) : inflate(data, maxOut);
      }
      if (data == null) continue;
      decoded++;
      if (data.length > maxOut) data = Uint8List.sublistView(data, 0, maxOut);
      final text = latin1.decode(data, allowInvalid: true);
      if (RegExp(r'/Type\s*/ObjStm').hasMatch(dict)) {
        objStms.add([dict, text]);
      } else if (text.contains('begincmap')) {
        cmaps[num] = _CMap.parse(text);
      } else {
        contents.add(text);
      }
    }
    for (final o in objStms) {
      final first = RegExp(r'/First\s+(\d+)').firstMatch(o[0]), cnt = RegExp(r'/N\s+(\d+)').firstMatch(o[0]);
      if (first == null || cnt == null) continue;
      final f = int.parse(first.group(1)!), n = int.parse(cnt.group(1)!);
      final text = o[1];
      final nums = RegExp(r'\d+').allMatches(text.substring(0, math.min(f, text.length))).map((x) => int.parse(x.group(0)!)).toList();
      for (var k = 0; k + 1 < nums.length && k < 2 * n; k += 2) {
        final a = f + nums[k + 1];
        final b = k + 3 < nums.length ? f + nums[k + 3] : text.length;
        if (a < 0 || a > text.length) continue;
        objText[nums[k]] = text.substring(a, math.max(a, math.min(math.min(b, a + _maxObj), text.length)));
      }
    }
    // Font resources: /Font << /F1 12 0 R ... >> (direct or through an indirect dictionary).
    final res = <String, int>{};
    void addPairs(String body) {
      for (final e in RegExp(r'/([^\s/<>\[\]()]+)\s+(\d+)\s+\d+\s+R').allMatches(body)) {
        res.putIfAbsent(e.group(1)!, () => int.parse(e.group(2)!));
      }
    }

    final fontRe = RegExp(r'/Font\s*(?:<<([^>]*)>>|(\d+)\s+\d+\s+R)');
    for (final t in objText.values) {
      for (final e in fontRe.allMatches(t)) {
        if (e.group(1) != null) {
          addPairs(e.group(1)!);
        } else {
          final ref = objText[int.parse(e.group(2)!)];
          if (ref != null) addPairs(ref.replaceFirst(RegExp(r'^\s*<<'), '').replaceFirst(RegExp(r'>>\s*$'), ''));
        }
      }
    }
    final cache = <String, _Font>{};
    _Font fontFor(String resName) => cache.putIfAbsent(resName, () {
          final n = res[resName];
          final t = n == null ? '' : (objText[n] ?? '');
          final bf = RegExp(r'/BaseFont\s*/([^\s/<>\[\]()]+)').firstMatch(t);
          final tu = RegExp(r'/ToUnicode\s+(\d+)\s+\d+\s+R').firstMatch(t);
          final cm = tu == null ? null : cmaps[int.parse(tu.group(1)!)];
          final key = bf == null
              ? resName
              : bf.group(1)!.replaceAllMapped(RegExp(r'#([0-9a-fA-F]{2})'), (x) => String.fromCharCode(int.parse(x.group(1)!, radix: 16)));
          return _Font(key, RegExp(r'/Subtype\s*/Type0').hasMatch(t) || (cm != null && cm.bytes == 2), cm?.map);
        });

    final stats = <String, _Stat>{};
    var total = 0, white = 0;
    for (final c in contents) {
      final r = _Content(c, fontFor, stats)..run();
      total += r.chars;
      white += r.white;
    }
    out['whiteBoxes'] = white;
    if (total <= 0) return;
    final used = stats.entries.where((e) => e.value.chars > 0).toList();
    final major = used.where((e) => e.value.chars / total >= 0.1).map((e) => e.key).toList();
    final rare = <Map<String, dynamic>>[];
    if (total >= 100) {
      for (final e in used) {
        final v = e.value, k = e.key;
        final share = v.chars / total, dsh = v.known > 0 ? v.digits / v.known : 0.0;
        if (share >= 0.03 || dsh < 0.6 || v.digits < 1) continue;
        // A bold or italic of the main font (same family, same embedding) is normal, e.g. a totals line.
        if (major.any((mk) => _family(mk) == _family(k) && _subset.hasMatch(mk) == _subset.hasMatch(k))) continue;
        rare.add({'name': k.length > 60 ? k.substring(0, 60) : k, 'chars': v.chars, 'digitShare': (dsh * 100).round() / 100});
        if (rare.length >= 5) break;
      }
    }
    out['fonts'] = <String, dynamic>{'checked': true, 'count': used.length, 'rare': rare};
  }

  static String _family(String name) {
    var f = name.replaceFirst(_subset, '').split(RegExp(r'[-,]')).first.toLowerCase();
    f = f
        .replaceFirst(RegExp(r'(psmt|mt|ps)$'), '')
        .replaceFirst(RegExp(r'(bold|italic|oblique|regular|medium|light|semibold|black|condensed)+$'), '')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return f;
  }

  /// ASCII85 ("~>" ends the data).
  static Uint8List _a85(Uint8List b) {
    final out = BytesBuilder(copy: false);
    final grp = <int>[];
    void flush(int keep) {
      var v = 0;
      for (final d in grp) {
        v = v * 85 + d;
      }
      final four = [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
      out.add(four.sublist(0, keep));
    }

    for (var i = 0; i < b.length; i++) {
      final c = b[i];
      if (c == 126) break;
      if (c == 122 && grp.isEmpty) {
        out.add(const [0, 0, 0, 0]);
        continue;
      }
      if (c < 33 || c > 117) continue;
      grp.add(c - 33);
      if (grp.length == 5) {
        flush(4);
        grp.clear();
      }
    }
    if (grp.length > 1) {
      final k = grp.length - 1;
      while (grp.length < 5) {
        grp.add(84);
      }
      flush(k);
    }
    return out.takeBytes();
  }
}

class _Font {
  _Font(this.key, this.two, this.cmap);
  final String key;
  final bool two;
  final Map<int, String>? cmap;
}

class _Stat {
  int chars = 0, digits = 0, known = 0;
}

/// ToUnicode CMap: code → text (bfchar and bfrange entries).
class _CMap {
  _CMap(this.map, this.bytes);
  final Map<int, String> map;
  final int bytes;

  static _CMap parse(String s) {
    final map = <int, String>{};
    var bytes = 1;
    int hex(String h) => int.parse(h, radix: 16);
    String uni(String h) {
      final b = StringBuffer();
      for (var i = 0; i + 4 <= h.length; i += 4) {
        b.writeCharCode(hex(h.substring(i, i + 4)));
      }
      if (b.isEmpty && h.isNotEmpty) b.writeCharCode(hex(h));
      return b.toString();
    }

    final cs = RegExp(r'begincodespacerange\s*<([0-9a-fA-F]+)>').firstMatch(s);
    if (cs != null) bytes = math.max(1, math.min(2, cs.group(1)!.length >> 1));
    var n = 0;
    for (final m in RegExp(r'beginbf(char|range)([\s\S]*?)endbf\1').allMatches(s)) {
      if (n >= 20000) break;
      if (m.group(1) == 'char') {
        for (final e in RegExp(r'<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]*)>').allMatches(m.group(2)!)) {
          if (n++ >= 20000) break;
          map[hex(e.group(1)!)] = uni(e.group(2)!);
        }
      } else {
        for (final e in RegExp(r'<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*(?:<([0-9a-fA-F]+)>|\[([^\]]*)\])').allMatches(m.group(2)!)) {
          if (n >= 20000) break;
          final lo = hex(e.group(1)!), hi = math.min(hex(e.group(2)!), lo + 1000);
          if (e.group(3) != null) {
            final base = hex(e.group(3)!);
            for (var c = lo; c <= hi && n < 20000; c++, n++) {
              map[c] = String.fromCharCode(base + c - lo);
            }
          } else {
            final arr = RegExp(r'<[0-9a-fA-F]*>').allMatches(e.group(4)!).map((x) => x.group(0)!).toList();
            for (var c = lo, k = 0; c <= hi && k < arr.length; c++, k++, n++) {
              map[c] = uni(arr[k].substring(1, arr[k].length - 1));
            }
          }
        }
      }
    }
    return _CMap(map, bytes);
  }
}

class _Gs {
  _Gs(this.ctm, this.font, this.size, this.white);
  List<double> ctm;
  String? font;
  double size;
  bool white;
  _Gs copy() => _Gs(ctm, font, size, white);
}

/// One content stream: counts characters per font and white rectangles painted over earlier text.
class _Content {
  _Content(this.s, this.fontFor, this.stats);
  final String s;
  final _Font Function(String) fontFor;
  final Map<String, _Stat> stats;
  int chars = 0, white = 0;

  static const _id = <double>[1, 0, 0, 1, 0, 0];
  static final _delim = RegExp(r'[\s/\[\]()<>{}%]');
  static final _number = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$');
  static final _blank = RegExp(r'^\s*$');
  static final _digit = RegExp(r'^[0-9]$');

  static List<double> _mul(List<double> a, List<double> b) => [
        a[0] * b[0] + a[1] * b[2],
        a[0] * b[1] + a[1] * b[3],
        a[2] * b[0] + a[3] * b[2],
        a[2] * b[1] + a[3] * b[3],
        a[4] * b[0] + a[5] * b[2] + b[4],
        a[4] * b[1] + a[5] * b[3] + b[5],
      ];

  _Gs gs = _Gs(_id, null, 0, false);
  final stack = <_Gs>[];
  List<double> tm = _id, tlm = _id;
  double lead = 0;
  final ops = <Object?>[]; // double, String '[', _Str, _Arr, _Name, null
  final segs = <List<double>>[];
  var rects = <List<double>>[];

  double num(int k) {
    if (ops.length < k) return double.nan;
    final v = ops[ops.length - k];
    return v is double ? v : double.nan;
  }

  void show(List<String> strs) {
    final fn = gs.font;
    if (fn == null) return;
    final f = fontFor(fn);
    final st = stats.putIfAbsent(f.key, () => _Stat());
    var drawn = 0;
    final step = f.two ? 2 : 1;
    for (final b in strs) {
      for (var k = 0; k + step <= b.length; k += step) {
        final code = step == 2 ? (b.codeUnitAt(k) << 8) | b.codeUnitAt(k + 1) : b.codeUnitAt(k);
        final cm = f.cmap;
        final String? u = cm != null && cm.containsKey(code) ? cm[code] : (!f.two ? String.fromCharCode(code) : null);
        if (u != null && _blank.hasMatch(u)) continue;
        drawn++;
        if (u != null) {
          st.known++;
          if (_digit.hasMatch(u)) st.digits++;
        }
      }
    }
    st.chars += drawn;
    chars += drawn;
    if (drawn > 0 && segs.length < 20000) {
      final t = _mul(tm, gs.ctm);
      final w = drawn * gs.size * 0.6 * math.sqrt(t[0] * t[0] + t[1] * t[1]);
      segs.add([t[4], t[4] + w, t[5]]);
    }
  }

  void nextLine() {
    tlm = _mul([1, 0, 0, 1, 0, -lead], tlm);
    tm = tlm;
  }

  List<double>? six() {
    final v = [num(6), num(5), num(4), num(3), num(2), num(1)];
    return v.every((x) => x.isFinite) ? v : null;
  }

  void run() {
    final n = s.length;
    var i = 0, tokens = 0;
    while (i < n && tokens++ < PdfForensics._tokenCap) {
      final c = s.codeUnitAt(i);
      if (c <= 32) {
        i++;
        continue;
      }
      if (c == 37) {
        while (i < n && s[i] != '\n' && s[i] != '\r') {
          i++;
        }
        continue;
      }
      if (c == 40) {
        // ( literal string )
        var depth = 1;
        final r = StringBuffer();
        i++;
        while (i < n && depth > 0) {
          final ch = s[i];
          if (ch == '\\') {
            i++;
            if (i >= n) break;
            final e = s[i];
            if (e == 'n') {
              r.write('\n');
            } else if (e == 'r') {
              r.write('\r');
            } else if (e == 't') {
              r.write('\t');
            } else if (e == 'b') {
              r.write('\b');
            } else if (e == 'f') {
              r.write('\f');
            } else if (e.codeUnitAt(0) >= 48 && e.codeUnitAt(0) <= 55) {
              var v = 0, k = 0;
              while (k < 3 && i < n && s.codeUnitAt(i) >= 48 && s.codeUnitAt(i) <= 55) {
                v = v * 8 + (s.codeUnitAt(i) - 48);
                i++;
                k++;
              }
              i--;
              r.writeCharCode(v & 255);
            } else if (e == '\r') {
              if (i + 1 < n && s[i + 1] == '\n') i++;
            } else if (e != '\n') {
              r.write(e);
            }
            i++;
            continue;
          }
          if (ch == '(') {
            depth++;
          } else if (ch == ')') {
            depth--;
            if (depth == 0) {
              i++;
              break;
            }
          }
          r.write(ch);
          i++;
        }
        ops.add(_Str(r.toString()));
        continue;
      }
      if (c == 60 && (i + 1 >= n || s[i + 1] != '<')) {
        // <hex string>
        final e = s.indexOf('>', i);
        if (e < 0) break;
        var h = s.substring(i + 1, e).replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
        if (h.length.isOdd) h = '${h}0';
        final r = StringBuffer();
        for (var k = 0; k < h.length; k += 2) {
          r.writeCharCode(int.parse(h.substring(k, k + 2), radix: 16));
        }
        ops.add(_Str(r.toString()));
        i = e + 1;
        continue;
      }
      if (c == 60 || c == 62) {
        i += 2;
        ops.add(null);
        continue;
      }
      if (c == 91) {
        ops.add('[');
        i++;
        continue;
      }
      if (c == 93) {
        final arr = <String>[];
        while (ops.isNotEmpty && ops.last != '[') {
          final v = ops.removeLast();
          if (v is _Str) arr.insert(0, v.s);
        }
        if (ops.isNotEmpty) ops.removeLast();
        ops.add(_Arr(arr));
        i++;
        continue;
      }
      if (c == 47) {
        var j = i + 1;
        while (j < n && !_delim.hasMatch(s[j])) {
          j++;
        }
        ops.add(_Name(s.substring(i + 1, j)));
        i = j;
        continue;
      }
      var j = i;
      while (j < n && !_delim.hasMatch(s[j])) {
        j++;
      }
      if (j == i) {
        i++;
        continue;
      }
      final w = s.substring(i, j);
      i = j;
      if (_number.hasMatch(w)) {
        ops.add(double.parse(w));
        continue;
      }
      switch (w) {
        case 'q':
          stack.add(gs);
          if (stack.length > 64) stack.removeAt(0);
          gs = gs.copy();
          break;
        case 'Q':
          if (stack.isNotEmpty) gs = stack.removeLast();
          break;
        case 'cm':
          final v3 = six();
          if (v3 != null) gs.ctm = _mul(v3, gs.ctm);
          break;
        case 'BT':
          tm = tlm = _id;
          break;
        case 'Tf':
          final f5 = ops.length >= 2 ? ops[ops.length - 2] : null;
          if (f5 is _Name) gs.font = f5.name;
          if (num(1).isFinite) gs.size = num(1);
          break;
        case 'Tm':
          final v6 = six();
          if (v6 != null) tm = tlm = v6;
          break;
        case 'Td':
        case 'TD':
          if (num(2).isFinite && num(1).isFinite) {
            if (w == 'TD') lead = -num(1);
            tlm = _mul([1, 0, 0, 1, num(2), num(1)], tlm);
            tm = tlm;
          }
          break;
        case 'TL':
          if (num(1).isFinite) lead = num(1);
          break;
        case 'T*':
          nextLine();
          break;
        case 'Tj':
          final v11 = ops.isEmpty ? null : ops.last;
          if (v11 is _Str) show([v11.s]);
          break;
        case "'":
        case '"':
          nextLine();
          final v13 = ops.isEmpty ? null : ops.last;
          if (v13 is _Str) show([v13.s]);
          break;
        case 'TJ':
          final v14 = ops.isEmpty ? null : ops.last;
          if (v14 is _Arr) show(v14.items);
          break;
        case 'g':
          gs.white = num(1) >= 0.99;
          break;
        case 'rg':
          gs.white = num(3) >= 0.99 && num(2) >= 0.99 && num(1) >= 0.99;
          break;
        case 'k':
          gs.white = num(4) <= 0.01 && num(3) <= 0.01 && num(2) <= 0.01 && num(1) <= 0.01;
          break;
        case 'sc':
        case 'scn':
          var k19 = 0;
          while (k19 < ops.length && ops[ops.length - 1 - k19] is double) {
            k19++;
          }
          if (k19 == 1 || k19 == 3) {
            gs.white = List.generate(k19, (x) => num(x + 1)).every((x) => x >= 0.99);
          } else if (k19 == 4) {
            gs.white = [1, 2, 3, 4].every((x) => num(x) <= 0.01);
          } else {
            gs.white = false;
          }
          break;
        case 'cs':
          gs.white = false;
          break;
        case 're':
          final v21 = [num(4), num(3), num(2), num(1)];
          if (v21.every((x) => x.isFinite) && rects.length < 100) rects.add(v21);
          break;
        case 'f':
        case 'F':
        case 'f*':
        case 'B':
        case 'B*':
        case 'b':
        case 'b*':
          if (gs.white && segs.isNotEmpty) {
            for (final r in rects) {
              final t = gs.ctm;
              final xs = <double>[], ys = <double>[];
              for (final a in [r[0], r[0] + r[2]]) {
                for (final b in [r[1], r[1] + r[3]]) {
                  xs.add(a * t[0] + b * t[2] + t[4]);
                  ys.add(a * t[1] + b * t[3] + t[5]);
                }
              }
              final x0 = xs.reduce(math.min), x1 = xs.reduce(math.max), y0 = ys.reduce(math.min), y1 = ys.reduce(math.max);
              if (x1 - x0 < 3 || y1 - y0 < 3 || x1 - x0 > 500 || y1 - y0 > 80) continue;
              if (segs.any((g) => g[2] >= y0 - 2 && g[2] <= y1 + 2 && g[1] >= x0 - 2 && g[0] <= x1 + 2)) white++;
            }
          }
          rects = [];
          break;
        case 'S':
        case 's':
        case 'n':
          rects = [];
          break;
        case 'BI':
          final e32 = s.indexOf('EI', i);
          i = e32 < 0 ? n : e32 + 2;
          break;
        default:
          break;
      }
      ops.clear();
    }
  }
}

class _Str {
  _Str(this.s);
  final String s;
}

class _Arr {
  _Arr(this.items);
  final List<String> items;
}

class _Name {
  _Name(this.name);
  final String name;
}
