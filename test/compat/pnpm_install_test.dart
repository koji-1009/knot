/// Real-registry integration test for pnpm-mode.
///
/// Runs only when `KNOT_NETWORK=1`. Drives `knot install` against the
/// real npm registry in a project that carries a `pnpm-lock.yaml`, and
/// verifies knot stays in pnpm-mode end to end: it materializes
/// `node_modules`, rewrites `pnpm-lock.yaml` (not `package-lock.json`),
/// and the rewritten lockfile drives a second, locked install.
@TestOn('vm')
@Tags(['network'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:knot/src/lockfile/lockfile.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

import '../cli/_test_binary.dart';

void main() {
  final enabled = Platform.environment['KNOT_NETWORK'] == '1';

  test(
    'pnpm-mode install reads/writes pnpm-lock.yaml from the live registry',
    skip: enabled ? null : 'network gated test (set KNOT_NETWORK=1 to enable)',
    () async {
      await d.dir('proj', [
        d.file(
          'package.json',
          const JsonEncoder.withIndent('  ').convert({
            'name': 'knot-compat-pnpm',
            'version': '0.0.0',
            'private': true,
            'dependencies': {'react': '^18.0.0'},
          }),
        ),
        // A pnpm-lock.yaml — even a stale, empty one — selects pnpm-mode.
        // knot re-resolves against package.json and rewrites it.
        d.file('pnpm-lock.yaml', "lockfileVersion: '9.0'\nimporters: {}\n"),
      ]).create();

      final projDir = p.join(d.sandbox, 'proj');
      final bin = await knotTestBinary();

      Future<void> runInstall() async {
        final process = await TestProcess.start(bin, [
          'install',
          '--ignore-scripts',
        ], workingDirectory: projDir);
        await process.shouldExit(0);
      }

      await runInstall();

      // react materialized at 18.x.
      final reactPkgFile = File(
        p.join(projDir, 'node_modules', 'react', 'package.json'),
      );
      expect(await reactPkgFile.exists(), isTrue);
      final pkg =
          jsonDecode(await reactPkgFile.readAsString()) as Map<String, dynamic>;
      expect(
        (pkg['version'] as String).startsWith('18.'),
        isTrue,
        reason: 'expected react@18.x, got ${pkg['version']}',
      );

      // pnpm-mode stays pnpm-mode: pnpm-lock.yaml is rewritten with the
      // resolution and no package-lock.json is produced.
      expect(File(p.join(projDir, 'package-lock.json')).existsSync(), isFalse);
      final lock = parsePnpmLockfile(
        await File(p.join(projDir, 'pnpm-lock.yaml')).readAsString(),
      );
      expect(lock.importers['.']!.dependencies['react']!.specifier, '^18.0.0');
      expect(
        lock.packages.keys.any((k) => k.startsWith('react@18.')),
        isTrue,
        reason: 'rewritten pnpm-lock.yaml should pin a react@18.x package',
      );

      // The freshly written pnpm-lock.yaml drives a second install via
      // the read/locked path — it must still succeed.
      await runInstall();
      expect(await reactPkgFile.exists(), isTrue);
    },
  );
}
