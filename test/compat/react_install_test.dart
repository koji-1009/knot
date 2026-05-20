/// Real-registry integration test.
///
/// Runs only when `KNOT_NETWORK=1`. Drives `knot install` against the
/// real npm registry in a sandbox tmp directory, then verifies the
/// produced `node_modules/react/package.json`.
@TestOn('vm')
@Tags(['network'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

import '../cli/_test_binary.dart';

void main() {
  final enabled = Platform.environment['KNOT_NETWORK'] == '1';

  test(
    'installs react@18.x from the live npm registry',
    skip: enabled ? null : 'network gated test (set KNOT_NETWORK=1 to enable)',
    () async {
      await d.dir('proj', [
        d.file(
          'package.json',
          const JsonEncoder.withIndent('  ').convert({
            'name': 'knot-compat-react-only',
            'version': '0.0.0',
            'private': true,
            'dependencies': {'react': '^18.0.0'},
          }),
        ),
      ]).create();

      final projDir = p.join(d.sandbox, 'proj');
      final bin = await knotTestBinary();
      final process = await TestProcess.start(bin, [
        'install',
        '--ignore-scripts',
      ], workingDirectory: projDir);
      await process.shouldExit(0);

      final reactPkgFile = File(
        p.join(projDir, 'node_modules', 'react', 'package.json'),
      );
      expect(
        await reactPkgFile.exists(),
        isTrue,
        reason: 'node_modules/react/package.json should exist',
      );
      final pkg =
          jsonDecode(await reactPkgFile.readAsString()) as Map<String, dynamic>;
      expect(pkg['name'], 'react');
      expect(
        (pkg['version'] as String).startsWith('18.'),
        isTrue,
        reason: 'expected react@18.x, got ${pkg['version']}',
      );

      final lock = File(p.join(projDir, 'package-lock.json'));
      expect(await lock.exists(), isTrue);
    },
  );
}
