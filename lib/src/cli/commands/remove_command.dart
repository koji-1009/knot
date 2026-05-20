import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

import '../install_operation.dart';
import '../package_json_edit.dart';
import '../progress_renderer.dart';
import '../runner.dart';

class RemoveCommand extends Command<int> {
  RemoveCommand({KnotLogger? logger})
    : _logger = logger ?? KnotLogger('knot.remove');

  final KnotLogger _logger;

  @override
  String get name => 'remove';

  @override
  List<String> get aliases => const ['rm'];

  @override
  String get description => 'Remove one or more dependencies.';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('at least one package name is required');
    }
    final root = Directory.current.path;
    final editor = PackageJsonEditor(p.join(root, 'package.json'));
    for (final name in rest) {
      await editor.removeDependency(name);
      _logger.info('removed $name');
    }
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
}
