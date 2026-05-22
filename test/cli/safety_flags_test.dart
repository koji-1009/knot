import 'package:knot/src/cli/commands/_safety_flags.dart';
import 'package:knot/src/cli/install_operation.dart';
import 'package:knot/src/core/core.dart';
import 'package:test/test.dart';

void main() {
  group('parseScriptPolicy', () {
    test('defaults to allowlist for null', () {
      expect(parseScriptPolicy(null), ScriptPolicy.allowlist);
    });

    test('maps known values', () {
      expect(parseScriptPolicy('all'), ScriptPolicy.all);
      expect(parseScriptPolicy('allowlist'), ScriptPolicy.allowlist);
      expect(parseScriptPolicy('none'), ScriptPolicy.none);
    });

    test('rejects unknown values with UsageError', () {
      expect(() => parseScriptPolicy('strict'), throwsA(isA<UsageError>()));
    });
  });

  group('parseMinReleaseAge', () {
    test('returns null for null / empty / whitespace', () {
      expect(parseMinReleaseAge(null), isNull);
      expect(parseMinReleaseAge(''), isNull);
      expect(parseMinReleaseAge('   '), isNull);
    });

    test('parses non-negative integer as minutes (pnpm grammar)', () {
      expect(parseMinReleaseAge('1440'), const Duration(minutes: 1440));
      expect(parseMinReleaseAge('10080'), const Duration(minutes: 10080));
      expect(parseMinReleaseAge('1'), const Duration(minutes: 1));
    });

    test('0 means no filter (matches pnpm opt-out)', () {
      expect(parseMinReleaseAge('0'), isNull);
    });

    test('rejects unit suffixes (pnpm rejects them too)', () {
      expect(() => parseMinReleaseAge('7d'), throwsA(isA<UsageError>()));
      expect(() => parseMinReleaseAge('48h'), throwsA(isA<UsageError>()));
      expect(() => parseMinReleaseAge('30m'), throwsA(isA<UsageError>()));
      expect(() => parseMinReleaseAge('60s'), throwsA(isA<UsageError>()));
    });

    test('rejects malformed values', () {
      expect(() => parseMinReleaseAge('abc'), throwsA(isA<UsageError>()));
      expect(() => parseMinReleaseAge('-5'), throwsA(isA<UsageError>()));
      expect(() => parseMinReleaseAge('1.5'), throwsA(isA<UsageError>()));
      expect(() => parseMinReleaseAge('1 day'), throwsA(isA<UsageError>()));
    });
  });

  group('InstallOptions.effectiveScriptPolicy', () {
    test('honors explicit scriptPolicy when ignoreScripts is false', () {
      const opts = InstallOptions(scriptPolicy: ScriptPolicy.all);
      expect(opts.effectiveScriptPolicy, ScriptPolicy.all);
    });

    test('forces none when ignoreScripts is true', () {
      const opts = InstallOptions(
        ignoreScripts: true,
        scriptPolicy: ScriptPolicy.all,
      );
      expect(opts.effectiveScriptPolicy, ScriptPolicy.none);
    });

    test('defaults to allowlist', () {
      const opts = InstallOptions();
      expect(opts.effectiveScriptPolicy, ScriptPolicy.allowlist);
    });
  });
}
