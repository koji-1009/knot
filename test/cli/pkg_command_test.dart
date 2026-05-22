import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

import '_test_binary.dart';

Future<TestProcess> _runKnot(
  List<String> args, {
  required String workingDirectory,
}) async {
  final bin = await knotTestBinary();
  return TestProcess.start(bin, args, workingDirectory: workingDirectory);
}

void main() {
  group('knot pkg with malformed package.json', () {
    test(
      'pkg get exits 70 with error: (not fatal:) and mentions the path',
      () async {
        await d.dir('proj', [
          d.file('package.json', '{ this is not json }'),
        ]).create();
        final projectDir = p.join(d.sandbox, 'proj');

        final process = await _runKnot([
          'pkg',
          'get',
          'name',
        ], workingDirectory: projectDir);

        final stderr = await process.stderrStream().toList();
        final stderrText = stderr.join('\n');

        await process.shouldExit(70);

        expect(stderrText, startsWith('error: '));
        expect(stderrText, isNot(contains('fatal:')));
        expect(stderrText, contains(p.join(projectDir, 'package.json')));
      },
    );

    test('pkg set exits 70 with error: and mentions the path', () async {
      await d.dir('proj', [
        d.file('package.json', '{ this is not json }'),
      ]).create();
      final projectDir = p.join(d.sandbox, 'proj');

      final process = await _runKnot([
        'pkg',
        'set',
        'name=demo',
      ], workingDirectory: projectDir);

      final stderr = await process.stderrStream().toList();
      final stderrText = stderr.join('\n');

      await process.shouldExit(70);
      expect(stderrText, startsWith('error: '));
      expect(stderrText, isNot(contains('fatal:')));
      expect(stderrText, contains(p.join(projectDir, 'package.json')));
    });

    test('pkg delete exits 70 with error: and mentions the path', () async {
      await d.dir('proj', [
        d.file('package.json', '{ this is not json }'),
      ]).create();
      final projectDir = p.join(d.sandbox, 'proj');

      final process = await _runKnot([
        'pkg',
        'delete',
        'name',
      ], workingDirectory: projectDir);

      final stderr = await process.stderrStream().toList();
      final stderrText = stderr.join('\n');

      await process.shouldExit(70);
      expect(stderrText, startsWith('error: '));
      expect(stderrText, isNot(contains('fatal:')));
      expect(stderrText, contains(p.join(projectDir, 'package.json')));
    });
  });
}
