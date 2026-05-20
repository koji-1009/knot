import 'package:knot/src/core/core.dart';
import 'package:knot/src/resolver/resolver.dart';
import 'package:knot/src/semver/semver.dart';
import 'package:test/test.dart';

PackageDependencies _pd(Map<String, String> deps) =>
    PackageDependencies(dependencies: deps);

void main() {
  group('PubgrubSolver simple chains', () {
    test('resolves a simple chain', () async {
      final provider = InMemoryProvider({
        'react': {
          '18.2.0': _pd({'loose-envify': '^1.0.0'}),
        },
        'loose-envify': {
          '1.4.0': _pd({'js-tokens': '^4.0.0'}),
        },
        'js-tokens': {'4.0.0': _pd({})},
      });
      final solver = PubgrubSolver(
        SolverRequest(dependencies: {'react': '^18.0.0'}, provider: provider),
      );
      final result = await solver.solve();
      expect(result.assignments['react'], parseVersion('18.2.0'));
      expect(result.assignments['loose-envify'], parseVersion('1.4.0'));
      expect(result.assignments['js-tokens'], parseVersion('4.0.0'));
    });

    test('intersects multiple range constraints', () async {
      final provider = InMemoryProvider({
        'a': {
          '1.0.0': _pd({'shared': '^1.0.0'}),
        },
        'b': {
          '1.0.0': _pd({'shared': '>=1.2.0 <2.0.0'}),
        },
        'shared': {
          '1.0.0': _pd({}),
          '1.2.0': _pd({}),
          '1.5.0': _pd({}),
          '2.0.0': _pd({}),
        },
      });
      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: {'a': '^1.0.0', 'b': '^1.0.0'},
          provider: provider,
        ),
      );
      final result = await solver.solve();
      expect(result.assignments['shared'], parseVersion('1.5.0'));
    });

    test('honors flat overrides', () async {
      final provider = InMemoryProvider({
        'a': {
          '1.0.0': _pd({'shared': '^1.0.0'}),
        },
        'shared': {'1.0.0': _pd({}), '1.5.0': _pd({})},
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

  group('PubgrubSolver failure cases', () {
    test('throws ResolutionError on no satisfying version', () async {
      final provider = InMemoryProvider({
        'a': {'1.0.0': _pd({})},
      });
      final solver = PubgrubSolver(
        SolverRequest(dependencies: {'a': '^99.0.0'}, provider: provider),
      );
      expect(solver.solve(), throwsA(isA<ResolutionError>()));
    });

    test('throws when transitive deps conflict on a shared package', () async {
      final provider = InMemoryProvider({
        'a': {
          '1.0.0': _pd({'shared': '^1.0.0'}),
        },
        'b': {
          '1.0.0': _pd({'shared': '^2.0.0'}),
        },
        'shared': {'1.0.0': _pd({}), '2.0.0': _pd({})},
      });
      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: {'a': '^1.0.0', 'b': '^1.0.0'},
          provider: provider,
        ),
      );
      await expectLater(solver.solve(), throwsA(isA<ResolutionError>()));
    });
  });

  group('PubgrubSolver decision priority', () {
    test('packages with fewer viable versions get decided first', () async {
      // shared has many versions but constrained to a single point by a.
      // We can't directly observe order, but the solver must pick a value
      // consistent with both constraints.
      final provider = InMemoryProvider({
        'a': {
          '1.0.0': _pd({'shared': '1.5.0'}),
        },
        'b': {
          '1.0.0': _pd({'shared': '^1.0.0'}),
        },
        'shared': {'1.0.0': _pd({}), '1.5.0': _pd({}), '1.9.0': _pd({})},
      });
      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: {'a': '^1.0.0', 'b': '^1.0.0'},
          provider: provider,
        ),
      );
      final result = await solver.solve();
      expect(result.assignments['shared'], parseVersion('1.5.0'));
    });
  });
}
