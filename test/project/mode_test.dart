import 'dart:io';

import 'package:knot/src/project/project.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('detectProjectMode', () {
    test('pnpm-mode when pnpm-workspace.yaml present', () async {
      await d.dir('proj', [d.file('pnpm-workspace.yaml', '')]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.pnpm,
      );
    });

    test('pnpm-mode when pnpm-lock.yaml present', () async {
      await d.dir('proj', [d.file('pnpm-lock.yaml', '')]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.pnpm,
      );
    });

    test('pnpm-mode wins over npm files when both are present', () async {
      await d.dir('proj', [
        d.file('pnpm-lock.yaml', ''),
        d.file('package-lock.json', '{}'),
      ]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.pnpm,
      );
    });

    test('npm-mode when package-lock.json present', () async {
      await d.dir('proj', [d.file('package-lock.json', '{}')]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.npm,
      );
    });

    test('npm-mode when .npmrc has non-auth entries', () async {
      await d.dir('proj', [
        d.file('.npmrc', 'registry=https://example.com\n'),
      ]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.npm,
      );
    });

    test('knot-mode when only auth-only .npmrc present', () async {
      await d.dir('proj', [
        d.file(
          '.npmrc',
          '//registry.example.com/:_authToken=\${TOKEN}\n',
        ),
      ]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.knot,
      );
    });

    test('knot-mode on fresh project (no relevant files)', () async {
      await d.dir('proj', [d.file('package.json', '{}')]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.knot,
      );
    });

    test('ignores comments and blank lines in .npmrc', () async {
      await d.dir('proj', [
        d.file(
          '.npmrc',
          '# a comment\n\n  ; another\n//x.com/:_authtoken=secret\n',
        ),
      ]).create();
      expect(
        detectProjectMode(p.join(d.sandbox, 'proj')),
        ProjectMode.knot,
      );
    });
  });

  group('loadProjectConfig', () {
    test('npm-mode keeps full .npmrc', () async {
      await d.dir('proj', [
        d.file(
          '.npmrc',
          'registry=https://example.com/\n'
              '//example.com/:_authToken=abc\n',
        ),
      ]).create();
      final cfg = await loadProjectConfig(
        projectRoot: p.join(d.sandbox, 'proj'),
        homeDir: Directory.systemTemp.path,
        environment: const {},
      );
      expect(cfg.mode, ProjectMode.npm);
      expect(cfg.npmrc.registry, 'https://example.com/');
    });

    test('pnpm-mode filters .npmrc to auth-only', () async {
      await d.dir('proj', [
        d.file('pnpm-lock.yaml', ''),
        d.file(
          '.npmrc',
          'registry=https://example.com/\n'
              '//example.com/:_authToken=abc\n',
        ),
      ]).create();
      final cfg = await loadProjectConfig(
        projectRoot: p.join(d.sandbox, 'proj'),
        homeDir: Directory.systemTemp.path,
        environment: const {},
      );
      expect(cfg.mode, ProjectMode.pnpm);
      // registry policy entry was dropped; default registry kicks in
      expect(cfg.npmrc.registry, 'https://registry.npmjs.org/');
      // auth entry preserved
      expect(
        cfg.npmrc.authTokenFor(Uri.parse('https://example.com/')),
        'abc',
      );
    });

    test('knot-mode loads .npmrc the same as npm-mode', () async {
      await d.dir('proj', [
        // auth-only .npmrc → knot-mode; no policy override expected
        d.file(
          '.npmrc',
          '//example.com/:_authToken=t\n',
        ),
      ]).create();
      final cfg = await loadProjectConfig(
        projectRoot: p.join(d.sandbox, 'proj'),
        homeDir: Directory.systemTemp.path,
        environment: const {},
      );
      expect(cfg.mode, ProjectMode.knot);
      expect(cfg.npmrc.registry, 'https://registry.npmjs.org/');
      expect(
        cfg.npmrc.authTokenFor(Uri.parse('https://example.com/')),
        't',
      );
    });
  });
}
