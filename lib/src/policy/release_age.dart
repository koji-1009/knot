/// Settings governing the minimum-release-age filter (pnpm v11 Phase B).
///
/// Four independent axes from the v11.1.x docs:
///
/// - [minimum]: how old a release must be before it counts as
///   installable. `null` disables the filter entirely.
/// - [strict]: when true, "too-new" versions are excluded outright —
///   the resolver fails if no mature version satisfies the range. When
///   false, the resolver falls back to the lowest immature candidate
///   so installs do not stall behind a freshly-published package.
/// - [ignoreMissingTime]: when true, versions with no `time` entry
///   (some legacy / mirrored registries) are allowed through. When
///   false, missing-time is treated as "too new to verify".
/// - [excludePatterns]: a list of `package` / `@scope/package` /
///   `@scope/*` patterns whose releases bypass the age check entirely.
class MinReleaseAgePolicy {
  const MinReleaseAgePolicy({
    this.minimum,
    this.strict = false,
    this.ignoreMissingTime = true,
    this.excludePatterns = const [],
  });

  final Duration? minimum;
  final bool strict;
  final bool ignoreMissingTime;
  final List<String> excludePatterns;

  bool get enabled => minimum != null;

  /// pnpm v11's published default: a 24h waiting period on every
  /// release. Defaults stay non-strict so users can still bootstrap
  /// fresh projects; users who opt in explicitly tighten with
  /// `minimumReleaseAgeStrict`.
  static const MinReleaseAgePolicy v11Default = MinReleaseAgePolicy(
    minimum: Duration(hours: 24),
  );

  /// Whether [packageName] is excluded from the age check by
  /// [excludePatterns]. Patterns support `*` only as a scope-tail
  /// wildcard (`@scope/*` matches every package in `@scope`).
  bool isExcluded(String packageName) {
    for (final pattern in excludePatterns) {
      if (_matches(pattern, packageName)) return true;
    }
    return false;
  }

  bool _matches(String pattern, String name) {
    if (pattern == name) return true;
    if (pattern.endsWith('/*')) {
      final prefix = pattern.substring(
        0,
        pattern.length - 1,
      ); // keeps trailing /
      return name.startsWith(prefix);
    }
    return false;
  }
}

/// Per-version verdict from [evaluateReleaseAge]. Tracks both whether
/// the version passes the filter and *why* a version was held back so
/// the resolver can compute strict-vs-fallback semantics.
enum ReleaseAgeVerdict {
  /// Version is older than the cutoff (or missing-time + ignore-missing).
  mature,

  /// Version is younger than the cutoff.
  immature,

  /// Version has no time data and `ignoreMissingTime` is false.
  unknownTime,
}

/// Decide the [ReleaseAgeVerdict] for one version.
///
/// [publishedAt] is the `time[<version>]` value from the packument
/// (null if absent). [cutoff] is `now - policy.minimum`, computed once
/// by the caller and reused across every version in a loop — the
/// value is loop-invariant for one resolve.
///
/// Callers must gate on `policy.enabled` themselves; this function
/// assumes the filter is active.
ReleaseAgeVerdict evaluateReleaseAge({
  required DateTime cutoff,
  required DateTime? publishedAt,
  required bool ignoreMissingTime,
}) {
  if (publishedAt == null) {
    return ignoreMissingTime
        ? ReleaseAgeVerdict.mature
        : ReleaseAgeVerdict.unknownTime;
  }
  if (publishedAt.isBefore(cutoff)) return ReleaseAgeVerdict.mature;
  return ReleaseAgeVerdict.immature;
}
