import 'package:knot/src/workspace_state/workspace_state.dart';
import 'package:test/test.dart';

void main() {
  group('parseVerifyDepsBeforeRun', () {
    test('default is install', () {
      expect(parseVerifyDepsBeforeRun(null), VerifyDepsBeforeRunPolicy.install);
      expect(parseVerifyDepsBeforeRun(''), VerifyDepsBeforeRunPolicy.install);
    });

    test('round-trips the five explicit values', () {
      expect(parseVerifyDepsBeforeRun('off'), VerifyDepsBeforeRunPolicy.off);
      expect(parseVerifyDepsBeforeRun('warn'), VerifyDepsBeforeRunPolicy.warn);
      expect(
        parseVerifyDepsBeforeRun('error'),
        VerifyDepsBeforeRunPolicy.error,
      );
      expect(
        parseVerifyDepsBeforeRun('install'),
        VerifyDepsBeforeRunPolicy.install,
      );
      expect(
        parseVerifyDepsBeforeRun('prompt'),
        VerifyDepsBeforeRunPolicy.prompt,
      );
    });

    test('aliases: false→off, true→error', () {
      expect(parseVerifyDepsBeforeRun('false'), VerifyDepsBeforeRunPolicy.off);
      expect(parseVerifyDepsBeforeRun('true'), VerifyDepsBeforeRunPolicy.error);
    });

    test('unknown value throws', () {
      expect(() => parseVerifyDepsBeforeRun('panic'), throwsFormatException);
    });
  });

  group('decideVerifyAction', () {
    test('not stale → proceed regardless of policy', () {
      for (final p in VerifyDepsBeforeRunPolicy.values) {
        expect(
          decideVerifyAction(policy: p, stale: false),
          VerifyDepsAction.proceed,
        );
      }
    });

    test('stale + each policy maps to expected action', () {
      expect(
        decideVerifyAction(policy: VerifyDepsBeforeRunPolicy.off, stale: true),
        VerifyDepsAction.proceedNoState,
      );
      expect(
        decideVerifyAction(policy: VerifyDepsBeforeRunPolicy.warn, stale: true),
        VerifyDepsAction.warn,
      );
      expect(
        decideVerifyAction(
          policy: VerifyDepsBeforeRunPolicy.error,
          stale: true,
        ),
        VerifyDepsAction.fail,
      );
      expect(
        decideVerifyAction(
          policy: VerifyDepsBeforeRunPolicy.install,
          stale: true,
        ),
        VerifyDepsAction.install,
      );
      expect(
        decideVerifyAction(
          policy: VerifyDepsBeforeRunPolicy.prompt,
          stale: true,
        ),
        VerifyDepsAction.prompt,
      );
    });
  });
}
