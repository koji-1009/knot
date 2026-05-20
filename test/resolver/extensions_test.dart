import 'package:knot/src/resolver/resolver.dart';
import 'package:knot/src/semver/semver.dart';
import 'package:test/test.dart';

void main() {
  PackageDependencies pd({
    Map<String, String> deps = const {},
    Map<String, String> optional = const {},
    Map<String, String> peer = const {},
    Set<String> optionalPeers = const {},
  }) => PackageDependencies(
    dependencies: deps,
    optionalDependencies: optional,
    peerDependencies: peer,
    optionalPeers: optionalPeers,
  );

  test('autoInstallPeers brings peer deps into the graph', () async {
    final provider = InMemoryProvider({
      'use-react': {
        '1.0.0': pd(peer: {'react': '^18.0.0'}),
      },
      'react': {'18.2.0': pd()},
    });
    final solver = PubgrubSolver(
      SolverRequest(dependencies: {'use-react': '^1.0.0'}, provider: provider),
    );
    final result = await solver.solve();
    expect(result.assignments['react'], parseVersion('18.2.0'));
  });

  test('peer warnings issued when autoInstallPeers=false', () async {
    final provider = InMemoryProvider({
      'use-react': {
        '1.0.0': pd(peer: {'react': '^18.0.0'}),
      },
      'react': {'18.2.0': pd()},
    });
    final solver = PubgrubSolver(
      SolverRequest(
        dependencies: {'use-react': '^1.0.0'},
        provider: provider,
        autoInstallPeers: false,
      ),
    );
    final result = await solver.solve();
    expect(result.assignments.containsKey('react'), isFalse);
    expect(solver.warnings, isNotEmpty);
    expect(solver.warnings.first, contains('react'));
  });

  test('optional deps are non-fatal on miss', () async {
    final provider = InMemoryProvider({
      'tool': {
        '1.0.0': pd(optional: {'native-addon': '^2.0.0'}),
      },
      // intentionally no native-addon entry
    });
    final solver = PubgrubSolver(
      SolverRequest(dependencies: {'tool': '^1.0.0'}, provider: provider),
    );
    final result = await solver.solve();
    expect(result.assignments['tool'], parseVersion('1.0.0'));
    expect(result.assignments.containsKey('native-addon'), isFalse);
  });

  test('peerDependenciesMeta.optional peers are not force-installed', () async {
    final provider = InMemoryProvider({
      // Mirrors vite's shape: declares CSS-preprocessor peers as
      // {optional: true}. The resolver must leave them out unless
      // something else hard-depends on them.
      'tool': {
        '1.0.0': pd(
          peer: {'sass': '^1.0.0', 'less': '^4.0.0'},
          optionalPeers: {'sass', 'less'},
        ),
      },
      'sass': {'1.99.0': pd()},
      'less': {'4.6.0': pd()},
    });
    final solver = PubgrubSolver(
      SolverRequest(dependencies: {'tool': '^1.0.0'}, provider: provider),
    );
    final result = await solver.solve();
    expect(result.assignments['tool'], parseVersion('1.0.0'));
    expect(result.assignments.containsKey('sass'), isFalse);
    expect(result.assignments.containsKey('less'), isFalse);
    expect(solver.warnings, isEmpty);
  });

  test(
    'optional peer still installed when another package hard-depends',
    () async {
      final provider = InMemoryProvider({
        'tool': {
          '1.0.0': pd(peer: {'sass': '^1.0.0'}, optionalPeers: {'sass'}),
        },
        'styles': {
          '1.0.0': pd(deps: {'sass': '^1.0.0'}),
        },
        'sass': {'1.99.0': pd()},
      });
      final solver = PubgrubSolver(
        SolverRequest(
          dependencies: {'tool': '^1.0.0', 'styles': '^1.0.0'},
          provider: provider,
        ),
      );
      final result = await solver.solve();
      expect(result.assignments['sass'], parseVersion('1.99.0'));
    },
  );

  test('overrides rewrite declared ranges', () async {
    final provider = InMemoryProvider({
      'parent': {
        '1.0.0': pd(deps: {'leaf': '^1.0.0'}),
      },
      'leaf': {'1.0.0': pd(), '2.0.0': pd()},
    });
    final solver = PubgrubSolver(
      SolverRequest(
        dependencies: {'parent': '^1.0.0'},
        provider: provider,
        overrides: {'leaf': '^2.0.0'},
      ),
    );
    final result = await solver.solve();
    expect(result.assignments['leaf'], parseVersion('2.0.0'));
  });
}
