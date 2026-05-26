import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/core/core.dart';

import 'lockfile.dart';

/// Import an npm `package-lock.json` (v3) and translate it.
Future<Lockfile> importNpmLockfile(String path) async {
  final bytes = await File(path).readAsBytes();
  return importNpmLockfileFromBytes(bytes, path: path);
}

/// Same as [importNpmLockfile] but operates on pre-read bytes — used
/// by the install path so the lockfile is opened once and shared
/// between the workspace-state fingerprint (sha256 of bytes) and the
/// parsed in-memory shape (json decode of bytes).
Lockfile importNpmLockfileFromBytes(Uint8List bytes, {required String path}) {
  final raw = utf8.decode(bytes);
  final root = jsonDecode(raw);
  if (root is! Map) {
    throw LockfileError('package-lock.json root is not an object', path: path);
  }

  // npm v3+ stores the project's declared dep ranges under
  // `packages[""]`. Older v1 lockfiles put them at the file root
  // (and only the v1 form had top-level `dependencies` as a nested
  // tree). Read both shapes so v3 round-trips cleanly and v1 still
  // works as a degraded import path.
  final nodes = root['packages'];
  Importer rootImporter;
  if (nodes is Map && nodes[''] is Map) {
    final r = Map<String, dynamic>.from(nodes[''] as Map);
    rootImporter = Importer(
      dependencies: _stringMap(r['dependencies']),
      devDependencies: _stringMap(r['devDependencies']),
      optionalDependencies: _stringMap(r['optionalDependencies']),
      peerDependencies: _stringMap(r['peerDependencies']),
    );
  } else {
    rootImporter = Importer(
      dependencies: _stringMap(root['dependencies']),
      devDependencies: _stringMap(root['devDependencies']),
      optionalDependencies: _stringMap(root['optionalDependencies']),
      peerDependencies: _stringMap(root['peerDependencies']),
    );
  }
  final importers = <String, Importer>{'.': rootImporter};

  final packages = <String, LockedPackage>{};
  if (nodes is Map) {
    for (final entry in nodes.entries) {
      final key = entry.key as String;
      if (key.isEmpty) continue; // root project entry
      final value = Map<String, dynamic>.from(entry.value as Map);
      final name = value['name'] as String? ?? _packageNameFromPath(key);
      final version = value['version'] as String?;
      if (name == null || version == null) continue;
      final integrity = value['integrity'] as String?;
      final resolved = value['resolved'] as String?;

      // Pick up the knot-specific extensions we may have written
      // ourselves on a previous run. These are tolerated by npm.
      final signatures = <LockedSignature>[];
      final rawSigs = value['_signatures'];
      if (rawSigs is List) {
        for (final entry in rawSigs) {
          if (entry is! Map) continue;
          final keyid = entry['keyid'];
          final sig = entry['sig'];
          if (keyid is String && sig is String) {
            signatures.add(LockedSignature(keyid: keyid, sig: sig));
          }
        }
      }

      packages['$name@$version'] = LockedPackage(
        name: name,
        version: version,
        resolution: Resolution.tarball(tarball: resolved),
        integrity: integrity,
        dependencies: _stringMap(value['dependencies']),
        optionalDependencies: _stringMap(value['optionalDependencies']),
        peerDependencies: _stringMap(value['peerDependencies']),
        os: _stringList(value['os']),
        cpu: _stringList(value['cpu']),
        hasBin: value['bin'] != null,
        hasInstallScript: value['hasInstallScript'] == true,
        bin: _stringMap(value['bin']),
        scripts: _stringMap(value['_scripts']),
        engines: _stringMap(value['engines']),
        signatures: signatures,
        installPath: key.startsWith('node_modules/')
            ? key.substring('node_modules/'.length)
            : null,
      );
    }
  }

  return Lockfile(
    lockfileVersion: knotLockfileVersion,
    importers: importers,
    packages: packages,
  );
}

Map<String, String> _stringMap(Object? node) {
  if (node is! Map) return const {};
  return {for (final e in node.entries) e.key as String: '${e.value}'};
}

List<String> _stringList(Object? node) {
  if (node is! List) return const [];
  return [for (final e in node) '$e'];
}

String? _packageNameFromPath(String key) {
  // package-lock.json v3 keys look like `node_modules/<name>` or
  // `node_modules/<scope>/<name>` for scoped packages.
  const prefix = 'node_modules/';
  if (!key.startsWith(prefix)) return null;
  final rest = key.substring(prefix.length);
  final inner = rest.lastIndexOf('/node_modules/');
  final tail = inner >= 0
      ? rest.substring(inner + '/node_modules/'.length)
      : rest;
  return tail;
}
