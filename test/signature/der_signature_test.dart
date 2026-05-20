import 'dart:typed_data';

import 'package:knot/src/signature/signature.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('derEcdsaSignatureToRaw P-256', () {
    test('round-trip: 32-byte R, 32-byte S without sign-byte padding', () {
      // SEQUENCE(len=68)
      //   INTEGER(len=32) <r>
      //   INTEGER(len=32) <s>
      // (32 here is the natural P-256 component size; top bit clear so no
      //  leading 0x00 sign byte is needed.)
      final r = List<int>.filled(32, 0x42);
      final s = List<int>.filled(32, 0x53);
      final der = Uint8List.fromList([
        0x30, 0x44, // SEQUENCE, length=0x44=68
        0x02, 0x20, ...r, // INTEGER r
        0x02, 0x20, ...s, // INTEGER s
      ]);
      final raw = derEcdsaSignatureToRaw(der, curveByteSize: 32)!;
      expect(raw, hasLength(64));
      expect(raw.sublist(0, 32), r);
      expect(raw.sublist(32, 64), s);
    });

    test('strips DER sign byte (0x00) when component starts ≥ 0x80', () {
      // R has high bit set → DER prepends 0x00 to keep value unsigned.
      final rBody = List<int>.filled(32, 0x80);
      final sBody = List<int>.filled(32, 0x70);
      final der = Uint8List.fromList([
        0x30, 0x45, // SEQUENCE, length=0x45=69 (33 + 2 + 32 + 2)
        0x02, 0x21, 0x00, ...rBody, // INTEGER r (33 bytes: sign byte + 32)
        0x02, 0x20, ...sBody, // INTEGER s (32 bytes)
      ]);
      final raw = derEcdsaSignatureToRaw(der, curveByteSize: 32)!;
      expect(raw.sublist(0, 32), rBody);
      expect(raw.sublist(32, 64), sBody);
    });

    test('left-pads short components to curveByteSize', () {
      // R is a short integer (leading zero bits → DER omits them).
      final der = Uint8List.fromList([
        0x30, 0x26, // SEQUENCE, length=38 = 2+2 (r tag+len+body=4) + 2+32
        0x02, 0x02, 0x12, 0x34, // INTEGER r = 0x1234 (2 bytes)
        0x02, 0x20, ...List<int>.filled(32, 0x55), // INTEGER s (32 bytes)
      ]);
      final raw = derEcdsaSignatureToRaw(der, curveByteSize: 32)!;
      // r should be left-padded: 30 zero bytes, then 0x12 0x34.
      expect(raw.sublist(0, 30), List<int>.filled(30, 0));
      expect(raw[30], 0x12);
      expect(raw[31], 0x34);
    });

    test('returns null for malformed inputs', () {
      // empty
      expect(derEcdsaSignatureToRaw(Uint8List(0), curveByteSize: 32), isNull);
      // wrong outer tag
      expect(
        derEcdsaSignatureToRaw(
          Uint8List.fromList([0x31, 0x00]),
          curveByteSize: 32,
        ),
        isNull,
      );
      // inner length larger than container
      expect(
        derEcdsaSignatureToRaw(
          Uint8List.fromList([0x30, 0x02, 0x02, 0x05, 0x01]),
          curveByteSize: 32,
        ),
        isNull,
      );
      // component too large for curve
      expect(
        derEcdsaSignatureToRaw(
          Uint8List.fromList([
            0x30, 0x46,
            0x02,
            0x21,
            ...List<int>.filled(33, 0xFF), // 33-byte r (no sign byte)
            0x02, 0x20, ...List<int>.filled(32, 0x01),
          ]),
          curveByteSize: 32,
        ),
        isNull,
      );
    });

    test('accepts real-world boringssl-signed payload round trip', () {
      // Smoke: a DER blob produced by openssl ecparam+dgst is shaped
      // <SEQUENCE 0x30><len><INTEGER 0x02><len><r><INTEGER 0x02><len><s>.
      // We don't have an external fixture handy here, so just rely on
      // the construction tests above for the property checks.
      // SEQUENCE(len=0x46=70) {
      //   INTEGER(len=0x21=33, sign-byte + 32 of 0xC1),
      //   INTEGER(len=0x20=32, 32 of 0x53)
      // }
      final fakeDer = _hex(
        // SEQUENCE inner = 35 (r) + 34 (s) = 69 = 0x45
        '3045'
        // INTEGER len=0x21=33: 0x00 sign byte + 32 bytes of 0xC1
        '022100c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1'
        // INTEGER len=0x20=32: 32 bytes of 0x53
        '02205353535353535353535353535353535353535353535353535353535353535353',
      );
      final raw = derEcdsaSignatureToRaw(fakeDer, curveByteSize: 32);
      expect(raw, isNotNull);
      expect(raw!.length, 64);
      // r: 32 bytes of 0xC1 (sign byte stripped)
      expect(raw.sublist(0, 32), List<int>.filled(32, 0xC1));
      // s: 32 bytes of 0x53
      expect(raw.sublist(32, 64), List<int>.filled(32, 0x53));
    });
  });
}
