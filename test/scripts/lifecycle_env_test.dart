import 'package:knot/src/scripts/scripts.dart';
import 'package:test/test.dart';

void main() {
  LifecycleScript newScript() => LifecycleScript(
        event: LifecycleEvent.postinstall,
        packageName: 'demo',
        packageVersion: '1.0.0',
        workingDir: '/tmp/demo',
        command: 'echo hi',
      );

  group('buildLifecycleEnv', () {
    test('strips ambient env not in the passthrough list', () {
      final env = buildLifecycleEnv(
        script: newScript(),
        baseEnv: const {
          'PATH': '/usr/bin',
          'HOME': '/home/u',
          'SECRET_API_KEY': 'leak-me',
          'NPM_CONFIG_REGISTRY': 'https://leak.example/',
        },
      );
      expect(env.containsKey('SECRET_API_KEY'), isFalse);
      expect(env.containsKey('NPM_CONFIG_REGISTRY'), isFalse);
      expect(env['HOME'], '/home/u');
    });

    test('NODE_OPTIONS is passed through explicitly', () {
      final env = buildLifecycleEnv(
        script: newScript(),
        baseEnv: const {'NODE_OPTIONS': '--max-old-space-size=4096'},
      );
      expect(env['NODE_OPTIONS'], '--max-old-space-size=4096');
    });

    test('npm_package_json is NOT set even when present in ambient env', () {
      final env = buildLifecycleEnv(
        script: newScript(),
        baseEnv: const {'npm_package_json': '/legacy/package.json'},
      );
      expect(env.containsKey('npm_package_json'), isFalse);
    });

    test('npm metadata is populated from the script', () {
      final env = buildLifecycleEnv(script: newScript(), baseEnv: const {});
      expect(env['npm_lifecycle_event'], 'postinstall');
      expect(env['npm_package_name'], 'demo');
      expect(env['npm_package_version'], '1.0.0');
    });

    test('binDir is prepended to PATH', () {
      final env = buildLifecycleEnv(
        script: newScript(),
        baseEnv: const {'PATH': '/usr/bin'},
        binDir: '/proj/node_modules/.bin',
      );
      expect(env['PATH'], '/proj/node_modules/.bin:/usr/bin');
    });

    test('extraEnv merges on top of populated env', () {
      final env = buildLifecycleEnv(
        script: newScript(),
        baseEnv: const {'PATH': '/usr/bin'},
        extraEnv: const {'CUSTOM_OVERRIDE': '1', 'PATH': '/override'},
      );
      expect(env['CUSTOM_OVERRIDE'], '1');
      expect(env['PATH'], '/override');
    });
  });
}
