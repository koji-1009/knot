import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/core.dart';
import '../npmrc/npmrc.dart';

/// Project mode determines which config sources and lockfile format
/// knot uses.
///
/// Detection is purely file-based — see `detectProjectMode` for the rules,
/// and the project memory `knot_config_principle.md` for the rationale.
enum ProjectMode {
  /// Project carries pnpm artifacts (`pnpm-workspace.yaml` or
  /// `pnpm-lock.yaml`). knot stays transparently pnpm-compatible:
  /// reads/writes `pnpm-lock.yaml`, reads `pnpm-workspace.yaml`, treats
  /// `.npmrc` as auth-only.
  pnpm,

  /// Project carries npm artifacts (`package-lock.json` or a non-auth
  /// `.npmrc`) and no pnpm artifacts. Canonical at-rest for non-pnpm
  /// projects: full policy in `.npmrc`, project config under
  /// `package.json#knot`, lockfile is `package-lock.json`.
  npm,

  /// Fresh project (no pnpm and no npm artifacts). Same on-disk
  /// behavior as [npm] — knot does not introduce a new file format.
  knot,
}

/// Detect the project mode for [projectRoot] from on-disk file presence.
///
/// Detection order (first match wins):
/// 1. `pnpm-workspace.yaml` OR `pnpm-lock.yaml` present → [ProjectMode.pnpm].
///    (Dual presence of npm files alongside pnpm files is still pnpm-mode.)
/// 2. `package-lock.json` present OR `.npmrc` exists with any non-auth
///    entry → [ProjectMode.npm].
/// 3. Otherwise → [ProjectMode.knot].
///
/// "Non-auth" means anything other than credential keys (`_auth`,
/// `_authToken`, `_password`, `username`, `email`) — a project that
/// only stashes credentials in `.npmrc` is treated like a fresh project
/// for mode purposes, since it has not opted into policy config there.
ProjectMode detectProjectMode(String projectRoot) {
  if (_fileExists(projectRoot, 'pnpm-workspace.yaml') ||
      _fileExists(projectRoot, 'pnpm-lock.yaml')) {
    return ProjectMode.pnpm;
  }
  if (_fileExists(projectRoot, 'package-lock.json') ||
      _hasNonAuthNpmrc(projectRoot)) {
    return ProjectMode.npm;
  }
  return ProjectMode.knot;
}

/// Resolve the in-flight registry request budget for [mode], honoring the
/// active package manager's native config key and falling back to
/// [defaultHttpConcurrency].
///
/// Mode fidelity (see the principle in `doc/spec.md` and the
/// [ProjectMode] doc): where npm and pnpm expose the same knob under
/// different names, knot reads the one the active mode's tool reads —
/// `network-concurrency` in pnpm mode, npm's `maxsockets` in npm/knot
/// mode. A non-positive value is treated as unset (npm and pnpm both
/// reject `<= 0` here), so it falls back to the default.
int resolveNetworkConcurrency(NpmrcConfig config, ProjectMode mode) {
  final key = mode == ProjectMode.pnpm ? 'network-concurrency' : 'maxsockets';
  final value = config.integer(key, fallback: defaultHttpConcurrency);
  return value >= 1 ? value : defaultHttpConcurrency;
}

bool _fileExists(String root, String name) =>
    File(p.join(root, name)).existsSync();

bool _hasNonAuthNpmrc(String root) {
  final file = File(p.join(root, '.npmrc'));
  if (!file.existsSync()) return false;
  final lines = file.readAsLinesSync();
  for (final raw in lines) {
    final stripped = _stripCommentAndTrim(raw);
    if (stripped.isEmpty) continue;
    final eq = stripped.indexOf('=');
    if (eq < 0) continue;
    final key = stripped.substring(0, eq).trim().toLowerCase();
    if (_isAuthKey(key)) continue;
    return true;
  }
  return false;
}

String _stripCommentAndTrim(String line) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == "'" && !inDouble) inSingle = !inSingle;
    if (ch == '"' && !inSingle) inDouble = !inDouble;
    if (!inSingle && !inDouble && (ch == '#' || ch == ';')) {
      return line.substring(0, i).trim();
    }
  }
  return line.trim();
}

bool _isAuthKey(String key) {
  if (key == '_auth' || key == 'email') return true;
  if (key.contains(':_authtoken')) return true;
  if (key.contains(':_password')) return true;
  if (key.contains(':username')) return true;
  if (key.contains(':_auth')) return true;
  return false;
}
