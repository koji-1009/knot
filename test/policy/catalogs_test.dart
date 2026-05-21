import 'package:knot/src/policy/catalogs.dart';
import 'package:test/test.dart';

void main() {
  group('parseCatalogMode', () {
    test('default is manual', () {
      expect(parseCatalogMode(null), CatalogMode.manual);
      expect(parseCatalogMode(''), CatalogMode.manual);
    });

    test('round-trips the three explicit values', () {
      expect(parseCatalogMode('manual'), CatalogMode.manual);
      expect(parseCatalogMode('strict'), CatalogMode.strict);
      expect(parseCatalogMode('prefer'), CatalogMode.prefer);
    });

    test('unknown value throws', () {
      expect(() => parseCatalogMode('aggressive'), throwsFormatException);
    });
  });

  group('CatalogSet.fromConfig', () {
    test('shortForm populates the default catalog', () {
      final set = CatalogSet.fromConfig(
        shortForm: const {'react': '^18.0.0', 'lodash': '^4.0.0'},
      );
      expect(set.lookup(packageName: 'react'), '^18.0.0');
      expect(set.lookup(packageName: 'lodash'), '^4.0.0');
    });

    test('namedForm populates each named catalog', () {
      final set = CatalogSet.fromConfig(
        namedForm: const {
          'ui': {'react': '^18.0.0'},
          'cli': {'commander': '^12.0.0'},
        },
      );
      expect(
        set.lookup(catalogName: 'ui', packageName: 'react'),
        '^18.0.0',
      );
      expect(
        set.lookup(catalogName: 'cli', packageName: 'commander'),
        '^12.0.0',
      );
    });

    test('missing lookup returns null', () {
      final set = CatalogSet.fromConfig(shortForm: const {'a': '1.0.0'});
      expect(set.lookup(packageName: 'missing'), isNull);
      expect(set.lookup(catalogName: 'nope', packageName: 'a'), isNull);
    });
  });

  group('CatalogReference.tryParse', () {
    test('plain "catalog:" returns the default reference', () {
      final ref = CatalogReference.tryParse('catalog:');
      expect(ref, isNotNull);
      expect(ref!.name, defaultCatalogName);
    });

    test('named form returns the explicit name', () {
      final ref = CatalogReference.tryParse('catalog:ui');
      expect(ref!.name, 'ui');
    });

    test('non-catalog spec returns null', () {
      expect(CatalogReference.tryParse('^1.0.0'), isNull);
      expect(CatalogReference.tryParse('workspace:*'), isNull);
      expect(CatalogReference.tryParse('catalogue:'), isNull);
    });
  });

  group('resolveCatalogReference', () {
    final catalogs = CatalogSet.fromConfig(
      shortForm: const {'react': '^18.0.0'},
      namedForm: const {
        'ui': {'react': '^17.0.0'},
      },
    );

    test('default reference picks the default catalog', () {
      final ref = CatalogReference.tryParse('catalog:')!;
      expect(
        resolveCatalogReference(
          reference: ref,
          catalogs: catalogs,
          packageName: 'react',
        ),
        '^18.0.0',
      );
    });

    test('named reference picks the named catalog', () {
      final ref = CatalogReference.tryParse('catalog:ui')!;
      expect(
        resolveCatalogReference(
          reference: ref,
          catalogs: catalogs,
          packageName: 'react',
        ),
        '^17.0.0',
      );
    });

    test('missing entry returns null', () {
      final ref = CatalogReference.tryParse('catalog:')!;
      expect(
        resolveCatalogReference(
          reference: ref,
          catalogs: catalogs,
          packageName: 'vue',
        ),
        isNull,
      );
    });
  });
}
