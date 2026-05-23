import 'pnpm_reader.dart';
import 'schema.dart';

/// Bridge between pnpm-lock.yaml's v9 shape and knot's internal
/// [Lockfile] (npm v3 shape). The install pipeline only ever sees the
/// internal model, so pnpm-mode read/write is two pure conversions on
/// either side of it — no special-casing leaks into the resolver,
/// locked fast-path, or linker.
///
/// The two formats disagree structurally:
/// - npm v3 keeps one flat `packages` table with dependency *ranges*;
///   the resolved version is implicit in the (deduped) tree.
/// - pnpm v9 splits metadata (`packages`) from the resolved dependency
///   graph (`snapshots`, keyed `name@version(peer@x)?`), storing
///   resolved *versions* on each edge.
///
/// knot's hoisted linker dedupes to one version per name, so the peer
/// context that distinguishes pnpm snapshots collapses: every edge
/// re-resolves to the single installed version via the lockfile-wide
/// name→version map. That is what lets the conversion stay lossless
/// for knot's purposes even though pnpm carries strictly more shape.

/// Convert a parsed [pnpm] lockfile into knot's internal [Lockfile].
///
/// Registry packages store only `integrity` in pnpm's resolution map;
/// their tarball URL is implied by the registry, so it is reconstructed
/// from [registry] + name + version. Non-registry resolutions (git /
/// https / tarball) carry an explicit `tarball` which is used as-is.
Lockfile pnpmToLockfile(PnpmLockfile pnpm, {required Uri registry}) {
  final root = pnpm.importers['.'];
  final importer = root == null
      ? const Importer()
      : Importer(
          dependencies: _specifierMap(root.dependencies),
          devDependencies: _specifierMap(root.devDependencies),
          optionalDependencies: _specifierMap(root.optionalDependencies),
          peerDependencies: _specifierMap(root.peerDependencies),
        );

  // Index snapshots by their base `name@version`, dropping the peer
  // suffix. Sorted so the bare key (which sorts before any `(peer)`
  // variant) wins when a package has several peer-resolved snapshots.
  final snapshotByBase = <String, PnpmSnapshotEntry>{};
  final snapshotKeys = pnpm.snapshots.keys.toList()..sort();
  for (final key in snapshotKeys) {
    snapshotByBase.putIfAbsent(
      _stripPeerSuffix(key),
      () => pnpm.snapshots[key]!,
    );
  }

  final packages = <String, LockedPackage>{};
  for (final entry in pnpm.packages.entries) {
    final id = _parseId(entry.key);
    if (id == null) continue;
    final pkg = entry.value;
    final snapshot = snapshotByBase[_stripPeerSuffix(entry.key)];
    final integrity = pkg.resolution['integrity'] as String?;
    final explicitTarball = pkg.resolution['tarball'] as String?;

    packages['${id.name}@${id.version}'] = LockedPackage(
      name: id.name,
      version: id.version,
      resolution: Resolution.tarball(
        tarball:
            explicitTarball ??
            _registryTarballUrl(registry, id.name, id.version),
      ),
      integrity: integrity,
      dependencies: snapshot?.dependencies ?? const {},
      optionalDependencies: snapshot?.optionalDependencies ?? const {},
      peerDependencies: pkg.peerDependencies,
      peerDependenciesMeta: {
        for (final e in pkg.peerDependenciesMeta.entries)
          e.key: PeerDependencyMeta(optional: e.value['optional'] == true),
      },
      os: pkg.os,
      cpu: pkg.cpu,
      hasBin: pkg.hasBin,
      engines: pkg.engines,
      signatures: _signaturesFrom(pkg.signatures),
    );
  }

  return Lockfile(
    lockfileVersion: knotLockfileVersion,
    importers: {'.': importer},
    packages: packages,
  );
}

