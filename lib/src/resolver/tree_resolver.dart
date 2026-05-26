import 'package:knot/src/core/core.dart';
import 'package:knot/src/semver/semver.dart';

import 'provider.dart';

/// Resolves a dependency graph the npm way: each edge gets the highest
/// version satisfying its range, and **when ranges conflict the resolver
/// keeps MULTIPLE versions** — hoisting the first to the top of
/// `node_modules` and nesting conflicting ones under the package that
/// requires them. This is what lets knot install graphs like
/// `A → x@^1`, `B → x@^2` (e.g. eslint → minimatch@^3 alongside
/// `@typescript-eslint/* → minimatch@^9`) that the single-version
/// pubgrub solver rejects.
///
/// Ported from the Go reference (`gnpm/internal/treeresolver`). It reuses
/// the same [PackageProvider]; when there are no conflicts every package
/// hoists to the top level, so the output is identical to a flat layout.
class TreeResolver {
  TreeResolver(this.request);

  final TreeResolveRequest request;

  final List<String> _warnings = [];
  final Map<String, List<Version>> _versionsCache = {};
  final Map<String, Map<Version, PackageDependencies>> _depsCache = {};

  Future<TreeResolveResult> resolve() async {
    final root = _Node(name: '', version: Version(0, 0, 0), path: '');

    final queue = <_Edge>[];
    for (final name in _sortedKeys(request.dependencies)) {
      queue.add(_Edge(root, name, request.dependencies[name]!, true, false));
    }
    for (final name in _sortedKeys(request.optionalDependencies)) {
      queue.add(
        _Edge(root, name, request.optionalDependencies[name]!, true, true),
      );
    }

    while (queue.isNotEmpty) {
      final edge = queue.removeAt(0);
      queue.addAll(await _resolveEdge(root, edge));
    }

    final instances = <ResolvedInstance>[];
    void walk(_Node n) {
      for (final name in n.contents.keys.toList()..sort()) {
        final c = n.contents[name]!;
        instances.add(
          ResolvedInstance(
            name: c.name,
            version: c.version,
            path: c.path,
            isDirect: c.direct,
            deps: Map.unmodifiable(c.deps),
          ),
        );
        walk(c);
      }
    }

    walk(root);
    return TreeResolveResult(instances: instances, warnings: _warnings);
  }

  Future<List<_Edge>> _resolveEdge(_Node root, _Edge e) async {
    final eff = _effective(e.requirer, e.name, e.range);

    final NpmRange parsed;
    try {
      parsed = NpmRange.parse(eff);
    } on FormatException {
      // Non-semver specifier (file:/git:/alias). These are resolved on a
      // separate path before the tree resolver runs; ignore here.
      return const [];
    }

    // Reuse a visible instance: walk ancestors for the nearest one named
    // e.name. Compatible → reuse; incompatible → it shadows, so we must
    // place at/below the requirer (nesting).
    _Node? nearest;
    for (_Node? a = e.requirer; a != null; a = a.parent) {
      final inst = a.contents[e.name];
      if (inst != null) {
        nearest = a;
        if (parsed.satisfies(inst.version)) {
          e.requirer.deps[e.name] = inst.version;
          return const []; // reuse
        }
        break; // incompatible → shadow
      }
    }

    final versions = await _versions(e.name);
    final best = _pick(e.name, versions, parsed);
    if (best == null) {
      if (e.optional) return const [];
      throw ResolutionError('no version of ${e.name} satisfies $eff');
    }

    // Placement target: top level when no ancestor holds the name, else
    // nest directly under the requirer.
    final target = nearest != null ? e.requirer : root;
    final existing = target.contents[e.name];
    if (existing != null) {
      // Already placed here (rare dep/peer overlap) — keep the first.
      e.requirer.deps[e.name] = existing.version;
      return const [];
    }

    final path = identical(target, root)
        ? e.name
        : '${target.path}/node_modules/${e.name}';
    final node = _Node(
      name: e.name,
      version: best,
      path: path,
      direct: e.direct,
      parent: target,
    );
    target.contents[e.name] = node;
    e.requirer.deps[e.name] = best;
    request.onResolved?.call(e.name, best);

    final deps = await _dependenciesOf(e.name, best);
    final next = <_Edge>[];
    for (final d in _sortedKeys(deps.dependencies)) {
      next.add(_Edge(node, d, deps.dependencies[d]!, false, false));
    }
    for (final d in _sortedKeys(deps.optionalDependencies)) {
      next.add(_Edge(node, d, deps.optionalDependencies[d]!, false, true));
    }
    if (request.autoInstallPeers) {
      for (final d in _sortedKeys(deps.peerDependencies)) {
        if (deps.optionalPeers.contains(d)) continue;
        next.add(_Edge(node, d, deps.peerDependencies[d]!, false, false));
      }
    } else {
      for (final d in deps.peerDependencies.keys) {
        if (deps.optionalPeers.contains(d)) continue;
        if (!_isVisible(node, d)) {
          _warnings.add('unmet peer dependency: ${e.name}@$best → $d');
        }
      }
    }
    return next;
  }

