import 'package:knot/src/cli/dependency_spec.dart';
import 'package:knot/src/policy/exotic_subdeps.dart';
import 'package:test/test.dart';

void main() {
  group('classifyExoticDep', () {
    test('semver registry dep is notExotic', () {
      final spec = DependencySpec.parse('react', '^18.0.0');
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.notExotic,
      );
    });

    test('workspace protocol is notExotic', () {
      final spec = DependencySpec.parse('app', 'workspace:*');
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.notExotic,
      );
    });

    test('file: dep is notExotic (local source, not remote exotic)', () {
      final spec = DependencySpec.parse('local', 'file:./pkg');
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.notExotic,
      );
    });

    test('direct exotic git is permitted (directExotic)', () {
      final spec = DependencySpec.parse(
        'something',
        'git+https://example.com/something.git',
      );
      expect(
        classifyExoticDep(spec: spec, isDirect: true),
        ExoticDepRule.directExotic,
      );
    });

    test('transitive untrusted git is blocked', () {
      final spec = DependencySpec.parse(
        'evil',
        'git+https://attacker.example/evil.git',
      );
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.blocked,
      );
    });

    test('transitive github:nodejs/node is trusted', () {
      final spec = DependencySpec.parse('node', 'github:nodejs/node#main');
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.trusted,
      );
    });

    test('transitive github:oven-sh/bun is trusted', () {
      final spec = DependencySpec.parse('bun', 'github:oven-sh/bun');
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.trusted,
      );
    });

    test('transitive git+https://github.com/denoland/deno is trusted', () {
      final spec = DependencySpec.parse(
        'deno',
        'git+https://github.com/denoland/deno.git',
      );
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.trusted,
      );
    });

    test('transitive https://github.com tarball outside whitelist is blocked',
        () {
      final spec = DependencySpec.parse(
        'pkg',
        'https://github.com/random/repo/archive/refs/tags/v1.tar.gz',
      );
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.blocked,
      );
    });

    test('case-insensitive owner/repo match', () {
      final spec = DependencySpec.parse('node', 'github:NodeJS/Node');
      expect(
        classifyExoticDep(spec: spec, isDirect: false),
        ExoticDepRule.trusted,
      );
    });
  });
}
