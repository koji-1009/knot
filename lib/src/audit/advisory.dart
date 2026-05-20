/// One npm security advisory. Mirrors the shape returned by the npm
/// registry's `/-/npm/v1/security/advisories/bulk` endpoint.
///
/// We keep only the fields the audit command renders or filters on;
/// the registry returns additional metadata (CWE list, references,
/// disclosure timeline) that's accessible via [url].
class Advisory {
  const Advisory({
    required this.id,
    required this.severity,
    required this.title,
    required this.vulnerableVersions,
    required this.url,
    this.patchedVersions,
  });

  /// GitHub Advisory Database ID (e.g. `GHSA-…`) or the legacy numeric
  /// npm advisory ID, stringified.
  final String id;

  /// One of `info`, `low`, `moderate`, `high`, `critical`. Anything
  /// outside that set is treated as `info` by [AuditSeverity.parse].
  final String severity;

  /// Short human-readable title (e.g. "Prototype Pollution in lodash").
  final String title;

  /// Semver range describing affected versions (e.g. `<4.17.21`).
  final String vulnerableVersions;

  /// Semver range describing fixed versions (e.g. `>=4.17.21`).
  /// `null` when there is no known fix yet.
  final String? patchedVersions;

  /// Canonical advisory URL — surfaced in the report so users can drill
  /// into the full disclosure / patch notes.
  final String url;

  factory Advisory.fromJson(Map<String, dynamic> json) {
    String stringId(Object? raw) {
      if (raw is num) return raw.toString();
      return (raw as String?) ?? '';
    }

    return Advisory(
      id: stringId(json['id'] ?? json['ghsa_id'] ?? json['github_advisory_id']),
      severity: (json['severity'] as String?) ?? 'info',
      title: (json['title'] as String?) ?? '(no title)',
      vulnerableVersions: (json['vulnerable_versions'] as String?) ?? '*',
      patchedVersions: json['patched_versions'] as String?,
      url: (json['url'] as String?) ?? '',
    );
  }
}

/// Ordered severity ladder. The values correspond to npm's vocabulary
/// and the ordering matches `pnpm audit --audit-level=<level>`.
enum AuditSeverity {
  info,
  low,
  moderate,
  high,
  critical;

  /// Map a registry-style severity string to an enum case. Unknown
  /// inputs fall through to [info] so a future severity npm adds
  /// doesn't crash the audit; surface the value in `--json` output
  /// for inspection.
  ///
  /// Written as an explicit switch (rather than `values.firstWhere`)
  /// so every case is statically reachable in the call graph — both
  /// readers and `dartrics unused` can see which enum members the
  /// dispatch produces.
  static AuditSeverity parse(String raw) => switch (raw) {
    'info' => info,
    'low' => low,
    'moderate' => moderate,
    'high' => high,
    'critical' => critical,
    _ => info,
  };

  bool atLeast(AuditSeverity other) => index >= other.index;
}
