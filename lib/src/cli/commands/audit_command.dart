import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:knot/src/audit/audit.dart';
import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:path/path.dart' as p;

import '../package_json.dart';
import '../package_json_edit.dart';
import '../runner.dart';

/// `knot audit` — query the registry's advisory database for installed
/// packages and report findings.
///
/// Exit code is `1` whenever any finding has severity ≥ `--audit-level`
/// (default `high`), matching the npm/pnpm convention so CI scripts
/// can gate merges on `knot audit`.
class AuditCommand extends Command<int> {
  AuditCommand() {
    argParser
      ..addOption(
        'audit-level',
        defaultsTo: 'high',
        allowed: ['info', 'low', 'moderate', 'high', 'critical'],
        help:
            'Minimum severity that triggers exit code 1 '
            '(info < low < moderate < high < critical).',
      )
      ..addFlag(
        'production',
        defaultsTo: false,
        help: 'Skip advisories that only affect devDependencies.',
      )
      ..addFlag(
        'fix',
        defaultsTo: false,
        help:
            'Propose minimum version bumps for fixable advisories. '
            'Combine with --apply to rewrite package.json + lockfile; '
            'otherwise only the plan is printed (dry-run).',
      )
      ..addFlag(
        'apply',
        defaultsTo: false,
        help:
            'Persist the --fix plan to package.json (bumping dep '
            'ranges to exactly the patched version) and remove the '
            'now-stale lockfile entries. Run `knot install` after to '
            'materialize the bumps.',
      )
      ..addOption(
        'ignore-ghsas',
        help:
            'Comma-separated GHSA IDs to exclude from the report. '
            'Layered on top of `auditConfig.ignoreGhsas` and `.npmrc` '
            'ignore-ghsas; final list is the union.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit findings as a machine-readable JSON document on stdout.',
      );
  }

  @override
  String get name => 'audit';

  @override
  String get description =>
      'Check installed dependencies for known security advisories.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final json = results['json'] as bool;
    final threshold = AuditSeverity.parse(results['audit-level'] as String);
    final root = Directory.current.path;
    final lock = await readProjectLockfile(root);
    if (lock == null) {
      stderr.writeln(
        'knot audit: no lockfile found. Run `knot install` first.',
      );
      return 1;
    }
    final lockfile = results['production'] as bool
        ? _stripDevOnly(lock, root)
        : lock;
    if (lockfile.packages.isEmpty) {
      _emitClean(json);
      return 0;
    }

    final npmrc = await NpmrcLoader(projectDir: root).load();

    // Phase F: gather GHSA ignore list from CLI flag + .npmrc +
    // package.json#knot.auditConfig.ignoreGhsas. Union the sources;
    // case-insensitive comparison since the registry returns mixed
    // case and users may type either form.
    final pkgPath = p.join(root, 'package.json');
    final pkgManifest = await PackageJson.read(pkgPath);
    final ignoreGhsas = <String>{
      ..._splitCsv(results['ignore-ghsas'] as String?),
      ..._splitCsv(npmrc['ignore-ghsas']),
      ...pkgManifest.auditIgnoreGhsas,
    }.map((s) => s.toLowerCase()).toSet();

