import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

/// `knot pkg get|set|delete` — minimal package.json field manipulator.
class PkgCommand extends Command<int> {
  PkgCommand() {
    addSubcommand(_PkgGet());
    addSubcommand(_PkgSet());
    addSubcommand(_PkgDelete());
  }

  @override
  String get name => 'pkg';

  @override
  String get description =>
      'Read / write fields on package.json (e.g. `pkg get name`, `pkg set scripts.test=jest`).';
}

class _PkgGet extends Command<int> {
  @override
  String get name => 'get';

  @override
  String get description => 'Print a field value from package.json.';

  @override
  Future<int> run() async {
    final fields = argResults!.rest;
    if (fields.isEmpty) usageException('at least one field name is required');
    final json = await _loadPkg();
    final out = <String, dynamic>{};
    for (final f in fields) {
      out[f] = _walk(json, f);
    }
    if (out.length == 1) {
      stdout.writeln(const JsonEncoder().convert(out.values.first));
    } else {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
    }
    return 0;
  }
}

class _PkgSet extends Command<int> {
  @override
  String get name => 'set';

  @override
  String get description => 'Write a field (path=value form).';

  @override
  Future<int> run() async {
    final assignments = argResults!.rest;
    if (assignments.isEmpty) {
      usageException('at least one path=value is required');
    }
    final json = await _loadPkg();
    for (final a in assignments) {
      final eq = a.indexOf('=');
      if (eq < 0) usageException('expected path=value, got "$a"');
      final path = a.substring(0, eq);
      final raw = a.substring(eq + 1);
      _setAtPath(json, path, _decode(raw));
    }
    await _writePkg(json);
    return 0;
  }
}

class _PkgDelete extends Command<int> {
  @override
  String get name => 'delete';

  @override
  String get description => 'Remove a field from package.json.';

  @override
  Future<int> run() async {
    final paths = argResults!.rest;
    if (paths.isEmpty) usageException('at least one field path is required');
    final json = await _loadPkg();
    for (final path in paths) {
      _deleteAtPath(json, path);
    }
    await _writePkg(json);
    return 0;
  }
}

// --- shared helpers --------------------------------------------------------

String _path() => p.join(Directory.current.path, 'package.json');

Future<Map<String, dynamic>> _loadPkg() async {
  final path = _path();
  final String body;
  try {
    body = await File(path).readAsString();
  } on FileSystemException catch (e) {
    throw ManifestError(
      'failed to read package.json at $path: ${e.message}',
      cause: e,
      path: path,
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    final offset = e.offset;
    final where = offset == null ? '' : ' at offset $offset';
    throw ManifestError(
      'package.json at $path is not valid JSON$where: ${e.message}',
      cause: e,
      path: path,
    );
  }
  if (decoded is! Map) {
    throw ManifestError(
      'package.json at $path is not a JSON object',
      path: path,
    );
  }
  return Map<String, dynamic>.from(decoded);
}

Future<void> _writePkg(Map<String, dynamic> json) async {
  await File(
    _path(),
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(json)}\n');
}

Object? _walk(Map<String, dynamic> root, String path) {
  Object? cursor = root;
  for (final segment in path.split('.')) {
    if (cursor is Map) {
      cursor = (cursor)[segment];
    } else {
      return null;
    }
  }
  return cursor;
}

void _setAtPath(Map<String, dynamic> root, String path, Object? value) {
  final segments = path.split('.');
  Map<String, dynamic> cursor = root;
  for (var i = 0; i < segments.length - 1; i++) {
    final segment = segments[i];
    final next = cursor[segment];
    if (next is Map<String, dynamic>) {
      cursor = next;
    } else {
      final fresh = <String, dynamic>{};
      cursor[segment] = fresh;
      cursor = fresh;
    }
  }
  cursor[segments.last] = value;
}

void _deleteAtPath(Map<String, dynamic> root, String path) {
  final segments = path.split('.');
  Map<String, dynamic> cursor = root;
  for (var i = 0; i < segments.length - 1; i++) {
    final next = cursor[segments[i]];
    if (next is Map<String, dynamic>) {
      cursor = next;
    } else {
      return;
    }
  }
  cursor.remove(segments.last);
}

Object? _decode(String raw) {
  if (raw == 'true') return true;
  if (raw == 'false') return false;
  if (raw == 'null') return null;
  final asInt = int.tryParse(raw);
  if (asInt != null) return asInt;
  final asDouble = double.tryParse(raw);
  if (asDouble != null) return asDouble;
  if (raw.startsWith('[') || raw.startsWith('{')) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      // fall through to raw string
    }
  }
  return raw;
}
