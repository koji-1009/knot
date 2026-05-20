import 'dart:convert';
import 'dart:typed_data';

import 'package:boringssl_dart/boringssl_dart.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:knot/src/core/core.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:knot/src/signature/signature.dart';
import 'package:test/test.dart';

/// Sign `message` with `key` then re-encode the raw signature as DER
/// so we get the exact byte shape the npm registry advertises.
Uint8List _signAsDer(EcKey key, Uint8List message) {
  final raw = Ecdsa.sign(key, message, 'SHA-256');
  // Raw is R||S (64 bytes for P-256). Convert to DER:
  //   SEQUENCE { INTEGER r, INTEGER s }
  Uint8List encodeInteger(Uint8List value) {
    // Trim leading zeros, then add one back if the high bit is set
    // (DER requires the value be unsigned).
    var i = 0;
    while (i < value.length - 1 && value[i] == 0) {
      i++;
    }
    final trimmed = value.sublist(i);
    final needsSignByte = trimmed.isNotEmpty && trimmed[0] >= 0x80;
    final body = needsSignByte ? Uint8List.fromList([0, ...trimmed]) : trimmed;
    return Uint8List.fromList([0x02, body.length, ...body]);
  }

  final rDer = encodeInteger(Uint8List.sublistView(raw, 0, 32));
  final sDer = encodeInteger(Uint8List.sublistView(raw, 32, 64));
  final inner = Uint8List.fromList([...rDer, ...sDer]);
  return Uint8List.fromList([0x30, inner.length, ...inner]);
}

/// SPKI export — boringssl_dart doesn't expose this directly so we
/// build it by hand from the curve coordinates. P-256 SPKI for an
/// uncompressed point:
///
///   SEQUENCE {
///     SEQUENCE {
///       OID 1.2.840.10045.2.1 ecPublicKey,
///       OID 1.2.840.10045.3.1.7 prime256v1
///     },
///     BIT STRING (uncompressed point: 0x04 || X || Y)
///   }
Uint8List _spkiP256(EcKey key) {
  final coords = key.exportCoordinates();
  final x = coords['x']!;
  final y = coords['y']!;
  final point = Uint8List.fromList([0x04, ...x, ...y]); // uncompressed
  // point.length = 65, bit-string content = 1 (unused-bits) + 65 = 66
  final bitString = Uint8List.fromList([
    0x03, point.length + 1, 0x00, // BIT STRING tag, len, unused-bits
    ...point,
  ]);
  final algId = Uint8List.fromList([
    0x30, 0x13, // SEQUENCE len=19
    0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // OID ecPublicKey
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID P-256
  ]);
  final inner = Uint8List.fromList([...algId, ...bitString]);
  // inner.length is 21 + 68 = 89 < 128 so we use short-form length.
  return Uint8List.fromList([0x30, inner.length, ...inner]);
}

