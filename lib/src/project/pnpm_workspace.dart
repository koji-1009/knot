import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Parsed view of the install-relevant subset of `pnpm-workspace.yaml`.
class PnpmWorkspaceConfig {
  const PnpmWorkspaceConfig({
    this.allowBuilds = const [],
    this.configDependencies = const {},
  });

  /// Patterns from `pnpm-workspace.yaml#allowBuilds`. Merged with
  /// `package.json#knot.allowBuilds` by the install path so the
  /// build-script gate honors both sources.
  final List<String> allowBuilds;

  /// `name → version` pins from `pnpm-workspace.yaml#configDependencies`.
  /// Materialized under `node_modules/.knot-config/<name>/` by the install
  /// path. pnpm v11 accepts both `name: "1.2.3"` and
  /// `name: { version: "1.2.3" }`.
  final Map<String, String> configDependencies;

  bool get isEmpty => allowBuilds.isEmpty && configDependencies.isEmpty;
}

/// Read `<projectRoot>/pnpm-workspace.yaml`. Returns an empty config
/// when the file is absent or unreadable; returns the parsed
/// install-relevant subset otherwise.
Future<PnpmWorkspaceConfig> readPnpmWorkspaceConfig(String projectRoot) async {
  final file = File(p.join(projectRoot, 'pnpm-workspace.yaml'));
  if (!await file.exists()) return const PnpmWorkspaceConfig();
  final String body;
  try {
    body = await file.readAsString();
  } on FileSystemException {
    return const PnpmWorkspaceConfig();
  }
  final Object? doc;
  try {
    doc = loadYaml(body);
  } on YamlException {
    return const PnpmWorkspaceConfig();
  }
  if (doc is! Map) return const PnpmWorkspaceConfig();

  final allowBuilds = <String>[];
  final raw = doc['allowBuilds'];
  if (raw is List) {
    for (final entry in raw) {
      if (entry is String && entry.isNotEmpty) allowBuilds.add(entry);
    }
  }

  final configDeps = <String, String>{};
  final rawConfigDeps = doc['configDependencies'];
  if (rawConfigDeps is Map) {
    for (final entry in rawConfigDeps.entries) {
      if (entry.key is! String) continue;
      final value = entry.value;
      if (value is String && value.isNotEmpty) {
        configDeps[entry.key as String] = value;
      } else if (value is Map) {
        final v = value['version'];
        if (v is String && v.isNotEmpty) {
          configDeps[entry.key as String] = v;
        }
      }
    }
  }

  return PnpmWorkspaceConfig(
    allowBuilds: List.unmodifiable(allowBuilds),
    configDependencies: Map.unmodifiable(configDeps),
  );
}
