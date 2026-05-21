import 'dart:io';

import 'package:knot/src/core/core.dart';

/// Lifecycle events npm runs against installed packages.
///
/// knot only iterates the install-time events (no `publish` flow), so
/// the publish-bound `prepublish` / `prepublishOnly` entries that npm
/// defines aren't enumerated here.
enum LifecycleEvent {
  preinstall('preinstall'),
  install('install'),
  postinstall('postinstall'),
  prepare('prepare');

  const LifecycleEvent(this.scriptKey);
  final String scriptKey;
}

/// A package's lifecycle script entry.
class LifecycleScript {
  LifecycleScript({
    required this.event,
    required this.packageName,
    required this.packageVersion,
    required this.workingDir,
    required this.command,
  });

  final LifecycleEvent event;
  final String packageName;
  final String packageVersion;
  final String workingDir;
  final String command;
}

/// Outcome of running one lifecycle script. Only the fields the
/// install path actually reads survive — script/stderr/duration were
/// kept around for diagnostics that never materialised; the live
/// callers consume `exitCode` and surface `stdout` in their own logs.
class ScriptResult {
  ScriptResult({required this.exitCode, required this.stdout});
  final int exitCode;
  final String stdout;
}

/// Names from the process environment that are passed through to
/// lifecycle scripts. Mirrors pnpm v11's env policy (Phase G of the
/// v11 alignment plan): the host environment is stripped by default
/// and only this allowlist is forwarded.
///
/// `NODE_OPTIONS` is included intentionally — many tools depend on
/// it. `npm_package_json` is deliberately omitted; the populated
/// `npm_package_*` metadata is set per-script from the manifest, not
/// reflected from a pre-existing ambient value.
///
/// PATH is handled separately (see [ScriptRunner.run]) because we
/// prepend `binDir` to it.
const List<String> lifecycleScriptEnvPassthrough = [
  // POSIX core
  'HOME',
  'USER',
  'LOGNAME',
  'SHELL',
  'TERM',
  'PWD',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'LC_MESSAGES',
  'TMPDIR',
  // Windows core
  'USERPROFILE',
  'USERNAME',
  'COMPUTERNAME',
  'SYSTEMROOT',
  'WINDIR',
  'TEMP',
  'TMP',
  // Tool selection
  'NODE_OPTIONS',
  'CI',
];

/// Build the environment for a lifecycle script. Pulls a curated set
/// of vars from [baseEnv] (the host environment), adds npm-style
/// metadata for [script], appends [binDir] to PATH, and finally
/// merges [extraEnv].
Map<String, String> buildLifecycleEnv({
  required LifecycleScript script,
  Map<String, String>? baseEnv,
  String? binDir,
  Map<String, String>? extraEnv,
  String? initCwd,
}) {
  final source = baseEnv ?? Platform.environment;
  final env = <String, String>{};
  for (final name in lifecycleScriptEnvPassthrough) {
    final value = source[name];
    if (value != null) env[name] = value;
  }

  // PATH gets the bin-dir prepend treatment; preserve the host PATH.
  final pathKey = Platform.isWindows ? 'Path' : 'PATH';
  final hostPath = source[pathKey] ?? source['PATH'] ?? source['Path'];
  if (hostPath != null) env[pathKey] = hostPath;
  if (binDir != null) {
    final sep = Platform.isWindows ? ';' : ':';
    final existing = env[pathKey] ?? '';
    env[pathKey] = existing.isEmpty ? binDir : '$binDir$sep$existing';
  }

  // npm-style metadata. `npm_package_json` is intentionally NOT set
  // (Phase G: prevents config_json leakage; pnpm v11 omits it too).
  env['npm_lifecycle_event'] = script.event.scriptKey;
  env['npm_package_name'] = script.packageName;
  env['npm_package_version'] = script.packageVersion;
  env['INIT_CWD'] = initCwd ?? Directory.current.path;

  if (extraEnv != null) env.addAll(extraEnv);
  return env;
}

/// Executor for npm lifecycle scripts.
class ScriptRunner {
  ScriptRunner({this.timeout = const Duration(minutes: 10), this.shellPath});

  /// Wall-clock timeout per script. Scripts exceeding this are killed.
  final Duration timeout;

  /// Override the shell used to invoke commands. Defaults to `/bin/sh`
  /// on POSIX and `cmd.exe` on Windows.
  final String? shellPath;

  /// Run [script] and return the result. Throws [ScriptError] on
  /// non-zero exit or timeout.
  Future<ScriptResult> run(
    LifecycleScript script, {
    String? binDir,
    Map<String, String>? extraEnv,
  }) async {
    final env = buildLifecycleEnv(
      script: script,
      binDir: binDir,
      extraEnv: extraEnv,
    );

    final (exec, args) = _commandSplit(script.command);
    final process = await Process.start(
      exec,
      args,
      workingDirectory: script.workingDir,
      environment: env,
      runInShell: false,
    );

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final stdoutDone = process.stdout
        .transform(systemEncoding.decoder)
        .listen(stdoutBuf.write)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(systemEncoding.decoder)
        .listen(stderrBuf.write)
        .asFuture<void>();

    final timer = Future.delayed(timeout, () {
      process.kill(ProcessSignal.sigkill);
    });
    final exitCode = await process.exitCode;
    timer.ignore();
    await Future.wait([stdoutDone, stderrDone]);

    if (exitCode != 0) {
      throw ScriptError(
        '${script.event.scriptKey} script for '
        '${script.packageName}@${script.packageVersion} '
        'exited with $exitCode',
        script: script.command,
        exitCode: exitCode,
      );
    }
    return ScriptResult(exitCode: exitCode, stdout: stdoutBuf.toString());
  }

  (String, List<String>) _commandSplit(String command) {
    if (Platform.isWindows) {
      return ('cmd.exe', ['/C', command]);
    }
    return (shellPath ?? '/bin/sh', ['-c', command]);
  }
}
