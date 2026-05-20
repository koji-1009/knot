// Stand-alone AOT smoke for the boringssl_dart binding wired into knot.
//
// Why this exists: `dart compile exe` (and `dart build cli`) tree-shakes
// FFI symbols based on `@ffi.Native` references it can see at compile
// time. When the boringssl_dart linker hook produces a `.dylib` whose
// symbols are local-only (the visibility regression we hit), JIT keeps
// running because the analyzer / VM resolves the bindings differently,
// but AOT fails at `dlsym` time with "symbol not found". Plain
// `knot --version` doesn't touch ECDSA, so it can't see the breakage.
//
// This program performs the smallest possible round-trip that exercises
// the same code path the install-time signature verifier uses:
//
//   1. `EcKey.generate('P-256')` — populates an EC_KEY through the
//      bindings.
//   2. `Ecdsa.sign(...)` — exercises `EVP_DigestSign*`.
//   3. `Ecdsa.verify(...)` — exercises `EVP_DigestVerify*` and the
//      `EVP_parse_public_key` path via [EcKey.importSpki] on the
//      exported coordinates.
//
// CI compiles this with `dart compile exe` and runs it on every push.
// Exit code 0 means every symbol resolved; non-zero means we've
// regressed the link-hook visibility / tree-shake again.

import 'dart:typed_data';

import 'package:boringssl_dart/boringssl_dart.dart';

void main() {
  final key = EcKey.generate('P-256');
  final message = Uint8List.fromList(List<int>.generate(32, (i) => i & 0xFF));

  final sig = Ecdsa.sign(key, message, 'SHA-256');
  final ok = Ecdsa.verify(key, sig, message, 'SHA-256');
  if (!ok) {
    throw StateError('AOT smoke: ECDSA round-trip verify returned false');
  }

  // Tampered message must NOT verify — guards against a "verify
  // unconditionally returns true" failure mode that would slip past
  // the happy-path check above.
  final tampered = Uint8List.fromList(message)..[0] ^= 0x01;
  final badOk = Ecdsa.verify(key, sig, tampered, 'SHA-256');
  if (badOk) {
    throw StateError('AOT smoke: tampered message unexpectedly verified');
  }

  // Touch the SPKI parser the install path actually calls — the
  // EVP_parse_public_key symbol is the one that surfaced the
  // visibility regression originally.
  final coords = key.exportCoordinates();
  final spki = _spkiP256(coords['x']!, coords['y']!);
  EcKey.importSpki(spki, 'P-256');

  // ignore: avoid_print
  print('boringssl AOT smoke: OK');
}

/// Hand-roll an SPKI DER for an uncompressed P-256 point so we can
/// exercise `EVP_parse_public_key` without depending on `pointycastle`
/// or another DER encoder. Matches the shape the npm registry returns
/// at `/-/npm/v1/keys`.
Uint8List _spkiP256(Uint8List x, Uint8List y) {
  if (x.length != 32 || y.length != 32) {
    throw StateError('expected 32-byte P-256 coordinates');
  }
  final point = Uint8List.fromList([0x04, ...x, ...y]);
  // BIT STRING wrapping the uncompressed point.
  final bitString = Uint8List.fromList([
    0x03,
    point.length + 1,
    0x00,
    ...point,
  ]);
  // ALG ID: SEQUENCE { OID 1.2.840.10045.2.1, OID 1.2.840.10045.3.1.7 }
  final algId = Uint8List.fromList([
    0x30,
    0x13,
    0x06,
    0x07,
    0x2A,
    0x86,
    0x48,
    0xCE,
    0x3D,
    0x02,
    0x01,
    0x06,
    0x08,
    0x2A,
    0x86,
    0x48,
    0xCE,
    0x3D,
    0x03,
    0x01,
    0x07,
  ]);
  final inner = Uint8List.fromList([...algId, ...bitString]);
  return Uint8List.fromList([0x30, inner.length, ...inner]);
}
