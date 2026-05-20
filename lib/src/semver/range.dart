import 'package:pub_semver/pub_semver.dart' as ps;

import 'parser.dart';
import 'version.dart';

/// An npm-flavored version range. Internally backed by [ps.VersionConstraint]
/// from `package:pub_semver`, but parsed with npm rules and aware of the
/// "include prereleases" flag.
class NpmRange {
  NpmRange._(this.raw, this._constraint, {required this.includePrereleases});

  /// The original input that produced this range.
  final String raw;

  final ps.VersionConstraint _constraint;

  /// `true` if any sub-range explicitly mentioned a prerelease, so
  /// prereleases on the matching side may satisfy this range.
  final bool includePrereleases;

  /// Parse [input] as an npm range. Throws [FormatException] on failure.
  factory NpmRange.parse(String input) => parseNpmRange(input);

  /// A range that matches every version (`*`).
  static final NpmRange any = NpmRange._(
    '*',
    ps.VersionConstraint.any,
    includePrereleases: false,
  );

  /// Whether [version] is contained in this range.
  bool satisfies(Version version) {
    if (version.isPreRelease && !includePrereleases) {
      // npm rule: a prerelease only matches if some comparator explicitly
      // references a prerelease on the same (major, minor, patch).
      return _matchesPrereleaseTuple(version) && _constraint.allows(version);
    }
    return _constraint.allows(version);
  }

  bool _matchesPrereleaseTuple(Version v) {
    // Inspect the underlying constraint for an explicit prerelease bound that
    // shares (major, minor, patch) with [v]. pub_semver does not expose this
    // directly so we string-match against the raw input as a pragmatic fallback.
    final tuple = '${v.major}.${v.minor}.${v.patch}-';
    return raw.contains(tuple);
  }

  /// Intersection — versions allowed by both `this` and [other].
  NpmRange intersect(NpmRange other) {
    final c = _constraint.intersect(other._constraint);
    return NpmRange._(
      '$raw && ${other.raw}',
      c,
      includePrereleases: includePrereleases || other.includePrereleases,
    );
  }

  /// Whether the range matches no versions.
  bool get isEmpty => _constraint.isEmpty;

  /// The underlying pub_semver constraint, for advanced callers.
  ps.VersionConstraint get underlying => _constraint;

  @override
  String toString() => raw;
}

/// Returns the highest version in [versions] that satisfies [range], or null.
Version? maxSatisfying(Iterable<Version> versions, NpmRange range) {
  Version? best;
  for (final v in versions) {
    if (range.satisfies(v)) {
      if (best == null || v > best) best = v;
    }
  }
  return best;
}

/// Internal constructor used by the parser to build a range from a constraint.
NpmRange rangeFromConstraint(
  String raw,
  ps.VersionConstraint c, {
  required bool includePrereleases,
}) => NpmRange._(raw, c, includePrereleases: includePrereleases);
