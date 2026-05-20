import 'package:knot/src/core/core.dart';
import 'package:knot/src/resolver/resolver.dart';
import 'package:knot/src/semver/semver.dart';
import 'package:test/test.dart';

void main() {
  PackageDependencies pd(Map<String, String> deps) =>
      PackageDependencies(dependencies: deps);

  test('resolves a simple chain', () async {
    final provider = InMemoryProvider({
      'react': {
        '18.2.0': pd({'loose-envify': '^1.0.0'}),
        '17.0.2': pd({'loose-envify': '^1.0.0'}),
      },
      'loose-envify': {
        '1.4.0': pd({'js-tokens': '^4.0.0'}),
      },
      'js-tokens': {'4.0.0': pd({})},
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
        '1.0.0': pd({'shared': '^1.0.0'}),
      },
      'b': {
        '1.0.0': pd({'shared': '>=1.2.0 <2.0.0'}),
      },
      'shared': {
        '1.0.0': pd({}),
        '1.2.0': pd({}),
        '1.5.0': pd({}),
        '2.0.0': pd({}),
      },
    });
    final solver = PubgrubSolver(
      SolverRequest(
        dependencies: {'a': '^1.0.0', 'b': '^1.0.0'},
        provider: provider,
      ),
    );
    final result = await solver.solve();
    // shared must be >=1.2.0 <2.0.0 ∩ ^1.0.0 = >=1.2.0 <2.0.0 → pick 1.5.0
    expect(result.assignments['shared'], parseVersion('1.5.0'));
  });

  test('throws ResolutionError when no version satisfies', () async {
    final provider = InMemoryProvider({
      'a': {
        '1.0.0': pd({'shared': '^1.0.0'}),
      },
      'b': {
        '1.0.0': pd({'shared': '^2.0.0'}),
      },
      'shared': {'1.0.0': pd({}), '2.0.0': pd({})},
    });
    final solver = PubgrubSolver(
      SolverRequest(
        dependencies: {'a': '^1.0.0', 'b': '^1.0.0'},
        provider: provider,
      ),
    );
    expect(solver.solve(), throwsA(isA<ResolutionError>()));
  });

  test('prefers locked version when within range', () async {
    final provider = InMemoryProvider({
      'react': {'18.0.0': pd({}), '18.1.0': pd({}), '18.2.0': pd({})},
    });
    final solver = PubgrubSolver(
      SolverRequest(
        dependencies: {'react': '^18.0.0'},
        provider: provider,
        preferred: {'react': parseVersion('18.1.0')},
      ),
    );
    final result = await solver.solve();
    expect(result.assignments['react'], parseVersion('18.1.0'));
  });
}
