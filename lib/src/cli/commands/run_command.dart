import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

import '../package_json.dart';

class RunCommand extends Command<int> {
  @override
  String get name => 'run';

  @override
  String get description => 'Run a script declared in package.json.';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('script name is required');
    }
    final scriptName = rest.first;
    final extraArgs = rest.skip(1).toList();
    final projectRoot = Directory.current.path;

    final pkg = await PackageJson.read(p.join(projectRoot, 'package.json'));
    final script = pkg.scripts[scriptName];
    if (script == null) {
      throw UsageError('no script "$scriptName" in package.json');
    }
    final binDir = p.join(projectRoot, 'node_modules', '.bin');
    final env = <String, String>{
      ...Platform.environment,
      'PATH':
          '$binDir${Platform.isWindows ? ';' : ':'}'
          '${Platform.environment['PATH'] ?? ''}',
      'npm_lifecycle_event': scriptName,
      'npm_package_name': pkg.name,
      'npm_package_version': pkg.version,
    };
    final (exec, args) = Platform.isWindows
        ? ('cmd.exe', ['/C', '$script ${extraArgs.join(' ')}'])
        : ('/bin/sh', ['-c', '$script ${extraArgs.join(' ')}']);
    final process = await Process.start(
      exec,
      args,
      workingDirectory: projectRoot,
      environment: env,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}
