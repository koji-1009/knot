import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;

import '../install_operation.dart';
import '../progress_renderer.dart';
import '../runner.dart';
import '_safety_flags.dart';

/// `knot ci` — equivalent to `install --frozen-lockfile`, but also wipes
/// any existing `node_modules` so the build is reproducible.
class CiCommand extends Command<int> {
  CiCommand({this._logger}) {
    argParser
      ..addFlag(
        'ignore-scripts',
        defaultsTo: false,
        help: 'Do not run lifecycle scripts.',
      )
      ..addOption(
        'allow-scripts',
        defaultsTo: 'allowlist',
        allowed: ['all', 'allowlist', 'none'],
        help: 'Which packages may run install-time scripts.',
      )
      ..addOption(
        'minimum-release-age',
        help:
            'Refuse package versions younger than this duration '
            '(e.g. 7d, 24h, 48h).',
      )
      ..addOption(
        'verify-signatures',
        defaultsTo: 'none',
        allowed: ['none', 'weak', 'strict'],
        help: 'ECDSA signature enforcement for tarballs.',
      )
      ..addOption(
        'audit-level',
        defaultsTo: 'none',
        allowed: ['none', 'info', 'low', 'moderate', 'high', 'critical'],
        help:
            'Fail when any installed package has a vulnerability '
            'at or above this severity.',
      );
  }

  final KnotLogger? _logger;

  @override
  String get name => 'ci';

  @override
  String get description =>
      'Clean install for CI: deletes node_modules and enforces the lockfile.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final root = Directory.current.path;
    final nodeModules = Directory(p.join(root, 'node_modules'));
    if (await nodeModules.exists()) {
      await nodeModules.delete(recursive: true);
    }
    final renderer = ProgressRenderer(level: logLevelFor(globalResults));
    try {
      final op = InstallOperation(
        projectRoot: root,
        options: InstallOptions(
          frozenLockfile: true,
          ignoreScripts: results['ignore-scripts'] as bool,
          scriptPolicy: parseScriptPolicy(results['allow-scripts'] as String?),
          minReleaseAge: parseMinReleaseAge(
            results['minimum-release-age'] as String?,
          ),
          signaturePolicy: parseSignaturePolicy(
            results['verify-signatures'] as String?,
          ),
          auditLevel: parseInstallAuditLevel(results['audit-level'] as String?),
        ),
        logger: _logger,
        onEvent: renderer.emit,
      );
      await op.run();
      return 0;
    } finally {
      renderer.close();
    }
  }
}
