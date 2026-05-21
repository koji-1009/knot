/// pnpm v11 `verifyDepsBeforeRun` (Phase I). Knot consults this
/// policy before `knot run` / `knot exec` to decide whether
/// node_modules + the lockfile are consistent enough to proceed.
enum VerifyDepsBeforeRunPolicy {
  /// Skip the verification entirely.
  off,

  /// Compute the hash; warn on mismatch but continue.
  warn,

  /// Compute the hash; abort on mismatch.
  error,

  /// Compute the hash; on mismatch run a fresh `knot install` first.
  install,

  /// Compute the hash; on mismatch ask the user (TTY only). Non-TTY
  /// invocations throw a UsageError-style hint so CI doesn't deadlock.
  prompt,
}

/// Parse `.npmrc` / `pnpm-workspace.yaml` value. pnpm's default per
/// the v11 docs is `install`; knot follows the same default (memory
/// "Run-time UX defaults").
VerifyDepsBeforeRunPolicy parseVerifyDepsBeforeRun(String? raw) {
  if (raw == null) return VerifyDepsBeforeRunPolicy.install;
  switch (raw.trim().toLowerCase()) {
    case '':
    case 'install':
      return VerifyDepsBeforeRunPolicy.install;
    case 'off':
    case 'false':
      return VerifyDepsBeforeRunPolicy.off;
    case 'warn':
      return VerifyDepsBeforeRunPolicy.warn;
    case 'error':
    case 'true':
      return VerifyDepsBeforeRunPolicy.error;
    case 'prompt':
      return VerifyDepsBeforeRunPolicy.prompt;
    default:
      throw FormatException('unknown verifyDepsBeforeRun: "$raw"');
  }
}

/// What a caller should do after evaluating the workspace state hash.
enum VerifyDepsAction {
  /// State is current — proceed with the requested command.
  proceed,

  /// State is missing or stale; user said `off` — proceed anyway.
  proceedNoState,

  /// State is stale; print warning and continue.
  warn,

  /// State is stale; abort.
  fail,

  /// State is stale; run install before continuing.
  install,

  /// State is stale; ask the user (TTY) before continuing.
  prompt,
}

/// Map the live policy + state comparison into a [VerifyDepsAction].
///
/// [stale] is `true` when there is no recorded hash, or the recorded
/// hash differs from the freshly computed one.
VerifyDepsAction decideVerifyAction({
  required VerifyDepsBeforeRunPolicy policy,
  required bool stale,
}) {
  if (!stale) return VerifyDepsAction.proceed;
  switch (policy) {
    case VerifyDepsBeforeRunPolicy.off:
      return VerifyDepsAction.proceedNoState;
    case VerifyDepsBeforeRunPolicy.warn:
      return VerifyDepsAction.warn;
    case VerifyDepsBeforeRunPolicy.error:
      return VerifyDepsAction.fail;
    case VerifyDepsBeforeRunPolicy.install:
      return VerifyDepsAction.install;
    case VerifyDepsBeforeRunPolicy.prompt:
      return VerifyDepsAction.prompt;
  }
}
