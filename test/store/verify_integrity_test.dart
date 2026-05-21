import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/core/core.dart';
import 'package:knot/src/store/store.dart';
import 'package:test/test.dart';

void main() {
  group('Store.verifyTarballIntegrity (Phase K)', () {
    late Directory tmp;
    late Store store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('knot_verify_int_');
      store = Store(tmp.path);
      await store.initialize();
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('throws StateError when the tarball is unknown', () async {
      expect(
        () => store.verifyTarballIntegrity('a' * 128),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'clean store reports no issues; tampering reports a mismatch',
      () async {
        // Hand-build a minimal index entry referencing one file.
        final hello = const [104, 101, 108, 108, 111]; // "hello"
        final sha = KnotHash.sha512Hex(Uint8List.fromList(hello));
        final filePath = store.layout.filePath(sha);
        await Directory(filePath).parent.create(recursive: true);
        await File(filePath).writeAsBytes(hello);
        final tarSha = 'tar${'b' * 125}';
        final indexPath = store.layout.indexPath(tarSha);
        await Directory(indexPath).parent.create(recursive: true);
        await File(indexPath).writeAsString(
          '{"files":[{"path":"hello.txt","sha512":"$sha","size":5,"mode":420}]}',
        );

        expect(await store.verifyTarballIntegrity(tarSha), isEmpty);

        // Tamper: overwrite the CAS entry.
        await File(filePath).writeAsBytes([1, 2, 3]);
        final issues = await store.verifyTarballIntegrity(tarSha);
        expect(issues, hasLength(1));
        expect(issues.first.reason, 'sha512-mismatch');
        expect(issues.first.expectedSha512, sha);
      },
    );

    test('missing CAS file is reported as `missing`', () async {
      final tarSha = 'mtar${'c' * 124}';
      final indexPath = store.layout.indexPath(tarSha);
      await Directory(indexPath).parent.create(recursive: true);
      await File(indexPath).writeAsString(
        '{"files":[{"path":"gone","sha512":"${'d' * 128}","size":0,"mode":420}]}',
      );
      final issues = await store.verifyTarballIntegrity(tarSha);
      expect(issues, hasLength(1));
      expect(issues.first.reason, 'missing');
    });
  });
}