    final service = AuditService(config: npmrc, userAgent: 'knot/$knotVersion');
    try {
      var report = await service.audit(lockfile);
      if (ignoreGhsas.isNotEmpty) {
        report = AuditReport(
          findings: [
            for (final f in report.findings)
              if (!ignoreGhsas.contains(f.advisory.id.toLowerCase())) f,
          ],
          advisoryFetchErrors: report.advisoryFetchErrors,
        );
      }
      for (final err in report.advisoryFetchErrors) {
        stderr.writeln('warning: $err');
      }
      if (json) {
        _emitJson(report);
      } else {
        _emitHuman(report, threshold);
      }

      if (results['fix'] as bool) {
        final apply = results['apply'] as bool;
        final exitCode = await _runFix(
          report: report,
          lockfile: lockfile,
          npmrc: npmrc,
          root: root,
          apply: apply,
        );
        if (exitCode != 0) return exitCode;
      }

      if (report.advisoryFetchErrors.isNotEmpty && report.findings.isEmpty) {
        // We didn't get a clean view of the registry — treat as a soft
        // failure so CI doesn't pass on partial data.
        return 1;
      }
      return report.meetsThreshold(threshold) ? 1 : 0;
    } finally {
      service.close();
    }
  }

  /// `knot audit --fix [--apply]` implementation. Computes the bump
  /// plan and either prints it (dry-run) or rewrites
  /// `package.json` ranges. Lockfile mutation is deliberately limited
  /// to deleting the now-stale entries — running `knot install`
  /// afterwards lets the resolver pick the new graph.
  Future<int> _runFix({
    required AuditReport report,
    required Lockfile lockfile,
    required NpmrcConfig npmrc,
    required String root,
    required bool apply,
  }) async {
    if (report.findings.isEmpty) {
      stdout.writeln('audit fix: no findings to address');
      return 0;
    }
    final client = RegistryClient(
      config: npmrc,
      userAgent: 'knot/$knotVersion',
    );
    try {
      final planner = AuditFixPlanner(client: client);
      final plan = await planner.plan(report: report, lockfile: lockfile);

      if (plan.isEmpty) {
        stdout.writeln('audit fix: nothing actionable');
        return 0;
      }

      stdout.writeln('audit fix plan:');
      for (final f in plan.fixes) {
        stdout.writeln(
          '  bump ${f.packageName} ${f.fromVersion} → ${f.toVersion} '
          '(${f.severity})',
        );
        stdout.writeln('      ${f.reason}');
        stdout.writeln('      ${f.advisoryUrl}');
      }
      for (final u in plan.unfixable) {
        stdout.writeln(
          '  skip ${u.packageName}@${u.installedVersion} '
          '(${u.severity}): ${u.reason}',
        );
        stdout.writeln('      ${u.advisoryUrl}');
      }

      if (!apply) {
        stdout.writeln(
          '\nrun `knot audit --fix --apply` to write these bumps to '
          'package.json + lockfile, then `knot install`.',
        );
        return 0;
      }

      if (plan.fixes.isEmpty) {
        stdout.writeln('\nnothing to apply (all entries were unfixable).');
        return 0;
      }

      // Rewrite package.json ranges to pin the bumped versions
      // exactly. The user can relax to a caret/tilde manually later;
      // pinning keeps the lockfile-install path deterministic.
      final pkgPath = p.join(root, 'package.json');
      final pkg = await PackageJson.read(pkgPath);
      final editor = PackageJsonEditor(pkgPath);
      for (final f in plan.fixes) {
        final kind = _kindFor(pkg, f.packageName);
        if (kind == null) continue; // shouldn't happen — planner gates this
        await editor.addDependency(f.packageName, f.toVersion, kind);
      }

      // Drop the now-stale lockfile entries so a subsequent install
      // re-resolves them with the new range. We don't rewrite the
      // resolved graph here — the install path is the source of
      // truth for graph shape.
      final remainingPackages = <String, LockedPackage>{
        for (final e in lockfile.packages.entries)
          if (!plan.fixes.any(
            (f) =>
                e.value.name == f.packageName &&
                e.value.version == f.fromVersion,
          ))
            e.key: e.value,
      };
      final updated = Lockfile(
        lockfileVersion: lockfile.lockfileVersion,
        importers: lockfile.importers,
        packages: remainingPackages,
      );
      await writeProjectLockfile(
        projectRoot: root,
        lockfile: updated,
        projectName: pkg.name,
        projectVersion: pkg.version,
      );

      stdout.writeln(
        '\napplied ${plan.fixes.length} bump'
        '${plan.fixes.length == 1 ? "" : "s"} to package.json + '
        'lockfile. Run `knot install` to materialize.',
      );
      return 0;
    } finally {
      client.close();
    }
  }

  List<String> _splitCsv(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  DependencyKind? _kindFor(PackageJson pkg, String name) {
    if (pkg.dependencies.containsKey(name)) return DependencyKind.prod;
    if (pkg.devDependencies.containsKey(name)) return DependencyKind.dev;
    if (pkg.optionalDependencies.containsKey(name)) {
      return DependencyKind.optional;
    }
    if (pkg.peerDependencies.containsKey(name)) return DependencyKind.peer;
    return null;
  }

  /// Drop packages that only exist because of devDependencies. We don't
  /// have full dev-edge tracking, so we approximate: keep packages that
  /// are reachable from `dependencies` only.
  Lockfile _stripDevOnly(Lockfile lock, String root) {
    final importer = lock.importers['.'];
    if (importer == null) return lock;
    final keep = <String>{...importer.dependencies.keys};
    bool grew = true;
    while (grew) {
      grew = false;
      for (final pkg in lock.packages.values) {
        if (!keep.contains(pkg.name)) continue;
        for (final dep in pkg.dependencies.keys) {
          if (keep.add(dep)) grew = true;
        }
      }
    }
    return Lockfile(
      lockfileVersion: lock.lockfileVersion,
      importers: lock.importers,
      packages: {
        for (final e in lock.packages.entries)
          if (keep.contains(e.value.name)) e.key: e.value,
      },
    );
  }

  void _emitClean(bool json) {
    if (json) {
      stdout.writeln(
        jsonEncode({
          'findings': <Object>[],
          'totals': <String, int>{},
          'total': 0,
        }),
      );
    } else {
      stdout.writeln('found 0 vulnerabilities');
    }
  }

  void _emitJson(AuditReport report) {
    stdout.writeln(
      jsonEncode({
        'findings': [
          for (final f in report.findings)
            {
              'package': f.packageName,
              'installed': f.installedVersion,
              'severity': f.advisory.severity,
              'title': f.advisory.title,
              'vulnerable_versions': f.advisory.vulnerableVersions,
              'patched_versions': f.advisory.patchedVersions,
              'url': f.advisory.url,
              'id': f.advisory.id,
            },
        ],
        'totals': {
          for (final e in report.countsBySeverity.entries) e.key.name: e.value,
        },
        'total': report.total,
        'errors': report.advisoryFetchErrors,
      }),
    );
  }

  void _emitHuman(AuditReport report, AuditSeverity threshold) {
    if (report.findings.isEmpty) {
      stdout.writeln('found 0 vulnerabilities');
      return;
    }
    // Deduplicate per (package, advisory id) — the same advisory may
    // hit multiple installed versions of the same package and we don't
    // want to spam the user with near-identical lines.
    final seen = <String>{};
    final unique = <AuditFinding>[];
    for (final f in report.findings) {
      final key = '${f.packageName}#${f.advisory.id}';
      if (seen.add(key)) unique.add(f);
    }
    // Sort: highest severity first, then alphabetical by package.
    unique.sort((a, b) {
      final sa = AuditSeverity.parse(a.advisory.severity).index;
      final sb = AuditSeverity.parse(b.advisory.severity).index;
      if (sa != sb) return sb.compareTo(sa);
      return a.packageName.compareTo(b.packageName);
    });
    for (final f in unique) {
      stdout.writeln(
        '${_paintSeverity(f.advisory.severity)} '
        '${f.packageName}@${f.installedVersion}: '
        '${f.advisory.title}',
      );
      if (f.advisory.patchedVersions != null &&
          f.advisory.patchedVersions!.isNotEmpty) {
        stdout.writeln('  fix available: ${f.advisory.patchedVersions}');
      } else {
        stdout.writeln('  no fix available');
      }
      if (f.advisory.url.isNotEmpty) {
        stdout.writeln('  ${f.advisory.url}');
      }
    }
    stdout.writeln();
    final totals = report.countsBySeverity;
    stdout.writeln(
      'found ${report.total} vulnerabilities '
      '(${_summary(totals)})',
    );
    if (report.meetsThreshold(threshold)) {
      stdout.writeln(
        'audit-level=${threshold.name}: failing because at least one '
        'finding is ≥ ${threshold.name}',
      );
    }
  }

  String _paintSeverity(String severity) {
    // Keep this terminal-color-free; the global --color flag wires
    // ANSI codes through `ProgressRenderer`, but `audit` writes
    // directly to stdout so the safest cross-platform default is no
    // escape codes. Users grepping the output (or CI logs) prefer
    // plain labels anyway.
    final label = severity.toUpperCase().padRight(8);
    return label;
  }

  String _summary(Map<AuditSeverity, int> counts) {
    final parts = <String>[];
    for (final s in AuditSeverity.values.reversed) {
      final c = counts[s] ?? 0;
      if (c == 0) continue;
      parts.add('$c ${s.name}');
    }
    if (parts.isEmpty) parts.add('0 by severity');
    return parts.join(', ');
  }
}
