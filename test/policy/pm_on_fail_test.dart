import 'package:knot/src/cli/package_json.dart';
import 'package:knot/src/policy/pm_on_fail.dart';
import 'package:test/test.dart';

PackageJson pkg({String? packageManager, DevEnginesEntry? devEnginesPm}) =>
    PackageJson(
      name: 'app',
      version: '1.0.0',
      packageManager: packageManager,
      devEnginesPackageManager: devEnginesPm,
    );

void main() {
  group('parsePmOnFail', () {
    test('default is download', () {
      expect(parsePmOnFail(null), PmOnFailPolicy.download);
      expect(parsePmOnFail(''), PmOnFailPolicy.download);
    });

    test('all four explicit values round-trip', () {
      expect(parsePmOnFail('download'), PmOnFailPolicy.download);
      expect(parsePmOnFail('error'), PmOnFailPolicy.error);
      expect(parsePmOnFail('warn'), PmOnFailPolicy.warn);
      expect(parsePmOnFail('ignore'), PmOnFailPolicy.ignore);
    });

    test('unknown value throws', () {
      expect(() => parsePmOnFail('panic'), throwsFormatException);
    });
  });

  group('evaluatePmOnFail', () {
    test('no pin → proceed/satisfied', () {
      final r = evaluatePmOnFail(pkg: pkg(), knotVersion: '0.0.1-dev');
      expect(r.satisfied, isTrue);
      expect(r.action, PmOnFailAction.proceed);
    });

    test('knot pin satisfied by current version → proceed', () {
      final r = evaluatePmOnFail(
        pkg: pkg(packageManager: 'knot@0.0.1-dev'),
        knotVersion: '0.0.1-dev',
      );
      expect(r.satisfied, isTrue);
      expect(r.action, PmOnFailAction.proceed);
    });

    test('knot range via devEngines satisfied → proceed', () {
      final r = evaluatePmOnFail(
        pkg: pkg(
          devEnginesPm: const DevEnginesEntry(
            name: 'knot',
            version: '>=0.0.0-0 <1.0.0',
          ),
        ),
        knotVersion: '0.0.1-dev',
      );
      expect(r.satisfied, isTrue);
    });

    test('knot pin mismatch + policy=error → fail', () {
      final r = evaluatePmOnFail(
        pkg: pkg(packageManager: 'knot@9.9.9'),
        knotVersion: '0.0.1-dev',
        policy: PmOnFailPolicy.error,
      );
      expect(r.satisfied, isFalse);
      expect(r.action, PmOnFailAction.fail);
    });

    test('knot pin mismatch + policy=warn → warn', () {
      final r = evaluatePmOnFail(
        pkg: pkg(packageManager: 'knot@9.9.9'),
        knotVersion: '0.0.1-dev',
        policy: PmOnFailPolicy.warn,
      );
      expect(r.action, PmOnFailAction.warn);
    });

    test('knot pin mismatch + policy=ignore → ignore', () {
      final r = evaluatePmOnFail(
        pkg: pkg(packageManager: 'knot@9.9.9'),
        knotVersion: '0.0.1-dev',
        policy: PmOnFailPolicy.ignore,
      );
      expect(r.action, PmOnFailAction.ignore);
    });

    test(
      'knot pin mismatch + policy=download → downloadDeferred (L-basic)',
      () {
        final r = evaluatePmOnFail(
          pkg: pkg(packageManager: 'knot@9.9.9'),
          knotVersion: '0.0.1-dev',
          policy: PmOnFailPolicy.download,
        );
        expect(r.action, PmOnFailAction.downloadDeferred);
      },
    );

    test('devEngines.onFail overrides the global policy', () {
      final r = evaluatePmOnFail(
        pkg: pkg(
          devEnginesPm: const DevEnginesEntry(
            name: 'knot',
            version: '^9.0.0',
            onFail: 'error',
          ),
        ),
        knotVersion: '0.0.1-dev',
        policy: PmOnFailPolicy.warn,
      );
      expect(r.action, PmOnFailAction.fail);
    });

    test('foreign manager (pnpm@11) → warn + foreignManager set', () {
      final r = evaluatePmOnFail(
        pkg: pkg(packageManager: 'pnpm@11.1.3'),
        knotVersion: '0.0.1-dev',
      );
      expect(r.foreignManager, 'pnpm');
      expect(r.action, PmOnFailAction.warn);
      expect(r.satisfied, isFalse);
    });

    test('integrity suffix is stripped from legacy packageManager', () {
      final r = evaluatePmOnFail(
        pkg: pkg(
          packageManager: 'knot@0.0.1-dev+sha224:abcdef0123456789abcdef01',
        ),
        knotVersion: '0.0.1-dev',
      );
      expect(r.satisfied, isTrue);
    });
  });
}
