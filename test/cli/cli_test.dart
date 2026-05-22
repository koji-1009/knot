import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

import '_test_binary.dart';

Future<TestProcess> _runKnot(
  List<String> args, {
  String? workingDirectory,
}) async {
  final bin = await knotTestBinary();
  return TestProcess.start(bin, args, workingDirectory: workingDirectory);
}

void main() {
  test('--version prints the version literal and exits 0', () async {
    final process = await _runKnot(['--version']);
    await expectLater(process.stdout, emitsThrough('0.0.1-dev'));
    await process.shouldExit(0);
  });

  test('--help lists every subcommand and exits 0', () async {
    final process = await _runKnot(['--help']);
    await expectLater(
      process.stdout,
      emitsThrough(contains('Available commands:')),
    );
    await process.shouldExit(0);
  });

  test('unknown command exits 64', () async {
    final process = await _runKnot(['bogus']);
    await expectLater(
      process.stderr,
      emitsThrough(contains('Could not find a command named "bogus"')),
    );
    await process.shouldExit(64);
  });

  test('add --no-install writes the dependency and exits 0', () async {
    await d.dir('proj', [
      d.file(
        'package.json',
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'name': 'demo', 'version': '0.0.0'}),
      ),
    ]).create();

    final projectDir = p.join(d.sandbox, 'proj');
    final process = await _runKnot([
      'add',
      'left-pad@^1.3.0',
      '--no-install',
    ], workingDirectory: projectDir);
    await process.shouldExit(0);

    final raw = await File(p.join(projectDir, 'package.json')).readAsString();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded['dependencies'], {'left-pad': '^1.3.0'});
  });

  test('install --json is rejected by the arg parser (exit 64)', () async {
    // `--json` is declared only on commands that actually emit JSON
    // (`audit`). For every other command it must be an unknown flag
    // rather than silently swallowed.
    final process = await _runKnot(['install', '--json']);
    await expectLater(
      process.stderr,
      emitsThrough(contains('Could not find an option named "--json"')),
    );
    await process.shouldExit(64);
  });

  test('audit --json is accepted as a local flag', () async {
    // Smoke check: arg parser must not reject `--json` for `audit`.
    // We don't need a project here — `audit` will fail at lockfile
    // discovery, which exits 64 with its own message, but the
    // failure must come from missing lockfile, not unknown option.
    final process = await _runKnot(['audit', '--json']);
    await expectLater(
      process.stderr,
      emitsThrough(contains('no lockfile found')),
    );
    await process.shouldExit(64);
  });

  test('add with no arguments exits 64 with usage', () async {
    await d.dir('proj', [
      d.file(
        'package.json',
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'name': 'demo', 'version': '0.0.0'}),
      ),
    ]).create();

    final process = await _runKnot([
      'add',
    ], workingDirectory: p.join(d.sandbox, 'proj'));
    await expectLater(
      process.stderr,
      emitsThrough(contains('package name is required')),
    );
    await process.shouldExit(64);
  });
}
