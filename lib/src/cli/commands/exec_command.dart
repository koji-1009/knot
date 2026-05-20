import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

class ExecCommand extends Command<int> {
  ExecCommand() {
    argParser.addOption(
      'cwd',
      help: 'Project root (defaults to current directory).',
    );
  }

  @override
  String get name => 'exec';

  @override
  String get description => 'Run a binary from node_modules/.bin.';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('command name required');
    }
    final projectRoot =
        (argResults!['cwd'] as String?) ?? Directory.current.path;
    final binary = rest.first;
    final binDir = p.join(projectRoot, 'node_modules', '.bin');
    final executable = Platform.isWindows
        ? p.join(binDir, '$binary.cmd')
        : p.join(binDir, binary);
    if (!File(executable).existsSync() && !Link(executable).existsSync()) {
      throw UsageError('no executable named "$binary" in node_modules/.bin');
    }
    final process = await Process.start(
      executable,
      rest.skip(1).toList(),
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}
