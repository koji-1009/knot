import 'package:pub_semver/pub_semver.dart' as ps;

import 'range.dart';
import 'version.dart';

/// Parse [input] as an npm range. Empty string and `*` mean any version.
///
/// Supports: exact (`1.2.3`), `=`, comparators (`>=`, `<=`, `>`, `<`),
/// caret (`^`), tilde (`~`), x-ranges (`1.x`, `1.2.*`), hyphen
/// ranges (`1.2.3 - 2.3.4`), and `||` disjunction.
NpmRange parseNpmRange(String input) {
  final raw = _normalizeOperatorSpaces(input.trim());
  if (raw.isEmpty ||
      raw == '*' ||
      raw == 'x' ||
      raw == 'X' ||
      raw == 'latest') {
    return NpmRange.any;
  }

  final clauses = _splitOr(raw);
  if (clauses.isEmpty) {
    return NpmRange.any;
  }
  final parsed = clauses.map(_parseClause).toList();

  final union = ps.VersionConstraint.unionOf([for (final p in parsed) p.$1]);
  final includesPre = parsed.any((p) => p.$2);

  return rangeFromConstraint(raw, union, includePrereleases: includesPre);
}

/// Collapse whitespace between an operator (`>=`, `<=`, `>`, `<`, `=`, `~`,
/// `~>`, `^`) and its operand. `>=  1.0.0` → `>=1.0.0`.
String _normalizeOperatorSpaces(String input) {
  return input.replaceAllMapped(
    RegExp(r'(>=|<=|~>|[><=~^])\s+'),
    (m) => m.group(1)!,
  );
}

List<String> _splitOr(String s) {
  final parts = <String>[];
  var depth = 0;
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (depth == 0 && i + 1 < s.length && ch == '|' && s[i + 1] == '|') {
      parts.add(buf.toString());
      buf.clear();
      i++;
      continue;
    }
    buf.write(ch);
  }
  parts.add(buf.toString());
  return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
}

/// Returns (constraint, mentionsPrerelease) for a single AND-clause.
(ps.VersionConstraint, bool) _parseClause(String clause) {
  final trimmed = clause.trim();
  if (trimmed.isEmpty) return (ps.VersionConstraint.any, false);

  // Hyphen range: "<lower> - <upper>"
  final hyphen = _matchHyphen(trimmed);
  if (hyphen != null) {
    final (lower, upper) = hyphen;
    final l = _partial(lower);
    final u = _partial(upper);
    final lo = l.toLowerBound();
    final hi = u.toHyphenUpperBound();
    final mentionsPre = l.hasPrerelease || u.hasPrerelease;
    return (
      _and(_ge(lo), hi.$1 == _BoundOp.lt ? _lt(hi.$2) : _le(hi.$2)),
      mentionsPre,
    );
  }

  // Otherwise: whitespace-separated comparators ANDed together.
  final tokens = _tokenize(trimmed);
  ps.VersionConstraint acc = ps.VersionConstraint.any;
  var mentionsPre = false;

  for (final t in tokens) {
    final (c, pre) = _parseComparator(t);
    acc = acc.intersect(c);
    mentionsPre = mentionsPre || pre;
  }
  return (acc, mentionsPre);
}

(String, String)? _matchHyphen(String input) {
  // Find " - " (with surrounding spaces) at top level.
  final idx = input.indexOf(' - ');
  if (idx < 0) return null;
  final lower = input.substring(0, idx).trim();
  final upper = input.substring(idx + 3).trim();
  if (lower.isEmpty || upper.isEmpty) return null;
  return (lower, upper);
}

List<String> _tokenize(String s) =>
    s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