  /// Highest version satisfying [parsed], preferring an existing locked
  /// version when it still satisfies (reproducible installs).
  Version? _pick(String name, List<Version> versions, NpmRange parsed) {
    final preferred = request.preferred[name];
    if (preferred != null &&
        parsed.satisfies(preferred) &&
        versions.contains(preferred)) {
      return preferred;
    }
    return maxSatisfying(versions, parsed);
  }

  bool _isVisible(_Node from, String name) {
    for (_Node? a = from; a != null; a = a.parent) {
      if (a.contents.containsKey(name)) return true;
    }
    return false;
  }

  String _effective(_Node requirer, String name, String declared) {
    if (requirer.name.isNotEmpty) {
      final scoped = request.nestedOverrides[requirer.name]?[name];
      if (scoped != null) return scoped;
    }
    return request.overrides[name] ?? declared;
  }

  Future<List<Version>> _versions(String pkg) async {
    final cached = _versionsCache[pkg];
    if (cached != null) return cached;
    final v = await request.provider.versions(pkg);
    final sorted = [...v]..sort();
    _versionsCache[pkg] = sorted;
    return sorted;
  }

  Future<PackageDependencies> _dependenciesOf(String pkg, Version v) async {
    final byVersion = _depsCache[pkg];
    final cached = byVersion?[v];
    if (cached != null) return cached;
    final d = await request.provider.dependenciesOf(pkg, v);
    (_depsCache[pkg] ??= {})[v] = d;
    return d;
  }

  static List<String> _sortedKeys(Map<String, String> m) =>
      m.keys.toList()..sort();
}

/// One resolved package instance and where it goes in `node_modules`.
class ResolvedInstance {
  ResolvedInstance({
    required this.name,
    required this.version,
    required this.path,
    required this.isDirect,
    required this.deps,
  });

  final String name;
  final Version version;

  /// `node_modules`-relative location: `react` when hoisted to the top
  /// level, or `a/node_modules/lodash` when nested under a conflicting
  /// version.
  final String path;
  final bool isDirect;

  /// This instance's own dependency edges resolved to concrete versions
  /// (`name → version`). Drives the isolated linker's symlink wiring and
  /// the lockfile's per-package dependency map.
  final Map<String, Version> deps;

  String get id => '$name@$version';
}

class TreeResolveResult {
  TreeResolveResult({required this.instances, required this.warnings});
  final List<ResolvedInstance> instances;
  final List<String> warnings;
}

class TreeResolveRequest {
  TreeResolveRequest({
    required this.dependencies,
    required this.provider,
    this.optionalDependencies = const {},
    this.preferred = const {},
    this.overrides = const {},
    this.nestedOverrides = const {},
    this.autoInstallPeers = true,
    this.onResolved,
  });

  final Map<String, String> dependencies;
  final Map<String, String> optionalDependencies;
  final PackageProvider provider;
  final Map<String, Version> preferred;
  final Map<String, String> overrides;
  final Map<String, Map<String, String>> nestedOverrides;
  final bool autoInstallPeers;

  /// Fired the moment an instance's version is finalized (the greedy walk
  /// never revises a placement), so the install path can start its
  /// tarball download in parallel with the rest of resolution.
  final void Function(String name, Version version)? onResolved;
}

class _Node {
  _Node({
    required this.name,
    required this.version,
    required this.path,
    this.direct = false,
    this.parent,
  });

  final String name;
  final Version version;
  final String path;
  final bool direct;
  final _Node? parent;
  final Map<String, _Node> contents = {};

  /// Resolved versions of this node's own dependency edges.
  final Map<String, Version> deps = {};
}

class _Edge {
  _Edge(this.requirer, this.name, this.range, this.direct, this.optional);
  final _Node requirer;
  final String name;
  final String range;
  final bool direct;
  final bool optional;
}