void main() {
  group('SignatureVerifier', () {
    test('verified: valid registry-style signature passes', () async {
      final key = EcKey.generate('P-256');
      const name = 'react';
      const version = '18.2.0';
      const integrity = 'sha512-fakehash';
      final message = utf8.encode('$name@$version:$integrity');
      final derSig = _signAsDer(key, Uint8List.fromList(message));
      final spki = _spkiP256(key);

      final mockHttp = http_testing.MockClient((req) async {
        return http.Response(
          jsonEncode({
            'keys': [
              {
                'keyid': 'SHA256:test-key',
                'scheme': 'ecdsa-sha2-nistp256',
                'key': base64.encode(spki),
              },
            ],
          }),
          200,
        );
      });
      final keyStore = RegistryKeyStore(
        client: mockHttp,
        registry: Uri.parse('https://registry.test/'),
      );
      final verifier = SignatureVerifier(keyStoreFor: (_) => keyStore);

      final check = await verifier.verify(
        name: name,
        version: version,
        integrity: integrity,
        signatures: [
          DistSignature(keyid: 'SHA256:test-key', sig: base64.encode(derSig)),
        ],
      );
      expect(check.outcome, SignatureOutcome.verified);
    });

    test('failed: wrong message body fails verification', () async {
      final key = EcKey.generate('P-256');
      final message = utf8.encode('react@18.2.0:sha512-DIFFERENT');
      final derSig = _signAsDer(key, Uint8List.fromList(message));
      final spki = _spkiP256(key);

      final mockHttp = http_testing.MockClient((req) async {
        return http.Response(
          jsonEncode({
            'keys': [
              {
                'keyid': 'SHA256:k',
                'scheme': 'ecdsa-sha2-nistp256',
                'key': base64.encode(spki),
              },
            ],
          }),
          200,
        );
      });
      final verifier = SignatureVerifier(
        keyStoreFor: (_) => RegistryKeyStore(
          client: mockHttp,
          registry: Uri.parse('https://registry.test/'),
        ),
      );
      final check = await verifier.verify(
        name: 'react',
        version: '18.2.0',
        integrity: 'sha512-realintegrity', // signed with DIFFERENT
        signatures: [
          DistSignature(keyid: 'SHA256:k', sig: base64.encode(derSig)),
        ],
      );
      expect(check.outcome, SignatureOutcome.failed);
      expect(check.reason, contains('did not verify'));
    });

    test('failed: unknown keyid', () async {
      final mockHttp = http_testing.MockClient((req) async {
        return http.Response(
          jsonEncode({'keys': const <Map<String, dynamic>>[]}),
          200,
        );
      });
      final verifier = SignatureVerifier(
        keyStoreFor: (_) => RegistryKeyStore(
          client: mockHttp,
          registry: Uri.parse('https://registry.test/'),
        ),
      );
      final check = await verifier.verify(
        name: 'x',
        version: '1.0.0',
        integrity: 'sha512-x',
        signatures: const [DistSignature(keyid: 'SHA256:nope', sig: 'AAAA')],
      );
      expect(check.outcome, SignatureOutcome.failed);
      expect(check.reason, contains('unknown keyid'));
    });

    test('missing: no signatures attached', () async {
      final verifier = SignatureVerifier(
        keyStoreFor: (_) => throw StateError('unused'),
      );
      final check = await verifier.verify(
        name: 'x',
        version: '1.0.0',
        integrity: 'sha512-x',
        signatures: const [],
      );
      expect(check.outcome, SignatureOutcome.missing);
    });

    group('enforce', () {
      late SignatureVerifier verifier;
      setUp(() {
        verifier = SignatureVerifier(
          keyStoreFor: (_) => throw StateError('not used'),
        );
      });

      test('none lets everything through', () {
        verifier.enforce(
          policy: SignaturePolicy.none,
          name: 'x',
          version: '1',
          result: SignatureCheck(
            outcome: SignatureOutcome.failed,
            reason: 'bad',
          ),
        );
        // No throw.
      });

      test('weak tolerates missing but fails on bad', () {
        verifier.enforce(
          policy: SignaturePolicy.weak,
          name: 'x',
          version: '1',
          result: SignatureCheck(outcome: SignatureOutcome.missing),
        );
        expect(
          () => verifier.enforce(
            policy: SignaturePolicy.weak,
            name: 'x',
            version: '1',
            result: SignatureCheck(
              outcome: SignatureOutcome.failed,
              reason: 'r',
            ),
          ),
          throwsA(isA<IntegrityError>()),
        );
      });

      test('strict fails on missing AND bad', () {
        expect(
          () => verifier.enforce(
            policy: SignaturePolicy.strict,
            name: 'x',
            version: '1',
            result: SignatureCheck(outcome: SignatureOutcome.missing),
          ),
          throwsA(isA<IntegrityError>()),
        );
        expect(
          () => verifier.enforce(
            policy: SignaturePolicy.strict,
            name: 'x',
            version: '1',
            result: SignatureCheck(
              outcome: SignatureOutcome.failed,
              reason: 'r',
            ),
          ),
          throwsA(isA<IntegrityError>()),
        );
      });
    });
  });
}
