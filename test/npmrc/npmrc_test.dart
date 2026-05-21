import 'dart:io';

import 'package:knot/src/npmrc/npmrc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('parseNpmrcBody', () {
    test('parses simple key=value', () {
      final m = parseNpmrcBody(
        'registry=https://example.com\nfetch-retries=5\n',
        expandVar: (_) => '',
      );
      expect(m['registry'], 'https://example.com');
      expect(m['fetch-retries'], '5');
    });

    test('strips comments', () {
      final m = parseNpmrcBody(
        '# top comment\nregistry=https://example.com ; trailing\n',
        expandVar: (_) => '',
      );
      expect(m['registry'], 'https://example.com');
    });

    test('lower-cases keys', () {
      final m = parseNpmrcBody('Registry=x', expandVar: (_) => '');
      expect(m['registry'], 'x');
    });

    test('unquotes single and double quotes', () {
      final m = parseNpmrcBody(
        'a="hello world"\nb=\'x y\'\n',
        expandVar: (_) => '',
      );
      expect(m['a'], 'hello world');
      expect(m['b'], 'x y');
    });

    test('expands \${VAR}', () {
      final m = parseNpmrcBody(
        '//registry.example.com/:_authToken=\${MY_TOKEN}\n',
        expandVar: (name) => name == 'MY_TOKEN' ? 'secret-abc' : '',
      );
      expect(m['//registry.example.com/:_authtoken'], 'secret-abc');
    });

    test('preserves scoped registry keys', () {
      final m = parseNpmrcBody(
        '@scope:registry=https://scope.example.com/\n',
        expandVar: (_) => '',
      );
      expect(m['@scope:registry'], 'https://scope.example.com/');
    });
  });

  group('NpmrcConfig.authTokenFor', () {
    test('longest-match host+path wins', () {
      final config = NpmrcConfig({
        '//registry.example.com/:_authtoken': 'root-token',
        '//registry.example.com/scoped/path/:_authtoken': 'long-token',
      });
      expect(
        config.authTokenFor(
          Uri.parse('https://registry.example.com/scoped/path/foo'),
        ),
        'long-token',
      );
      expect(
        config.authTokenFor(Uri.parse('https://registry.example.com/other')),
        'root-token',
      );
    });

    test('returns null when no entry matches', () {
      final config = NpmrcConfig({'//registry.example.com/:_authtoken': 'x'});
      expect(
        config.authTokenFor(Uri.parse('https://other.example.com/')),
        isNull,
      );
    });
  });

  group('NpmrcConfig.registryFor', () {
    test('returns scoped registry', () {
      final config = NpmrcConfig({
        '@scope:registry': 'https://scope.example.com/',
      });
      expect(config.registryFor('@scope'), 'https://scope.example.com/');
      expect(config.registryFor('scope'), 'https://scope.example.com/');
      expect(config.registryFor('@other'), isNull);
    });
  });

  group('NpmrcLoader', () {
    test('merges layers with project > home', () async {
      final tmp = await Directory.systemTemp.createTemp('knot_npmrc_test_');
      try {
        final home = await Directory(p.join(tmp.path, 'home')).create();
        final proj = await Directory(p.join(tmp.path, 'proj')).create();
        await File(
          p.join(home.path, '.npmrc'),
        ).writeAsString('registry=https://home.example.com/\n');
        await File(p.join(proj.path, '.npmrc')).writeAsString(
          'registry=https://proj.example.com/\nfetch-retries=8\n',
        );

        final loader = NpmrcLoader(
          projectDir: proj.path,
          homeDir: home.path,
          globalConfig: p.join(tmp.path, 'no-such-global'),
          env: const {},
        );
        final config = await loader.load();
        expect(config.registry, 'https://proj.example.com/');
        expect(config.integer('fetch-retries'), 8);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('env KNOT_CONFIG_* overrides files', () async {
      final tmp = await Directory.systemTemp.createTemp('knot_npmrc_test_');
      try {
        final proj = await Directory(p.join(tmp.path, 'proj')).create();
        await File(
          p.join(proj.path, '.npmrc'),
        ).writeAsString('registry=https://file.example.com/\n');

        final loader = NpmrcLoader(
          projectDir: proj.path,
          homeDir: p.join(tmp.path, 'no-home'),
          globalConfig: p.join(tmp.path, 'no-such-global'),
          env: const {'KNOT_CONFIG_REGISTRY': 'https://env.example.com/'},
        );
        final config = await loader.load();
        expect(config.registry, 'https://env.example.com/');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('env NPM_CONFIG_* is ignored (Phase G env policy)', () async {
      final tmp = await Directory.systemTemp.createTemp('knot_npmrc_test_');
      try {
        final proj = await Directory(p.join(tmp.path, 'proj')).create();
        await File(
          p.join(proj.path, '.npmrc'),
        ).writeAsString('registry=https://file.example.com/\n');

        final loader = NpmrcLoader(
          projectDir: proj.path,
          homeDir: p.join(tmp.path, 'no-home'),
          globalConfig: p.join(tmp.path, 'no-such-global'),
          env: const {'NPM_CONFIG_REGISTRY': 'https://env.example.com/'},
        );
        final config = await loader.load();
        expect(config.registry, 'https://file.example.com/');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
