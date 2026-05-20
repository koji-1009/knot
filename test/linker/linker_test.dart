import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/linker/linker.dart';
import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  test('links a simple package with one dependency', () async {
    final tmp = await Directory.systemTemp.createTemp('knot_linker_test_');
    try {
      final store = Store(p.join(tmp.path, 'store'));

      // ingest a "react" tarball
      final reactTarHash = 'react-tarball-hash';
      final reactTar = await _buildTar([
        ('package/package.json', '{"name":"react","version":"18.0.0"}'),
        ('package/index.js', 'module.exports = "react";'),
      ]);
      await store.ingestTarball(
        bytes: reactTar,
        tarballSha512Hex: reactTarHash,
      );

      // ingest a "child" tarball
      final childTarHash = 'child-tarball-hash';
      final childTar = await _buildTar([
        ('package/package.json', '{"name":"child","version":"1.0.0"}'),
        ('package/lib.js', 'module.exports = "child";'),
      ]);
      await store.ingestTarball(
        bytes: childTar,
        tarballSha512Hex: childTarHash,
      );

      final project = await Directory(p.join(tmp.path, 'project')).create();
      final pool = await WorkerPool.spawn(storeRoot: store.root, size: 2);
      final materializer = StoreMaterializer.forPlatform(
        store,
        workerPool: pool,
      );
      final linker = NodeModulesLinker(materializer: materializer);
      await linker.link(
        projectRoot: project.path,
        packages: [
          LinkSpec(
            name: 'react',
            version: '18.0.0',
            tarballSha512Hex: reactTarHash,
            dependencies: {'child': '1.0.0'},
            isDirect: true,
          ),
          LinkSpec(
            name: 'child',
            version: '1.0.0',
            tarballSha512Hex: childTarHash,
            dependencies: {},
          ),
        ],
      );

      // top-level symlink resolves to react package files
      final reactPkgJson = await File(
        p.join(project.path, 'node_modules', 'react', 'package.json'),
      ).readAsString();
      expect(reactPkgJson, contains('"react"'));

      // sibling dep is symlinked under react's private node_modules
      final childThroughReact = await File(
        p.join(
          project.path,
          'node_modules',
          '.knot',
          'react@18.0.0',
          'node_modules',
          'child',
          'package.json',
        ),
      ).readAsString();
      expect(childThroughReact, contains('"child"'));
      await pool.dispose();
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
