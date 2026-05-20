import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:path/path.dart' as p;

/// `knot doctor` — environment / registry / store health diagnostics.
class DoctorCommand extends Command<int> {
  @override
  String get name => 'doctor';

  @override
  String get description => 'Diagnose node / registry / cache / store health.';

  @override
  Future<int> run() async {
    var failed = 0;

    stdout.writeln('node version:');
    try {
      final result = await Process.run('node', ['--version']);
      stdout.writeln('  ${result.stdout.toString().trim()}');
    } on ProcessException {
      stderr.writeln('  node not found on PATH');
      failed++;
    }

    final root = Directory.current.path;
    stdout.writeln('npmrc resolved:');
    final npmrc = await NpmrcLoader(projectDir: root).load();
    stdout.writeln('  registry: ${npmrc.registry}');

    stdout.writeln('registry reachability:');
    final client = RegistryClient(config: npmrc);
    try {
      try {
        await client.packument('npm');
        stdout.writeln('  ok');
      } on NetworkError catch (e) {
        stderr.writeln('  FAIL: ${e.message}');
        failed++;
      }
    } finally {
      client.close();
    }

    stdout.writeln('store path:');
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final storeDir = Directory(p.join(home, '.knot', 'store'));
    stdout.writeln(
      '  ${storeDir.path}'
      ' (${storeDir.existsSync() ? 'present' : 'missing'})',
    );

    return failed == 0 ? 0 : 1;
  }
}
