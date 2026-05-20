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
    final env = <String, String>{
      ...Platform.environment,
      'npm_lifecycle_event': script.event.scriptKey,
      'npm_package_name': script.packageName,
      'npm_package_version': script.packageVersion,
      'INIT_CWD': Directory.current.path,
      ...?extraEnv,
    };
    if (binDir != null) {
      final pathKey = Platform.isWindows ? 'Path' : 'PATH';
      env[pathKey] =
          '$binDir${Platform.isWindows ? ';' : ':'}'
          '${env[pathKey] ?? ''}';
    }

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
