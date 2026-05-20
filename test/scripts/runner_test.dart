import 'dart:io';

import 'package:knot/src/core/core.dart';
import 'package:knot/src/scripts/scripts.dart';
import 'package:test/test.dart';

void main() {
  test('runs a script and captures stdout', () async {
    if (Platform.isWindows) return; // sh-only here
    final tmp = await Directory.systemTemp.createTemp('knot_scripts_test_');
    try {
      final runner = ScriptRunner();
      final result = await runner.run(
        LifecycleScript(
          event: LifecycleEvent.postinstall,
          packageName: 'sample',
          packageVersion: '1.0.0',
          workingDir: tmp.path,
          command: 'echo hello',
        ),
      );
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hello');
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('throws ScriptError on non-zero exit', () async {
    if (Platform.isWindows) return;
    final tmp = await Directory.systemTemp.createTemp('knot_scripts_test_');
    try {
      final runner = ScriptRunner();
      await expectLater(
        runner.run(
          LifecycleScript(
            event: LifecycleEvent.install,
            packageName: 'sample',
            packageVersion: '1.0.0',
            workingDir: tmp.path,
            command: 'exit 7',
          ),
        ),
        throwsA(isA<ScriptError>().having((e) => e.exitCode, 'exitCode', 7)),
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('sets npm_lifecycle_event env var', () async {
    if (Platform.isWindows) return;
    final tmp = await Directory.systemTemp.createTemp('knot_scripts_test_');
    try {
      final runner = ScriptRunner();
      final result = await runner.run(
        LifecycleScript(
          event: LifecycleEvent.preinstall,
          packageName: 'sample',
          packageVersion: '1.0.0',
          workingDir: tmp.path,
          command: r'printf "$npm_lifecycle_event"',
        ),
      );
      expect(result.stdout, 'preinstall');
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
