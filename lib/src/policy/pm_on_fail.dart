import '../cli/package_json.dart';
import '../semver/semver.dart';

/// How knot reacts when the running binary's version does not satisfy
/// the project's pinned package-manager requirement (pnpm v11 `pmOnFail`).
///
/// [download] (default in pnpm) covers self-update via the binary
/// cache. It needs the Phase Q-impl infrastructure and is therefore
/// only honored by Phase L-full; the L-basic implementation here
/// reports it as [PmOnFailAction.downloadDeferred] so the caller
/// downgrades gracefully (warn + continue) until L-full lands.
enum PmOnFailPolicy { download, error, warn, ignore }

/// Parse a textual policy value (from `.npmrc`, `package.json#knot`,
/// or `pnpm-workspace.yaml`). Falls back to [PmOnFailPolicy.download]
/// when the value is null or empty, mirroring pnpm's default.
PmOnFailPolicy parsePmOnFail(String? raw) {
  if (raw == null) return PmOnFailPolicy.download;
  switch (raw.trim().toLowerCase()) {
    case '':
    case 'download':
      return PmOnFailPolicy.download;
    case 'error':
      return PmOnFailPolicy.error;
    case 'warn':
      return PmOnFailPolicy.warn;
    case 'ignore':
      return PmOnFailPolicy.ignore;
    default:
      throw FormatException('unknown pmOnFail policy: "$raw"');
  }
}

/// Action a caller should take after evaluating the project's pin
/// against the running binary's version.
enum PmOnFailAction {
  /// Pin satisfied (or no pin) — continue normally.
  proceed,

  /// Pin missed; policy = `error`. Caller throws.
  fail,

  /// Pin missed; policy = `warn`. Caller logs a warning and continues.
  warn,

  /// Pin missed; policy = `ignore`. Caller continues silently.
  ignore,

  /// Pin missed; policy = `download` (the default), but L-full is
  /// not wired yet. Treat as warn for now — Phase L-full upgrades
  /// this to "fetch + exec the matching binary via Phase Q-impl".
  downloadDeferred,
}

/// Result of evaluating the package-manager pin. [satisfied] is true
/// only when the project asks for a manager named "knot" and the
/// running knot version falls inside its range; [action] is what the
/// caller should do otherwise.
///
/// A project pinned to a *different* manager (e.g. `pnpm@11.1.3`) is
/// surfaced via [foreignManager] — the caller may want to log a
/// dedicated warning since `pmOnFail` does not apply across managers.
class PmOnFailResult {
  const PmOnFailResult({
    required this.action,
    required this.satisfied,
    this.foreignManager,
    this.requiredRange,
  });

  final PmOnFailAction action;
  final bool satisfied;
  final String? foreignManager;
  final String? requiredRange;
}

/// Decide what to do given the project's pins, the running knot version,
/// and the active policy.
///
/// Precedence (highest first): explicit `onFail` on
/// [PackageJson.devEnginesPackageManager], the [policy] argument
/// (from config), then the built-in default.
PmOnFailResult evaluatePmOnFail({
  required PackageJson pkg,
  required String knotVersion,
  PmOnFailPolicy policy = PmOnFailPolicy.download,
}) {
  final pin = _resolveManagerPin(pkg);
  if (pin == null) {
    return const PmOnFailResult(
      action: PmOnFailAction.proceed,
      satisfied: true,
    );
  }
  if (pin.name != 'knot') {
    return PmOnFailResult(
      action: PmOnFailAction.warn,
      satisfied: false,
      foreignManager: pin.name,
      requiredRange: pin.version,
    );
  }

  final running = tryParseVersion(knotVersion);
  if (running == null) {
    return PmOnFailResult(
      action: _toAction(policy),
      satisfied: false,
      requiredRange: pin.version,
    );
  }

  bool satisfies;
  try {
    satisfies = NpmRange.parse(pin.version).satisfies(running);
  } on FormatException {
    // pnpm `packageManager` is `knot@<exact>`; if it's not a valid
    // range we treat it as exact-version comparison.
    satisfies = pin.version == knotVersion;
  }

  if (satisfies) {
    return PmOnFailResult(
      action: PmOnFailAction.proceed,
      satisfied: true,
      requiredRange: pin.version,
    );
  }

  final effective = pin.onFail != null ? parsePmOnFail(pin.onFail) : policy;
  return PmOnFailResult(
    action: _toAction(effective),
    satisfied: false,
    requiredRange: pin.version,
  );
}

PmOnFailAction _toAction(PmOnFailPolicy policy) => switch (policy) {
      PmOnFailPolicy.download => PmOnFailAction.downloadDeferred,
      PmOnFailPolicy.error => PmOnFailAction.fail,
      PmOnFailPolicy.warn => PmOnFailAction.warn,
      PmOnFailPolicy.ignore => PmOnFailAction.ignore,
    };

class _ManagerPin {
  const _ManagerPin({required this.name, required this.version, this.onFail});
  final String name;
  final String version;
  final String? onFail;
}

/// Prefer `devEngines.packageManager` (richer, range-friendly) over
/// the legacy `packageManager` string; return null when neither is set.
_ManagerPin? _resolveManagerPin(PackageJson pkg) {
  final dev = pkg.devEnginesPackageManager;
  if (dev != null) {
    return _ManagerPin(
      name: dev.name,
      version: dev.version,
      onFail: dev.onFail,
    );
  }
  final pm = pkg.packageManager;
  if (pm == null || pm.isEmpty) return null;
  final at = pm.indexOf('@');
  if (at <= 0) return null;
  final namePart = pm.substring(0, at);
  // Strip integrity suffix (`name@ver+sha224:hash`)
  var versionPart = pm.substring(at + 1);
  final plus = versionPart.indexOf('+');
  if (plus >= 0) versionPart = versionPart.substring(0, plus);
  return _ManagerPin(name: namePart, version: versionPart);
}
