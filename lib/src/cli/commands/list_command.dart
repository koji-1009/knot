import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/lockfile/lockfile.dart';

class ListCommand extends Command<int> {
  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['ls'];

  @override
  String get description => 'Print the resolved dependency tree.';

  @override
  Future<int> run() async {
    final projectRoot = Directory.current.path;
    final lock = await readProjectLockfile(projectRoot);
    if (lock == null) {
      throw UsageError(
        'no lockfile in $projectRoot — run "knot install" first',
      );
    }
    final root = lock.importers['.'] ?? const Importer();
    final visited = <String>{};
    for (final entry in {
      ...root.dependencies,
      ...root.devDependencies,
    }.entries) {
      _walk(lock, entry.key, entry.value, depth: 0, visited: visited);
    }
    return 0;
  }

  void _walk(
    Lockfile lock,
    String name,
    String range, {
    required int depth,
    required Set<String> visited,
  }) {
    final resolved = lock.packages.values.firstWhere(
      (p) => p.name == name,
      orElse: () => LockedPackage(
        name: name,
        version: '?',
        resolution: const Resolution.tarball(tarball: null),
      ),
    );
    final indent = '  ' * depth;
    final id = '$name@${resolved.version}';
    final marker = visited.contains(id) ? ' (^)' : '';
    stdout.writeln('$indent- $name@${resolved.version} <- $range$marker');
    if (resolved.version == '?' || marker.isNotEmpty) return;
    visited.add(id);
    for (final d in resolved.dependencies.entries) {
      _walk(lock, d.key, d.value, depth: depth + 1, visited: visited);
    }
  }
}
