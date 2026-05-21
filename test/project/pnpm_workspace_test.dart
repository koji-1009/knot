import 'dart:io';

import 'package:knot/src/project/pnpm_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('readPnpmWorkspaceConfig', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('knot-pnpm-ws-');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    test('missing file returns empty config', () async {
      final cfg = await readPnpmWorkspaceConfig(tmp.path);
      expect(cfg.isEmpty, isTrue);
    });

    test('reads allowBuilds list', () async {
      await File(p.join(tmp.path, 'pnpm-workspace.yaml')).writeAsString('''
allowBuilds:
  - esbuild
  - "@swc/*"
''');
      final cfg = await readPnpmWorkspaceConfig(tmp.path);
      expect(cfg.allowBuilds, ['esbuild', '@swc/*']);
    });

    test('reads configDependencies shorthand and object forms', () async {
      await File(p.join(tmp.path, 'pnpm-workspace.yaml')).writeAsString('''
configDependencies:
  prettier-config-knot: "1.0.0"
  eslint-config-knot:
    version: "2.3.4"
''');
      final cfg = await readPnpmWorkspaceConfig(tmp.path);
      expect(cfg.configDependencies, {
        'prettier-config-knot': '1.0.0',
        'eslint-config-knot': '2.3.4',
      });
    });

    test('drops configDependencies entries missing a version', () async {
      await File(p.join(tmp.path, 'pnpm-workspace.yaml')).writeAsString('''
configDependencies:
  good: "1.0.0"
  no-version:
    something-else: "x"
  empty-string: ""
''');
      final cfg = await readPnpmWorkspaceConfig(tmp.path);
      expect(cfg.configDependencies, {'good': '1.0.0'});
    });

    test('malformed yaml returns empty config (does not throw)', () async {
      await File(p.join(tmp.path, 'pnpm-workspace.yaml')).writeAsString('''
allowBuilds:
  - good
unbalanced: [
''');
      final cfg = await readPnpmWorkspaceConfig(tmp.path);
      expect(cfg.isEmpty, isTrue);
    });
  });
}
