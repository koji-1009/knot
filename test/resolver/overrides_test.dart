import 'package:knot/src/cli/package_json.dart';
import 'package:knot/src/resolver/resolver.dart';
import 'package:knot/src/semver/semver.dart';
import 'package:test/test.dart';

void main() {
  PackageDependencies pd(Map<String, String> deps) =>
      PackageDependencies(dependencies: deps);

  group('flat overrides (applies-everywhere)', () {
    test('flat override forces a specific version', () async {
      final provider = InMemoryProvider({
        'a': {
          '1.0.0': pd({'shared': '^1.0.0'}),
        },
        'shared': {'1.0.0': pd({}), '1.5.0': pd({}), '2.0.0': pd({})},
      });
      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: {'a': '^1.0.0'},
          provider: provider,
          overrides: {'shared': '1.0.0'},
        ),
      );
      final result = await solver.solve();
      expect(result.assignments['shared'], parseVersion('1.0.0'));
    });
  });

  group('nested overrides (parent > child)', () {
    test('only the child of the specified parent is rewritten', () async {
      final provider = InMemoryProvider({
        // a's transitive shared should be pinned to 1.0.0.
        // b's transitive shared keeps the latest matching.
        'a': {
          '1.0.0': pd({'shared': '^1.0.0'}),
        },
        'b': {
          '1.0.0': pd({'shared': '^1.0.0'}),
        },
        'shared': {'1.0.0': pd({}), '1.5.0': pd({}), '2.0.0': pd({})},
      });
      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: {'a': '^1.0.0', 'b': '^1.0.0'},
          provider: provider,
          nestedOverrides: {
            'a': {'shared': '1.0.0'},
          },
        ),
      );
      // We only have one final version per package in the flat solver,
      // and the constraint intersection picks the strictest. Since
      // a > shared is pinned 1.0.0 and b > shared accepts ^1.0.0,
      // the intersection is exactly 1.0.0.
      final result = await solver.solve();
      expect(result.assignments['shared'], parseVersion('1.0.0'));
    });

    test('non-matching parent leaves child untouched', () async {
      final provider = InMemoryProvider({
        'a': {
          '1.0.0': pd({'shared': '^1.0.0'}),
        },
        'shared': {'1.0.0': pd({}), '1.5.0': pd({})},
      });
      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: {'a': '^1.0.0'},
          provider: provider,
          nestedOverrides: {
            'other': {'shared': '1.0.0'},
          },
        ),
      );
      final result = await solver.solve();
      expect(result.assignments['shared'], parseVersion('1.5.0'));
    });
  });

  group('package.json override parser', () {
    test('flat string override', () {
      final pkg = PackageJson.fromJson({
        'name': 'demo',
        'version': '0.0.0',
        'overrides': {'foo': '1.0.0'},
      });
      expect(pkg.overrides, {'foo': '1.0.0'});
      expect(pkg.nestedOverrides, isEmpty);
    });

    test('a > b nested string syntax', () {
      final pkg = PackageJson.fromJson({
        'name': 'demo',
        'version': '0.0.0',
        'overrides': {'foo>bar': '2.0.0'},
      });
      expect(pkg.nestedOverrides, {
        'foo': {'bar': '2.0.0'},
      });
    });

    test('object nested syntax with . and child', () {
      final pkg = PackageJson.fromJson({
        'name': 'demo',
        'version': '0.0.0',
        'overrides': {
          'foo': {'.': '1.5.0', 'bar': '2.0.0'},
        },
      });
      expect(pkg.overrides, {'foo': '1.5.0'});
      expect(pkg.nestedOverrides, {
        'foo': {'bar': '2.0.0'},
      });
    });
  });
}
