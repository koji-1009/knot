import 'dart:convert';

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
  test('audit with no lockfile exits 1 and prints a clear error', () async {
    await d.dir('proj', [
      d.file(
        'package.json',
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'name': 'demo', 'version': '0.0.0'}),
      ),
    ]).create();

    final process = await _runKnot([
      'audit',
    ], workingDirectory: p.join(d.sandbox, 'proj'));
    await expectLater(
      process.stderr,
      emitsThrough(contains('no lockfile found')),
    );
    await process.shouldExit(1);
  });
}
