import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../cli/package_json.dart';
import '../core/core.dart';

/// pnpm v11 workspace state file (Phase I/J).
///
/// Persisted at `node_modules/.knot/workspace-state.json` once a
/// successful install completes. Subsequent commands (notably
/// `knot run` / `knot exec` with `verifyDepsBeforeRun`, and warm
/// re-installs with `optimisticRepeatInstall`) compute the same hash
/// and skip work when it matches.
///
/// Hash inputs (sorted before canonical JSON encoding):
/// - declared deps (`dependencies` / `devDependencies` / `optional`)
/// - lockfile path + sha256 of its bytes
/// - engine key: `<platform>;<arch>;node<major>`
///   - `<major>` is the project's pinned major when
///     `devEngines.runtime` carries one, else the running host Node's
///     major. This mirrors pnpm v11.1.3's pinning behavior so the
///     warm-skip decision survives transient Node version skew.
class WorkspaceState {
  WorkspaceState({
    required this.hash,
    required this.engineKey,
    required this.installedAt,
    required this.knotVersion,
  });

  /// SHA-256 hex of the canonical hash inputs.
  final String hash;
  final String engineKey;
  final DateTime installedAt;
  final String knotVersion;

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'hash': hash,
        'engineKey': engineKey,
        'installedAt': installedAt.toUtc().toIso8601String(),
        'knotVersion': knotVersion,
      };

  static WorkspaceState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final hash = raw['hash'];
    final engineKey = raw['engineKey'];
    final installedAt = raw['installedAt'];
    final knotVersion = raw['knotVersion'];
    if (hash is! String ||
        engineKey is! String ||
        installedAt is! String ||
        knotVersion is! String) {
      return null;
    }
    final ts = DateTime.tryParse(installedAt);
    if (ts == null) return null;
    return WorkspaceState(
      hash: hash,
      engineKey: engineKey,
      installedAt: ts,
      knotVersion: knotVersion,
    );
  }
}

/// Compute the engine key for the workspace state hash.
///
/// `nodeMajor` overrides the running host's Node major — pass the
/// `devEngines.runtime` pinned major when present so the install
/// environment vs script-runner Node version drift cannot invalidate
/// the cache spuriously.
///
/// When `nodeMajor` is null and no `KNOT_HOST_NODE_MAJOR` env override
/// is set, the engine portion falls back to `node?`. We deliberately
/// do **not** spawn `node --version` from this hot path — calling it
/// inside `compute_workspace_hash` would add ~45 ms to every install
/// (warm or cold) on macOS, which dwarfs the rest of the warm-install
/// budget. Callers that need a precise Node major (Phase I's pinned
/// case) should pass [nodeMajor] explicitly.
String workspaceEngineKey({
  String? platform,
  String? arch,
  int? nodeMajor,
}) {
  final platformPart = platform ?? Platform.operatingSystem;
  final archPart = arch ?? _hostArch();
  final overrideMajor = _envNodeMajor();
  final majorPart = nodeMajor ?? overrideMajor;
  return '$platformPart;$archPart;node${majorPart ?? '?'}';
}

int? _envNodeMajor() {
  final raw = Platform.environment['KNOT_HOST_NODE_MAJOR'];
  if (raw == null || raw.isEmpty) return null;
  return int.tryParse(raw);
}

/// Compute the workspace-state hash for the project rooted at
/// [projectRoot]. The lockfile portion uses [lockfilePath] (sha256 of
/// its bytes when present, "absent" sentinel otherwise) so a
/// hand-edited lockfile invalidates the cache the next time.
///
/// [lockfileFingerprint] lets the install path skip the second read of
/// the lockfile: pass the precomputed `sha256:<hex>` (or `'absent'`)
/// directly. When both are null, the function treats the lockfile as
/// absent.
Future<String> computeWorkspaceHash({
  required String projectRoot,
  required PackageJson pkg,
  String? lockfilePath,
  String? lockfileFingerprint,
  String? engineKey,
}) async {
  final fingerprint =
      lockfileFingerprint ?? await _lockfileFingerprint(lockfilePath);
  final inputs = <String, Object?>{
    'dependencies': _sortedMap(pkg.dependencies),
    'devDependencies': _sortedMap(pkg.devDependencies),
    'optionalDependencies': _sortedMap(pkg.optionalDependencies),
    'peerDependencies': _sortedMap(pkg.peerDependencies),
    'lockfile': fingerprint,
    'engineKey': engineKey ?? workspaceEngineKey(),
  };
  final canonical = jsonEncode(inputs);
  return KnotHash.sha256Hex(Uint8List.fromList(utf8.encode(canonical)));
}

/// Sentinel fingerprint for a missing lockfile. Exposed so callers
/// that read bytes themselves can produce the same encoding as the
/// path-based [computeWorkspaceHash] without re-implementing.
const String lockfileFingerprintAbsent = 'absent';

/// Encode pre-read lockfile bytes as the `sha256:<hex>` fingerprint
/// the install path passes into [computeWorkspaceHash].
String lockfileFingerprintFromBytes(Uint8List bytes) =>
    'sha256:${KnotHash.sha256Hex(bytes)}';

Map<String, String> _sortedMap(Map<String, String> input) {
  final keys = input.keys.toList()..sort();
  return {for (final k in keys) k: input[k]!};
}

Future<String> _lockfileFingerprint(String? path) async {
  if (path == null) return 'absent';
  final file = File(path);
  if (!await file.exists()) return 'absent';
  final bytes = await file.readAsBytes();
  return 'sha256:${KnotHash.sha256Hex(bytes)}';
}

/// Default location for the workspace state file: alongside the
/// project's `node_modules`, namespaced under `.knot/`.
String workspaceStatePath(String projectRoot) =>
    p.join(projectRoot, 'node_modules', '.knot', 'workspace-state.json');

/// Read the workspace state JSON from disk (or null if absent /
/// corrupt). Corrupt entries are treated as "no state" so installs
/// rerun rather than failing.
Future<WorkspaceState?> readWorkspaceState(String projectRoot) async {
  final path = workspaceStatePath(projectRoot);
  final file = File(path);
  if (!await file.exists()) return null;
  try {
    final raw = await file.readAsString();
    final json = jsonDecode(raw);
    return WorkspaceState.fromJson(json);
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// Write [state] to the workspace state file, creating parent dirs.
Future<void> writeWorkspaceState({
  required String projectRoot,
  required WorkspaceState state,
}) async {
  final path = workspaceStatePath(projectRoot);
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(state.toJson()),
  );
}

String? _hostArch() {
  final v = Platform.version;
  // Platform.version doesn't expose arch directly; rely on the system.
  // dart:io provides only operatingSystem + operatingSystemVersion;
  // we fall back to env `KNOT_HOST_ARCH` to allow tests to override.
  final override = Platform.environment['KNOT_HOST_ARCH'];
  if (override != null && override.isNotEmpty) return override;
  // Best-effort detection from Dart's locale-independent identifier.
  if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
  if (v.contains('x64') || v.contains('x86_64')) return 'x64';
  return 'unknown';
}

// Note: an earlier draft of this file spawned `node --version`
// synchronously here. That landed ~45 ms on the warm-install
// critical path. The current design relies on the caller (or the
// `KNOT_HOST_NODE_MAJOR` env override) to supply a precomputed major
// when one is needed.
