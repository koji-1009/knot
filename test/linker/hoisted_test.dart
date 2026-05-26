import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/linker/linker.dart';
import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

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

void main() {
  test(
    'hoisted layout puts packages directly under node_modules/<name>',
    () async {
      final tmp = await Directory.systemTemp.createTemp('knot_hoisted_test_');
      try {
        final store = Store(p.join(tmp.path, 'store'));

        final reactTarHash = 'react-hoisted-hash';
        final reactTar = await _buildTar([
          ('package/package.json', '{"name":"react","version":"18.0.0"}'),
          ('package/index.js', 'module.exports = "react";'),
        ]);
        await store.ingestTarball(
          bytes: reactTar,
          tarballSha512Hex: reactTarHash,
        );

        final lodashTarHash = 'lodash-hoisted-hash';
        final lodashTar = await _buildTar([
          ('package/package.json', '{"name":"lodash","version":"4.17.21"}'),
          ('package/lodash.js', 'module.exports = {};'),
        ]);
        await store.ingestTarball(
          bytes: lodashTar,
          tarballSha512Hex: lodashTarHash,
        );

        final project = await Directory(p.join(tmp.path, 'project')).create();
        final pool = await WorkerPool.spawn(size: 2);
        final materializer = StoreMaterializer.forPlatform(
          store,
          workerPool: pool,
        );
        final linker = HoistedLinker(materializer: materializer);
        await linker.link(
          projectRoot: project.path,
          packages: [
            LinkSpec(
              name: 'react',
              version: '18.0.0',
              tarballSha512Hex: reactTarHash,
              dependencies: {},
              isDirect: true,
            ),
            LinkSpec(
              name: 'lodash',
              version: '4.17.21',
              tarballSha512Hex: lodashTarHash,
              dependencies: {},
              isDirect: false,
            ),
          ],
        );

        // No .knot directory in hoisted mode — everything is flat.
        expect(
          Directory(p.join(project.path, 'node_modules', '.knot')).existsSync(),
          isFalse,
          reason: 'hoisted linker must not create .knot/',
        );

        final reactPkg = await File(
          p.join(project.path, 'node_modules', 'react', 'package.json'),
        ).readAsString();
        expect(reactPkg, contains('"react"'));

        final lodashPkg = await File(
          p.join(project.path, 'node_modules', 'lodash', 'package.json'),
        ).readAsString();
        expect(lodashPkg, contains('"lodash"'));
        await pool.dispose();
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );

  test(
    'hoisted nests a conflicting version at its resolver-assigned path',
    () async {
      // Multi-version model: the tree resolver hoists one version of a
      // name and nests the conflicting one under its requirer (via
      // `installPath`). The linker places each at its path — both
      // versions coexist, exactly as npm installs them.
      final tmp = await Directory.systemTemp.createTemp('knot_hoisted_conf_');
      try {
        final store = Store(p.join(tmp.path, 'store'));

        final v1Hash = 'lodash-1-hash';
        await store.ingestTarball(
          bytes: await _buildTar([
            ('package/package.json', '{"name":"lodash","version":"3.0.0"}'),
          ]),
          tarballSha512Hex: v1Hash,
        );
        final v2Hash = 'lodash-2-hash';
        await store.ingestTarball(
          bytes: await _buildTar([
            ('package/package.json', '{"name":"lodash","version":"4.17.21"}'),
          ]),
          tarballSha512Hex: v2Hash,
        );
        final consumerHash = 'consumer-hash';
        await store.ingestTarball(
          bytes: await _buildTar([
            ('package/package.json', '{"name":"consumer","version":"1.0.0"}'),
          ]),
          tarballSha512Hex: consumerHash,
        );

        final project = await Directory(p.join(tmp.path, 'project')).create();
        final pool = await WorkerPool.spawn(size: 2);
        final materializer = StoreMaterializer.forPlatform(
          store,
          workerPool: pool,
        );
        final linker = HoistedLinker(materializer: materializer);
        await linker.link(
          projectRoot: project.path,
          packages: [
            LinkSpec(
              name: 'consumer',
              version: '1.0.0',
              tarballSha512Hex: consumerHash,
              dependencies: {'lodash': '3.0.0'},
              isDirect: true,
            ),
            // lodash@4 hoisted to the top level.
            LinkSpec(
              name: 'lodash',
              version: '4.17.21',
              tarballSha512Hex: v2Hash,
              dependencies: {},
            ),
            // lodash@3 nested under consumer (incompatible with the
            // hoisted v4).
            LinkSpec(
              name: 'lodash',
              version: '3.0.0',
              tarballSha512Hex: v1Hash,
              dependencies: {},
              installPath: 'consumer/node_modules/lodash',
            ),
          ],
        );

        final top = await File(
          p.join(project.path, 'node_modules', 'lodash', 'package.json'),
        ).readAsString();
        expect(top, contains('4.17.21'), reason: 'v4 hoisted to top level');

        final nested = await File(
          p.join(
            project.path,
            'node_modules',
            'consumer',
            'node_modules',
            'lodash',
            'package.json',
          ),
        ).readAsString();
        expect(
          nested,
          contains('3.0.0'),
          reason: 'v3 nested under its requirer — both versions coexist',
        );
        await pool.dispose();
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );
}
