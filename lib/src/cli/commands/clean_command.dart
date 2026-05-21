import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

/// `knot clean` — wipe per-project install artifacts.
///
/// pnpm-compatible (`pnpm clean`): removes `node_modules` and the
/// workspace state file by default; `--lockfile` / `-l` also deletes
/// the project lockfile (either npm-mode `package-lock.json` or
/// pnpm-mode `pnpm-lock.yaml`, whichever is present).
class CleanCommand extends Command<int> {
  CleanCommand() {
    argParser
      ..addFlag(
        'lockfile',
        abbr: 'l',
        negatable: false,
        help: 'Also delete the project lockfile.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print what would be removed without touching the filesystem.',
      );
  }

  @override
  String get name => 'clean';

  @override
  String get description =>
      'Remove node_modules + workspace state (and optionally the lockfile).';

  @override
  Future<int> run() => cleanProject(
        projectRoot: Directory.current.path,
        dryRun: argResults!['dry-run'] as bool,
        deleteLockfile: argResults!['lockfile'] as bool,
      );
}

/// Library-level entry point for the clean logic. Pulled out so tests
/// can drive it without mutating `Directory.current`, which would race
/// with other parallel tests in the suite.
Future<int> cleanProject({
  required String projectRoot,
  required bool dryRun,
  required bool deleteLockfile,
  IOSink? out,
  IOSink? err,
}) async {
  // ignore: close_sinks — stdout/stderr survive the process lifetime.
  final stdoutSink = out ?? stdout;
  // ignore: close_sinks
  final stderrSink = err ?? stderr;

  final targets = <String>[
    p.join(projectRoot, 'node_modules'),
    p.join(projectRoot, 'node_modules', '.knot', 'workspace-state.json'),
  ];
  if (deleteLockfile) {
    // Prefer pnpm-lock.yaml when present (pnpm-mode), fall back to
    // package-lock.json. Removing both is safe — they are mode-
    // exclusive on a healthy project.
    targets.add(p.join(projectRoot, 'pnpm-lock.yaml'));
    targets.add(p.join(projectRoot, 'package-lock.json'));
  }

  for (final path in targets) {
    final dir = Directory(path);
    final file = File(path);
    final dirExists = await dir.exists();
    final fileExists = !dirExists && await file.exists();
    if (!dirExists && !fileExists) continue;
    if (dryRun) {
      stdoutSink.writeln('would remove $path');
      continue;
    }
    try {
      if (dirExists) {
        await dir.delete(recursive: true);
      } else {
        await file.delete();
      }
      stdoutSink.writeln('removed $path');
    } on FileSystemException catch (e) {
      stderrSink.writeln('failed to remove $path: ${e.message}');
      return 1;
    }
  }

  return 0;
}
