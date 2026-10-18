import 'dart:io';

/// Phones: decompresses GZIP (or zlib) data. Returns null if it isn't valid.
List<int>? gunzip(List<int> data) {
  try {
    return GZipCodec().decode(data);
  } catch (_) {
    try {
      return ZLibCodec().decode(data);
    } catch (_) {
      return null;
    }
  }
}
