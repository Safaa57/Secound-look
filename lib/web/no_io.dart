// Laptop (web) build: there is no file system, so shared screenshot paths never occur.
import 'dart:typed_data';

class File {
  File(this.path);
  final String path;
  Future<Uint8List> readAsBytes() => throw UnsupportedError('No files in the browser');
}
