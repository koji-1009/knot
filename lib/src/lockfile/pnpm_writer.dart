import 'dart:io';

import 'pnpm_reader.dart';

/// Emit [lockfile] as a pnpm-lock.yaml v9 block-style document.
///
/// Phase A of the v11 alignment plan demands semantic round-trip
/// preservation: re-serializing a parsed lockfile should reproduce
/// the same logical content (settings, importers, packages, etc. +
/// every unknown top-level field). We **do not** try to byte-preserve
/// the original's whitespace / comment layout — that requires
/// `yaml_edit` and a much larger investment.
///
/// Top-level key order matches what pnpm itself emits:
/// `lockfileVersion → settings → importers → packages → snapshots →
/// catalog → catalogs → preserved fields (alphabetical)`.
String writePnpmLockfileString(PnpmLockfile lockfile) {
  final buf = StringBuffer();
  buf.writeln("lockfileVersion: '${lockfile.lockfileVersion}'");
  buf.writeln();

  if (lockfile.settings.isNotEmpty) {
    buf.writeln('settings:');
    _writeMap(buf, lockfile.settings, 1);
    buf.writeln();
  }

  if (lockfile.importers.isNotEmpty) {
    buf.writeln('importers:');
    for (final entry in _sortedKeys(lockfile.importers.keys)) {
      _writeKey(buf, entry, 1);
      buf.writeln();
      _writeImporter(buf, lockfile.importers[entry]!, 2);
    }
    buf.writeln();
  }

  if (lockfile.packages.isNotEmpty) {
    buf.writeln('packages:');
    for (final id in _sortedKeys(lockfile.packages.keys)) {
      _writeKey(buf, id, 1);
      buf.writeln();
      _writePackageEntry(buf, lockfile.packages[id]!, 2);
    }
    buf.writeln();
  }

  if (lockfile.snapshots.isNotEmpty) {
    buf.writeln('snapshots:');
    for (final id in _sortedKeys(lockfile.snapshots.keys)) {
      _writeKey(buf, id, 1);
      buf.writeln();
      _writeSnapshotEntry(buf, lockfile.snapshots[id]!, 2);
    }
    buf.writeln();
  }

  final defaultCat = lockfile.catalogs['default'];
  if (defaultCat != null && defaultCat.isNotEmpty) {
    buf.writeln('catalog:');
    _writeMap(buf, defaultCat, 1);
    buf.writeln();
  }

  final namedCatalogs = <String, Map<String, String>>{};
  for (final entry in lockfile.catalogs.entries) {
    if (entry.key == 'default') continue;
    namedCatalogs[entry.key] = entry.value;
  }
  if (namedCatalogs.isNotEmpty) {
    buf.writeln('catalogs:');
    for (final name in _sortedKeys(namedCatalogs.keys)) {
      _writeKey(buf, name, 1);
      buf.writeln();
      _writeMap(buf, namedCatalogs[name]!, 2);
    }
    buf.writeln();
  }

  for (final name in _sortedKeys(lockfile.preservedTopLevel.keys)) {
    _writeValueAtTop(buf, name, lockfile.preservedTopLevel[name]);
  }

  return buf.toString();
}

/// Convenience wrapper for `writePnpmLockfileString` writing to disk.
Future<void> writePnpmLockfile(String path, PnpmLockfile lockfile) async {
  await File(path).writeAsString(writePnpmLockfileString(lockfile));
}

void _writeImporter(StringBuffer buf, PnpmImporter imp, int indent) {
  void writeGroup(String key, Map<String, PnpmDirectDep> deps) {
    if (deps.isEmpty) return;
    _writeKey(buf, key, indent);
    buf.writeln();
    for (final name in _sortedKeys(deps.keys)) {
      final dep = deps[name]!;
      _writeKey(buf, name, indent + 1);
      buf.writeln();
      _writePair(buf, 'specifier', dep.specifier, indent + 2);
      _writePair(buf, 'version', dep.version, indent + 2);
    }
  }

  writeGroup('dependencies', imp.dependencies);
  writeGroup('devDependencies', imp.devDependencies);
  writeGroup('optionalDependencies', imp.optionalDependencies);
  writeGroup('peerDependencies', imp.peerDependencies);
}

void _writePackageEntry(StringBuffer buf, PnpmPackageEntry pkg, int indent) {
  if (pkg.resolution.isNotEmpty) {
    _writeKey(buf, 'resolution', indent);
    buf.writeln();
    _writeMap(buf, pkg.resolution, indent + 1);
  }
  if (pkg.engines.isNotEmpty) {
    _writeKey(buf, 'engines', indent);
    buf.writeln();
    _writeMap(buf, pkg.engines, indent + 1);
  }
  if (pkg.os.isNotEmpty) {
    _writeList(buf, 'os', pkg.os, indent);
  }
  if (pkg.cpu.isNotEmpty) {
    _writeList(buf, 'cpu', pkg.cpu, indent);
  }
  if (pkg.peerDependencies.isNotEmpty) {
    _writeKey(buf, 'peerDependencies', indent);
    buf.writeln();
    _writeMap(buf, pkg.peerDependencies, indent + 1);
  }
  if (pkg.peerDependenciesMeta.isNotEmpty) {
    _writeKey(buf, 'peerDependenciesMeta', indent);
    buf.writeln();
    for (final name in _sortedKeys(pkg.peerDependenciesMeta.keys)) {
      _writeKey(buf, name, indent + 1);
      buf.writeln();
      _writeMap(buf, pkg.peerDependenciesMeta[name]!, indent + 2);
    }
  }
  if (pkg.hasBin) _writePair(buf, 'hasBin', true, indent);
  if (pkg.deprecated != null) {
    _writePair(buf, 'deprecated', pkg.deprecated, indent);
  }
  if (pkg.bundledDependencies.isNotEmpty) {
    _writeList(buf, 'bundledDependencies', pkg.bundledDependencies, indent);
  }
  for (final name in _sortedKeys(pkg.preserved.keys)) {
    _writeValueAtTop(buf, name, pkg.preserved[name], indent: indent);
  }
}

