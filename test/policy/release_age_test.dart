import 'package:knot/src/policy/release_age.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.parse('2026-05-18T00:00:00Z');

  group('MinReleaseAgePolicy', () {
    test('enabled when minimum is set', () {
      const p = MinReleaseAgePolicy(minimum: Duration(hours: 24));
      expect(p.enabled, isTrue);
      expect(MinReleaseAgePolicy.v11Default.enabled, isTrue);
      expect(const MinReleaseAgePolicy().enabled, isFalse);
    });

    test('exclude pattern matches exact package name', () {
      const p = MinReleaseAgePolicy(
        minimum: Duration(hours: 24),
        excludePatterns: ['react'],
      );
      expect(p.isExcluded('react'), isTrue);
      expect(p.isExcluded('react-dom'), isFalse);
    });

    test('exclude pattern with scope wildcard matches all in scope', () {
      const p = MinReleaseAgePolicy(
        minimum: Duration(hours: 24),
        excludePatterns: ['@types/*'],
      );
      expect(p.isExcluded('@types/node'), isTrue);
      expect(p.isExcluded('@types/react'), isTrue);
      expect(p.isExcluded('@radix-ui/react'), isFalse);
    });
  });

  group('evaluateReleaseAge', () {
    final cutoff = now.subtract(const Duration(days: 1));

    test('mature when published before the cutoff', () {
      expect(
        evaluateReleaseAge(
          cutoff: cutoff,
          publishedAt: DateTime.parse('2026-05-10T00:00:00Z'),
          ignoreMissingTime: true,
        ),
        ReleaseAgeVerdict.mature,
      );
    });

    test('immature when published after the cutoff', () {
      expect(
        evaluateReleaseAge(
          cutoff: cutoff,
          publishedAt: DateTime.parse('2026-05-17T23:00:00Z'),
          ignoreMissingTime: true,
        ),
        ReleaseAgeVerdict.immature,
      );
    });

    test('missing time + ignoreMissingTime=true → mature', () {
      expect(
        evaluateReleaseAge(
          cutoff: cutoff,
          publishedAt: null,
          ignoreMissingTime: true,
        ),
        ReleaseAgeVerdict.mature,
      );
    });

    test('missing time + ignoreMissingTime=false → unknownTime', () {
      expect(
        evaluateReleaseAge(
          cutoff: cutoff,
          publishedAt: null,
          ignoreMissingTime: false,
        ),
        ReleaseAgeVerdict.unknownTime,
      );
    });
  });
}
