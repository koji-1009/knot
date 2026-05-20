import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  test(
    'extracts a simple npm-style tarball, stripping package/ prefix',
    () async {
      final entries = Stream<TarEntry>.fromIterable([
        TarEntry.data(
          TarHeader(name: 'package/package.json', mode: 0x1A4),
          utf8.encode('{"name":"sample","version":"1.0.0"}'),
        ),
        TarEntry.data(
          TarHeader(name: 'package/lib/index.js', mode: 0x1A4),
          utf8.encode('module.exports = 42;\n'),
        ),
      ]);

      final tmp = await Directory.systemTemp.createTemp('knot_archive_test_');
      try {
        final raw = entries.transform(tarWriter);
        final gz = raw.transform(gzip.encoder);
        final extractor = TarExtractor();
        final emitted = await extractor.extract(
          Stream.value(await _collect(gz)),
          destination: tmp.path,
        );
        expect(emitted.map((e) => e.relativePath).toSet(), {
          'package.json',
          'lib/index.js',
        });
        final pkgJson = await File(
          p.join(tmp.path, 'package.json'),
        ).readAsString();
        expect(pkgJson, contains('"sample"'));
        final lib = await File(p.join(tmp.path, 'lib/index.js')).readAsString();
        expect(lib, contains('module.exports'));
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );
}

Future<Uint8List> _collect(Stream<List<int>> source) async {
  final buf = BytesBuilder(copy: false);
  await for (final chunk in source) {
    buf.add(chunk);
  }
  return buf.toBytes();
}
