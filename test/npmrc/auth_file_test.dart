import 'dart:io';

import 'package:knot/src/npmrc/npmrc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('NpmrcLoader: npmrc-auth-file (Phase N)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('knot_authfile_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('auth file token is merged into the resolved config', () async {
      final proj = await Directory(p.join(tmp.path, 'proj')).create();
      await File(p.join(proj.path, '.npmrc')).writeAsString(
        'registry=https://example.com/\n'
        'npmrc-auth-file=./auth.npmrc\n',
      );
      await File(p.join(proj.path, 'auth.npmrc')).writeAsString(
        '//example.com/:_authToken=secret-token\n',
      );

      final cfg = await NpmrcLoader(
        projectDir: proj.path,
        homeDir: p.join(tmp.path, 'no-home'),
        globalConfig: p.join(tmp.path, 'no-such-global'),
        env: const {},
      ).load();

      expect(cfg.registry, 'https://example.com/');
      expect(
        cfg.authTokenFor(Uri.parse('https://example.com/')),
        'secret-token',
      );
    });

    test('explicit npmrc entry wins over auth-file when keys overlap',
        () async {
      final proj = await Directory(p.join(tmp.path, 'proj')).create();
      await File(p.join(proj.path, '.npmrc')).writeAsString(
        '//example.com/:_authToken=project-token\n'
        'npmrc-auth-file=./auth.npmrc\n',
      );
      await File(p.join(proj.path, 'auth.npmrc')).writeAsString(
        '//example.com/:_authToken=auth-file-token\n',
      );

      final cfg = await NpmrcLoader(
        projectDir: proj.path,
        homeDir: p.join(tmp.path, 'no-home'),
        globalConfig: p.join(tmp.path, 'no-such-global'),
        env: const {},
      ).load();

      expect(
        cfg.authTokenFor(Uri.parse('https://example.com/')),
        'project-token',
      );
    });

    test('absolute path is honored as-is', () async {
      final proj = await Directory(p.join(tmp.path, 'proj')).create();
      final authPath = p.join(tmp.path, 'shared-auth.npmrc');
      await File(authPath).writeAsString(
        '//corp.example/:_authToken=abc\n',
      );
      await File(p.join(proj.path, '.npmrc')).writeAsString(
        'npmrc-auth-file=$authPath\n',
      );

      final cfg = await NpmrcLoader(
        projectDir: proj.path,
        homeDir: p.join(tmp.path, 'no-home'),
        globalConfig: p.join(tmp.path, 'no-such-global'),
        env: const {},
      ).load();

      expect(
        cfg.authTokenFor(Uri.parse('https://corp.example/')),
        'abc',
      );
    });

    test('missing auth file is silently ignored', () async {
      final proj = await Directory(p.join(tmp.path, 'proj')).create();
      await File(p.join(proj.path, '.npmrc')).writeAsString(
        'registry=https://example.com/\n'
        'npmrc-auth-file=./does-not-exist.npmrc\n',
      );

      final cfg = await NpmrcLoader(
        projectDir: proj.path,
        homeDir: p.join(tmp.path, 'no-home'),
        globalConfig: p.join(tmp.path, 'no-such-global'),
        env: const {},
      ).load();

      expect(cfg.registry, 'https://example.com/');
    });
  });
}
