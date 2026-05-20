import 'dart:typed_data';

/// Decode a DER-encoded ECDSA signature into the 64-byte raw `R||S`
/// form that `boringssl_dart`'s `Ecdsa.verify` expects.
///
/// The npm registry attaches signatures as base64(DER), where DER is:
///
///   SEQUENCE {
///     INTEGER r,
///     INTEGER s
///   }
///
/// Each integer is variable length (1–33 bytes due to a possible
/// leading sign byte). [curveByteSize] is 32 for P-256; we left-pad
/// each component to that width and concatenate.
///
/// Returns null on any malformed input — callers treat that as a
/// verification failure rather than a crash.
Uint8List? derEcdsaSignatureToRaw(Uint8List der, {required int curveByteSize}) {
  var i = 0;

  int? readByte() {
    if (i >= der.length) return null;
    return der[i++];
  }

  bool expect(int b) => readByte() == b;

  int? readLength() {
    final first = readByte();
    if (first == null) return null;
    if (first < 0x80) return first;
    final n = first & 0x7F;
    if (n == 0 || n > 4) return null;
    var len = 0;
    for (var k = 0; k < n; k++) {
      final b = readByte();
      if (b == null) return null;
      len = (len << 8) | b;
    }
    return len;
  }

  // outer SEQUENCE tag
  if (!expect(0x30)) return null;
  final seqLen = readLength();
  if (seqLen == null) return null;
  if (i + seqLen != der.length) return null;

  Uint8List? readInteger() {
    if (!expect(0x02)) return null;
    final len = readLength();
    if (len == null || len <= 0) return null;
    if (i + len > der.length) return null;
    var start = i;
    var length = len;
    // Strip the optional sign byte (leading 0x00 used to keep the
    // value unsigned in DER's two's-complement INTEGER encoding).
    if (length > 1 && der[start] == 0x00) {
      start++;
      length--;
    }
    if (length > curveByteSize) return null;
    i = start + length;
    return Uint8List.sublistView(der, start, start + length);
  }

  final r = readInteger();
  final s = readInteger();
  if (r == null || s == null) return null;
  if (i != der.length) return null;

  final raw = Uint8List(curveByteSize * 2);
  raw.setRange(curveByteSize - r.length, curveByteSize, r);
  raw.setRange(curveByteSize * 2 - s.length, curveByteSize * 2, s);
  return raw;
}
