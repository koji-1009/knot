/// Port of node-semver canonical fixture cases.
///
/// Each entry is `(range, version, expected_satisfies)`.
/// Source: https://github.com/npm/node-semver/blob/v7/test/fixtures/
///
/// Cases involving `loose: true` or `includePrerelease: true` are tagged
/// with the corresponding subgroup; knot's `NpmRange` performs strict
/// parsing by default but auto-includes pre-releases when the *range*
/// mentions them (matches node-semver's default `includePrerelease=false`
/// behavior).
library;

import 'package:knot/src/semver/semver.dart';
import 'package:test/test.dart';

void main() {
  group('node-semver include (range satisfies version)', () {
    final included = <(String, String)>[
      ('1.0.0 - 2.0.0', '1.2.3'),
      ('^1.2.3+build', '1.2.3'),
      ('^1.2.3+build', '1.3.0'),
      ('1.2.3-pre+asdf - 2.4.3-pre+asdf', '1.2.3'),
      ('1.2.3-pre+asdf - 2.4.3-pre+asdf', '1.2.3-pre.2'),
      ('1.2.3-pre+asdf - 2.4.3-pre+asdf', '2.4.3-alpha'),
      ('1.2.3+asdf - 2.4.3+asdf', '1.2.3'),
      ('1.0.0', '1.0.0'),
      ('>=*', '0.2.4'),
      ('', '1.0.0'),
      ('*', '1.2.3'),
      ('>=1.0.0', '1.0.0'),
      ('>=1.0.0', '1.0.1'),
      ('>=1.0.0', '1.1.0'),
      ('>1.0.0', '1.0.1'),
      ('>1.0.0', '1.1.0'),
      ('<=2.0.0', '2.0.0'),
      ('<=2.0.0', '1.9999.9999'),
      ('<=2.0.0', '0.2.9'),
      ('<2.0.0', '1.9999.9999'),
      ('<2.0.0', '0.2.9'),
      ('>= 1.0.0', '1.0.0'),
      ('>=  1.0.0', '1.0.1'),
      ('>=   1.0.0', '1.1.0'),
      ('> 1.0.0', '1.0.1'),
      ('>  1.0.0', '1.1.0'),
      ('<=   2.0.0', '2.0.0'),
      ('<= 2.0.0', '1.9999.9999'),
      ('<=  2.0.0', '0.2.9'),
      ('<    2.0.0', '1.9999.9999'),
      ('<\t2.0.0', '0.2.9'),
      ('>=0.1.97', '0.1.97'),
      ('0.1.20 || 1.2.4', '1.2.4'),
      ('>=0.2.3 || <0.0.1', '0.0.0'),
      ('>=0.2.3 || <0.0.1', '0.2.3'),
      ('>=0.2.3 || <0.0.1', '0.2.4'),
      ('||', '1.3.4'),
      ('2.x.x', '2.1.3'),
      ('1.2.x', '1.2.3'),
      ('1.2.x || 2.x', '2.1.3'),
      ('1.2.x || 2.x', '1.2.3'),
      ('x', '1.2.3'),
      ('2.*.*', '2.1.3'),
      ('1.2.*', '1.2.3'),
      ('1.2.* || 2.*', '2.1.3'),
      ('1.2.* || 2.*', '1.2.3'),
      ('*', '1.2.3'),
      ('2', '2.1.2'),
      ('2.3', '2.3.1'),
      ('~0.0.1', '0.0.1'),
      ('~0.0.1', '0.0.2'),
      ('~x', '0.0.9'),
      ('~2', '2.0.9'),
      ('~2.4', '2.4.0'),
      ('~2.4', '2.4.5'),
      ('~>3.2.1', '3.2.2'),
      ('~1', '1.2.3'),
      ('~>1', '1.2.3'),
      ('~> 1', '1.2.3'),
      ('~1.0', '1.0.2'),
      ('~ 1.0', '1.0.2'),
      ('~ 1.0.3', '1.0.12'),
      ('>=1', '1.0.0'),
      ('>= 1', '1.0.0'),
      ('<1.2', '1.1.1'),
      ('< 1.2', '1.1.1'),
      ('~v0.5.4-pre', '0.5.5'),
      ('~v0.5.4-pre', '0.5.4'),
      ('=0.7.x', '0.7.2'),
      ('<=0.7.x', '0.7.2'),
      ('>=0.7.x', '0.7.2'),
      ('<=0.7.x', '0.6.2'),
      ('~1.2.1 >=1.2.3', '1.2.3'),
      ('~1.2.1 =1.2.3', '1.2.3'),
      ('~1.2.1 1.2.3', '1.2.3'),
      ('~1.2.1 >=1.2.3 1.2.3', '1.2.3'),
      ('~1.2.1 1.2.3 >=1.2.3', '1.2.3'),
      ('~1.2.1 1.2.3', '1.2.3'),
      ('>=1.2.1 1.2.3', '1.2.3'),
      ('1.2.3 >=1.2.1', '1.2.3'),
      ('>=1.2.3 >=1.2.1', '1.2.3'),
      ('>=1.2.1 >=1.2.3', '1.2.3'),
      ('>=1.2', '1.2.8'),
      ('^1.2.3', '1.8.1'),
      ('^0.1.2', '0.1.2'),
      ('^0.1', '0.1.2'),
      ('^0.0.1', '0.0.1'),
      ('^1.2', '1.4.2'),
      ('^1.2 ^1', '1.4.2'),
      ('^1.2.3-alpha', '1.2.3-pre'),
      ('^1.2.0-alpha', '1.2.0-pre'),
      ('^0.0.1-alpha', '0.0.1-beta'),
      ('^0.0.1-alpha', '0.0.1'),
      ('^0.1.1-alpha', '0.1.1-beta'),
      ('^x', '1.2.3'),
      ('x - 1.0.0', '0.9.7'),
      ('x - 1.x', '0.9.7'),
      ('1.0.0 - x', '1.9.7'),
      ('1.x - x', '1.9.7'),
      ('<=7.x', '7.9.9'),
    ];
    var pass = 0, fail = 0;
    for (final (range, version) in included) {
      test('$range satisfies $version', () {
        try {
          final ok = NpmRange.parse(range).satisfies(parseVersion(version));
          expect(
            ok,
            isTrue,
            reason: '$range should include $version but did not',
          );
          pass++;
        } catch (e) {
          fail++;
          rethrow;
        }
      });
    }
    tearDownAll(() {
      // ignore: avoid_print
      print('node-semver include: pass=$pass fail=$fail');
    });
  });

  group('node-semver exclude (range does not satisfy version)', () {
    final excluded = <(String, String)>[
      ('1.0.0 - 2.0.0', '2.2.3'),
      ('1.2.3+asdf - 2.4.3+asdf', '1.2.3-pre.2'),
      ('1.2.3+asdf - 2.4.3+asdf', '2.4.3-alpha'),
      ('^1.2.3+build', '2.0.0'),
      ('^1.2.3+build', '1.2.0'),
      ('^1.2.3', '1.2.3-pre'),
      ('^1.2', '1.2.0-pre'),
      ('>1.2', '1.3.0-beta'),
      ('<=1.2.3', '1.2.3-beta'),
      ('^1.2.3', '1.2.3-beta'),
      ('=0.7.x', '0.7.0-asdf'),
      ('>=0.7.x', '0.7.0-asdf'),
      ('<=0.7.x', '0.7.0-asdf'),
      ('1', '2.0.0-beta'),
      ('<1', '1.0.0-beta'),
      ('< 1', '1.0.0-beta'),
      ('=0.7.x', '0.8.2'),
      ('>=0.7.x', '0.6.2'),
      ('<0.7.x', '0.7.2'),
      ('<1.2.3', '1.2.3-beta'),
      ('=1.2.3', '1.2.3-beta'),
      ('>1.2', '1.2.8'),
      ('^0.0.1', '0.0.2-alpha'),
      ('^0.0.1', '0.0.2'),
      ('^1.2.3', '2.0.0-alpha'),
      ('^1.2.3', '1.2.2'),
      ('^1.2', '1.1.9'),
      ('*', 'v1.2.3-foo'),
      ('blerg', '1.2.3'),
      ('git+https://user:password0123@github.com/foo', '123.0.0'),
      ('^1.2.3', '2.0.0-pre'),
    ];
    var pass = 0, fail = 0;
    for (final (range, version) in excluded) {
      test('$range excludes $version', () {
        bool ok;
        try {
          ok = NpmRange.parse(range).satisfies(parseVersion(version));
        } on FormatException {
          // Range/version unparseable counts as "excludes" per node-semver.
          ok = false;
        }
        try {
          expect(
            ok,
            isFalse,
            reason: '$range should exclude $version but included it',
          );
          pass++;
        } catch (_) {
          fail++;
          rethrow;
        }
      });
    }
    tearDownAll(() {
      // ignore: avoid_print
      print('node-semver exclude: pass=$pass fail=$fail');
    });
  });

  group('compare', () {
    final pairs = <(String, String, int)>[
      ('1.0.0', '1.0.0', 0),
      ('1.0.0', '1.0.1', -1),
      ('1.0.1', '1.0.0', 1),
      ('1.0.0-alpha', '1.0.0', -1),
      ('1.0.0', '1.0.0-alpha', 1),
      ('1.0.0-alpha.1', '1.0.0-alpha', 1),
      ('1.0.0-alpha.1', '1.0.0-alpha.2', -1),
      ('1.0.0-alpha.10', '1.0.0-alpha.9', 1),
      ('1.0.0-alpha.beta', '1.0.0-alpha.1', 1),
      ('1.0.0-beta', '1.0.0-alpha.beta', 1),
      ('1.0.0-rc.1', '1.0.0', -1),
      ('2.0.0', '1.9.9', 1),
    ];
    for (final (a, b, expected) in pairs) {
      test('compare($a, $b) == $expected', () {
        expect(parseVersion(a).compareTo(parseVersion(b)).sign, expected);
      });
    }
  });
}
