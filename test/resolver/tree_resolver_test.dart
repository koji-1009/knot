import 'package:knot/src/core/core.dart';
import 'package:knot/src/resolver/resolver.dart';
import 'package:test/test.dart';

PackageDependencies _deps(
  Map<String, String> deps, {
  Map<String, String> peers = const {},
}) => PackageDependencies(dependencies: deps, peerDependencies: peers);

Future<TreeResolveResult> _resolve(
  Map<String, String> root,
  Map<String, Map<String, PackageDependencies>> data,
) {
  return TreeResolver(
    TreeResolveRequest(dependencies: root, provider: InMemoryProvider(data)),
  ).resolve();
}

/// path -> version, for asserting the materialized tree shape.
Map<String, String> _byPath(TreeResolveResult r) => {
  for (final i in r.instances) i.path: i.version.toString(),
};

void main() {
  group('TreeResolver (multi-version, hoist-then-nest)', () {
    test('hoists everything when there are no conflicts', () async {
      final r = await _resolve(
        {'a': '^1.0.0'},
        {
          'a': {
            '1.0.0': _deps({'shared': '^1.0.0'}),
          },
          'shared': {'1.0.0': _deps({}), '1.5.0': _deps({})},
        },
      );
      expect(_byPath(r), {'a': '1.0.0', 'shared': '1.5.0'});
    });

    test(
      'keeps BOTH versions when ranges conflict (the eslint case)',
      () async {
        // a → shared@^1, b → shared@^2. A single-version solver fails;
        // the tree resolver hoists one and nests the other.
        final r = await _resolve(
          {'a': '^1.0.0', 'b': '^1.0.0'},
          {
            'a': {
              '1.0.0': _deps({'shared': '^1.0.0'}),
            },
            'b': {
              '1.0.0': _deps({'shared': '^2.0.0'}),
            },
            'shared': {'1.2.0': _deps({}), '2.3.0': _deps({})},
          },
        );
        final byPath = _byPath(r);
        // a hoists with shared@1 at top level; b nests shared@2 under itself
        // (a sorts before b, so shared@1 wins the top-level slot).
        expect(byPath['a'], '1.0.0');
        expect(byPath['b'], '1.0.0');
        expect(byPath['shared'], '1.2.0');
        expect(byPath['b/node_modules/shared'], '2.3.0');
        // Each requirer records the specific version it uses.
        final b = r.instances.firstWhere((i) => i.name == 'b');
        expect(b.deps['shared'].toString(), '2.3.0');
        final a = r.instances.firstWhere((i) => i.name == 'a');
        expect(a.deps['shared'].toString(), '1.2.0');
      },
    );

    test('reuses a hoisted version when compatible (no duplication)', () async {
      final r = await _resolve(
        {'a': '^1.0.0', 'b': '^1.0.0'},
        {
          'a': {
            '1.0.0': _deps({'shared': '^1.0.0'}),
          },
          'b': {
            '1.0.0': _deps({'shared': '^1.2.0'}),
          },
          'shared': {'1.5.0': _deps({})},
        },
      );
      // Only one shared instance, shared by both.
      expect(r.instances.where((i) => i.name == 'shared').length, 1);
      expect(_byPath(r)['shared'], '1.5.0');
    });

    test('auto-installs a peer dependency', () async {
      final r = await _resolve(
        {'plugin': '^1.0.0'},
        {
          'plugin': {
            '1.0.0': _deps({}, peers: {'host': '^8.0.0'}),
          },
          'host': {'8.1.0': _deps({})},
        },
      );
      expect(_byPath(r)['host'], '8.1.0');
    });

    test('errors when a required version is genuinely unavailable', () async {
      expect(
        () => _resolve(
          {'a': '^1.0.0'},
          {
            'a': {
              '1.0.0': _deps({'missing': '^9.0.0'}),
            },
            'missing': {'1.0.0': _deps({})},
          },
        ),
        throwsA(isA<ResolutionError>()),
      );
    });
  });
}