(ps.VersionConstraint, bool) _parseComparator(String tok) {
  // Operator prefixes, longest first.
  if (tok.startsWith('>=')) {
    final v = _partial(tok.substring(2));
    if (v.isXRange) {
      // >=1.x → >=1.0.0; >=x → any.
      final xb = v.toXRangeBounds();
      if (xb == null) return (ps.VersionConstraint.any, false);
      return (_ge(xb.$1), v.hasPrerelease);
    }
    return (_ge(v.toLowerBound()), v.hasPrerelease);
  }
  if (tok.startsWith('<=')) {
    final v = _partial(tok.substring(2));
    if (v.isXRange) {
      // <=1.2.x → <1.3.0; <=x → any.
      final xb = v.toXRangeBounds();
      if (xb == null) return (ps.VersionConstraint.any, false);
      return (_lt(xb.$2), v.hasPrerelease);
    }
    return (_le(v.toLowerBound()), v.hasPrerelease);
  }
  if (tok.startsWith('>')) {
    final v = _partial(tok.substring(1));
    if (v.isXRange) {
      // >1.x → >=2.0.0; >x → never.
      if (v.major == null) {
        return (ps.VersionConstraint.empty, false);
      }
      final xb = v.toXRangeBounds()!;
      return (_ge(xb.$2), v.hasPrerelease);
    }
    return (_gt(v.toLowerBound()), v.hasPrerelease);
  }
  if (tok.startsWith('<')) {
    final v = _partial(tok.substring(1));
    if (v.isXRange) {
      // <1.x → <1.0.0; <x → never (consistent with `<=x` being any).
      if (v.major == null) {
        return (ps.VersionConstraint.empty, false);
      }
      final xb = v.toXRangeBounds()!;
      return (_lt(xb.$1), v.hasPrerelease);
    }
    return (_lt(v.toLowerBound()), v.hasPrerelease);
  }
  if (tok.startsWith('^')) {
    final body = tok.substring(1);
    final v = _partial(body);
    if (v.major == null) {
      // `^x` / `^*` → any version.
      return (ps.VersionConstraint.any, false);
    }
    final bounds = v.toCaretBounds();
    return (_and(_ge(bounds.$1), _lt(bounds.$2)), v.hasPrerelease);
  }
  if (tok.startsWith('~')) {
    // ~> is treated like ~ (some legacy registries emit it).
    final body = tok.startsWith('~>') ? tok.substring(2) : tok.substring(1);
    final v = _partial(body);
    if (v.major == null) {
      return (ps.VersionConstraint.any, false);
    }
    final bounds = v.toTildeBounds();
    return (_and(_ge(bounds.$1), _lt(bounds.$2)), v.hasPrerelease);
  }
  if (tok.startsWith('=')) {
    final v = _partial(tok.substring(1));
    return _exactOrXRange(v);
  }
  if (tok == '*' || tok == 'x' || tok == 'X' || tok.isEmpty) {
    return (ps.VersionConstraint.any, false);
  }
  final v = _partial(tok);
  return _exactOrXRange(v);
}

(ps.VersionConstraint, bool) _exactOrXRange(_Partial v) {
  if (v.isXRange) {
    final bounds = v.toXRangeBounds();
    if (bounds == null) return (ps.VersionConstraint.any, false);
    return (_and(_ge(bounds.$1), _lt(bounds.$2)), false);
  }
  return (v.toExact(), v.hasPrerelease);
}

// --- bound helpers ---------------------------------------------------------

ps.VersionConstraint _ge(Version v) =>
    ps.VersionRange(min: v, includeMin: true);

ps.VersionConstraint _gt(Version v) =>
    ps.VersionRange(min: v, includeMin: false);

ps.VersionConstraint _le(Version v) =>
    ps.VersionRange(max: v, includeMax: true);

ps.VersionConstraint _lt(Version v) =>
    ps.VersionRange(max: v, includeMax: false);

ps.VersionConstraint _and(ps.VersionConstraint a, ps.VersionConstraint b) =>
    a.intersect(b);

enum _BoundOp { lt, le }

// --- partial-version model -------------------------------------------------

class _Partial {
  _Partial(this.major, this.minor, this.patch, this.preRelease);

  final int? major;
  final int? minor;
  final int? patch;
  final String? preRelease;

  bool get hasPrerelease => preRelease != null && preRelease!.isNotEmpty;
  bool get isXRange => major == null || minor == null || patch == null;

  /// Returns the version with missing components filled with zero.
  ///
  /// Build metadata is intentionally dropped — per SemVer 2.0 §10 it must
  /// not affect precedence, and including it makes equality comparisons
  /// inside the range fail to match a tarball-version without `+build`.
  Version toLowerBound() =>
      ps.Version(major ?? 0, minor ?? 0, patch ?? 0, pre: preRelease);

