import 'package:knot/src/lockfile/pnpm_reader.dart';
import 'package:knot/src/lockfile/pnpm_writer.dart';
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

packages:
  react@18.3.0:
    resolution:
      integrity: sha512-aaaaaa
    engines:
      node: '>=14'

snapshots:
  react@18.3.0:
    dependencies:
      loose-envify: 1.4.0

catalog:
  react: ^18.0.0

runtimeOnFail: download
nodeDownloadMirrors:
  - https://example.com/node
''';

void main() {
  group('writePnpmLockfileString', () {
    test('roundtrip preserves logical content', () {
      final original = parsePnpmLockfile(_basic);
      final emitted = writePnpmLockfileString(original);
      final reparsed = parsePnpmLockfile(emitted);

      expect(reparsed.lockfileVersion, original.lockfileVersion);
      expect(reparsed.settings, original.settings);

      expect(
        reparsed.importers['.']!.dependencies['react']!.version,
        '18.3.0',
      );
      expect(reparsed.packages['react@18.3.0']!.engines['node'], '>=14');
      expect(
        reparsed.snapshots['react@18.3.0']!.dependencies['loose-envify'],
        '1.4.0',
      );
      expect(reparsed.catalogs['default']!['react'], '^18.0.0');
      expect(reparsed.preservedTopLevel['runtimeOnFail'], 'download');
      expect(
        reparsed.preservedTopLevel['nodeDownloadMirrors'],
        ['https://example.com/node'],
      );
    });

    test('quoted package id keys survive roundtrip', () {
      const yaml = '''
lockfileVersion: '9.0'
importers: {}
packages:
  '@types/node@22.0.0':
    resolution:
      integrity: sha512-xxx
''';
      final original = parsePnpmLockfile(yaml);
      final emitted = writePnpmLockfileString(original);
      final reparsed = parsePnpmLockfile(emitted);
      expect(reparsed.packages.containsKey('@types/node@22.0.0'), isTrue);
    });
  });
}
