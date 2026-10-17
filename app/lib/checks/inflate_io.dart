import 'dart:io';
import 'dart:typed_data';

class _Full implements Exception {}

class _CapSink implements Sink<List<int>> {
  _CapSink(this.max);
  final int max;
  final BytesBuilder out = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    final room = max - out.length;
    if (chunk.length >= room) {
      if (room > 0) out.add(chunk.sublist(0, room));
      throw _Full();
    }
    out.add(chunk);
  }

  @override
  void close() {}
}

/// Phones: decompresses zlib ("FlateDecode") data, stopping at [maxOut] bytes so a crafted file can't use up
/// memory. Damaged or truncated data gives what could be decoded; null when nothing could.
Uint8List? inflate(Uint8List data, int maxOut) {
  final sink = _CapSink(maxOut);
  final conv = ZLibDecoder().startChunkedConversion(sink);
  try {
    const step = 16 * 1024;
    for (var i = 0; i < data.length; i += step) {
      conv.add(Uint8List.sublistView(data, i, i + step < data.length ? i + step : data.length));
    }
    conv.close();
  } on _Full {
    // reached the cap: keep what we have
  } catch (_) {
    // damaged stream: keep what we have
  }
  return sink.out.isEmpty ? null : sink.out.takeBytes();
}
