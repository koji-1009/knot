import 'dart:convert';
import 'dart:io';

import 'package:knot/src/core/core.dart';

/// Minimal `package.json` reader — only the fields knot consumes.
class PackageJson {
  PackageJson({
    required this.name,
    required this.version,
    this.dependencies = const {},
    this.devDependencies = const {},
    this.optionalDependencies = const {},
    this.peerDependencies = const {},
    this.scripts = const {},
    this.overrides = const {},
    this.nestedOverrides = const {},
    this.bin = const {},
    this.workspaces = const [],
    this.onlyBuiltDependencies = const [],
    this.engines = const {},
    this.packageManager,
  });

  final String name;
  final String version;
  final Map<String, String> dependencies;
  final Map<String, String> devDependencies;
  final Map<String, String> optionalDependencies;
  final Map<String, String> peerDependencies;
  final Map<String, String> scripts;

  /// Flat overrides: `pkg → range` applied wherever `pkg` shows up.
  final Map<String, String> overrides;

  /// Nested overrides: `parent → pkg → range`. Applied only when `pkg`
  /// appears as a dependency of `parent`.
  final Map<String, Map<String, String>> nestedOverrides;

  final Map<String, String> bin;
  final List<String> workspaces;

  /// Whitelist of dependencies whose install/postinstall scripts are
  /// allowed to run. When empty (default), all scripts are allowed.
  final List<String> onlyBuiltDependencies;

  /// `engines` field — typically `{ node: ">=18" }`.
  final Map<String, String> engines;

  /// `packageManager` field (corepack), e.g. `"knot@0.1.0"`.
  final String? packageManager;

  static Future<PackageJson> read(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw UsageError('no package.json at $path');
    }
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw UsageError('$path is not a JSON object');
    }
    return fromJson(Map<String, dynamic>.from(decoded));
  }

  static PackageJson fromJson(Map<String, dynamic> json) {
    Map<String, String> strMap(Object? n) {
      if (n is! Map) return const {};
      return {for (final e in n.entries) e.key as String: '${e.value}'};
    }

    final rawBin = json['bin'];
    final bin = rawBin is String
        ? {(json['name'] as String? ?? ''): rawBin}
        : strMap(rawBin);

    final workspaces = <String>[];
    final rawWorkspaces = json['workspaces'];
    if (rawWorkspaces is List) {
      workspaces.addAll(rawWorkspaces.cast<String>());
    } else if (rawWorkspaces is Map) {
      final packages = rawWorkspaces['packages'];
      if (packages is List) workspaces.addAll(packages.cast<String>());
    }

    final (flatOverrides, nestedOverrides) = _parseOverrides(json['overrides']);

    final onlyBuilt = <String>[];
    final rawOnly = json['onlyBuiltDependencies'];
    if (rawOnly is List) {
      onlyBuilt.addAll(rawOnly.map((e) => '$e'));
    }

    return PackageJson(
      name: (json['name'] as String?) ?? '',
      version: (json['version'] as String?) ?? '0.0.0',
      dependencies: strMap(json['dependencies']),
      devDependencies: strMap(json['devDependencies']),
      optionalDependencies: strMap(json['optionalDependencies']),
      peerDependencies: strMap(json['peerDependencies']),
      scripts: strMap(json['scripts']),
      overrides: flatOverrides,
      nestedOverrides: nestedOverrides,
      bin: bin,
      workspaces: workspaces,
      onlyBuiltDependencies: onlyBuilt,
      engines: strMap(json['engines']),
      packageManager: json['packageManager'] as String?,
    );
  }
}

/// Parse the `overrides` field — splitting into `flat` (applies everywhere)
/// and `nested` (`parent → child → range`) maps.
///
/// Supported syntaxes:
/// - `"foo": "1.0.0"`           — flat `foo`
/// - `"foo>bar": "1.0.0"`       — nested `foo > bar`
/// - `"foo": { ".": "1.0.0" }`  — flat `foo` (via object form)
/// - `"foo": { "bar": "2.0.0" }`— nested `foo > bar`
(Map<String, String>, Map<String, Map<String, String>>) _parseOverrides(
  Object? raw,
) {
  final flat = <String, String>{};
  final nested = <String, Map<String, String>>{};
  if (raw is! Map) return (flat, nested);
  for (final entry in raw.entries) {
    final key = entry.key as String;
    final value = entry.value;
    if (key.contains('>')) {
      final parts = key.split('>').map((s) => s.trim()).toList();
      if (parts.length == 2 && value is String) {
        nested.putIfAbsent(parts[0], () => <String, String>{})[parts[1]] =
            value;
      }
      continue;
    }
    if (value is String) {
      flat[key] = value;
    } else if (value is Map) {
      for (final inner in value.entries) {
        final ik = inner.key as String;
        if (ik == '.') {
          flat[key] = '${inner.value}';
        } else {
          nested.putIfAbsent(key, () => <String, String>{})[ik] =
              '${inner.value}';
        }
      }
    }
  }
  return (flat, nested);
}
