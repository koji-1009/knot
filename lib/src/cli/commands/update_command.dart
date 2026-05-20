import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/lockfile/lockfile.dart';

import '../install_operation.dart';
import '../progress_renderer.dart';
import '../runner.dart';

class UpdateCommand extends Command<int> {
  UpdateCommand({KnotLogger? logger})
    : _logger = logger ?? KnotLogger('knot.update');

  final KnotLogger _logger;

  @override
  String get name => 'update';

  @override
  List<String> get aliases => const ['up'];

  @override
  String get description => 'Refresh the lockfile and reinstall.';

  @override
  Future<int> run() async {
    final root = Directory.current.path;
    final args = argResults!.rest;
    final detected = detectExistingLockfile(root);
    if (detected != null) {
      if (args.isEmpty) {
        await File(detected.path).delete();
        _logger.info('removed ${detected.path} to refresh all versions');
      } else {
        _logger.info(
          'partial update is not yet implemented; '
          'delete ${detected.path} to refresh everything',
        );
      }
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
