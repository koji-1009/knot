import 'package:knot/src/registry/registry.dart';
import 'package:test/test.dart';

void main() {
  test('parses minimal packument', () {
    final pkg = Packument.fromJson({
      'name': 'react',
      'dist-tags': {'latest': '18.2.0'},
      'versions': {
        '18.2.0': {
          'name': 'react',
          'version': '18.2.0',
          'dist': {
            'tarball': 'https://registry.npmjs.org/react/-/react-18.2.0.tgz',
            'integrity': 'sha512-abc',
          },
          'dependencies': {'loose-envify': '^1.1.0'},
        },
      },
    });
    expect(pkg.name, 'react');
    expect(pkg.latest, '18.2.0');
    expect(pkg.versions['18.2.0']!.integrity, 'sha512-abc');
    expect(pkg.versions['18.2.0']!.dependencies['loose-envify'], '^1.1.0');
  });

  test('tolerates missing fields', () {
    final pkg = Packument.fromJson({'name': 'x'});
    expect(pkg.versions, isEmpty);
    expect(pkg.latest, isNull);
  });
}
