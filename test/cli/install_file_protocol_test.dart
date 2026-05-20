/// End-to-end test: `file:` protocol packs a local package and produces a
/// usable `node_modules/<name>` directory.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

import '_test_binary.dart';

void main() {
  test(
    'install resolves file:./sibling and creates node_modules/sibling',
    () async {
      // Sibling package the project depends on.
      await d.dir('sibling', [
        d.file(
          'package.json',
          const JsonEncoder.withIndent(
            '  ',
          ).convert({'name': 'sibling', 'version': '1.0.0'}),
        ),
        d.file('index.js', "module.exports = 'sibling';"),
      ]).create();

      await d.dir('proj', [
        d.file(
          'package.json',
          const JsonEncoder.withIndent('  ').convert({
            'name': 'consumer',
            'version': '0.0.0',
            'dependencies': {'sibling': 'file:../sibling'},
          }),
        ),
      ]).create();

      final projDir = p.join(d.sandbox, 'proj');
      final storeRoot = p.join(d.sandbox, '.knot-store');

      final bin = await knotTestBinary();
      final process = await TestProcess.start(
        bin,
        ['install', '--ignore-scripts', '--offline'],
        workingDirectory: projDir,
        environment: {'KNOT_STORE_ROOT_OVERRIDE_FOR_TEST': storeRoot},
      );
      await process.shouldExit(0);

      final sibling = File(
        p.join(projDir, 'node_modules', 'sibling', 'package.json'),
      );
      expect(
        await sibling.exists(),
        isTrue,
        reason: 'node_modules/sibling/package.json should exist',
      );
      final pkg =
          jsonDecode(await sibling.readAsString()) as Map<String, dynamic>;
      expect(pkg['name'], 'sibling');
      expect(pkg['version'], '1.0.0');
    },
  );
}
