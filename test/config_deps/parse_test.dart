import 'package:knot/src/config_deps/config_dependencies.dart';
import 'package:test/test.dart';

void main() {
  group('parseConfigDependencies', () {
    test('shorthand name → version', () {
      final deps = parseConfigDependencies({
        'eslint-config-airbnb': '19.0.4',
        'prettier-config-knot': '1.0.0',
      });
      expect(deps, hasLength(2));
      expect(deps.first.name, 'eslint-config-airbnb');
      expect(deps.first.version, '19.0.4');
    });

    test('object form { version: "..." }', () {
      final deps = parseConfigDependencies({
        'shared-tsconfig': {'version': '2.0.0'},
      });
      expect(deps.single.name, 'shared-tsconfig');
      expect(deps.single.version, '2.0.0');
    });

    test('skips entries with missing version', () {
      final deps = parseConfigDependencies({
        'broken': {'notVersion': '1.0.0'},
        'empty': '',
        'ok': '1.0.0',
      });
      expect(deps.map((d) => d.name), ['ok']);
    });

    test('non-map input returns empty list', () {
      expect(parseConfigDependencies(null), isEmpty);
      expect(parseConfigDependencies('string'), isEmpty);
    });
  });

  group('configDependenciesRoot', () {
    test('lives under node_modules/.knot-config', () {
      expect(
        configDependenciesRoot('/proj'),
        endsWith('node_modules/.knot-config'),
      );
    });
  });
}
