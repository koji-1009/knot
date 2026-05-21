import 'package:knot/src/cli/commands/dlx_command.dart';
import 'package:knot/src/core/core.dart';
import 'package:test/test.dart';

void main() {
  group('parsePackageSpec', () {
    test('bare name → latest', () {
      final s = parsePackageSpec('cowsay');
      expect(s.name, 'cowsay');
      expect(s.version, 'latest');
    });

    test('name@version', () {
      final s = parsePackageSpec('cowsay@2.0.0');
      expect(s.name, 'cowsay');
      expect(s.version, '2.0.0');
    });

    test('scoped name (no version) → latest', () {
      final s = parsePackageSpec('@types/node');
      expect(s.name, '@types/node');
      expect(s.version, 'latest');
    });

    test('scoped name with version', () {
      final s = parsePackageSpec('@types/node@22.0.0');
      expect(s.name, '@types/node');
      expect(s.version, '22.0.0');
    });

    test('range expression', () {
      final s = parsePackageSpec('lodash@^4.17.0');
      expect(s.name, 'lodash');
      expect(s.version, '^4.17.0');
    });

    test('empty input throws', () {
      expect(() => parsePackageSpec(''), throwsA(isA<UsageError>()));
    });

    test('malformed scoped name throws', () {
      expect(
        () => parsePackageSpec('@nameWithoutSlash'),
        throwsA(isA<UsageError>()),
      );
    });
  });

  group('defaultBinFor', () {
    test('non-scoped name passes through', () {
      expect(defaultBinFor('cowsay'), 'cowsay');
    });

    test('scoped name strips the scope', () {
      expect(defaultBinFor('@nx/cli'), 'cli');
      expect(defaultBinFor('@my-org/my-tool'), 'my-tool');
    });
  });

  group('dlxCacheKey', () {
    test('same packages produce same key regardless of order', () {
      final a = dlxCacheKey({'foo': '1', 'bar': '2'});
      final b = dlxCacheKey({'bar': '2', 'foo': '1'});
      expect(a, b);
    });

    test('different versions produce different keys', () {
      final a = dlxCacheKey({'foo': '1'});
      final b = dlxCacheKey({'foo': '2'});
      expect(a, isNot(b));
    });

    test('key is short (16 hex chars)', () {
      final k = dlxCacheKey({'foo': '1'});
      expect(k.length, 16);
      expect(RegExp(r'^[a-f0-9]+$').hasMatch(k), isTrue);
    });
  });

  group('DlxInvocation.fromShorthand', () {
    test('cowsay hello → cowsay@latest + bin=cowsay + args=[hello]', () {
      final inv = DlxInvocation.fromShorthand(
        target: 'cowsay',
        binArgs: ['hello'],
      );
      expect(inv.packages, {'cowsay': 'latest'});
      expect(inv.binName, 'cowsay');
      expect(inv.binArgs, ['hello']);
    });

    test('cowsay@2.0.0 → version=2.0.0', () {
      final inv = DlxInvocation.fromShorthand(
        target: 'cowsay@2.0.0',
        binArgs: const [],
      );
      expect(inv.packages, {'cowsay': '2.0.0'});
    });

    test('@nx/cli → bin=cli (strips scope)', () {
      final inv = DlxInvocation.fromShorthand(
        target: '@nx/cli',
        binArgs: const [],
      );
      expect(inv.binName, 'cli');
    });

    test('callOverride wins over default bin', () {
      final inv = DlxInvocation.fromShorthand(
        target: 'create-react-app',
        binArgs: const [],
        callOverride: 'cra',
      );
      expect(inv.binName, 'cra');
    });
  });

  group('DlxInvocation.fromExplicit', () {
    test('-p foo bar args → install foo, run bar with args', () {
      final inv = DlxInvocation.fromExplicit(
        packages: ['foo'],
        positional: ['bar', 'a', 'b'],
      );
      expect(inv.packages, {'foo': 'latest'});
      expect(inv.binName, 'bar');
      expect(inv.binArgs, ['a', 'b']);
    });

    test('-p foo (no positional) → install foo, run bin=foo', () {
      final inv = DlxInvocation.fromExplicit(
        packages: ['foo'],
        positional: const [],
      );
      expect(inv.binName, 'foo');
      expect(inv.binArgs, isEmpty);
    });

    test('multiple -p packages all installed', () {
      final inv = DlxInvocation.fromExplicit(
        packages: ['foo@1.0.0', 'bar@2.0.0'],
        positional: ['runner'],
      );
      expect(inv.packages, {'foo': '1.0.0', 'bar': '2.0.0'});
      expect(inv.binName, 'runner');
    });

    test('--call with positional treats positional as args', () {
      final inv = DlxInvocation.fromExplicit(
        packages: ['foo'],
        positional: ['arg1', 'arg2'],
        callOverride: 'foo-bin',
      );
      expect(inv.binName, 'foo-bin');
      expect(inv.binArgs, ['arg1', 'arg2']);
    });
  });
}
