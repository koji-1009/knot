import 'package:knot/src/semver/semver.dart';
import 'package:test/test.dart';

void main() {
  Version v(String s) => parseVersion(s);
  bool sat(String range, String version) =>
      NpmRange.parse(range).satisfies(v(version));

  group('exact', () {
    test('1.2.3 matches only 1.2.3', () {
      expect(sat('1.2.3', '1.2.3'), isTrue);
      expect(sat('1.2.3', '1.2.4'), isFalse);
      expect(sat('=1.2.3', '1.2.3'), isTrue);
    });
  });

  group('caret', () {
    test('^1.2.3 → >=1.2.3 <2.0.0', () {
      expect(sat('^1.2.3', '1.2.3'), isTrue);
      expect(sat('^1.2.3', '1.9.9'), isTrue);
      expect(sat('^1.2.3', '2.0.0'), isFalse);
      expect(sat('^1.2.3', '1.2.2'), isFalse);
    });

    test('^0.2.3 → >=0.2.3 <0.3.0', () {
      expect(sat('^0.2.3', '0.2.3'), isTrue);
      expect(sat('^0.2.3', '0.2.99'), isTrue);
      expect(sat('^0.2.3', '0.3.0'), isFalse);
    });

    test('^0.0.3 → >=0.0.3 <0.0.4', () {
      expect(sat('^0.0.3', '0.0.3'), isTrue);
      expect(sat('^0.0.3', '0.0.4'), isFalse);
    });

    test('^1.x → >=1.0.0 <2.0.0', () {
      expect(sat('^1.x', '1.0.0'), isTrue);
      expect(sat('^1.x', '1.9.9'), isTrue);
      expect(sat('^1.x', '2.0.0'), isFalse);
    });
  });

  group('tilde', () {
    test('~1.2.3 → >=1.2.3 <1.3.0', () {
      expect(sat('~1.2.3', '1.2.3'), isTrue);
      expect(sat('~1.2.3', '1.2.99'), isTrue);
      expect(sat('~1.2.3', '1.3.0'), isFalse);
    });

    test('~1.2 → >=1.2.0 <1.3.0', () {
      expect(sat('~1.2', '1.2.0'), isTrue);
      expect(sat('~1.2', '1.3.0'), isFalse);
    });

    test('~1 → >=1.0.0 <2.0.0', () {
      expect(sat('~1', '1.0.0'), isTrue);
      expect(sat('~1', '1.9.9'), isTrue);
      expect(sat('~1', '2.0.0'), isFalse);
    });
  });

  group('x-range', () {
    test('* matches everything', () {
      expect(sat('*', '0.0.1'), isTrue);
      expect(sat('*', '999.999.999'), isTrue);
    });

    test('1.x', () {
      expect(sat('1.x', '1.0.0'), isTrue);
      expect(sat('1.x', '1.9.0'), isTrue);
      expect(sat('1.x', '2.0.0'), isFalse);
    });

    test('1.2.x', () {
      expect(sat('1.2.x', '1.2.0'), isTrue);
      expect(sat('1.2.x', '1.2.99'), isTrue);
      expect(sat('1.2.x', '1.3.0'), isFalse);
    });

    test('partial 1 == 1.x.x', () {
      expect(sat('1', '1.0.0'), isTrue);
      expect(sat('1', '1.99.99'), isTrue);
      expect(sat('1', '2.0.0'), isFalse);
    });
  });

  group('comparators', () {
    test('>=, <=, >, <', () {
      expect(sat('>=1.2.3', '1.2.3'), isTrue);
      expect(sat('>=1.2.3', '1.2.2'), isFalse);
      expect(sat('<=1.2.3', '1.2.3'), isTrue);
      expect(sat('>1.2.3', '1.2.3'), isFalse);
      expect(sat('>1.2.3', '1.2.4'), isTrue);
      expect(sat('<1.2.3', '1.2.2'), isTrue);
    });

    test('AND: >=1.0.0 <2.0.0', () {
      expect(sat('>=1.0.0 <2.0.0', '1.5.0'), isTrue);
      expect(sat('>=1.0.0 <2.0.0', '2.0.0'), isFalse);
    });
  });

  group('hyphen', () {
    test('1.2.3 - 2.3.4', () {
      expect(sat('1.2.3 - 2.3.4', '1.2.3'), isTrue);
      expect(sat('1.2.3 - 2.3.4', '2.3.4'), isTrue);
      expect(sat('1.2.3 - 2.3.4', '2.3.5'), isFalse);
      expect(sat('1.2.3 - 2.3.4', '1.2.2'), isFalse);
    });

    test('partial upper: 1.2.3 - 2.3 → <2.4.0', () {
      expect(sat('1.2.3 - 2.3', '2.3.99'), isTrue);
      expect(sat('1.2.3 - 2.3', '2.4.0'), isFalse);
    });

    test('partial upper: 1.2.3 - 2 → <3.0.0', () {
      expect(sat('1.2.3 - 2', '2.99.99'), isTrue);
      expect(sat('1.2.3 - 2', '3.0.0'), isFalse);
    });
  });

  group('OR', () {
    test('1.0.0 || 2.0.0', () {
      expect(sat('1.0.0 || 2.0.0', '1.0.0'), isTrue);
      expect(sat('1.0.0 || 2.0.0', '2.0.0'), isTrue);
      expect(sat('1.0.0 || 2.0.0', '1.5.0'), isFalse);
    });

    test('^1 || ^2', () {
      expect(sat('^1 || ^2', '1.5.0'), isTrue);
      expect(sat('^1 || ^2', '2.5.0'), isTrue);
      expect(sat('^1 || ^2', '3.0.0'), isFalse);
    });
  });

  group('prerelease', () {
    test('prerelease excluded unless mentioned', () {
      expect(sat('^1.0.0', '1.0.0-rc1'), isFalse);
      expect(sat('>=1.0.0', '2.0.0-rc1'), isFalse);
    });

    test('prerelease included when explicitly referenced', () {
      expect(sat('>=1.0.0-rc1 <2.0.0', '1.0.0-rc2'), isTrue);
    });
  });

  group('maxSatisfying', () {
    test('picks highest match', () {
      final versions = [
        '1.0.0',
        '1.2.3',
        '1.9.9',
        '2.0.0',
        '2.1.0',
      ].map(parseVersion).toList();
      expect(
        maxSatisfying(versions, NpmRange.parse('^1.0.0')),
        parseVersion('1.9.9'),
      );
    });

    test('returns null when no match', () {
      final versions = [parseVersion('3.0.0')];
      expect(maxSatisfying(versions, NpmRange.parse('^1.0.0')), isNull);
    });
  });
}
