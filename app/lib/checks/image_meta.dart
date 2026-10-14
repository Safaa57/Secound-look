import 'dart:convert';
import 'dart:typed_data';

/// Looks inside an image file for the name of a photo-editing app.
///
/// Editors such as Photoshop, PicsArt or Snapseed usually write their name into the file
/// (EXIF "Software", XMP "CreatorTool" or a PNG text chunk). A payment screenshot that passed
/// through one of them may have been altered. Most screenshots forwarded on WhatsApp have this
/// information removed, so "nothing found" proves nothing either way.
class ImageMeta {
  ImageMeta._();

  // Exact, case-sensitive names as the apps write them, to avoid false matches in image data.
  static const _editors = <String, String>{
    'Photoshop': 'Adobe Photoshop',
    'Lightroom': 'Adobe Lightroom',
    'PicsArt': 'PicsArt',
    'Picsart': 'PicsArt',
    'Snapseed': 'Snapseed',
    'Canva': 'Canva',
    'GIMP': 'GIMP',
    'PhotoDirector': 'PhotoDirector',
    'Pixlr': 'Pixlr',
    'Fotor': 'Fotor',
    'InShot': 'InShot',
    'Meitu': 'Meitu',
    'Phonto': 'Phonto',
    'PicSay': 'PicSay',
    'ibisPaint': 'ibis Paint',
    'PhotoRoom': 'PhotoRoom',
    'Photoroom': 'PhotoRoom',
    'Remini': 'Remini',
    'Paint.NET': 'Paint.NET',
    'paint.net': 'Paint.NET',
    'Pixelmator': 'Pixelmator',
    'Affinity Photo': 'Affinity Photo',
  };

  /// Returns the editor's name, or null if none was found. Only the metadata areas at the start
  /// and end of the file are searched.
  static String? editorIn(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    const head = 256 * 1024, tail = 64 * 1024;
    final parts = <Uint8List>[
      Uint8List.sublistView(bytes, 0, bytes.length < head ? bytes.length : head),
      if (bytes.length > head) Uint8List.sublistView(bytes, bytes.length - (bytes.length - head < tail ? bytes.length - head : tail)),
    ];
    for (final p in parts) {
      final s = latin1.decode(p, allowInvalid: true);
      for (final e in _editors.entries) {
        if (s.contains(e.key)) return e.value;
      }
    }
    return null;
  }
}
