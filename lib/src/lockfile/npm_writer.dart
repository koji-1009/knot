import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'lockfile.dart';

/// Serialize a knot [Lockfile] into npm's `package-lock.json` (v3) shape.
///
/// We target lockfileVersion 3 — the format npm 7+ produces by default —
/// because it's now the only format that materially matters: every
/// supported Node.js LTS ships with an npm new enough to read it.
/// Older v1/v2 nested-`dependencies` style is intentionally not emitted;
/// the cost of dual-output far outweighs the value for projects pinned
/// to a 5-year-old npm.
///
/// Layout:
/// - `"packages": { "": { ... importer root ... } }`
/// - `"packages": { "node_modules/<name>": { ... per-package ... } }`
///
/// knot's flat hoisted linker maps 1:1 onto npm's flat `node_modules`
/// layout, so we only emit top-level `node_modules/<name>` entries —
/// nested duplicates aren't produced because the resolver always
/// dedupes to a single version per name.
String writeNpmLockfileToString(
  Lockfile lockfile, {
  required String projectName,
  String? projectVersion,
}) {
  final root = <String, dynamic>{
    'name': projectName,
    'version': ?projectVersion,
    'lockfileVersion': 3,
    'requires': true,
  };

  final packages = <String, dynamic>{};

  // Root importer ("") — npm encodes the project's own package.json
  // dep ranges (not resolved versions) here so npm can replay
  // resolution on `npm install`.
  final rootImporter = lockfile.importers['.'] ?? const Importer();
  packages[''] = <String, dynamic>{
    'name': projectName,
    'version': ?projectVersion,
    if (rootImporter.dependencies.isNotEmpty)
      'dependencies': _sortedMap(rootImporter.dependencies),
    if (rootImporter.devDependencies.isNotEmpty)
      'devDependencies': _sortedMap(rootImporter.devDependencies),
    if (rootImporter.optionalDependencies.isNotEmpty)
      'optionalDependencies': _sortedMap(rootImporter.optionalDependencies),
    if (rootImporter.peerDependencies.isNotEmpty)
      'peerDependencies': _sortedMap(rootImporter.peerDependencies),
  };

  // One entry per resolved package, keyed by its `node_modules/<name>`
  // path. Sort by key for deterministic output — `npm` does the same,
  // which keeps the file diff-friendly across consecutive installs.
  final sortedIds = lockfile.packages.keys.toList()..sort();
  for (final id in sortedIds) {
    final pkg = lockfile.packages[id]!;
    final key = 'node_modules/${pkg.name}';
    packages[key] = _serializePackage(pkg);
  }

  root['packages'] = packages;

  // Pretty-printed JSON with two-space indent — same convention as
  // `npm` so diffs vs. existing files don't churn on whitespace alone.
  const encoder = JsonEncoder.withIndent('  ');
  return '${encoder.convert(root)}\n';
}

Map<String, dynamic> _serializePackage(LockedPackage pkg) {
  final out = <String, dynamic>{'version': pkg.version};
  final tarball = pkg.resolution.tarball;
  if (tarball != null) {
    out['resolved'] = tarball;
  }
  if (pkg.integrity != null) {
    out['integrity'] = pkg.integrity;
  }
  if (pkg.dependencies.isNotEmpty) {
    out['dependencies'] = _sortedMap(pkg.dependencies);
  }
  if (pkg.optionalDependencies.isNotEmpty) {
    out['optionalDependencies'] = _sortedMap(pkg.optionalDependencies);
  }
  if (pkg.peerDependencies.isNotEmpty) {
    out['peerDependencies'] = _sortedMap(pkg.peerDependencies);
  }
  if (pkg.peerDependenciesMeta.isNotEmpty) {
    out['peerDependenciesMeta'] = <String, dynamic>{
      for (final e
          in pkg.peerDependenciesMeta.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
        e.key: {'optional': e.value.optional},
    };
  }
  if (pkg.os.isNotEmpty) {
    out['os'] = pkg.os;
  }
  if (pkg.cpu.isNotEmpty) {
    out['cpu'] = pkg.cpu;
  }
  if (pkg.engines.isNotEmpty) {
    out['engines'] = _sortedMap(pkg.engines);
  }
  if (pkg.bin.isNotEmpty) {
    out['bin'] = _sortedMap(pkg.bin);
  }
  if (pkg.hasInstallScript) {
    out['hasInstallScript'] = true;
  }
  // Fields below are knot-specific extensions. npm preserves unknown
  // keys verbatim across reads/writes, so they ride along without
  // breaking `npm install` interop. The leading underscore follows
  // npm's own internal-field convention.
  if (pkg.signatures.isNotEmpty) {
    out['_signatures'] = [
      for (final s in pkg.signatures)
        <String, String>{'keyid': s.keyid, 'sig': s.sig},
    ];
  }
  if (pkg.scripts.isNotEmpty) {
    // `scripts` isn't a standard package-lock.json field — npm reads
    // scripts from each tarball's package.json at install time. We
    // still cache them here so warm installs can skip the per-package
    // manifest read. npm tolerates the extra key.
    out['_scripts'] = _sortedMap(pkg.scripts);
  }
  return out;
}

Map<String, dynamic> _sortedMap(Map<String, String> m) {
  final keys = m.keys.toList()..sort();
  return <String, dynamic>{for (final k in keys) k: m[k]};
}

/// Atomically write `package-lock.json` to [path] via a temp file +
/// rename so a crash mid-write can't leave the project with a
/// truncated lockfile.
Future<void> writeNpmLockfileToFile(
  Lockfile lockfile,
  String path, {
  required String projectName,
  String? projectVersion,
}) async {
  final dir = p.dirname(path);
  await Directory(dir).create(recursive: true);
  final tmp = '$path.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}';
  final file = File(tmp);
  await file.writeAsString(
    writeNpmLockfileToString(
      lockfile,
      projectName: projectName,
      projectVersion: projectVersion,
    ),
    flush: true,
  );
  await file.rename(path);
}
