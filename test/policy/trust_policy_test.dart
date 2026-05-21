import 'package:knot/src/policy/trust_policy.dart';
import 'package:knot/src/semver/semver.dart';
import 'package:test/test.dart';

void main() {
  group('parseTrustPolicy', () {
    test('default is off', () {
      expect(parseTrustPolicy(null), TrustPolicy.off);
      expect(parseTrustPolicy(''), TrustPolicy.off);
    });

    test('no-downgrade is recognized in both forms', () {
      expect(parseTrustPolicy('no-downgrade'), TrustPolicy.noDowngrade);
      expect(parseTrustPolicy('NoDowngrade'), TrustPolicy.noDowngrade);
    });

    test('unknown value throws', () {
      expect(() => parseTrustPolicy('panic'), throwsFormatException);
    });
  });

  group('evaluateTrust', () {
    final now = DateTime.parse('2026-05-21T00:00:00Z');

    test('policy=off → accept regardless of history', () {
      final decision = evaluateTrust(
        policy: TrustPolicy.off,
        candidate: parseVersion('1.0.0'),
        now: now,
        previous: TrustRecord(
          version: parseVersion('2.0.0'),
          seenAt: now,
        ),
      );
      expect(decision, TrustDecision.accept);
    });

    test('no previous record → accept', () {
      final decision = evaluateTrust(
        policy: TrustPolicy.noDowngrade,
        candidate: parseVersion('1.0.0'),
        now: now,
      );
      expect(decision, TrustDecision.accept);
    });

    test('candidate >= previous → acceptAndRefresh', () {
      final decision = evaluateTrust(
        policy: TrustPolicy.noDowngrade,
        candidate: parseVersion('2.5.0'),
        now: now,
        previous: TrustRecord(
          version: parseVersion('2.0.0'),
          seenAt: now.subtract(const Duration(hours: 1)),
        ),
      );
      expect(decision, TrustDecision.acceptAndRefresh);
    });

    test('candidate < previous within window → downgrade refused', () {
      final decision = evaluateTrust(
        policy: TrustPolicy.noDowngrade,
        candidate: parseVersion('1.0.0'),
        now: now,
        previous: TrustRecord(
          version: parseVersion('2.0.0'),
          seenAt: now.subtract(const Duration(hours: 1)),
        ),
        ignoreAfter: const Duration(days: 7),
      );
      expect(decision, TrustDecision.downgrade);
    });

    test('expired record (older than ignoreAfter) → accept', () {
      final decision = evaluateTrust(
        policy: TrustPolicy.noDowngrade,
        candidate: parseVersion('1.0.0'),
        now: now,
        previous: TrustRecord(
          version: parseVersion('2.0.0'),
          seenAt: now.subtract(const Duration(days: 30)),
        ),
        ignoreAfter: const Duration(days: 7),
      );
      expect(decision, TrustDecision.accept);
    });
  });
}
