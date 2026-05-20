import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/lockfile/lockfile.dart';

class WhyCommand extends Command<int> {
  @override
  String get name => 'why';

  @override
  String get description =>
      'Explain why a package is part of the dependency graph.';

  @override
  Future<int> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      usageException('a package name is required');
    }
    final target = args.first;
    final projectRoot = Directory.current.path;
    final lock = await readProjectLockfile(projectRoot);
    if (lock == null) {
      throw UsageError('no lockfile — run "knot install" first');
    }
    final chains = <List<String>>[];
    final root = lock.importers['.'] ?? const Importer();
    final initial = {...root.dependencies, ...root.devDependencies};
    for (final entry in initial.entries) {
      _dfs(
        lock,
        entry.key,
        target,
        path: ['(root) → ${entry.key}'],
        visited: <String>{},
        chains: chains,
      );
    }
    if (chains.isEmpty) {
      stdout.writeln('$target is not in the dependency graph');
      return 1;
    }
    for (final chain in chains) {
      stdout.writeln(chain.join(' → '));
    }
    return 0;
  }

  void _dfs(
    Lockfile lock,
    String current,
    String target, {
    required List<String> path,
    required Set<String> visited,
    required List<List<String>> chains,
  }) {
    if (current == target) {
      chains.add(List<String>.from(path));
      return;
    }
    final pkg = lock.packages.values.firstWhere(
      (p) => p.name == current,
      orElse: () => LockedPackage(
        name: current,
        version: '?',
        resolution: const Resolution.tarball(tarball: null),
      ),
    );
    if (pkg.version == '?') return;
    if (!visited.add('${pkg.name}@${pkg.version}')) return;
    for (final d in pkg.dependencies.keys) {
      _dfs(
        lock,
        d,
        target,
        path: [...path, d],
        visited: visited,
        chains: chains,
      );
    }
  }
}