void _writeSnapshotEntry(StringBuffer buf, PnpmSnapshotEntry snap, int indent) {
  if (snap.dependencies.isNotEmpty) {
    _writeKey(buf, 'dependencies', indent);
    buf.writeln();
    _writeMap(buf, snap.dependencies, indent + 1);
  }
  if (snap.optionalDependencies.isNotEmpty) {
    _writeKey(buf, 'optionalDependencies', indent);
    buf.writeln();
    _writeMap(buf, snap.optionalDependencies, indent + 1);
  }
  if (snap.transitivePeerDependencies.isNotEmpty) {
    _writeList(
      buf,
      'transitivePeerDependencies',
      snap.transitivePeerDependencies,
      indent,
    );
  }
  for (final name in _sortedKeys(snap.preserved.keys)) {
    _writeValueAtTop(buf, name, snap.preserved[name], indent: indent);
  }
}

void _writeValueAtTop(
  StringBuffer buf,
  String key,
  Object? value, {
  int indent = 0,
}) {
  if (value is Map) {
    _writeKey(buf, key, indent);
    buf.writeln();
    _writeMap(buf, Map<String, Object?>.from(value), indent + 1);
  } else if (value is List) {
    _writeList(buf, key, value.map((e) => '$e').toList(), indent);
  } else {
    _writePair(buf, key, value, indent);
  }
}

void _writeMap(StringBuffer buf, Map<String, Object?> map, int indent) {
  for (final key in _sortedKeys(map.keys)) {
    final value = map[key];
    if (value is Map) {
      _writeKey(buf, key, indent);
      buf.writeln();
      _writeMap(buf, Map<String, Object?>.from(value), indent + 1);
    } else if (value is List) {
      _writeList(
        buf,
        key,
        value.map((e) => e is String ? e : '$e').toList(),
        indent,
      );
    } else {
      _writePair(buf, key, value, indent);
    }
  }
}

void _writeList(StringBuffer buf, String key, List<String> items, int indent) {
  _writeKey(buf, key, indent);
  buf.writeln();
  final pad = '  ' * (indent + 1);
  for (final item in items) {
    buf.writeln('$pad- ${_yamlScalar(item)}');
  }
}

void _writePair(StringBuffer buf, String key, Object? value, int indent) {
  final pad = '  ' * indent;
  buf.writeln('$pad${_yamlKey(key)}: ${_yamlScalar(value)}');
}

void _writeKey(StringBuffer buf, String key, int indent) {
  final pad = '  ' * indent;
  buf.write('$pad${_yamlKey(key)}:');
}

String _yamlKey(String key) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_\-.]*$').hasMatch(key)
    ? key
    : "'${key.replaceAll("'", "''")}'";

String _yamlScalar(Object? value) {
  if (value == null) return '~';
  if (value is bool || value is num) return '$value';
  final s = '$value';
  // Quote when the string needs it. A bare scalar is fine for typical
  // npm versions, sha512-… integrity strings, GitHub URLs, ranges
  // with `^`, `<`, etc. Quote when:
  //   - contains characters that need quoting in YAML flow context
  //   - starts with `>` `!` `&` `*` `|` `'` `"` or `#`
  //   - is `true`/`false`/`null`/`yes`/`no` (avoid type coercion)
  final reserved = {'true', 'false', 'null', 'yes', 'no', 'on', 'off'};
  if (reserved.contains(s.toLowerCase())) {
    return "'$s'";
  }
  if (s.isEmpty) return "''";
  final firstByte = s.codeUnitAt(0);
  const dangerousStarters = {
    0x3E, // >
    0x21, // !
    0x26, // &
    0x2A, // *
    0x7C, // |
    0x27, // '
    0x22, // "
    0x23, // #
    0x60, // `
    0x40, // @
    0x25, // %
    0x3A, // :
    0x3F, // ?
  };
  if (dangerousStarters.contains(firstByte)) {
    return "'${s.replaceAll("'", "''")}'";
  }
  if (s.contains(': ') ||
      s.contains(' #') ||
      s.contains('\n') ||
      s.contains(',') ||
      s.contains('{') ||
      s.contains('}') ||
      s.contains('[') ||
      s.contains(']')) {
    return "'${s.replaceAll("'", "''")}'";
  }
  return s;
}

Iterable<String> _sortedKeys(Iterable<String> keys) => keys.toList()..sort();
