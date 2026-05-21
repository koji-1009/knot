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

/// Parse `--minimum-release-age=<minutes>`. Matches pnpm's grammar
/// exactly: a non-negative integer interpreted as minutes. `0` and
/// empty input mean "no filter". Unit suffixes (`7d`, `48h`, etc.) are
/// rejected — pnpm does not accept them and accepting them would make
/// the same `pnpm-workspace.yaml` value behave differently under knot.
Duration? parseMinReleaseAge(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final n = int.tryParse(trimmed);
  if (n == null || n < 0) {
    throw UsageError(
      'invalid --minimum-release-age=$raw; '
      'expected a non-negative integer (minutes); see pnpm '
      'minimumReleaseAge — `1440` = 1 day, `10080` = 1 week',
    );
  }
  if (n == 0) return null;
  return Duration(minutes: n);
}
