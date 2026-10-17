import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../native.dart';
import 'image_meta.dart';

/// A picked or shared image, already read on the device.
class PickedImage {
  PickedImage({required this.bytes, this.text = '', this.qr = const [], this.editor, this.readError});
  final Uint8List bytes;
  final String text;
  final List<String> qr;
  final String? editor;
  /// In English: screens show it with tr() so it follows the current language.
  final String? readError;
}

/// Lets the user choose a screenshot (or take a photo of a QR code) and reads it on the device.
/// Nothing is uploaded.
class ImageReader {
  ImageReader._();

  static const maxBytes = 15 * 1024 * 1024;

  static Future<PickedImage?> pick({bool camera = false, bool layout = false}) async {
    // No resizing options: resizing would re-save the file and remove the editing-app info we look for.
    // requestFullMetadata is off so iPhone never asks for full photo-library access (Android ignores it).
    final f = await ImagePicker().pickImage(source: camera ? ImageSource.camera : ImageSource.gallery, requestFullMetadata: false);
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    if (bytes.length > maxBytes) {
      return PickedImage(bytes: Uint8List(0), readError: 'This image is too large (over 15 MB).');
    }
    return read(kIsWeb ? null : f.path, bytes, layout: layout);
  }

  /// Reads an image file at [path] (inside the app's own storage) or just its [bytes] (laptop).
  static Future<PickedImage> read(String? path, Uint8List bytes, {bool layout = false}) async {
    final editor = ImageMeta.editorIn(bytes);
    if (path == null || kIsWeb) {
      return PickedImage(bytes: bytes, editor: editor, readError: 'Reading the words in a screenshot works in the phone app. Type the details below instead.');
    }
    try {
      final r = await Native.instance.readImage(path, layout: layout);
      return PickedImage(
        bytes: bytes,
        text: (r['text'] as String?) ?? '',
        qr: ((r['qr'] as List?) ?? const []).map((e) => '$e').toList(),
        editor: editor,
      );
    } on PlatformException catch (e) {
      return PickedImage(bytes: bytes, editor: editor, readError: e.message ?? 'Couldn\'t read this image.');
    }
  }
}
