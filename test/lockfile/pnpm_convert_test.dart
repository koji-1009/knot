import 'package:knot/src/lockfile/pnpm_convert.dart';
import 'package:knot/src/lockfile/pnpm_reader.dart';
import 'package:knot/src/lockfile/pnpm_writer.dart';
import 'package:knot/src/lockfile/schema.dart';
import 'package:test/test.dart';

final _registry = Uri.parse('https://registry.npmjs.org/');

const _pnpm = r'''
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true
  excludeLinksFromLockfile: false

importers:
  .:
    dependencies:
      react:
        specifier: ^18.0.0
        version: 18.3.0
      '@babel/core':
        specifier: ^7.0.0
        version: 7.24.0
    devDependencies:
      react-dom:
        specifier: ^18.0.0
        version: 18.3.0

packages:
  react@18.3.0:
    resolution:
      integrity: sha512-react
    engines:
      node: '>=14'
    signatures:
      - keyid: SHA256:keyone
        sig: cmVhY3RzaWc=

  '@babel/core@7.24.0':
    resolution:
      integrity: sha512-babel
    hasBin: true

  react-dom@18.3.0:
    resolution:
      integrity: sha512-reactdom
    peerDependencies:
      react: ^18.0.0

snapshots:
  react@18.3.0:
    dependencies:
      loose-envify: 1.4.0

  '@babel/core@7.24.0':
    dependencies:
      loose-envify: 1.4.0

  react-dom@18.3.0(react@18.3.0):
    dependencies:
      react: 18.3.0
      loose-envify: 1.4.0
''';

void main() {
  group('pnpmToLockfile', () {
    final lock = pnpmToLockfile(parsePnpmLockfile(_pnpm), registry: _registry);

    test('importer keeps the declared specifier as the range', () {
      final importer = lock.importers['.']!;
      expect(importer.dependencies['react'], '^18.0.0');
      expect(importer.dependencies['@babel/core'], '^7.0.0');
      expect(importer.devDependencies['react-dom'], '^18.0.0');
    });

    test('reconstructs the registry tarball URL', () {
      expect(
        lock.packages['react@18.3.0']!.resolution.tarball,
        'https://registry.npmjs.org/react/-/react-18.3.0.tgz',
      );
    });

    test('scoped name keeps the scope in the path, drops it in the file', () {
      expect(
        lock.packages['@babel/core@7.24.0']!.resolution.tarball,
        'https://registry.npmjs.org/@babel/core/-/core-7.24.0.tgz',
      );
    });

    test('carries integrity, engines, hasBin', () {
      final react = lock.packages['react@18.3.0']!;
      expect(react.integrity, 'sha512-react');
      expect(react.engines['node'], '>=14');
      expect(lock.packages['@babel/core@7.24.0']!.hasBin, isTrue);
    });

    test('takes resolved dependency edges from the snapshot', () {
      expect(
        lock.packages['react@18.3.0']!.dependencies['loose-envify'],
        '1.4.0',
      );
    });

    test('collapses a peer-suffixed snapshot onto the base package', () {
      final reactDom = lock.packages['react-dom@18.3.0']!;
      expect(reactDom.dependencies['react'], '18.3.0');
      expect(reactDom.peerDependencies['react'], '^18.0.0');
    });

    test('parses dist signatures', () {
      final sigs = lock.packages['react@18.3.0']!.signatures;
      expect(sigs, hasLength(1));
      expect(sigs.first.keyid, 'SHA256:keyone');
      expect(sigs.first.sig, 'cmVhY3RzaWc=');
    });
  });

  group('lockfileToPnpm', () {
    final internal = Lockfile(
      lockfileVersion: knotLockfileVersion,
      importers: {
        '.': const Importer(
          dependencies: {'react': '^18.0.0'},
          devDependencies: {'react-dom': '^18.0.0'},
        ),
      },
      packages: {
        'react@18.3.0': const LockedPackage(
          name: 'react',
          version: '18.3.0',
          resolution: Resolution.tarball(
            tarball: 'https://registry.npmjs.org/react/-/react-18.3.0.tgz',
          ),
          integrity: 'sha512-react',
          dependencies: {'loose-envify': '^1.1.0'},
          engines: {'node': '>=14'},
          signatures: [
            LockedSignature(keyid: 'SHA256:keyone', sig: 'cmVhY3RzaWc='),
          ],
        ),
        'react-dom@18.3.0': const LockedPackage(
          name: 'react-dom',
          version: '18.3.0',
          resolution: Resolution.tarball(tarball: 'x'),
          integrity: 'sha512-reactdom',
          dependencies: {'react': '^18.0.0', 'loose-envify': '^1.1.0'},
          peerDependencies: {'react': '^18.0.0'},
        ),
        'loose-envify@1.4.0': const LockedPackage(
          name: 'loose-envify',
          version: '1.4.0',
          resolution: Resolution.tarball(tarball: 'y'),
          integrity: 'sha512-loose',
        ),
      },
    );
    final pnpm = lockfileToPnpm(internal);

    test('importer carries specifier + resolved version', () {
      final dep = pnpm.importers['.']!.dependencies['react']!;
      expect(dep.specifier, '^18.0.0');
      expect(dep.version, '18.3.0');
    });

    test('resolves snapshot edges to installed versions, not ranges', () {
      final snap = pnpm.snapshots['react-dom@18.3.0']!;
      // `^18.0.0` and `^1.1.0` resolve to the single installed versions.
      expect(snap.dependencies['react'], '18.3.0');
      expect(snap.dependencies['loose-envify'], '1.4.0');
    });

    test('emits integrity in the resolution map', () {
      expect(
        pnpm.packages['react@18.3.0']!.resolution['integrity'],
        'sha512-react',
      );
    });

    test('round-trips through the writer + reader', () {
      final reparsed = parsePnpmLockfile(writePnpmLockfileString(pnpm));
      expect(reparsed.importers['.']!.dependencies['react']!.version, '18.3.0');
      expect(
        reparsed.packages['react@18.3.0']!.resolution['integrity'],
        'sha512-react',
      );
      expect(
        reparsed.snapshots['react-dom@18.3.0']!.dependencies['react'],
        '18.3.0',
      );
    });
  });

  test('pnpm → internal → pnpm preserves resolved edges + integrity', () {
    final internal = pnpmToLockfile(
      parsePnpmLockfile(_pnpm),
      registry: _registry,
    );
    final back = lockfileToPnpm(internal);
    expect(
      back.packages['react@18.3.0']!.resolution['integrity'],
      'sha512-react',
    );
    expect(back.importers['.']!.dependencies['react']!.version, '18.3.0');
    // loose-envify was a transitive edge with no package entry of its own
    // in the fixture, so it has no version mapping and drops out — exactly
    // pnpm's "snapshots list only materialized edges" rule.
    expect(
      back.snapshots['react@18.3.0']!.dependencies.containsKey('loose-envify'),
      isFalse,
    );
  });
}
