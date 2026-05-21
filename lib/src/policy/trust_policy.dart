import '../semver/semver.dart';

/// pnpm v11 `trustPolicy` axis. Defends against supply-chain attacks
/// in which a malicious publish republishes a lower version inside a
/// previously-installed range, causing some installs to silently
/// regress.
///
/// - [off]: no check; classic npm/pnpm pre-v11 behavior.
/// - [noDowngrade]: refuse to resolve to a version lower than the
///   highest version the project has seen for that package within the
///   trust window.
enum TrustPolicy { off, noDowngrade }

/// Parse a `.npmrc` / `pnpm-workspace.yaml` value into a [TrustPolicy].
/// Defaults to [TrustPolicy.off] for null / empty input.
TrustPolicy parseTrustPolicy(String? raw) {
  if (raw == null) return TrustPolicy.off;
  switch (raw.trim().toLowerCase()) {
    case '':
    case 'off':
      return TrustPolicy.off;
    case 'no-downgrade':
    case 'nodowngrade':
      return TrustPolicy.noDowngrade;
    default:
      throw FormatException('unknown trustPolicy: "$raw"');
  }
}

/// One package's previously-seen highest version + a timestamp the
/// project last observed it. Persisted alongside the lockfile so
/// [TrustPolicy.noDowngrade] can consult historical state.
class TrustRecord {
  const TrustRecord({required this.version, required this.seenAt});

  final Version version;
  final DateTime seenAt;
}

/// Result of evaluating a candidate resolution under [TrustPolicy.noDowngrade].
enum TrustDecision {
  /// Policy is off, no record exists, or the record expired — accept.
  accept,

  /// Candidate is equal to or higher than the recorded version —
  /// accept and refresh the record.
  acceptAndRefresh,

  /// Candidate is lower than the recorded version and the record is
  /// still inside the trust window — refuse.
  downgrade,
}

/// Decide whether [candidate] is allowed given the project's
/// [previous] record. [ignoreAfter] is the configured trust window
/// (`trustPolicyIgnoreAfter`, in minutes); pass null to keep records
/// forever.
TrustDecision evaluateTrust({
  required TrustPolicy policy,
  required Version candidate,
  required DateTime now,
  TrustRecord? previous,
  Duration? ignoreAfter,
}) {
  if (policy == TrustPolicy.off || previous == null) {
    return TrustDecision.accept;
  }
  if (ignoreAfter != null && now.difference(previous.seenAt) > ignoreAfter) {
    return TrustDecision.accept;
  }
  if (candidate >= previous.version) return TrustDecision.acceptAndRefresh;
  return TrustDecision.downgrade;
}
