import 'package:knot/src/lockfile/pnpm_reader.dart';
import 'package:test/test.dart';

const _basic = r'''
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
    devDependencies:
      vitest:
        specifier: ^1.0.0
        version: 1.5.0

packages:
  react@18.3.0:
    resolution:
      integrity: sha512-aaaaaa
    engines:
      node: '>=14'

  vitest@1.5.0:
    resolution:
      integrity: sha512-bbbbbb
    hasBin: true
    deprecated: 'use the new release'

snapshots:
  react@18.3.0:
    dependencies:
      loose-envify: 1.4.0
  vitest@1.5.0:
    dependencies:
      foo: 1.0.0
    transitivePeerDependencies:
      - happy-dom

catalog:
  react: ^18.0.0

catalogs:
  ui:
    react: ^17.0.0
''';

void main() {
  group('parsePnpmLockfile', () {
    test('reads basic v9 lockfile', () {
      final lock = parsePnpmLockfile(_basic);
      expect(lock.lockfileVersion, '9.0');
      expect(lock.settings['autoInstallPeers'], isTrue);
      expect(lock.settings['excludeLinksFromLockfile'], isFalse);

      final root = lock.importers['.']!;
      expect(root.dependencies['react']!.specifier, '^18.0.0');
      expect(root.dependencies['react']!.version, '18.3.0');
      expect(root.devDependencies['vitest']!.version, '1.5.0');

      final react = lock.packages['react@18.3.0']!;
      expect(react.resolution['integrity'], 'sha512-aaaaaa');
      expect(react.engines['node'], '>=14');
      expect(react.hasBin, isFalse);

      final vitest = lock.packages['vitest@1.5.0']!;
      expect(vitest.hasBin, isTrue);
      expect(vitest.deprecated, 'use the new release');

      final snap = lock.snapshots['vitest@1.5.0']!;
      expect(snap.dependencies['foo'], '1.0.0');
      expect(snap.transitivePeerDependencies, ['happy-dom']);

      expect(lock.catalogs['default']!['react'], '^18.0.0');
      expect(lock.catalogs['ui']!['react'], '^17.0.0');
    });

    test('preserves unknown top-level fields', () {
      const yaml = '''
lockfileVersion: '9.0'
runtimeOnFail: download
packageManagerDependencies:
  knot:
    bin: knot
nodeDownloadMirrors:
  - https://example.com/node
unknownFutureField:
  hello: world
importers: {}
packages: {}
''';
      final lock = parsePnpmLockfile(yaml);
      expect(lock.preservedTopLevel['runtimeOnFail'], 'download');
      expect(lock.preservedTopLevel['nodeDownloadMirrors'], [
        'https://example.com/node',
      ]);
      expect(lock.preservedTopLevel['unknownFutureField'], {'hello': 'world'});
    });

    test('non-map root throws FormatException', () {
      expect(() => parsePnpmLockfile('- a\n- b\n'), throwsFormatException);
    });
  });
}
