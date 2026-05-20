import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

import '../install_operation.dart';
import '../package_json_edit.dart';
import '../progress_renderer.dart';
import '../runner.dart';

class AddCommand extends Command<int> {
  AddCommand({KnotLogger? logger})
    : _logger = logger ?? KnotLogger('knot.add') {
    argParser
      ..addFlag(
        'dev',
        abbr: 'D',
        defaultsTo: false,
        help: 'Add to devDependencies.',
      )
      ..addFlag(
        'peer',
        abbr: 'P',
        defaultsTo: false,
        help: 'Add to peerDependencies.',
      )
      ..addFlag(
        'optional',
        abbr: 'O',
        defaultsTo: false,
        help: 'Add to optionalDependencies.',
      )
      ..addFlag(
        'no-install',
        defaultsTo: false,
        help: 'Edit package.json but skip install.',
      );
  }

  final KnotLogger _logger;

  @override
  String get name => 'add';

  @override
  String get description =>
      'Add one or more dependencies (use pkg@range for an explicit version).';

  @override
  Future<int> run() async {
    final results = argResults!;
    final rest = results.rest;
    if (rest.isEmpty) {
      usageException('at least one package name is required');
    }
    final kind = (results['dev'] as bool)
        ? DependencyKind.dev
        : (results['peer'] as bool)
        ? DependencyKind.peer
        : (results['optional'] as bool)
        ? DependencyKind.optional
        : DependencyKind.prod;

    final root = Directory.current.path;
    final editor = PackageJsonEditor(p.join(root, 'package.json'));
    for (final spec in rest) {
      final (pkgName, range) = _splitNameRange(spec);
      await editor.addDependency(pkgName, range, kind);
      _logger.info('added $pkgName@$range to ${kind.name} deps');
    }
    if (results['no-install'] as bool) return 0;

    final renderer = ProgressRenderer(level: logLevelFor(globalResults));
    try {
      final op = InstallOperation(
        projectRoot: root,
        options: const InstallOptions(),
        logger: _logger,
        onEvent: renderer.emit,
      );
      await op.run();
      return 0;
    } finally {
      renderer.close();
    }
  }

  (String, String) _splitNameRange(String spec) {
    final lastAt = spec.lastIndexOf('@');
    if (lastAt > 0) {
      return (spec.substring(0, lastAt), spec.substring(lastAt + 1));
    }
    return (spec, 'latest');
  }
}
