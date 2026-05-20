import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/core/core.dart';

import '../install_operation.dart';
import '../progress_renderer.dart';
import '../runner.dart';
import '_safety_flags.dart';

class InstallCommand extends Command<int> {
  InstallCommand({this._logger}) {
    argParser
      ..addFlag(
        'frozen-lockfile',
        defaultsTo: false,
        help: 'Fail if resolution would change the lockfile.',
      )
      ..addFlag(
        'prefer-offline',
        defaultsTo: false,
        help: 'Skip network fetches when a cached copy exists.',
      )
      ..addFlag(
        'offline',
        defaultsTo: false,
        help: 'Forbid network access — fail on cache miss.',
      )
      ..addFlag(
        'ignore-scripts',
        defaultsTo: false,
        help:
            'Do not run lifecycle scripts. '
            'Alias for --allow-scripts=none.',
      )
      ..addOption(
        'allow-scripts',
        defaultsTo: 'allowlist',
        allowed: ['all', 'allowlist', 'none'],
        help:
            'Which packages may run install-time scripts. '
            'allowlist (default) honors package.json#onlyBuiltDependencies; '
            'all runs every script (legacy); '
            'none skips all scripts.',
      )
      ..addOption(
        'minimum-release-age',
        help:
            'Refuse package versions younger than this duration '
            '(e.g. 7d, 24h, 48h). Defends against freshly-published '
            'malicious releases.',
      )
      ..addOption(
        'verify-signatures',
        defaultsTo: 'none',
        allowed: ['none', 'weak', 'strict'],
        help:
            'Verify the registry\'s ECDSA signature on each tarball '
            'against /-/npm/v1/keys. weak verifies when a signature '
            'is present; strict additionally fails on missing or '
            'unknown-keyid signatures.',
      )
      ..addOption(
        'audit-level',
        defaultsTo: 'none',
        allowed: ['none', 'info', 'low', 'moderate', 'high', 'critical'],
        help:
            'After install completes, query the registry advisory '
            'database and fail when any package has a vulnerability '
            'at or above the given severity. `none` (default) skips '
            'the audit round-trip.',
      )
      ..addFlag('production', defaultsTo: false, help: 'Skip devDependencies.')
      ..addFlag(
        'engine-strict',
        defaultsTo: false,
        help: 'Fail when a dependency\'s engines.node is incompatible.',
      );
  }

  final KnotLogger? _logger;

  @override
  String get name => 'install';

  @override
  List<String> get aliases => const ['i'];

  @override
  String get description => 'Install dependencies from package.json.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final level = logLevelFor(globalResults);
    final renderer = ProgressRenderer(level: level);
    final options = InstallOptions(
      frozenLockfile: results['frozen-lockfile'] as bool,
      preferOffline: results['prefer-offline'] as bool,
      offline: results['offline'] as bool,
      ignoreScripts: results['ignore-scripts'] as bool,
      scriptPolicy: parseScriptPolicy(results['allow-scripts'] as String?),
      minReleaseAge: parseMinReleaseAge(
        results['minimum-release-age'] as String?,
      ),
      signaturePolicy: parseSignaturePolicy(
        results['verify-signatures'] as String?,
      ),
      auditLevel: parseInstallAuditLevel(results['audit-level'] as String?),
      production: results['production'] as bool,
      engineStrict: results['engine-strict'] as bool,
    );
    try {
      final op = InstallOperation(
        projectRoot: Directory.current.path,
        options: options,
        logger: _logger,
        onEvent: renderer.emit,
      );
      final report = await op.run();
      for (final w in report.warnings) {
        stdout.writeln('warning: $w');
      }
      return 0;
    } finally {
      renderer.close();
    }
  }
}
