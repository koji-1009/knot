import 'package:knot/src/semver/semver.dart';

/// Dependencies declared by a candidate package version.
///
/// `optionalDependencies` here means *transitively* declared optional
/// deps. The resolver propagates them as constraints (matching npm's
/// semantics for platform-specific native binary siblings like
/// `@esbuild/darwin-arm64`); the install path's platform filter then
/// silently drops the variants that don't match the host.
class PackageDependencies {
  PackageDependencies({
    required this.dependencies,
    this.optionalDependencies = const {},
    this.peerDependencies = const {},
    this.optionalPeers = const {},
  });

  final Map<String, String> dependencies;
  final Map<String, String> optionalDependencies;
  final Map<String, String> peerDependencies;

  /// Names from [peerDependencies] that the declaring package
  /// flagged `{optional: true}` in `peerDependenciesMeta`. Pubgrub
  /// must NOT force-install these — they enter the graph only when
  /// something else has a hard `dependencies` requirement for them.
  final Set<String> optionalPeers;
}

/// Source of resolver inputs. Implementations typically wrap a registry
/// client and a packument cache.
abstract class PackageProvider {
  /// All known versions for [package], in arbitrary order.
  Future<List<Version>> versions(String package);

  /// Dependency declarations for `[package]@[version]`.
  Future<PackageDependencies> dependenciesOf(String package, Version version);
}

/// In-memory provider, useful for tests and fixtures.
class InMemoryProvider implements PackageProvider {
  InMemoryProvider(Map<String, Map<String, PackageDependencies>> data)
    : _data = {
        for (final entry in data.entries)
          entry.key: {
            for (final v in entry.value.entries) parseVersion(v.key): v.value,
          },
      };

  final Map<String, Map<Version, PackageDependencies>> _data;

  @override
  Future<List<Version>> versions(String package) async {
    final m = _data[package];
    if (m == null) return const [];
    return m.keys.toList()..sort();
  }

  @override
  Future<PackageDependencies> dependenciesOf(
    String package,
    Version version,
  ) async {
    final deps = _data[package]?[version];
    if (deps == null) {
      throw StateError('no entry for $package@$version');
    }
    return deps;
  }
}
