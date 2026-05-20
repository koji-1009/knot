import 'package:knot/src/cli/dependency_spec.dart';
import 'package:test/test.dart';

void main() {
  group('DependencySpec.parse', () {
    test('plain semver: name=value, no alias', () {
      final s = DependencySpec.parse('react', '^18.0.0');
      expect(s.logicalName, 'react');
      expect(s.packageName, 'react');
      expect(s.range, '^18.0.0');
      expect(s.isAlias, isFalse);
      expect(s.protocol, SpecifierProtocol.semver);
    });

    test('npm: alias rewrites packageName', () {
      final s = DependencySpec.parse('react-18', 'npm:react@^18.0.0');
      expect(s.logicalName, 'react-18');
      expect(s.packageName, 'react');
      expect(s.range, '^18.0.0');
      expect(s.isAlias, isTrue);
    });

    test('npm: alias handles scoped package', () {
      final s = DependencySpec.parse('safe-foo', 'npm:@scope/foo@1.2.3');
      expect(s.packageName, '@scope/foo');
      expect(s.range, '1.2.3');
      expect(s.isAlias, isTrue);
    });

    test('npm: alias without explicit version defaults to latest', () {
      final s = DependencySpec.parse('xy', 'npm:lodash');
      expect(s.packageName, 'lodash');
      expect(s.range, 'latest');
    });

    test('workspace: protocol', () {
      final s = DependencySpec.parse('pkg', 'workspace:^1.0.0');
      expect(s.protocol, SpecifierProtocol.workspace);
      expect(s.range, '^1.0.0');
    });

    test('file: protocol', () {
      final s = DependencySpec.parse('pkg', 'file:../local');
      expect(s.protocol, SpecifierProtocol.file);
      expect(s.range, '../local');
    });

    test('link: protocol', () {
      final s = DependencySpec.parse('pkg', 'link:../local');
      expect(s.protocol, SpecifierProtocol.link);
    });

    test('https: protocol', () {
      final s = DependencySpec.parse('pkg', 'https://example.com/foo.tgz');
      expect(s.protocol, SpecifierProtocol.https);
      expect(s.url, 'https://example.com/foo.tgz');
    });

    test('git+ protocol', () {
      final s = DependencySpec.parse(
        'pkg',
        'git+https://github.com/u/r.git#main',
      );
      expect(s.protocol, SpecifierProtocol.git);
    });

    test('github: shorthand', () {
      final s = DependencySpec.parse('pkg', 'github:user/repo');
      expect(s.protocol, SpecifierProtocol.git);
    });
  });
}
