import 'dart:convert';
import 'dart:io';

import 'package:knot/src/semver/semver.dart';
import 'package:path/path.dart' as p;

/// Resolves the host `node --version`, caching the result on disk keyed by
/// the `node` binary's identity (resolved path + mtime + size).
///
/// A warm install otherwise pays a ~45 ms `node --version` fork+exec on
/// every run just to feed the (usually non-fatal) engines check — on a
/// warm relink that one fork dominates the whole install. The cache makes
/// it a microsecond file read; the fork is paid once per host, on the
/// first run or after the `node` binary changes. Mirrors gnpm's
/// `node-version.json` cache.
///
/// **Staleness:** version managers (nodenv / nvm / asdf) front `node` with
/// a shim whose path + mtime + size do not change when the active version
/// is switched, so a cached value can go stale until the shim itself
/// changes. The engines check this feeds is a warning by default, so a
/// stale value is low-harm; callers that must fail closed on a mismatch
/// (`--engine-strict`) pass `bypassCache: true` to force a fresh probe.
class NodeVersionCache {
  NodeVersionCache(
    this.cacheFile, {
    Future<ProcessResult> Function(String, List<String>)? runProcess,
    String? Function()? resolveNode,
  }) : _run = runProcess ?? Process.run,
       _resolveNode = resolveNode ?? whichNode;

  /// Absolute path to the JSON cache file (typically
  /// `~/.knot/cache/node-version.json`).
  final String cacheFile;

  final Future<ProcessResult> Function(String, List<String>) _run;
  final String? Function() _resolveNode;

  /// Return the host node [Version], or `null` when `node` is absent or
  /// its `--version` output is unparseable. When [bypassCache] is set the
  /// disk cache is neither read nor relied upon (it is still refreshed on
  /// a successful probe).
  Future<Version?> detect({bool bypassCache = false}) async {
    try {
      final nodePath = _resolveNode();
      FileStat? stat;
      if (nodePath != null) {
        final s = File(nodePath).statSync();
        if (s.type != FileSystemEntityType.notFound) stat = s;
      }

      if (!bypassCache && nodePath != null && stat != null) {
        final cached = _read(nodePath, stat);
        if (cached != null) return cached;
      }

      final result = await _run('node', const ['--version']);
      if (result.exitCode != 0) return null;
      final raw = '${result.stdout}'.trim();
      final body = raw.startsWith('v') ? raw.substring(1) : raw;
      final version = tryParseVersion(body);
      if (version != null && nodePath != null && stat != null) {
        _write(nodePath, stat, version);
      }
      return version;
    } on Object {
      // Detection is best-effort — a failure just disables the engines
      // check for this run, exactly as a non-zero exit would.
      return null;
    }
  }

  Version? _read(String nodePath, FileStat stat) {
    try {
      final file = File(cacheFile);
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return null;
      if (json['path'] != nodePath) return null;
      if (json['modUs'] != stat.modified.microsecondsSinceEpoch) return null;
      if (json['size'] != stat.size) return null;
      final version = json['version'];
      return version is String ? tryParseVersion(version) : null;
    } on Object {
      // A corrupt or unreadable cache entry is just a miss.
      return null;
    }
  }

  void _write(String nodePath, FileStat stat, Version version) {
    try {
      final file = File(cacheFile);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'path': nodePath,
          'modUs': stat.modified.microsecondsSinceEpoch,
          'size': stat.size,
          'version': version.toString(),
        }),
      );
    } on Object {
      // Best-effort: a write failure just means the next run re-probes.
    }
  }
}

/// Resolve `node` against `PATH` the way the OS would, without forking —
/// the first executable match wins. Returns `null` when `PATH` is unset
/// or no candidate exists.
String? whichNode() {
  final names = Platform.isWindows
      ? const ['node.exe', 'node.cmd', 'node.bat']
      : const ['node'];
  final pathEnv = Platform.environment['PATH'];
  if (pathEnv == null || pathEnv.isEmpty) return null;
  final separator = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      final candidate = p.join(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}