/// Convert knot's internal [Lockfile] into a pnpm-lock.yaml v9 model.
///
/// The internal model stores dependency *ranges*; pnpm snapshots want
/// resolved *versions*. Each edge name is looked up in the lockfile-wide
/// name→version map (knot installs one version per name), and edges to
/// names absent from the lockfile — optional deps skipped on this
/// platform, unresolved peers — are dropped, matching pnpm's rule that
/// snapshots list only materialized edges.
PnpmLockfile lockfileToPnpm(Lockfile lock) {
  final versionByName = <String, String>{
    for (final p in lock.packages.values) p.name: p.version,
  };

  final root = lock.importers['.'] ?? const Importer();
  final importer = PnpmImporter(
    dependencies: _directDeps(root.dependencies, versionByName),
    devDependencies: _directDeps(root.devDependencies, versionByName),
    optionalDependencies: _directDeps(root.optionalDependencies, versionByName),
    peerDependencies: _directDeps(root.peerDependencies, versionByName),
  );

  final packages = <String, PnpmPackageEntry>{};
  final snapshots = <String, PnpmSnapshotEntry>{};
  for (final p in lock.packages.values) {
    final key = '${p.name}@${p.version}';
    packages[key] = PnpmPackageEntry(
      resolution: {if (p.integrity != null) 'integrity': p.integrity},
      engines: p.engines,
      os: p.os,
      cpu: p.cpu,
      peerDependencies: p.peerDependencies,
      peerDependenciesMeta: {
        for (final e in p.peerDependenciesMeta.entries)
          e.key: {'optional': e.value.optional},
      },
      hasBin: p.hasBin,
      deprecated: null,
      bundledDependencies: const [],
      signatures: [
        for (final s in p.signatures) {'keyid': s.keyid, 'sig': s.sig},
      ],
      preserved: const {},
    );
    snapshots[key] = PnpmSnapshotEntry(
      dependencies: _resolveEdges(p.dependencies.keys, versionByName),
      optionalDependencies: _resolveEdges(
        p.optionalDependencies.keys,
        versionByName,
      ),
      transitivePeerDependencies: const [],
      preserved: const {},
    );
  }

  return PnpmLockfile(
    lockfileVersion: '9.0',
    settings: const {
      'autoInstallPeers': true,
      'excludeLinksFromLockfile': false,
    },
    importers: {'.': importer},
    packages: packages,
    snapshots: snapshots,
    catalogs: const {},
    preservedTopLevel: const {},
  );
}

({String name, String version})? _parseId(String key) {
  final base = _stripPeerSuffix(key);
  // `@scope/name@version` → split on the *last* `@`, which the leading
  // scope `@` never is.
  final at = base.lastIndexOf('@');
  if (at <= 0) return null;
  return (name: base.substring(0, at), version: base.substring(at + 1));
}

String _stripPeerSuffix(String key) {
  final paren = key.indexOf('(');
  return paren < 0 ? key : key.substring(0, paren);
}

/// Build `<registry>/<name>/-/<unscoped>-<version>.tgz`, the canonical
/// npm tarball path. Scoped names keep the scope in the path but drop
/// it from the filename (`@babel/core` → `.../@babel/core/-/core-…`).
String _registryTarballUrl(Uri registry, String name, String version) {
  final unscoped = name.startsWith('@')
      ? name.substring(name.indexOf('/') + 1)
      : name;
  final base = registry.toString();
  final sep = base.endsWith('/') ? '' : '/';
  return '$base$sep$name/-/$unscoped-$version.tgz';
}

Map<String, String> _specifierMap(Map<String, PnpmDirectDep> deps) => {
  for (final e in deps.entries) e.key: e.value.specifier,
};

Map<String, PnpmDirectDep> _directDeps(
  Map<String, String> declared,
  Map<String, String> versionByName,
) {
  final out = <String, PnpmDirectDep>{};
  for (final e in declared.entries) {
    final version = versionByName[e.key];
    // Skip names that never resolved to a registry package (workspace
    // links, file:/git: specifiers) — pnpm tracks those separately.
    if (version == null) continue;
    out[e.key] = PnpmDirectDep(specifier: e.value, version: version);
  }
  return out;
}

Map<String, String> _resolveEdges(
  Iterable<String> depNames,
  Map<String, String> versionByName,
) {
  final out = <String, String>{};
  for (final name in depNames) {
    final version = versionByName[name];
    if (version != null) out[name] = version;
  }
  return out;
}

List<LockedSignature> _signaturesFrom(List<Map<String, Object?>> raw) {
  final out = <LockedSignature>[];
  for (final entry in raw) {
    final keyid = entry['keyid'];
    final sig = entry['sig'];
    if (keyid is String && sig is String) {
      out.add(LockedSignature(keyid: keyid, sig: sig));
    }
  }
  return out;
}
