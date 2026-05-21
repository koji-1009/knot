import 'package:knot/src/npmrc/npmrc.dart';
import 'package:test/test.dart';

void main() {
  group('NpmrcConfig.namedRegistry', () {
    test('returns built-in gh alias when no override', () {
      final cfg = NpmrcConfig(const {});
      expect(cfg.namedRegistry('gh'), 'https://npm.pkg.github.com/');
    });

    test('alias lookup is case-insensitive', () {
      final cfg = NpmrcConfig(const {});
      expect(cfg.namedRegistry('GH'), 'https://npm.pkg.github.com/');
    });

    test('user override wins over built-in', () {
      final cfg = NpmrcConfig(const {
        'named-registry-gh': 'https://internal.example.com/',
      });
      expect(cfg.namedRegistry('gh'), 'https://internal.example.com/');
    });

    test('returns null for unknown alias', () {
      final cfg = NpmrcConfig(const {});
      expect(cfg.namedRegistry('unknown'), isNull);
    });

    test('namedRegistries merges built-ins with overrides', () {
      final cfg = NpmrcConfig(const {
        'named-registry-gh': 'https://gh.internal/',
        'named-registry-corp': 'https://corp.example/',
      });
      final all = cfg.namedRegistries;
      expect(all['gh'], 'https://gh.internal/');
      expect(all['corp'], 'https://corp.example/');
    });

    test('built-ins still surfaced when no overrides', () {
      final cfg = NpmrcConfig(const {});
      expect(cfg.namedRegistries['gh'], 'https://npm.pkg.github.com/');
    });

    test('namedRegistries map is unmodifiable', () {
      final cfg = NpmrcConfig(const {});
      expect(
        () => cfg.namedRegistries['gh'] = 'x',
        throwsUnsupportedError,
      );
    });
  });
}
