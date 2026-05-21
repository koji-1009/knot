import 'dart:io';

import 'package:yaml/yaml.dart';

/// Parsed pnpm-lock.yaml v9 view that retains *every* top-level field
/// (Phase A of the v11 alignment plan). knot's resolver consumes the
/// importers + packages + snapshots tables directly; the remaining
/// preserved fields are kept verbatim so a roundtrip through the
/// writer is lossless.
class PnpmLockfile {
  PnpmLockfile({
    required this.lockfileVersion,
    required this.settings,
    required this.importers,
    required this.packages,
    required this.snapshots,
    required this.catalogs,
    required this.preservedTopLevel,
  });

  /// `lockfileVersion` literal as it appeared on disk (e.g. `'9.0'`).
  /// Kept as a String because pnpm prints it as a YAML string while
  /// some forks emit it as a number; we round-trip whichever form was
  /// supplied.
  final String lockfileVersion;

  /// `settings` block (autoInstallPeers, excludeLinksFromLockfile,
  /// peersSuffixMaxLength, dedupePeers, …). Unmodifiable map of the
  /// raw YAML values, decoded to Dart core types.
  final Map<String, Object?> settings;

  /// `importers` table keyed by workspace path (`'.'` for root).
  final Map<String, PnpmImporter> importers;

  /// `packages` table keyed by `<name>@<version>` selectors.
  final Map<String, PnpmPackageEntry> packages;

  /// `snapshots` table keyed by the post-resolution selector
  /// (`<name>@<version>(_peerDep@x)?`). Only populated when
  /// `dedupePeers: false`; with `dedupePeers: true` snapshots is a
  /// flat map of the same shape as packages.
  final Map<String, PnpmSnapshotEntry> snapshots;

  /// `catalog` (default) + `catalogs:` (named) merged into a single
  /// `{catalogName → {pkg → range}}` table. The reader populates the
  /// default catalog under the key `default`.
  final Map<String, Map<String, String>> catalogs;

  /// All other top-level fields the reader did not specialise on —
  /// `devEngines.runtime`, `packageManagerDependencies`,
  /// `runtimeOnFail`, `nodeDownloadMirrors`, `gitHosted`, plus any
  /// unknown future addition. Preserved verbatim for the writer.
  final Map<String, Object?> preservedTopLevel;
}

class PnpmImporter {
  PnpmImporter({
    required this.dependencies,
    required this.devDependencies,
    required this.optionalDependencies,
    required this.peerDependencies,
  });

  final Map<String, PnpmDirectDep> dependencies;
  final Map<String, PnpmDirectDep> devDependencies;
  final Map<String, PnpmDirectDep> optionalDependencies;
  final Map<String, PnpmDirectDep> peerDependencies;
}

class PnpmDirectDep {
  PnpmDirectDep({required this.specifier, required this.version});
  final String specifier;
  final String version;
}

class PnpmPackageEntry {
  PnpmPackageEntry({
    required this.resolution,
    required this.engines,
    required this.os,
    required this.cpu,
    required this.peerDependencies,
    required this.peerDependenciesMeta,
    required this.hasBin,
    required this.deprecated,
    required this.bundledDependencies,
    required this.signatures,
    required this.preserved,
  });

  final Map<String, Object?> resolution;
  final Map<String, String> engines;
  final List<String> os;
  final List<String> cpu;
  final Map<String, String> peerDependencies;
  final Map<String, Map<String, Object?>> peerDependenciesMeta;
  final bool hasBin;
  final String? deprecated;
  final List<String> bundledDependencies;
  final List<Map<String, Object?>> signatures;

  /// Other fields on the entry (forward-compatible).
  final Map<String, Object?> preserved;
}

class PnpmSnapshotEntry {
  PnpmSnapshotEntry({
    required this.dependencies,
    required this.optionalDependencies,
    required this.transitivePeerDependencies,
    required this.preserved,
  });

  final Map<String, String> dependencies;
  final Map<String, String> optionalDependencies;
  final List<String> transitivePeerDependencies;
  final Map<String, Object?> preserved;
}

/// Read [path] as a pnpm-lock.yaml v9 file. Throws [FormatException]
/// when the YAML is malformed; throws [FileSystemException] for I/O.
Future<PnpmLockfile> readPnpmLockfile(String path) async {
  final raw = await File(path).readAsString();
  return parsePnpmLockfile(raw);
}

