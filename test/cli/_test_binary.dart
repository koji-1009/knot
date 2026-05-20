import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Path to the AOT-compiled `knot` binary, suitable for [Process.start] /
/// `TestProcess.start`.
///
/// Builds once (memoized) on first call via `dart build cli`, drops the
/// bundle in a temp directory, and reuses it for the lifetime of the
/// test runner. `dart build cli` (not `dart compile exe`) is used so
/// the `boringssl_dart` link hook is honoured — without it the binary
/// loads but the crypto FFI calls SEGV.
///
/// Override via `KNOT_TEST_BIN=/path/to/knot` to avoid the build step in
/// CI when the binary has already been produced upstream.
Future<String> knotTestBinary() {
  final override = Platform.environment['KNOT_TEST_BIN'];
  if (override != null && File(override).existsSync()) {
    return Future.value(override);
  }
  return _buildOnce.value;
}

final _buildOnce = _LazyFuture<String>(() async {
  final tmp = await Directory.systemTemp.createTemp('knot-test-bin-');
  final result = await Process.run('dart', ['build', 'cli', '-o', tmp.path]);
  if (result.exitCode != 0) {
    throw StateError(
      'failed to build knot for tests: ${result.stdout}\n${result.stderr}',
    );
  }
  final binName = Platform.isWindows ? 'knot.exe' : 'knot';
  return p.join(tmp.path, 'bundle', 'bin', binName);
});

class _LazyFuture<T> {
  _LazyFuture(this._init);
  final Future<T> Function() _init;
  Future<T>? _cached;
  Future<T> get value => _cached ??= _init();
}
