import 'package:knot/src/audit/audit.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/signature/signature.dart';

import '../install_operation.dart';

/// Parse `--allow-scripts=<all|allowlist|none>` into a [ScriptPolicy].
/// Returns [ScriptPolicy.allowlist] for null/unrecognized values so a
/// typo'd flag defaults to the safer policy rather than `all`.
ScriptPolicy parseScriptPolicy(String? raw) {
  switch (raw) {
    case 'all':
      return ScriptPolicy.all;
    case 'none':
      return ScriptPolicy.none;
    case null:
    case 'allowlist':
      return ScriptPolicy.allowlist;
    default:
      throw UsageError(
        'unknown --allow-scripts=$raw; expected one of '
        'all | allowlist | none',
      );
  }
}

/// Parse `--audit-level=<level>` for the install path. Returns null
/// when the flag is unset (or `none`), so the install path can skip
/// the audit round-trip entirely.
AuditSeverity? parseInstallAuditLevel(String? raw) {
  if (raw == null || raw == 'none') return null;
  return AuditSeverity.parse(raw);
}

/// Parse `--verify-signatures=<strict|weak|none>` into a
/// [SignaturePolicy]. Defaults to `none` (backwards-compat) for null
/// input; falls through to `none` for unrecognized values rather than
/// silently upgrading to strict.
SignaturePolicy parseSignaturePolicy(String? raw) {
  switch (raw) {
    case 'strict':
      return SignaturePolicy.strict;
    case 'weak':
      return SignaturePolicy.weak;
    case null:
    case 'none':
      return SignaturePolicy.none;
    default:
      throw UsageError(
        'unknown --verify-signatures=$raw; expected one of '
        'strict | weak | none',
      );
  }
}

/// Parse `--minimum-release-age=<duration>` (pnpm-compatible syntax):
/// `7d`, `48h`, `30m`. Returns null for an empty / null input so the
/// install path runs without a release-age filter.
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
  switch (match.group(2)!) {
    case 'd':
      return Duration(days: n);
    case 'h':
      return Duration(hours: n);
    case 'm':
      return Duration(minutes: n);
    case 's':
      return Duration(seconds: n);
  }
  return null;
}
