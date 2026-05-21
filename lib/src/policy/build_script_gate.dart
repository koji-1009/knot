/// Phase C/E of the v11 alignment plan — the gate that decides
/// whether a package's install-time build scripts may run.
///
/// Two settings cooperate:
/// - `allowBuilds`: pattern list that opts packages into running
///   build scripts (Phase C). Patterns are exact names, `@scope/*`,
///   or trailing `*` globs.
/// - `strictDepBuilds`: when true, an *unreviewed* package whose
///   install would trigger a build is refused outright (Phase E)
///   instead of silently skipped. Triggers are the union of:
///     1. `scripts.preinstall` / `install` / `postinstall` present
///     2. `binding.gyp` file at the package root
///     3. A `.hooks/<X>` script directory at the package root
///   `prepare` is intentionally excluded — it is a development /
///   workspace script, not an install-time build trigger.
/// - `dangerouslyAllowAllBuilds`: opts every package in — overrides
///   both `allowBuilds` and `strictDepBuilds`.
library;

/// One step of the build-script gate. Callers translate this into
/// either silent execution, a skip-with-warning, or a hard failure.
enum BuildScriptDecision {
  /// Package opted in via [BuildScriptPolicy.allowBuilds] or the
  /// dangerous-allow-all override; build scripts may run.
  allow,

  /// Package has no install-time triggers; nothing to gate.
  noTrigger,

  /// Package has triggers but is not on the allow list and
  /// `strictDepBuilds` is off → skip with a warning (legacy pnpm
  /// behavior).
  skip,

  /// Package has triggers, is not on the allow list, and
  /// `strictDepBuilds` is on → install must fail.
  fail,
}

/// The signal flags a single package carries into the gate.
class BuildScriptTriggers {
  const BuildScriptTriggers({
    this.hasPreinstall = false,
    this.hasInstall = false,
    this.hasPostinstall = false,
    this.hasBindingGyp = false,
    this.hasHooksDir = false,
  });

  final bool hasPreinstall;
  final bool hasInstall;
  final bool hasPostinstall;
  final bool hasBindingGyp;
  final bool hasHooksDir;

  /// True when any install-time trigger is present (the union called
  /// out in Phase E). `prepare` is intentionally absent.
  bool get any =>
      hasPreinstall ||
      hasInstall ||
      hasPostinstall ||
      hasBindingGyp ||
      hasHooksDir;

  /// Derive triggers from a `scripts` map (lifecycle key → command).
  /// Caller layers the on-disk checks (`binding.gyp`, `.hooks/`)
  /// separately because they require filesystem I/O.
  factory BuildScriptTriggers.fromScripts(
    Map<String, String> scripts, {
    bool hasBindingGyp = false,
    bool hasHooksDir = false,
  }) => BuildScriptTriggers(
    hasPreinstall: scripts['preinstall']?.isNotEmpty ?? false,
    hasInstall: scripts['install']?.isNotEmpty ?? false,
    hasPostinstall: scripts['postinstall']?.isNotEmpty ?? false,
    hasBindingGyp: hasBindingGyp,
    hasHooksDir: hasHooksDir,
  );
}

/// Policy configuration the gate evaluates against. Sourced from
/// `package.json#knot.allowBuilds` (npm/knot mode) or
/// `pnpm-workspace.yaml#allowBuilds` (pnpm mode) plus the
/// strictDepBuilds / dangerouslyAllowAllBuilds toggles.
class BuildScriptPolicy {
  const BuildScriptPolicy({
    this.allowBuilds = const [],
    this.strictDepBuilds = false,
    this.dangerouslyAllowAllBuilds = false,
  });

  final List<String> allowBuilds;
  final bool strictDepBuilds;
  final bool dangerouslyAllowAllBuilds;

  /// pnpm v11 default: strictDepBuilds is on for safety (memory
  /// "Security defaults" entry).
  static const BuildScriptPolicy v11Default = BuildScriptPolicy(
    strictDepBuilds: true,
  );

  BuildScriptDecision evaluate(
    String packageName,
    BuildScriptTriggers triggers,
  ) {
    if (dangerouslyAllowAllBuilds) return BuildScriptDecision.allow;
    if (!triggers.any) return BuildScriptDecision.noTrigger;
    if (matchesAllowPattern(packageName, allowBuilds)) {
      return BuildScriptDecision.allow;
    }
    return strictDepBuilds
        ? BuildScriptDecision.fail
        : BuildScriptDecision.skip;
  }
}

/// Match [packageName] against any pattern in [patterns]. Supports:
/// - exact match (`react`, `@types/node`)
/// - trailing `*` glob (`react*`, `@types/n*`)
/// - scope wildcard (`@types/*` = every package in `@types`)
bool matchesAllowPattern(String packageName, Iterable<String> patterns) {
  for (final pattern in patterns) {
    if (_matches(pattern, packageName)) return true;
  }
  return false;
}

bool _matches(String pattern, String name) {
  if (pattern == name) return true;
  if (pattern.endsWith('/*')) {
    final prefix = pattern.substring(0, pattern.length - 1);
    return name.startsWith(prefix);
  }
  if (pattern.endsWith('*')) {
    final prefix = pattern.substring(0, pattern.length - 1);
    return name.startsWith(prefix);
  }
  return false;
}