/// Parse a pnpm-lock.yaml document directly from its string form.
PnpmLockfile parsePnpmLockfile(String yamlString) {
  final doc = loadYaml(yamlString);
  if (doc is! YamlMap) {
    throw const FormatException('pnpm-lock.yaml root must be a map');
  }
  final map = _coerceMap(doc);

  final version = map['lockfileVersion'];
  final lockfileVersion = version is num ? version.toString() : '$version';

  final settings = _asMap(map['settings']);

  final importersRaw = _asMap(map['importers']);
  final importers = <String, PnpmImporter>{};
  for (final entry in importersRaw.entries) {
    final body = _asMap(entry.value);
    importers[entry.key] = PnpmImporter(
      dependencies: _readDirectDeps(_asMap(body['dependencies'])),
      devDependencies: _readDirectDeps(_asMap(body['devDependencies'])),
      optionalDependencies:
          _readDirectDeps(_asMap(body['optionalDependencies'])),
      peerDependencies: _readDirectDeps(_asMap(body['peerDependencies'])),
    );
  }

  final packagesRaw = _asMap(map['packages']);
  final packages = <String, PnpmPackageEntry>{};
  for (final entry in packagesRaw.entries) {
    final body = _asMap(entry.value);
    packages[entry.key] = PnpmPackageEntry(
      resolution: _asMap(body['resolution']),
      engines: _stringMap(_asMap(body['engines'])),
      os: _stringList(body['os']),
      cpu: _stringList(body['cpu']),
      peerDependencies: _stringMap(_asMap(body['peerDependencies'])),
      peerDependenciesMeta: _peerMetaMap(_asMap(body['peerDependenciesMeta'])),
      hasBin: body['hasBin'] == true,
      deprecated: body['deprecated'] as String?,
      bundledDependencies: _stringList(body['bundledDependencies']),
      signatures: _signatureList(body['signatures']),
      preserved: _preservedExcept(body, _packageKnownKeys),
    );
  }

  final snapshotsRaw = _asMap(map['snapshots']);
  final snapshots = <String, PnpmSnapshotEntry>{};
  for (final entry in snapshotsRaw.entries) {
    final body = _asMap(entry.value);
    snapshots[entry.key] = PnpmSnapshotEntry(
      dependencies: _stringMap(_asMap(body['dependencies'])),
      optionalDependencies: _stringMap(_asMap(body['optionalDependencies'])),
      transitivePeerDependencies:
          _stringList(body['transitivePeerDependencies']),
      preserved: _preservedExcept(body, _snapshotKnownKeys),
    );
  }

  final catalogs = <String, Map<String, String>>{};
  final shortCatalog = _asMap(map['catalog']);
  if (shortCatalog.isNotEmpty) {
    catalogs['default'] = _stringMap(shortCatalog);
  }
  final namedCatalogs = _asMap(map['catalogs']);
  for (final entry in namedCatalogs.entries) {
    catalogs[entry.key] = _stringMap(_asMap(entry.value));
  }

  final preservedTopLevel = _preservedExcept(map, _topLevelKnownKeys);

  return PnpmLockfile(
    lockfileVersion: lockfileVersion,
    settings: settings,
    importers: importers,
    packages: packages,
    snapshots: snapshots,
    catalogs: catalogs,
    preservedTopLevel: preservedTopLevel,
  );
}

const _topLevelKnownKeys = {
  'lockfileVersion',
  'settings',
  'importers',
  'packages',
  'snapshots',
  'catalog',
  'catalogs',
};

const _packageKnownKeys = {
  'resolution',
  'engines',
  'os',
  'cpu',
  'peerDependencies',
  'peerDependenciesMeta',
  'hasBin',
  'deprecated',
  'bundledDependencies',
  'signatures',
};

const _snapshotKnownKeys = {
  'dependencies',
  'optionalDependencies',
  'transitivePeerDependencies',
};

Map<String, PnpmDirectDep> _readDirectDeps(Map<String, Object?> raw) {
  final out = <String, PnpmDirectDep>{};
  for (final entry in raw.entries) {
    final body = _asMap(entry.value);
    out[entry.key] = PnpmDirectDep(
      specifier: (body['specifier'] ?? '').toString(),
      version: (body['version'] ?? '').toString(),
    );
  }
  return out;
}

Map<String, Map<String, Object?>> _peerMetaMap(Map<String, Object?> raw) {
  final out = <String, Map<String, Object?>>{};
  for (final entry in raw.entries) {
    out[entry.key] = _asMap(entry.value);
  }
  return out;
}

List<Map<String, Object?>> _signatureList(Object? raw) {
  if (raw is! YamlList && raw is! List) return const [];
  final list = (raw as Iterable).toList();
  return [for (final e in list) _asMap(e)];
}

Map<String, Object?> _asMap(Object? raw) {
  if (raw == null) return const {};
  if (raw is YamlMap) return _coerceMap(raw);
  if (raw is Map) return Map<String, Object?>.from(raw);
  return const {};
}

Map<String, Object?> _coerceMap(YamlMap raw) {
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    out['${entry.key}'] = _coerceValue(entry.value);
  }
  return out;
}

Object? _coerceValue(Object? raw) {
  if (raw is YamlMap) return _coerceMap(raw);
  if (raw is YamlList) return [for (final e in raw) _coerceValue(e)];
  return raw;
}

Map<String, String> _stringMap(Map<String, Object?> raw) {
  final out = <String, String>{};
  for (final entry in raw.entries) {
    out[entry.key] = '${entry.value}';
  }
  return out;
}

List<String> _stringList(Object? raw) {
  if (raw is YamlList) return [for (final e in raw) '$e'];
  if (raw is List) return [for (final e in raw) '$e'];
  return const [];
}

Map<String, Object?> _preservedExcept(
  Map<String, Object?> source,
  Set<String> known,
) {
  final out = <String, Object?>{};
  for (final entry in source.entries) {
    if (known.contains(entry.key)) continue;
    out[entry.key] = entry.value;
  }
  return out;
}
