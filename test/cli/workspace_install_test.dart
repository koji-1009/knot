/// End-to-end workspace test: a monorepo with two workspaces where one
/// depends on the other via `workspace:^` must result in
/// `<workspace-a>/node_modules/<b>` symlinked to workspace-b's directory.
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
  test('workspace-to-workspace dep produces <a>/node_modules/b → b', () async {
    await d.dir('mono', [
      d.file(
        'package.json',
        const JsonEncoder.withIndent('  ').convert({
          'name': 'mono',
          'version': '0.0.0',
          'private': true,
          'workspaces': ['packages/*'],
        }),
      ),
      d.dir('packages', [
        d.dir('a', [
          d.file(
            'package.json',
            const JsonEncoder.withIndent('  ').convert({
              'name': '@mono/a',
              'version': '1.0.0',
              'dependencies': {'@mono/b': 'workspace:^'},
            }),
          ),
          d.file('index.js', "module.exports = require('@mono/b');"),
        ]),
        d.dir('b', [
          d.file(
            'package.json',
            const JsonEncoder.withIndent(
              '  ',
            ).convert({'name': '@mono/b', 'version': '1.0.0'}),
          ),
          d.file('index.js', "module.exports = 'b';"),
        ]),
      ]),
    ]).create();

    final monoDir = p.join(d.sandbox, 'mono');
    final bin = await knotTestBinary();
    final process = await TestProcess.start(bin, [
      'install',
      '--ignore-scripts',
      '--offline',
    ], workingDirectory: monoDir);
    await process.shouldExit(0);

    // `<a>/node_modules/@mono/b` should be a symlink to `packages/b`.
    final symlinkPath = p.join(
      monoDir,
      'packages',
      'a',
      'node_modules',
      '@mono',
      'b',
    );
    // The directory exists if and only if the symlink resolved to a real dir.
    expect(
      Directory(symlinkPath).existsSync(),
      isTrue,
      reason: '<a>/node_modules/@mono/b should exist as a symlink',
    );
    final bPkg = File(p.join(symlinkPath, 'package.json'));
    expect(await bPkg.exists(), isTrue);
    final json = jsonDecode(await bPkg.readAsString()) as Map<String, dynamic>;
    expect(json['name'], '@mono/b');
  });
}
