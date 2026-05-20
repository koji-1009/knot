import 'dart:convert';
import 'dart:typed_data';

import 'package:knot/src/core/core.dart';

/// Parsed `<algorithm>-<base64>` subresource integrity value.
class Integrity {
  const Integrity(this.algorithm, this.digestBase64);

  /// Parse a string like `sha512-abcdef...`. Throws [FormatException] when
  /// the format does not match.
  factory Integrity.parse(String input) {
    final dash = input.indexOf('-');
    if (dash <= 0 || dash == input.length - 1) {
      throw FormatException('invalid integrity literal: $input');
    }
    return Integrity(
      input.substring(0, dash).toLowerCase(),
      input.substring(dash + 1),
    );
  }

  /// `sha512`, `sha384`, `sha256`.
  final String algorithm;
  final String digestBase64;

  /// Encode this integrity in npm/SRI canonical form.
  String encode() => '$algorithm-$digestBase64';

  /// Verify that [bytes] hash to this integrity. Throws [IntegrityError]
  /// when the digest does not match.
  void verify(Uint8List bytes) {
    final actual = computeIntegrity(algorithm, bytes);
    if (actual.digestBase64 != digestBase64) {
      throw IntegrityError(
        'integrity mismatch ($algorithm)',
        expected: encode(),
        actual: actual.encode(),
      );
    }
  }

  @override
  String toString() => encode();
}

/// Compute an [Integrity] using [algorithm] (one of `sha256`, `sha384`,
/// `sha512`). Backed by BoringSSL — see `KnotHash`.
Integrity computeIntegrity(String algorithm, Uint8List bytes) {
  final algo = algorithm.toLowerCase();
  try {
    final digest = KnotHash.digest(algo, bytes);
    return Integrity(algo, base64.encode(digest));
  } on ArgumentError {
    throw IntegrityError('unsupported integrity algorithm: $algorithm');
  }
}
