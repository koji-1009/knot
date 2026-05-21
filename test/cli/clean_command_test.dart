import 'dart:io';

import 'package:knot/src/cli/commands/clean_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('cleanProject', () {
    test('removes node_modules but keeps lockfile by default', () async {
      await d.dir('proj', [
        d.dir('node_modules', [
          d.file('foo.txt', 'x'),
        ]),
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
        d.file('package-lock.json', '{}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final code = await cleanProject(
        projectRoot: root,
        dryRun: false,
        deleteLockfile: false,
      );
      expect(code, 0);
      expect(Directory(p.join(root, 'node_modules')).existsSync(), isFalse);
      expect(File(p.join(root, 'package-lock.json')).existsSync(), isTrue);
    });

    test('deleteLockfile also removes package-lock.json', () async {
      await d.dir('proj', [
        d.dir('node_modules', [d.file('foo.txt', 'x')]),
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
        d.file('package-lock.json', '{}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final code = await cleanProject(
        projectRoot: root,
        dryRun: false,
        deleteLockfile: true,
      );
      expect(code, 0);
      expect(File(p.join(root, 'package-lock.json')).existsSync(), isFalse);
    });

    test('deleteLockfile removes pnpm-lock.yaml too', () async {
      await d.dir('proj', [
        d.dir('node_modules', [d.file('foo.txt', 'x')]),
        d.file('pnpm-lock.yaml', 'lockfileVersion: 9.0\n'),
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final code = await cleanProject(
        projectRoot: root,
        dryRun: false,
        deleteLockfile: true,
      );
      expect(code, 0);
      expect(File(p.join(root, 'pnpm-lock.yaml')).existsSync(), isFalse);
    });

    test('dryRun reports without deleting', () async {
      await d.dir('proj', [
        d.dir('node_modules', [d.file('foo.txt', 'x')]),
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final code = await cleanProject(
        projectRoot: root,
        dryRun: true,
        deleteLockfile: false,
      );
      expect(code, 0);
      expect(Directory(p.join(root, 'node_modules')).existsSync(), isTrue);
    });

    test('no-op when nothing to clean', () async {
      await d.dir('proj', [
        d.file('package.json', '{"name":"p","version":"1.0.0"}'),
      ]).create();
      final root = p.join(d.sandbox, 'proj');
      final code = await cleanProject(
        projectRoot: root,
        dryRun: false,
        deleteLockfile: false,
      );
      expect(code, 0);
    });
  });
}
