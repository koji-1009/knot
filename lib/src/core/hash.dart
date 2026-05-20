import 'dart:typed_data';

import 'package:boringssl_dart/boringssl_dart.dart' as bssl;

/// Streaming SHA-2 context backed by BoringSSL. Feed bytes via
/// [update] as they arrive, call [finish] for the digest. The
/// tarball fetch path uses this to fold integrity verification into
/// the network read instead of a second pass over the buffer.
class IncrementalHash {
  IncrementalHash._(this._ctx);
  final bssl.HashContext _ctx;

  factory IncrementalHash.forAlgorithm(String algorithm) {
    final algo = switch (algorithm) {
      'sha256' => bssl.Hash.sha256,
      'sha384' => bssl.Hash.sha384,
      'sha512' => bssl.Hash.sha512,
      _ => throw ArgumentError.value(algorithm, 'algorithm'),
    };
    return IncrementalHash._(algo.start());
  }

  void update(List<int> chunk) => _ctx.update(chunk);
  Uint8List finish() => _ctx.finish();

  /// Convenience for callers that immediately want the lowercase-hex
  /// form. Saves an intermediate [Uint8List] reference on the streaming
  /// per-file hash path used by `Store.ingest`.
  String finishHex() => _toHex(_ctx.finish());
}

/// Native SHA-2 helpers. BoringSSL's SHA-512 runs ~12× faster than
/// `package:crypto`'s pure-Dart implementation on the multi-MB
/// tarballs the integrity check verifies and the per-file extracted
/// blobs the store hashes during ingest.
class KnotHash {
  /// Compute a SHA-512 digest, returning lowercase hex.
  static String sha512Hex(Uint8List bytes) =>
      _toHex(bssl.Hash.sha512.digest(bytes));

  /// Hash using one of `sha256`, `sha384`, `sha512`. Returns raw bytes.
  static Uint8List digest(String algorithm, Uint8List bytes) {
    final algo = switch (algorithm) {
      'sha256' => bssl.Hash.sha256,
      'sha384' => bssl.Hash.sha384,
      'sha512' => bssl.Hash.sha512,
      _ => throw ArgumentError.value(algorithm, 'algorithm'),
    };
    return algo.digest(bytes);
  }
}

/// 256-entry hex pair lookup — `_hexAscii[b*2]` and `[b*2+1]` are the
/// two ASCII code-units for byte `b`. Beats `StringBuffer +
/// b.toRadixString(16)` by ~13× on the per-file hashing loop.
final Uint8List _hexAscii = _buildHexAscii();
Uint8List _buildHexAscii() {
  final out = Uint8List(256 * 2);
  const chars = '0123456789abcdef';
  for (var b = 0; b < 256; b++) {
    out[b * 2] = chars.codeUnitAt(b >> 4);
    out[b * 2 + 1] = chars.codeUnitAt(b & 0x0f);
  }
  return out;
}

String _toHex(Uint8List bytes) {
  final out = Uint8List(bytes.length * 2);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i] * 2;
    out[i * 2] = _hexAscii[b];
    out[i * 2 + 1] = _hexAscii[b + 1];
  }
  return String.fromCharCodes(out);
}
