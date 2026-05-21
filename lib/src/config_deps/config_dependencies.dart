/// Phase P — pnpm v11 `configDependencies`.
///
/// configDependencies are project-level packages downloaded at install
/// time but **not** registered in `node_modules` and **never** allowed
/// to run lifecycle scripts. They unpack to a knot-namespaced
/// directory (`node_modules/.knot-config/<name>/`) so other tools can
/// pull shared config / lint rule sets through a single declarative
/// list instead of devDependencies + lifecycle hacks.
///
/// The on-disk source is `pnpm-workspace.yaml#configDependencies` in
/// pnpm-mode and `package.json#knot.configDependencies` in npm/knot-
/// mode. Either form yields a `name → version` map.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../archive/archive.dart';
import '../core/core.dart';
import '../registry/registry.dart';

/// One declared config dependency.
class ConfigDependency {
  const ConfigDependency({required this.name, required this.version});
  final String name;

  /// Concrete version pin (no ranges — the value in
  /// `configDependencies` must be exact, mirroring pnpm v11).
  final String version;
}

/// Parse the `configDependencies` map. Accepts both shorthand
/// (`name: "1.2.3"`) and object (`name: { version: "1.2.3" }`)
/// forms — both are seen in pnpm docs.
List<ConfigDependency> parseConfigDependencies(Object? raw) {
  if (raw is! Map) return const [];
  final out = <ConfigDependency>[];
  for (final entry in raw.entries) {
    if (entry.key is! String) continue;
    final value = entry.value;
    String? version;
    if (value is String) {
      version = value;
    } else if (value is Map) {
      final v = value['version'];
      if (v is String) version = v;
    }
    if (version == null || version.isEmpty) continue;
    out.add(ConfigDependency(name: entry.key as String, version: version));
  }
  return out;
}

/// Directory that holds the unpacked trees for [projectRoot]'s
/// config dependencies. One subdir per package.
String configDependenciesRoot(String projectRoot) =>
    p.join(projectRoot, 'node_modules', '.knot-config');

/// Fetch + unpack [dependencies] into [configDependenciesRoot].
///
/// Lifecycle scripts are intentionally NOT executed; pnpm's spec
/// forbids them here. Returns the list of `<name>` directories that
/// were materialized this run (skipping ones already present).
Future<List<String>> materializeConfigDependencies({
  required String projectRoot,
  required RegistryClient client,
  required List<ConfigDependency> dependencies,
}) async {
  if (dependencies.isEmpty) return const [];
  final root = configDependenciesRoot(projectRoot);
  await Directory(root).create(recursive: true);

  final materialized = <String>[];
  for (final dep in dependencies) {
    final destDir = Directory(p.join(root, dep.name));
    if (await destDir.exists()) continue;
    final pack = await client.packument(dep.name);
    final slice = pack.versions[dep.version];
    if (slice == null) {
      throw UsageError(
        'configDependencies: ${dep.name}@${dep.version} not on registry',
      );
    }
    final tarballUrl = slice.tarball;
    final integrity = slice.integrity;
    if (tarballUrl == null || integrity == null) {
      throw UsageError(
        'configDependencies: ${dep.name}@${dep.version} has no tarball '
        'or integrity in the registry packument',
      );
    }
    final bytes = await client.tarball(url: tarballUrl, integrity: integrity);
    final extracted = await _extractInto(destDir, bytes);
    materialized.add(extracted.path);
  }
  return materialized;
}

Future<Directory> _extractInto(Directory dest, Uint8List bytes) async {
  await dest.create(recursive: true);
  final extractor = TarExtractor();
  await extractor.extract(Stream.value(bytes), destination: dest.path);
  return dest;
}
