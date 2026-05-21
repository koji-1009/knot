import 'dart:io';

import 'package:knot/src/cli/package_json.dart';
import 'package:knot/src/workspace_state/workspace_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('computeWorkspaceHash', () {
    test('same inputs → identical hash', () async {
      await d.dir('proj', [
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
        d.file('package-lock.json', '{"lockfileVersion":3}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final pkg = PackageJson(
        name: 'p',
        version: '1.0.0',
        dependencies: const {'react': '^18.0.0'},
      );
      final a = await computeWorkspaceHash(
        projectRoot: root,
        pkg: pkg,
        lockfilePath: p.join(root, 'package-lock.json'),
        engineKey: 'linux;x64;node22',
      );
      final b = await computeWorkspaceHash(
        projectRoot: root,
        pkg: pkg,
        lockfilePath: p.join(root, 'package-lock.json'),
        engineKey: 'linux;x64;node22',
      );
      expect(a, b);
    });

    test('different deps → different hash', () async {
      await d.dir('proj', [
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final a = await computeWorkspaceHash(
        projectRoot: root,
        pkg: PackageJson(
          name: 'p',
          version: '1.0.0',
          dependencies: const {'react': '^18.0.0'},
        ),
        engineKey: 'k',
      );
      final b = await computeWorkspaceHash(
        projectRoot: root,
        pkg: PackageJson(
          name: 'p',
          version: '1.0.0',
          dependencies: const {'react': '^19.0.0'},
        ),
        engineKey: 'k',
      );
      expect(a, isNot(b));
    });

    test('changed lockfile bytes → different hash', () async {
      await d.dir('proj', [
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
        d.file('package-lock.json', '{}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final lock = p.join(root, 'package-lock.json');
      final pkg = PackageJson(name: 'p', version: '1.0.0');
      final a = await computeWorkspaceHash(
        projectRoot: root,
        pkg: pkg,
        lockfilePath: lock,
        engineKey: 'k',
      );
      await File(lock).writeAsString('{"changed":true}');
      final b = await computeWorkspaceHash(
        projectRoot: root,
        pkg: pkg,
        lockfilePath: lock,
        engineKey: 'k',
      );
      expect(a, isNot(b));
    });

    test('different engine key → different hash', () async {
      await d.dir('proj', [
        d.file('package.json', '{}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final pkg = PackageJson(name: 'p', version: '1.0.0');
      final a = await computeWorkspaceHash(
        projectRoot: root,
        pkg: pkg,
        engineKey: 'darwin;arm64;node22',
      );
      final b = await computeWorkspaceHash(
        projectRoot: root,
        pkg: pkg,
        engineKey: 'darwin;arm64;node24',
      );
      expect(a, isNot(b));
    });
  });

  group('workspace state file I/O', () {
    test('read returns null when absent', () async {
      await d.dir('proj', []).create();
      expect(
        await readWorkspaceState(p.join(d.sandbox, 'proj')),
        isNull,
      );
    });

    test('write then read round-trips', () async {
      await d.dir('proj', []).create();
      final root = p.join(d.sandbox, 'proj');
      final state = WorkspaceState(
        hash: 'abc',
        engineKey: 'linux;x64;node22',
        installedAt: DateTime.parse('2026-05-21T12:00:00Z'),
        knotVersion: '0.0.1-dev',
      );
      await writeWorkspaceState(projectRoot: root, state: state);
      final read = await readWorkspaceState(root);
      expect(read, isNotNull);
      expect(read!.hash, 'abc');
      expect(read.engineKey, 'linux;x64;node22');
      expect(read.knotVersion, '0.0.1-dev');
    });

    test('corrupt JSON returns null (treated as no state)', () async {
      await d.dir('proj', [
        d.dir('node_modules', [
          d.dir('.knot', [
            d.file('workspace-state.json', 'not-json'),
          ]),
        ]),
      ]).create();
      expect(
        await readWorkspaceState(p.join(d.sandbox, 'proj')),
        isNull,
      );
    });
  });

  group('workspaceEngineKey', () {
    test('explicit overrides produce a stable string', () {
      final key = workspaceEngineKey(
        platform: 'darwin',
        arch: 'arm64',
        nodeMajor: 22,
      );
      expect(key, 'darwin;arm64;node22');
    });
  });
}
