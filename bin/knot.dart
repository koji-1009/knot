import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/knot.dart';

// sysexits.h
const int _exitSuccess = 0;
const int _exitUsage = 64;
const int _exitSoftware = 70;

Future<void> main(List<String> args) async {
  await runZonedGuarded(
    () async {
      try {
        final code = await KnotCommandRunner().run(args);
        exit(code ?? _exitSuccess);
      } on UsageException catch (e) {
        stderr.writeln(e.message);
        stderr.writeln();
        stderr.writeln(e.usage);
        exit(_exitUsage);
      } on KnotError catch (e) {
        stderr.writeln('error: ${e.message}');
        if (e is UsageError) {
          exit(_exitUsage);
        }
        exit(_exitSoftware);
      }
    },
    (error, stack) {
      stderr.writeln('fatal: $error');
      stderr.writeln(stack);
      exit(_exitSoftware);
    },
  );
}
