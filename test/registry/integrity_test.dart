import 'dart:convert';
import 'dart:typed_data';

import 'package:knot/src/core/core.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

void main() {
  group('Integrity', () {
    test('parse + encode round-trips', () {
      final i = Integrity.parse('sha512-abcdef==');
      expect(i.algorithm, 'sha512');
      expect(i.digestBase64, 'abcdef==');
      expect(i.encode(), 'sha512-abcdef==');
    });

    test('verify matches sha512 of known input', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final computed = computeIntegrity('sha512', bytes);
      computed.verify(bytes);
    });

    test('verify throws on mismatch', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final computed = computeIntegrity('sha512', bytes);
      final wrong = Uint8List.fromList(utf8.encode('goodbye world'));
      expect(() => computed.verify(wrong), throwsA(isA<IntegrityError>()));
    });

    test('rejects malformed literal', () {
      expect(() => Integrity.parse('nodash'), throwsFormatException);
      expect(() => Integrity.parse('-onlysuffix'), throwsFormatException);
      expect(() => Integrity.parse('alg-'), throwsFormatException);
    });

    test('rejects unsupported algorithm', () {
      expect(
        () => computeIntegrity('md5', Uint8List.fromList([0])),
        throwsA(isA<IntegrityError>()),
      );
    });
  });
}
