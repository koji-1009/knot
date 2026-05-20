import 'package:knot/src/semver/semver.dart';

import 'provider.dart';

/// Solver result: a flat map of `package` → chosen `Version`.
class SolverResult {
  SolverResult(this.assignments);
  final Map<String, Version> assignments;
}

/// Solver inputs — root project's direct deps + a [PackageProvider].
///
/// Used by [PubgrubSolver][1] to drive resolution.
///
/// [1]: ../pubgrub.dart
class SolverRequest {
  SolverRequest({
    required this.dependencies,
    required this.provider,
    this.optionalDependencies = const {},
    this.preferred = const {},
    this.overrides = const {},
    this.nestedOverrides = const {},
    this.autoInstallPeers = true,
    this.onDecide,
  });

  final Map<String, String> dependencies;
  final Map<String, String> optionalDependencies;
  final PackageProvider provider;

  /// Existing locked versions to prefer when otherwise equal.
  final Map<String, Version> preferred;

  /// Map of `<package>` → range that overrides whatever was declared by any
  /// transitive consumer. Matches npm `overrides`/yarn `resolutions`.
  final Map<String, String> overrides;

  /// `parent → child → range` overrides that apply only when `child` is a
  /// transitive dep of `parent`.
  final Map<String, Map<String, String>> nestedOverrides;

  /// npm@7+ behavior: missing peers are pulled in automatically.
  final bool autoInstallPeers;

  /// Fired the moment the solver commits to `package@version`. Used by
  /// the install path to start the tarball download in parallel with
  /// the rest of resolution — by the time `solve()` returns the
  /// tarball is often already in the store cache.
  ///
  /// The callback runs synchronously in the solver hot loop; any
  /// network work it kicks off must be fire-and-forget. pubgrub may
  /// later backtrack past this decision: an already-fetched tarball
  /// for the "wrong" version is left in the store as a future-run
  /// cache hit and does not need to be cancelled.
  final void Function(String package, Version version)? onDecide;
}
