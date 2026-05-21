import 'package:knot/src/cli/commands/sbom_command.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:test/test.dart';

Lockfile _lock(Map<String, LockedPackage> packages, {Map<String, Importer> importers = const {}}) =>
    Lockfile(
      lockfileVersion: 1,
      importers: importers,
      packages: packages,
    );

LockedPackage _pkg(String name, String version, {String? integrity}) =>
    LockedPackage(
      name: name,
      version: version,
      resolution: const Resolution.tarball(tarball: 'x'),
      integrity: integrity,
    );

void main() {
  group('generateCycloneDx', () {
    test('emits CycloneDX 1.7 envelope with sorted components', () {
      final lock = _lock({
        'react': _pkg('react', '18.3.0', integrity: 'sha512-aaa'),
        'lodash': _pkg('lodash', '4.17.21', integrity: 'sha512-bbb'),
      });
      final doc = generateCycloneDx(
        lock,
        filter: const SbomFilter(),
        bomType: 'library',
        specVersion: '1.7',
      );
      expect(doc['bomFormat'], 'CycloneDX');
      expect(doc['specVersion'], '1.7');
      final components = doc['components'] as List;
      expect(components, hasLength(2));
      // alphabetical purl order: lodash before react
      expect(
        (components.first as Map)['name'],
        'lodash',
      );
      final purl = (components.first as Map)['purl'] as String;
      expect(purl, 'pkg:npm/lodash@4.17.21');
    });

    test('purl encodes scoped names', () {
      final lock = _lock({
        '@types/node': _pkg('@types/node', '22.0.0'),
      });
      final doc = generateCycloneDx(
        lock,
        filter: const SbomFilter(),
        bomType: 'library',
        specVersion: '1.7',
      );
      final purl = ((doc['components'] as List).first as Map)['purl'];
      expect(purl, 'pkg:npm/%40types/node@22.0.0');
    });

    test('serial is stable across runs', () {
      final lock = _lock({'a': _pkg('a', '1.0.0', integrity: 'sha512-x')});
      final a = generateCycloneDx(
        lock,
        filter: const SbomFilter(),
        bomType: 'library',
        specVersion: '1.7',
      );
      final b = generateCycloneDx(
        lock,
        filter: const SbomFilter(),
        bomType: 'library',
        specVersion: '1.7',
      );
      expect(a['serialNumber'], b['serialNumber']);
    });
  });

  group('generateSpdx', () {
    test('emits SPDX 2.3 envelope and purl externalRef', () {
      final lock = _lock({
        'react': _pkg('react', '18.3.0', integrity: 'sha512-aaa'),
      });
      final doc = generateSpdx(
        lock,
        filter: const SbomFilter(),
        specVersion: 'SPDX-2.3',
      );
      expect(doc['spdxVersion'], 'SPDX-2.3');
      final packages = doc['packages'] as List;
      expect(packages, hasLength(1));
      final pkg = packages.first as Map;
      expect(pkg['name'], 'react');
      final refs = pkg['externalRefs'] as List;
      expect(
        (refs.first as Map)['referenceLocator'],
        'pkg:npm/react@18.3.0',
      );
    });
  });

  group('SbomFilter', () {
    test('prodOnly limits to dependencies only', () {
      final lock = _lock(
        {
          'a': _pkg('a', '1.0.0'),
          'b': _pkg('b', '1.0.0'),
        },
        importers: const {
          '.': Importer(
            dependencies: {'a': '^1'},
            devDependencies: {'b': '^1'},
          ),
        },
      );
      final doc = generateCycloneDx(
        lock,
        filter: const SbomFilter(prodOnly: true),
        bomType: 'library',
        specVersion: '1.7',
      );
      final components = doc['components'] as List;
      expect(components, hasLength(1));
      expect((components.first as Map)['name'], 'a');
    });
  });
}
