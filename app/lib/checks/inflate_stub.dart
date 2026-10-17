import 'dart:typed_data';

/// Browser build: no built-in zlib here, so compressed PDF page contents can't be read (the check reports
/// "not checked" and only uncompressed pages are looked at).
Uint8List? inflate(Uint8List data, int maxOut) => null;
