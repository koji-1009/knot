import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  test('ingestTarball stores files atomically and is idempotent', () async {
    final tmp = await Directory.systemTemp.createTemp('knot_store_test_');
    try {
      final store = Store(p.join(tmp.path, 'store'));
      final tarBytes = await _buildTar([
        ('package/package.json', '{"name":"sample","version":"1.0.0"}'),
        ('package/lib/index.js', 'module.exports = 42;\n'),
      ]);
      final fakeIntegrity = 'abc123';

      final first = await store.ingestTarball(
        bytes: tarBytes,
        tarballSha512Hex: fakeIntegrity,
      );
      expect(first.files.length, 2);
      final paths = first.files.map((f) => f.relativePath).toSet();
      expect(paths, {'package.json', 'lib/index.js'});

      // Idempotency: a second call returns the manifest without re-ingesting.
      final second = await store.ingestTarball(
        bytes: tarBytes,
        tarballSha512Hex: fakeIntegrity,
      );
      expect(second.files.length, 2);

      // Each stored file lives at files/<aa>/<sha>
      for (final f in first.files) {
        final blob = File(store.layout.filePath(f.sha512Hex));
        expect(await blob.exists(), isTrue);
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}

Future<Uint8List> _buildTar(List<(String, String)> files) async {
  final entries = Stream<TarEntry>.fromIterable([
    for (final f in files)
      TarEntry.data(TarHeader(name: f.$1, mode: 0x1A4), utf8.encode(f.$2)),
  ]);
  final raw = entries.transform(tarWriter);
  final gz = raw.transform(gzip.encoder);
  final buf = BytesBuilder(copy: false);
  await for (final chunk in gz) {
    buf.add(chunk);
  }
  return buf.toBytes();
}
