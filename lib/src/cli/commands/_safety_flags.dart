import 'package:knot/src/audit/audit.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/signature/signature.dart';

import '../install_operation.dart';

/// Parse `--allow-scripts=<all|allowlist|none>` into a [ScriptPolicy].
/// Defaults to [ScriptPolicy.allowlist] for null input so an unspecified
/// flag picks the safer policy rather than `all`.
ScriptPolicy parseScriptPolicy(String? raw) => switch (raw) {
  'all' => .all,
  'none' => .none,
  null || 'allowlist' => .allowlist,
  _ => throw UsageError(
    'unknown --allow-scripts=$raw; expected one of all | allowlist | none',
  ),
};

/// Parse `--audit-level=<level>` for the install path. Returns null
/// when the flag is unset (or `none`), so the install path can skip
/// the audit round-trip entirely.
AuditSeverity? parseInstallAuditLevel(String? raw) {
  if (raw == null || raw == 'none') return null;
  return AuditSeverity.parse(raw);
}

/// Parse `--verify-signatures=<strict|weak|none>` into a
/// [SignaturePolicy]. Defaults to `none` (backwards-compat) for null
/// input; unrecognized values throw rather than silently upgrading.
SignaturePolicy parseSignaturePolicy(String? raw) => switch (raw) {
  'strict' => .strict,
  'weak' => .weak,
  null || 'none' => .none,
  _ => throw UsageError(
    'unknown --verify-signatures=$raw; expected one of strict | weak | none',
  ),
};

/// Parse `--minimum-release-age=<duration>` (pnpm-compatible syntax):
/// `7d`, `48h`, `30m`, `60s`. Returns null for an empty / null input
/// so the install path runs without a release-age filter.
///
/// Allowing only one unit per value keeps the parser unambiguous —
/// compose with the OS shell if a finer grain is needed.
Duration? parseMinReleaseAge(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^(\d+)\s*([dhms])$').firstMatch(trimmed);
  if (match == null) {
    throw UsageError(
      'invalid --minimum-release-age=$raw; '
      'expected e.g. "7d", "48h", "30m", "60s"',
    );
  }
  final n = int.parse(match.group(1)!);
  return switch (match.group(2)!) {
    'd' => Duration(days: n),
    'h' => Duration(hours: n),
    'm' => Duration(minutes: n),
    's' => Duration(seconds: n),
    _ => throw StateError('unreachable: regex guarantees one of d/h/m/s'),
  };
}
