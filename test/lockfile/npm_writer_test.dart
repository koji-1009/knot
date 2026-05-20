import 'dart:convert';
import 'dart:io';

import 'package:knot/src/lockfile/lockfile.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

Lockfile _fixture({
  Map<String, LockedPackage> packages = const {},
  Importer? root,
}) {
  return Lockfile(
    lockfileVersion: 1,
    importers: {
      '.': root ?? const Importer(dependencies: {'react': '^18'}),
    },
    packages: packages,
  );
}

void main() {
  group('writeNpmLockfileToString', () {
    test('emits npm v3 shape: lockfileVersion 3, packages keyed by path', () {
      final lock = _fixture(
        packages: {
          'react@18.3.1': LockedPackage(
            name: 'react',
            version: '18.3.1',
            resolution: Resolution.tarball(
              tarball: 'https://registry.npmjs.org/react/-/react-18.3.1.tgz',
            ),
            integrity: 'sha512-abc',
            dependencies: const {'loose-envify': '^1.1.0'},
          ),
        },
      );
      final body = writeNpmLockfileToString(
        lock,
        projectName: 'demo',
        projectVersion: '1.0.0',
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['lockfileVersion'], 3);
      expect(json['name'], 'demo');
      expect(json['requires'], true);
      final pkgs = json['packages'] as Map<String, dynamic>;
      final rootEntry = pkgs[''] as Map<String, dynamic>;
      expect(rootEntry['name'], 'demo');
      expect(rootEntry['dependencies'], {'react': '^18'});
      final react = pkgs['node_modules/react'] as Map<String, dynamic>;
      expect(react['version'], '18.3.1');
      expect(react['integrity'], 'sha512-abc');
      expect(
        react['resolved'],
        'https://registry.npmjs.org/react/-/react-18.3.1.tgz',
      );
      expect(react['dependencies'], {'loose-envify': '^1.1.0'});
    });

    test('sorts packages alphabetically for deterministic output', () {
      final lock = _fixture(
        packages: {
          'z-pkg@1.0.0': LockedPackage(
            name: 'z-pkg',
            version: '1.0.0',
            resolution: const Resolution.tarball(tarball: 'https://x/z.tgz'),
            integrity: 'sha512-z',
          ),
          'a-pkg@1.0.0': LockedPackage(
            name: 'a-pkg',
            version: '1.0.0',
            resolution: const Resolution.tarball(tarball: 'https://x/a.tgz'),
            integrity: 'sha512-a',
          ),
        },
      );
      final body = writeNpmLockfileToString(lock, projectName: 'demo');
      final aIdx = body.indexOf('"node_modules/a-pkg"');
      final zIdx = body.indexOf('"node_modules/z-pkg"');
      expect(aIdx, lessThan(zIdx));
    });

    test(
      'serializes hasInstallScript + bin + engines + os/cpu + knot extensions',
      () {
        final lock = _fixture(
          packages: {
            'esbuild@0.21.5': LockedPackage(
              name: 'esbuild',
              version: '0.21.5',
              resolution: const Resolution.tarball(
                tarball: 'https://x/esbuild.tgz',
              ),
              integrity: 'sha512-x',
              hasInstallScript: true,
              bin: const {'esbuild': 'bin/esbuild'},
              engines: const {'node': '>=12'},
              os: const ['darwin'],
              cpu: const ['arm64'],
              scripts: const {'postinstall': 'node install.js'},
              signatures: const [
                LockedSignature(keyid: 'SHA256:x', sig: 'MEUC...'),
              ],
            ),
          },
        );
        final body = writeNpmLockfileToString(lock, projectName: 'demo');
        final json = jsonDecode(body) as Map<String, dynamic>;
        final esbuild =
            (json['packages'] as Map)['node_modules/esbuild']
                as Map<String, dynamic>;
        expect(esbuild['hasInstallScript'], isTrue);
        expect(esbuild['bin'], {'esbuild': 'bin/esbuild'});
        expect(esbuild['engines'], {'node': '>=12'});
        expect(esbuild['os'], ['darwin']);
        expect(esbuild['cpu'], ['arm64']);
        expect(esbuild['_scripts'], {'postinstall': 'node install.js'});
        expect(esbuild['_signatures'], [
          {'keyid': 'SHA256:x', 'sig': 'MEUC...'},
        ]);
      },
    );

    test('importer block carries declared ranges, not resolved versions', () {
      final lock = _fixture(
        root: const Importer(
          dependencies: {'react': '^18.0.0'},
          devDependencies: {'vite': '^5.0.0'},
        ),
        packages: {
          'react@18.3.1': LockedPackage(
            name: 'react',
            version: '18.3.1',
            resolution: const Resolution.tarball(
              tarball: 'https://x/react.tgz',
            ),
            integrity: 'sha512-r',
          ),
        },
      );
      final body = writeNpmLockfileToString(lock, projectName: 'demo');
      final json = jsonDecode(body) as Map<String, dynamic>;
      final rootEntry = (json['packages'] as Map)[''] as Map<String, dynamic>;
      expect(rootEntry['dependencies'], {'react': '^18.0.0'});
      expect(rootEntry['devDependencies'], {'vite': '^5.0.0'});
    });

    test('ends with a single trailing newline (matches npm convention)', () {
      final body = writeNpmLockfileToString(_fixture(), projectName: 'demo');
      expect(body.endsWith('\n'), isTrue);
      expect(body.endsWith('\n\n'), isFalse);
    });
  });

  group('round trip via importNpmLockfile', () {
    test(
      'write → read preserves package set, integrity, knot extensions',
      () async {
        final lock = _fixture(
          packages: {
            'react@18.3.1': LockedPackage(
              name: 'react',
              version: '18.3.1',
              resolution: const Resolution.tarball(
                tarball: 'https://x/react.tgz',
              ),
              integrity: 'sha512-r',
              dependencies: const {'loose-envify': '^1'},
              engines: const {'node': '>=0.10.0'},
              scripts: const {'prepare': 'tsc'},
              signatures: const [LockedSignature(keyid: 'kid1', sig: 'sig1')],
            ),
          },
        );
        final body = writeNpmLockfileToString(lock, projectName: 'demo');
        await d.dir('proj', [d.file('package-lock.json', body)]).create();
        final path = p.join(d.sandbox, 'proj', 'package-lock.json');
        final round = await importNpmLockfile(path);
        final r = round.packages['react@18.3.1']!;
        expect(r.name, 'react');
        expect(r.version, '18.3.1');
        expect(r.integrity, 'sha512-r');
        expect(r.resolution.tarball, 'https://x/react.tgz');
        expect(r.dependencies, {'loose-envify': '^1'});
        expect(r.engines, {'node': '>=0.10.0'});
        expect(r.scripts, {'prepare': 'tsc'});
        expect(r.signatures, hasLength(1));
        expect(r.signatures.first.keyid, 'kid1');
        expect(round.importers['.']?.dependencies, {'react': '^18'});
      },
    );
  });

  group('writeProjectLockfile', () {
    test('creates package-lock.json', () async {
      await d.dir('proj').create();
      final root = p.join(d.sandbox, 'proj');
      final written = await writeProjectLockfile(
        projectRoot: root,
        lockfile: _fixture(),
        projectName: 'demo',
      );
      expect(written.path, p.join(root, 'package-lock.json'));
      expect(File(p.join(root, 'package-lock.json')).existsSync(), isTrue);
    });

    test('ignores pnpm-lock.yaml entirely — writes package-lock.json as if '
        'the repo had no lockfile, leaves the pnpm file untouched', () async {
      await d.dir('proj', [
        d.file('pnpm-lock.yaml', "lockfileVersion: '9.0'\nimporters: {}\n"),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final written = await writeProjectLockfile(
        projectRoot: root,
        lockfile: _fixture(),
        projectName: 'demo',
      );
      expect(written.path, p.join(root, 'package-lock.json'));
      expect(File(p.join(root, 'pnpm-lock.yaml')).existsSync(), isTrue);
      expect(File(p.join(root, 'package-lock.json')).existsSync(), isTrue);
    });
  });
}
