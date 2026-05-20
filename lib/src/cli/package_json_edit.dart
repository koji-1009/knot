import 'dart:convert';
import 'dart:io';

import 'package:knot/src/core/core.dart';

/// Where to record a dependency added via `knot add`.
enum DependencyKind { prod, dev, optional, peer }

/// In-place editor for a project's `package.json`.
///
/// Reads the file, applies a mutation, and writes it back with a stable
/// two-space indent (preserving common conventions; full whitespace round-trip
/// is out of scope here).
class PackageJsonEditor {
  PackageJsonEditor(this.path);
  final String path;

  Future<void> addDependency(
    String name,
    String range,
    DependencyKind kind,
  ) async {
    final key = switch (kind) {
      DependencyKind.prod => 'dependencies',
      DependencyKind.dev => 'devDependencies',
      DependencyKind.optional => 'optionalDependencies',
      DependencyKind.peer => 'peerDependencies',
    };
    await _mutate((json) {
      final group = (json[key] as Map?)?.cast<String, dynamic>() ?? {};
      group[name] = range;
      json[key] = group;
    });
  }

  Future<void> removeDependency(String name) async {
    await _mutate((json) {
      for (final key in const [
        'dependencies',
        'devDependencies',
        'optionalDependencies',
        'peerDependencies',
      ]) {
        final group = json[key];
        if (group is Map) {
          group.remove(name);
          if (group.isEmpty) json.remove(key);
        }
      }
    });
  }

  Future<void> _mutate(void Function(Map<String, dynamic>) edit) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw UsageError('no package.json at $path');
    }
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw UsageError('$path is not a JSON object');
    }
    final map = Map<String, dynamic>.from(decoded);
    edit(map);
    final body = const JsonEncoder.withIndent('  ').convert(map);
    final tmp = '$path.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final tmpFile = File(tmp);
    await tmpFile.writeAsString('$body\n', flush: true);
    await tmpFile.rename(path);
  }
}
