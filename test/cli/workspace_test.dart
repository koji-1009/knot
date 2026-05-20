import 'dart:convert';
import 'dart:io';

import 'package:knot/src/cli/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

Future<void> _writeJson(String relativePath, Map<String, dynamic> json) async {
  final segments = p.split(relativePath);
  final dir = p.joinAll(segments.sublist(0, segments.length - 1));
  final fileName = segments.last;
  await Directory(p.join(d.sandbox, dir)).create(recursive: true);
  await File(
    p.join(d.sandbox, dir, fileName),
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(json));
}

void main() {
  test('expands packages/*', () async {
    await _writeJson('packages/foo/package.json', {
      'name': '@scope/foo',
      'version': '1.0.0',
    });
    await _writeJson('packages/bar/package.json', {
      'name': '@scope/bar',
      'version': '0.0.1',
    });
    // Non-package directory should be skipped.
    await Directory(p.join(d.sandbox, 'packages', 'empty')).create();

    final resolver = WorkspaceResolver(d.sandbox);
    final workspaces = await resolver.resolve(['packages/*']);
    expect(workspaces.map((w) => w.name).toSet(), {'@scope/foo', '@scope/bar'});
  });

  test('honors ! exclusions', () async {
    await _writeJson('packages/foo/package.json', {
      'name': 'foo',
      'version': '1.0.0',
    });
    await _writeJson('packages/internal-tool/package.json', {
      'name': 'internal-tool',
      'version': '0.0.0',
    });
    final resolver = WorkspaceResolver(d.sandbox);
    final workspaces = await resolver.resolve([
      'packages/*',
      '!packages/internal-tool',
    ]);
    expect(workspaces.map((w) => w.name).toSet(), {'foo'});
  });

  test('returns empty list when no patterns', () async {
    final resolver = WorkspaceResolver(d.sandbox);
    expect(await resolver.resolve(const []), isEmpty);
  });
}
