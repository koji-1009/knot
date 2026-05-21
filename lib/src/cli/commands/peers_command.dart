import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/semver/semver.dart';

/// `knot peers` — peer-dep utilities (pnpm parity, Phase M).
class PeersCommand extends Command<int> {
  PeersCommand() {
    addSubcommand(PeersCheckCommand());
  }

  @override
  String get name => 'peers';

  @override
  String get description => 'Peer-dependency utilities.';
}

/// `knot peers check` — verify peer-dep satisfaction without installing.
///
/// Walks the project lockfile, collects every peer demand a locked
/// package declares, and matches it against installed versions
/// elsewhere in the lockfile. Returns non-zero exit when any non-
/// optional peer is unsatisfied — same shape as `pnpm peers check`.
class PeersCheckCommand extends Command<int> {
  @override
  String get name => 'check';

  @override
  String get description =>
      'Verify peer dependencies without installing; exits 1 on mismatch.';

  @override
  Future<int> run() async {
    final root = Directory.current.path;
    final lockfile = await readProjectLockfile(root);
    if (lockfile == null) {
      stderr.writeln(
        'knot peers check: no lockfile at $root/package-lock.json',
      );
      return 1;
    }
    final issues = checkPeerDependencies(lockfile);
    if (issues.isEmpty) {
      stdout.writeln('all peer dependencies satisfied');
      return 0;
    }
    for (final issue in issues) {
      stderr.writeln(issue.format());
    }
    return 1;
  }
}

/// One peer-dependency problem reported by [checkPeerDependencies].
class PeerIssue {
  PeerIssue({
    required this.kind,
    required this.consumer,
    required this.peerName,
    required this.range,
    this.installedVersion,
  });

  /// `missing` or `mismatch`.
  final String kind;

  /// `<name>@<version>` of the package demanding the peer.
  final String consumer;
  final String peerName;
  final String range;
  final String? installedVersion;

  String format() {
    if (kind == 'missing') {
      return '$consumer requires peer $peerName@$range but no version is '
          'installed';
    }
    return '$consumer requires peer $peerName@$range but '
        '$peerName@$installedVersion is installed';
  }
}

/// Inspect [lockfile]'s packages and return any unsatisfied non-
/// optional peer demands. Pure function so callers can drive the
/// check from tests without I/O.
List<PeerIssue> checkPeerDependencies(Lockfile lockfile) {
  // Build a name → version index of the locked tree. The lockfile
  // schema stores each package by id (e.g. `react@18.0.0`) but every
  // entry already knows its name + version directly.
  final installed = <String, String>{};
  for (final entry in lockfile.packages.values) {
    installed[entry.name] = entry.version;
  }

  final issues = <PeerIssue>[];
  for (final entry in lockfile.packages.values) {
    for (final peer in entry.peerDependencies.entries) {
      final meta = entry.peerDependenciesMeta[peer.key];
      final isOptional = meta?.optional ?? false;
      final installedVersion = installed[peer.key];
      if (installedVersion == null) {
        if (!isOptional) {
          issues.add(
            PeerIssue(
              kind: 'missing',
              consumer: '${entry.name}@${entry.version}',
              peerName: peer.key,
              range: peer.value,
            ),
          );
        }
        continue;
      }
      if (!_satisfies(peer.value, installedVersion)) {
        issues.add(
          PeerIssue(
            kind: 'mismatch',
            consumer: '${entry.name}@${entry.version}',
            peerName: peer.key,
            range: peer.value,
            installedVersion: installedVersion,
          ),
        );
      }
    }
  }
  return issues;
}

bool _satisfies(String range, String versionStr) {
  final version = tryParseVersion(versionStr);
  if (version == null) return false;
  try {
    return NpmRange.parse(range).satisfies(version);
  } on FormatException {
    return false;
  }
}
