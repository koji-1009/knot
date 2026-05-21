import 'dart:io';

import '../npmrc/npmrc.dart';
import 'mode.dart';

/// Resolved project-level config, mode-aware. The merged view abstracts
/// over the underlying file shape (`.npmrc` + `package.json#knot` vs
/// `pnpm-workspace.yaml` + auth-only `.npmrc`) so callers can ask for
/// config without knowing which mode the project is in.
class ProjectConfig {
  ProjectConfig({
    required this.mode,
    required this.projectRoot,
    required this.npmrc,
  });

  final ProjectMode mode;
  final String projectRoot;

  /// In `npm`/`knot` mode, this carries the project's full `.npmrc`
  /// (policy + auth). In `pnpm` mode, only auth keys survive — policy
  /// in `.npmrc` is ignored because pnpm-mode's policy lives in
  /// `pnpm-workspace.yaml`.
  final NpmrcConfig npmrc;
}

/// Load the project config for [projectRoot]. Detects the mode, then
/// loads `.npmrc` (filtered for auth-only in pnpm-mode).
///
/// Full pnpm-workspace.yaml / package.json#knot policy merging is
/// layered in by Phase A (lockfile) / Phase N (registry/auth). Phase 0
/// establishes the structure: mode is detected once, callers reach
/// for config through this entry.
Future<ProjectConfig> loadProjectConfig({
  String? projectRoot,
  String? homeDir,
  Map<String, String>? environment,
}) async {
  final root = projectRoot ?? Directory.current.path;
  final mode = detectProjectMode(root);
  final loader = NpmrcLoader(
    projectDir: root,
    homeDir: homeDir,
    env: environment,
  );
  final full = await loader.load();
  final scopedNpmrc = mode == ProjectMode.pnpm
      ? NpmrcConfig(_keepAuthOnly(full.raw))
      : full;
  return ProjectConfig(mode: mode, projectRoot: root, npmrc: scopedNpmrc);
}

Map<String, String> _keepAuthOnly(Map<String, String> entries) {
  final out = <String, String>{};
  for (final entry in entries.entries) {
    final key = entry.key;
    if (_isAuthKey(key)) {
      out[key] = entry.value;
    }
  }
  return out;
}

bool _isAuthKey(String key) {
  if (key == '_auth' || key == 'email') return true;
  if (key.contains(':_authtoken')) return true;
  if (key.contains(':_password')) return true;
  if (key.contains(':username')) return true;
  if (key.contains(':_auth')) return true;
  if (key == 'always-auth') return true;
  return false;
}
