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

    test('parses day / hour / minute / second suffixes', () {
      expect(parseMinReleaseAge('7d'), const Duration(days: 7));
      expect(parseMinReleaseAge('48h'), const Duration(hours: 48));
      expect(parseMinReleaseAge('30m'), const Duration(minutes: 30));
      expect(parseMinReleaseAge('60s'), const Duration(seconds: 60));
    });

    test('rejects malformed values', () {
      // Missing unit
      expect(() => parseMinReleaseAge('7'), throwsA(isA<UsageError>()));
      // Unknown unit
      expect(() => parseMinReleaseAge('7w'), throwsA(isA<UsageError>()));
      // Multiple units in one expression — disallowed for unambiguity.
      expect(() => parseMinReleaseAge('1d2h'), throwsA(isA<UsageError>()));
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
