import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Compat fixture runner.
///
/// Builds the knot CLI, runs `knot install` against each fixture in
/// `tools/compat_test/fixtures/`, and reports per-fixture exit codes.
///
/// Skips the network-dependent run unless `KNOT_NETWORK=1` is set; the
/// nightly CI workflow exports that variable.
Future<void> main(List<String> args) async {
  if (Platform.environment['KNOT_NETWORK'] != '1') {
    stdout.writeln(
      'compat run skipped (set KNOT_NETWORK=1 to enable real-registry runs)',
    );
    return;
  }

  final repoRoot = _findRepoRoot();
  final fixturesDir = Directory(
    p.join(repoRoot, 'tools', 'compat_test', 'fixtures'),
  );
  if (!fixturesDir.existsSync()) {
    stderr.writeln('no fixtures directory found at ${fixturesDir.path}');
    exit(64);
  }

  // Compile the CLI once and reuse the native binary across all fixtures.
  // `dart run` per fixture pays a fresh JIT cost each time; the AOT binary
  // amortizes startup to a single up-front compile.
  final binPath = await _compileKnot(repoRoot);

  final fixtures = fixturesDir
      .listSync()
      .whereType<Directory>()
      .where((d) => File(p.join(d.path, 'package.json')).existsSync())
      .toList();
  if (fixtures.isEmpty) {
    stderr.writeln('no fixtures');
    exit(64);
  }

  var failed = 0;
  for (final fx in fixtures) {
    stdout.writeln('::group::compat ${p.basename(fx.path)}');
    final result = await Process.run(binPath, [
      'install',
      '--ignore-scripts',
    ], workingDirectory: fx.path);
    stdout
      ..writeln(result.stdout)
      ..writeln(result.stderr);
    if (result.exitCode != 0) {
      failed++;
      stderr.writeln('FAIL: install in ${fx.path} (exit ${result.exitCode})');
      stdout.writeln('::endgroup::');
      continue;
    }
    final smokeOk = await _smokeRequire(fx);
    if (!smokeOk) {
      failed++;
      stderr.writeln('FAIL: smoke require() in ${fx.path}');
    }
    stdout.writeln('::endgroup::');
  }
  exit(failed == 0 ? 0 : 1);
}

/// Pick one production dep from `package.json` and `node -e "require(...)"`
/// it. Returns true on success or when there are no production deps to test.
Future<bool> _smokeRequire(Directory fixture) async {
  final pkgFile = File(p.join(fixture.path, 'package.json'));
  final pkg = jsonDecode(await pkgFile.readAsString());
  if (pkg is! Map) return true;
  final deps = pkg['dependencies'];
  if (deps is! Map || deps.isEmpty) return true;
  final dep = deps.keys.first as String;
  // Skip non-registry specifiers — they're not always require-able by name.
  final spec = '${deps[dep]}';
  if (spec.startsWith('workspace:') ||
      spec.startsWith('file:') ||
      spec.startsWith('link:')) {
    return true;
  }
  final result = await Process.run('node', [
    '-e',
    "require('$dep')",
  ], workingDirectory: fixture.path);
  if (result.exitCode != 0) {
    stderr
      ..writeln(result.stdout)
      ..writeln(result.stderr);
    return false;
  }
  return true;
}

Future<String> _compileKnot(String repoRoot) async {
  final outDir = Directory.systemTemp.createTempSync('knot-compat-').path;
  final result = await Process.run('dart', [
    'build',
    'cli',
    // bin/ now carries the aot_smoke CI helper alongside knot.dart,
    // so dart build cli needs an explicit target.
    '--target',
    'bin/knot.dart',
    '-o',
    outDir,
  ], workingDirectory: repoRoot);
  if (result.exitCode != 0) {
    stderr.writeln('failed to build knot: ${result.stdout}\n${result.stderr}');
    exit(70);
  }
  final binName = Platform.isWindows ? 'knot.exe' : 'knot';
  return p.join(outDir, 'bundle', 'bin', binName);
}

String _findRepoRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('cannot find repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}
