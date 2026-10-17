import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Photo forensics for the document check: size, screenshot or camera photo, and JPEG error-level analysis (ELA).
///
/// ELA: a JPEG is saved again at quality 90 and compared with itself in 16×16 blocks. Areas pasted in from
/// another picture (or edited and saved once more) often lose a different amount of detail than the rest.
/// Because text edges naturally change more than plain paper, each block's change is divided by how busy
/// the block is, so only blocks that change more than similar-looking blocks stand out.
class ImageForensics {
  ImageForensics._();

  static const _screenWidths = <int>{640, 720, 750, 828, 1080, 1125, 1170, 1179, 1206, 1242, 1260, 1284, 1290, 1320, 1440, 1536, 1600};

  /// [bytes] → `{width, height, screenshot, camera, ela: {checked, score, hotspots}}`. Never throws.
  static Map<String, dynamic> analyze(Uint8List bytes) {
    final out = <String, dynamic>{
      'width': null,
      'height': null,
      'screenshot': false,
      'camera': false,
      'ela': <String, dynamic>{'checked': false, 'score': 0.0, 'hotspots': 0},
    };
    try {
      final h = _header(bytes);
      out['width'] = h.width;
      out['height'] = h.height;
      out['camera'] = h.camera;
      out['screenshot'] = _looksLikeScreenshot(h);
      if (h.format == 'jpeg' && out['screenshot'] != true && h.width != null && h.height != null) {
        out['ela'] = _ela(bytes, h.width!, h.height!);
      }
    } catch (_) {
      // unreadable file: keep the defaults
    }
    return out;
  }

  static bool _looksLikeScreenshot(_Header h) {
    final w = h.width, ht = h.height;
    if (w == null || ht == null || w <= 0 || ht <= 0) return false;
    if (h.camera) return false;
    if (h.format != 'png' && h.exif) return false; // a JPEG that kept its EXIF came from a camera app
    final short = math.min(w, ht), long = math.max(w, ht);
    final ratio = long / short;
    final phoneTall = ratio >= 2.0 && ratio <= 2.4; // 18:9 … 21.5:9 (19.5:9 is most common)
    final phone169 = ratio >= 1.76 && ratio <= 1.79; // older 16:9 phones
    return _screenWidths.contains(short) && (phoneTall || (phone169 && h.format == 'png'));
  }

  // ---------------------------------------------------------------- ELA
  static Map<String, dynamic> _ela(Uint8List bytes, int w0, int h0) {
    final skipped = <String, dynamic>{'checked': false, 'score': 0.0, 'hotspots': 0};
    if (w0 > 4000 && h0 > 4000) return skipped; // very large: too slow and too much memory on a phone
    var a = img.decodeJpg(bytes);
    if (a == null) return skipped;
    if (math.max(a.width, a.height) > 2400) {
      a = a.width >= a.height ? img.copyResize(a, width: 1600) : img.copyResize(a, height: 1600);
    }
    final b = img.decodeJpg(img.encodeJpg(a, quality: 90));
    if (b == null || b.width != a.width || b.height != a.height) return skipped;
    final w = a.width, h = a.height;
    final pa = a.getBytes(order: img.ChannelOrder.rgb), pb = b.getBytes(order: img.ChannelOrder.rgb);
    if (pa.length < w * h * 3 || pb.length < w * h * 3) return skipped;
    const bs = 16;
    final bw = w ~/ bs, bh = h ~/ bs;
    if (bw < 4 || bh < 4) return skipped;
    final ratio = List<double>.filled(bw * bh, 0);
    for (var by = 0; by < bh; by++) {
      for (var bx = 0; bx < bw; bx++) {
        var diff = 0, grad = 0;
        for (var y = by * bs; y < by * bs + bs; y++) {
          final row = y * w * 3;
          for (var x = bx * bs; x < bx * bs + bs; x++) {
            final p = row + x * 3;
            diff += (pa[p] - pb[p]).abs() + (pa[p + 1] - pb[p + 1]).abs() + (pa[p + 2] - pb[p + 2]).abs();
            if (x + 1 < bx * bs + bs) grad += (pa[p] - pa[p + 3]).abs() + (pa[p + 1] - pa[p + 4]).abs() + (pa[p + 2] - pa[p + 5]).abs();
          }
        }
        final e = diff / (bs * bs * 3), g = grad / (bs * (bs - 1) * 3);
        ratio[by * bw + bx] = e / (g + 2);
      }
    }
    final sorted = List<double>.of(ratio)..sort();
    final med = sorted[sorted.length ~/ 2];
    final dev = ratio.map((v) => (v - med).abs()).toList()..sort();
    final mad = math.max(dev[dev.length ~/ 2], 0.01);
    final thr = med + 4 * mad;
    final seen = List<bool>.filled(ratio.length, false);
    var hotspots = 0, clustered = 0;
    var strength = 0.0;
    for (var i = 0; i < ratio.length; i++) {
      if (seen[i] || ratio[i] <= thr) continue;
      // flood-fill one cluster of outlier blocks (4-neighbours)
      final stack = <int>[i];
      seen[i] = true;
      final members = <int>[];
      while (stack.isNotEmpty) {
        final k = stack.removeLast();
        members.add(k);
        final x = k % bw, y = k ~/ bw;
        for (final n in [if (x > 0) k - 1, if (x + 1 < bw) k + 1, if (y > 0) k - bw, if (y + 1 < bh) k + bw]) {
          if (!seen[n] && ratio[n] > thr) {
            seen[n] = true;
            stack.add(n);
          }
        }
      }
      if (members.length >= 4) {
        hotspots++;
        clustered += members.length;
        for (final k in members) {
          strength += math.min(1.0, (ratio[k] - med) / (8 * mad));
        }
      }
    }
    if (hotspots == 0) return <String, dynamic>{'checked': true, 'score': 0.0, 'hotspots': 0};
    // Edits are local: when a large part of the picture "stands out", it's texture or noise, not an edit.
    final frac = clustered / ratio.length;
    final spread = frac <= 0.25 ? 1.0 : (frac >= 0.6 ? 0.0 : (0.6 - frac) / 0.35);
    final score = (strength / clustered) * spread;
    return <String, dynamic>{'checked': true, 'score': (score * 100).round() / 100, 'hotspots': hotspots};
  }

