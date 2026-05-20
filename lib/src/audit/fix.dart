import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:knot/src/semver/semver.dart';

import 'service.dart';

/// One advisory whose locked version can be replaced with a safe one.
class AuditFix {
  AuditFix({
    required this.packageName,
    required this.fromVersion,
    required this.toVersion,
    required this.severity,
    required this.advisoryUrl,
    required this.reason,
  });
  final String packageName;
  final String fromVersion;
  final String toVersion;
  final String severity;
  final String advisoryUrl;

  /// Human-readable explanation: which advisory was matched, which
  /// `patched_versions` range produced [toVersion], and whether the
  /// user's `package.json` range needs to widen.
  final String reason;
}

/// An advisory we *can't* auto-fix — typically a transitive
/// vulnerability whose nearest patched version doesn't satisfy the
/// upstream consumer's range, or one with no `patched_versions` field
/// at all. Surfaced so the operator can decide manually.
class AuditUnfixable {
  AuditUnfixable({
    required this.packageName,
    required this.installedVersion,
    required this.severity,
    required this.advisoryUrl,
    required this.reason,
  });
  final String packageName;
  final String installedVersion;
  final String severity;
  final String advisoryUrl;
  final String reason;
}

class AuditFixPlan {
  AuditFixPlan({required this.fixes, required this.unfixable});
  final List<AuditFix> fixes;
  final List<AuditUnfixable> unfixable;

  bool get isEmpty => fixes.isEmpty && unfixable.isEmpty;
}

/// Build a [AuditFixPlan] from an [AuditReport] by consulting the
/// registry for each affected package's full version list.
///
/// Strategy (kept narrow on purpose):
///
/// 1. For every finding, look up the package's packument via the
///    supplied [RegistryClient].
/// 2. Filter the version list by the advisory's `patched_versions`
///    range. The minimum match wins — smallest possible bump.
/// 3. The fix is only proposed when the chosen version differs from
///    the locked one. Equal versions (lockfile already at a patched
///    release that just happens to share an id with another
///    advisory) drop out.
///
/// Out of scope (deliberately):
///   - Re-solving the dependency graph. Transitive vulnerabilities
///     where the bumped version conflicts with the parent's pinned
///     range are reported via [AuditUnfixable] for manual handling.
///   - Re-running install. The plan only rewrites lockfile entries;
///     the operator runs `knot install` afterwards to materialise.
class AuditFixPlanner {
  AuditFixPlanner({required this.client});
  final RegistryClient client;

  Future<AuditFixPlan> plan({
    required AuditReport report,
    required Lockfile lockfile,
  }) async {
    final fixes = <AuditFix>[];
    final unfixable = <AuditUnfixable>[];
    final seen = <String>{};

    // Group findings by (package, advisory.id) so we don't propose
    // multiple bumps for the same vulnerability.
    for (final finding in report.findings) {
      final key = '${finding.packageName}#${finding.advisory.id}';
      if (!seen.add(key)) continue;

      final patched = finding.advisory.patchedVersions;
      if (patched == null || patched.isEmpty) {
        unfixable.add(
          AuditUnfixable(
            packageName: finding.packageName,
            installedVersion: finding.installedVersion,
            severity: finding.advisory.severity,
            advisoryUrl: finding.advisory.url,
            reason: 'no patched_versions advertised by the advisory',
          ),
        );
        continue;
      }

      final NpmRange patchedRange;
      try {
        patchedRange = NpmRange.parse(patched);
      } on FormatException {
        unfixable.add(
          AuditUnfixable(
            packageName: finding.packageName,
            installedVersion: finding.installedVersion,
            severity: finding.advisory.severity,
            advisoryUrl: finding.advisory.url,
            reason: 'unparseable patched_versions: $patched',
          ),
        );
        continue;
      }

      final Packument packument;
      try {
        packument = await client.packument(finding.packageName);
      } on Object catch (e) {
        unfixable.add(
          AuditUnfixable(
            packageName: finding.packageName,
            installedVersion: finding.installedVersion,
            severity: finding.advisory.severity,
            advisoryUrl: finding.advisory.url,
            reason: 'could not fetch packument: $e',
          ),
        );
        continue;
      }

      final candidates = <Version>[];
      for (final v in packument.versions.keys) {
        final parsed = tryParseVersion(v);
        if (parsed == null) continue;
        if (!patchedRange.satisfies(parsed)) continue;
        candidates.add(parsed);
      }
      if (candidates.isEmpty) {
        unfixable.add(
          AuditUnfixable(
            packageName: finding.packageName,
            installedVersion: finding.installedVersion,
            severity: finding.advisory.severity,
            advisoryUrl: finding.advisory.url,
            reason: 'no published version satisfies patched_versions=$patched',
          ),
        );
        continue;
      }
      candidates.sort();
      final target = candidates.first.toString();

      if (target == finding.installedVersion) {
        // Already at a patched release but the advisory still
        // matched — probably a server-side over-report. Skip
        // silently rather than churn the lockfile.
        continue;
      }

      // Conservative gate: only fix when the target version is
      // already in the lockfile, OR the package is a top-level
      // declared dep (where the user's range governs and we can
      // sensibly bump). Transitive packages whose nearest patched
      // release falls outside the parent's range stay in
      // unfixable — we can't safely tweak someone else's lockfile
      // graph without rerunning resolution.
      final isTopLevel = _topLevelNames(lockfile).contains(finding.packageName);
      if (!isTopLevel) {
        unfixable.add(
          AuditUnfixable(
            packageName: finding.packageName,
            installedVersion: finding.installedVersion,
            severity: finding.advisory.severity,
            advisoryUrl: finding.advisory.url,
            reason:
                'transitive dependency — run `knot update ${finding.packageName}` '
                'and re-audit',
          ),
        );
        continue;
      }

      fixes.add(
        AuditFix(
          packageName: finding.packageName,
          fromVersion: finding.installedVersion,
          toVersion: target,
          severity: finding.advisory.severity,
          advisoryUrl: finding.advisory.url,
          reason:
              'min version in patched_versions=$patched is $target '
              '(advisory ${finding.advisory.id})',
        ),
      );
    }

    return AuditFixPlan(fixes: fixes, unfixable: unfixable);
  }

  Set<String> _topLevelNames(Lockfile lockfile) {
    final importer = lockfile.importers['.'];
    if (importer == null) return const {};
    return {
      ...importer.dependencies.keys,
      ...importer.devDependencies.keys,
      ...importer.optionalDependencies.keys,
      ...importer.peerDependencies.keys,
    };
  }
}
