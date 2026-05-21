import 'package:knot/src/cli/commands/peers_command.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:test/test.dart';

Lockfile _makeLock(Map<String, LockedPackage> packages) => Lockfile(
      lockfileVersion: 1,
      importers: const {},
      packages: packages,
    );

LockedPackage _pkg(
  String name,
  String version, {
  Map<String, String> peerDependencies = const {},
  Map<String, PeerDependencyMeta> peerDependenciesMeta = const {},
}) =>
    LockedPackage(
      name: name,
      version: version,
      resolution: const Resolution.tarball(tarball: 'x'),
      peerDependencies: peerDependencies,
      peerDependenciesMeta: peerDependenciesMeta,
    );

void main() {
  group('checkPeerDependencies', () {
    test('no peers → no issues', () {
      final lock = _makeLock({
        'a': _pkg('a', '1.0.0'),
      });
      expect(checkPeerDependencies(lock), isEmpty);
    });

    test('satisfied peer → no issues', () {
      final lock = _makeLock({
        'a': _pkg(
          'a',
          '1.0.0',
          peerDependencies: const {'react': '^18.0.0'},
        ),
        'react': _pkg('react', '18.3.0'),
      });
      expect(checkPeerDependencies(lock), isEmpty);
    });

    test('missing peer (non-optional) → issue.kind=missing', () {
      final lock = _makeLock({
        'a': _pkg(
          'a',
          '1.0.0',
          peerDependencies: const {'react': '^18.0.0'},
        ),
      });
      final issues = checkPeerDependencies(lock);
      expect(issues, hasLength(1));
      expect(issues.first.kind, 'missing');
      expect(issues.first.peerName, 'react');
    });

    test('missing peer marked optional → no issue', () {
      final lock = _makeLock({
        'a': _pkg(
          'a',
          '1.0.0',
          peerDependencies: const {'react': '^18.0.0'},
          peerDependenciesMeta: const {
            'react': PeerDependencyMeta(optional: true),
          },
        ),
      });
      expect(checkPeerDependencies(lock), isEmpty);
    });

    test('installed version outside range → issue.kind=mismatch', () {
      final lock = _makeLock({
        'a': _pkg(
          'a',
          '1.0.0',
          peerDependencies: const {'react': '^18.0.0'},
        ),
        'react': _pkg('react', '17.0.2'),
      });
      final issues = checkPeerDependencies(lock);
      expect(issues, hasLength(1));
      expect(issues.first.kind, 'mismatch');
      expect(issues.first.installedVersion, '17.0.2');
    });

    test('multiple issues all reported', () {
      final lock = _makeLock({
        'a': _pkg(
          'a',
          '1.0.0',
          peerDependencies: const {'react': '^18.0.0', 'vue': '^3.0.0'},
        ),
        'react': _pkg('react', '17.0.0'),
        // vue missing
      });
      final issues = checkPeerDependencies(lock);
      expect(issues, hasLength(2));
    });
  });
}