  Version toExact() =>
      ps.Version(major ?? 0, minor ?? 0, patch ?? 0, pre: preRelease);

  /// `^a.b.c` semantics:
  ///   ^1.2.3  → >=1.2.3 <2.0.0
  ///   ^0.2.3  → >=0.2.3 <0.3.0
  ///   ^0.0.3  → >=0.0.3 <0.0.4
  ///   ^1.2.x  → >=1.2.0 <2.0.0
  ///   ^0.x    → >=0.0.0 <1.0.0
  (Version, Version) toCaretBounds() {
    final lo = toLowerBound();
    if (major == null || major == 0 && minor == null) {
      return (lo, ps.Version((major ?? 0) + 1, 0, 0));
    }
    if (major != 0) {
      return (lo, ps.Version(major! + 1, 0, 0));
    }
    if (minor != 0 || patch == null) {
      return (lo, ps.Version(0, (minor ?? 0) + 1, 0));
    }
    return (lo, ps.Version(0, minor!, patch! + 1));
  }

  /// `~a.b.c` semantics:
  ///   ~1.2.3 → >=1.2.3 <1.3.0
  ///   ~1.2   → >=1.2.0 <1.3.0
  ///   ~1     → >=1.0.0 <2.0.0
  (Version, Version) toTildeBounds() {
    final lo = toLowerBound();
    if (minor != null) {
      return (lo, ps.Version(major ?? 0, minor! + 1, 0));
    }
    return (lo, ps.Version((major ?? 0) + 1, 0, 0));
  }

  /// X-range bounds for partial versions like `1`, `1.2`, `1.x`, `1.2.x`.
  (Version, Version)? toXRangeBounds() {
    if (major == null) return null;
    if (minor == null) {
      return (ps.Version(major!, 0, 0), ps.Version(major! + 1, 0, 0));
    }
    if (patch == null) {
      return (ps.Version(major!, minor!, 0), ps.Version(major!, minor! + 1, 0));
    }
    return (
      ps.Version(major!, minor!, patch!),
      ps.Version(major!, minor!, patch! + 1),
    );
  }
}

extension on (_BoundOp, Version) {}

_Partial _partial(String input) {
  var s = input.trim();
  // Strip leading "v" or "=".
  while (s.isNotEmpty && (s[0] == 'v' || s[0] == 'V' || s[0] == '=')) {
    s = s.substring(1).trim();
  }
  if (s.isEmpty) return _Partial(null, null, null, null);

  // Split off build metadata — discarded. SemVer 2.0 §10 says build
  // metadata is not part of precedence, and `toLowerBound` already
  // throws it away, so we don't bother carrying it on `_Partial`.
  final plus = s.indexOf('+');
  if (plus >= 0) {
    s = s.substring(0, plus);
  }

  // Split off prerelease.
  String? pre;
  final dash = s.indexOf('-');
  if (dash >= 0) {
    pre = s.substring(dash + 1);
    s = s.substring(0, dash);
  }

  final parts = s.split('.');
  int? parsePart(int i) {
    if (i >= parts.length) return null;
    final p = parts[i];
    if (p.isEmpty || p == 'x' || p == 'X' || p == '*') return null;
    final v = int.tryParse(p);
    if (v == null) {
      throw FormatException('invalid version component "$p" in "$input"');
    }
    return v;
  }

  return _Partial(parsePart(0), parsePart(1), parsePart(2), pre);
}

// Helpers used by hyphen range upper bound.
extension on _Partial {
  /// Upper bound for the right-hand side of a hyphen range.
  ///   1.2.3 - 2.3.4 → upper is "<=2.3.4"
  ///   1.2.3 - 2.3   → upper is "<2.4.0"
  ///   1.2.3 - 2     → upper is "<3.0.0"
  (_BoundOp, Version) toHyphenUpperBound() {
    if (major == null) {
      return (_BoundOp.lt, ps.Version(1 << 30, 0, 0));
    }
    if (minor == null) {
      return (_BoundOp.lt, ps.Version(major! + 1, 0, 0));
    }
    if (patch == null) {
      return (_BoundOp.lt, ps.Version(major!, minor! + 1, 0));
    }
    return (_BoundOp.le, ps.Version(major!, minor!, patch!, pre: preRelease));
  }
}