  // ---------------------------------------------------------------- headers (size, EXIF camera)
  static _Header _header(Uint8List b) {
    final h = _Header();
    if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      h.format = 'png';
      h.width = _be32(b, 16);
      h.height = _be32(b, 20);
      return h;
    }
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      h.format = 'jpeg';
      var i = 2;
      while (i + 4 <= b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final m = b[i + 1];
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) || m == 0xFF) {
          i += m == 0xFF ? 1 : 2;
          continue;
        }
        if (m == 0xD9 || m == 0xDA) break;
        final len = (b[i + 2] << 8) | b[i + 3];
        if (len < 2) break;
        final seg = i + 4;
        if (m == 0xE1 && seg + 6 <= b.length && b[seg] == 0x45 && b[seg + 1] == 0x78 && b[seg + 2] == 0x69 && b[seg + 3] == 0x66) {
          h.exif = true;
          h.camera = _exifCamera(b, seg + 6, math.min(b.length, i + 2 + len));
        }
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC && seg + 5 <= b.length) {
          h.height = (b[seg + 1] << 8) | b[seg + 2];
          h.width = (b[seg + 3] << 8) | b[seg + 4];
        }
        i += 2 + len;
      }
      return h;
    }
    if (b.length > 30 && b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45) {
      h.format = 'webp';
      try {
        final d = img.WebPDecoder().startDecode(b);
        h.width = d?.width;
        h.height = d?.height;
      } catch (_) {}
    }
    return h;
  }

  static int _be32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  /// True when IFD0 has a non-empty Make (0x010F) or Model (0x0110).
  static bool _exifCamera(Uint8List b, int t, int end) {
    if (t + 8 > end) return false;
    final le = b[t] == 0x49;
    int u16(int o) => o + 2 > end ? 0 : (le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1]);
    int u32(int o) => o + 4 > end ? 0 : (le ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24) : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);
    final ifd = t + u32(t + 4);
    final n = u16(ifd);
    for (var k = 0; k < n && k < 200; k++) {
      final e = ifd + 2 + k * 12;
      if (e + 12 > end) break;
      final tag = u16(e);
      if (tag != 0x010F && tag != 0x0110) continue;
      final count = u32(e + 4);
      final at = count <= 4 ? e + 8 : t + u32(e + 8);
      for (var j = 0; j < count && at + j < end; j++) {
        final c = b[at + j];
        if (c > 32 && c < 127) return true;
      }
    }
    return false;
  }
}

class _Header {
  String? format;
  int? width, height;
  bool exif = false, camera = false;
}
