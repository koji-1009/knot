import 'dart:io';

import 'package:path/path.dart' as p;

import 'npmrc.dart';

/// Source of a single .npmrc layer, used in the merge order.
///
/// The `label` (file path / `env`) was kept around for diagnostic
/// output, but the loader never surfaces it; only `entries` flows
/// into the merged [NpmrcConfig].
class NpmrcSource {
  const NpmrcSource(this.entries);
  final Map<String, String> entries;
}

/// Strategy for loading and merging .npmrc files.
///
/// Merge precedence (highest wins):
///   1. environment variables (`KNOT_CONFIG_*`)
///   2. project `.npmrc` (searched from [projectDir] up to filesystem root)
///   3. user `~/.npmrc`
///   4. global `/etc/npmrc`
///
/// Per Phase G of the v11-alignment plan knot only ingests its own
/// `KNOT_CONFIG_*` env vars — `npm_config_*` and `NPM_CONFIG_*` are
/// ignored to prevent ambient npm-side config from leaking into knot's
/// runtime. Lifecycle scripts still receive npm_* metadata vars (see
/// `ScriptRunner.buildLifecycleEnv`).
class NpmrcLoader {
  const NpmrcLoader({
    this.projectDir,
    this.homeDir,
    this.globalConfig = '/etc/npmrc',
    this.env,
  });

  final String? projectDir;
  final String? homeDir;
  final String globalConfig;
  final Map<String, String>? env;

  Map<String, String> get _environment => env ?? Platform.environment;

  /// Returns the merged configuration assembled from all available layers.
  Future<NpmrcConfig> load() async {
    final layers = <NpmrcSource>[];

    final global = await _readFile(globalConfig);
    if (global != null) layers.add(NpmrcSource(global));

    final home = homeDir ?? _detectHome();
    if (home != null) {
      final userPath = p.join(home, '.npmrc');
      final user = await _readFile(userPath);
      if (user != null) layers.add(NpmrcSource(user));
    }

    final project = projectDir ?? Directory.current.path;
    for (final dir in _walkUp(project)) {
      final candidate = p.join(dir, '.npmrc');
      final found = await _readFile(candidate);
      if (found != null) {
        layers.add(NpmrcSource(found));
        break;
      }
    }

    final fromEnv = _envOverrides();
    if (fromEnv.isNotEmpty) layers.add(NpmrcSource(fromEnv));

    // Phase N: `npmrc-auth-file=<path>` opts the user into a separate
    // file holding only auth entries — convenient for keeping secrets
    // out of the project-tracked `.npmrc`. The auth file is layered
    // BENEATH every npmrc layer the user explicitly authored, so any
    // explicit override still wins. Walk highest-precedence first so a
    // single hash lookup per layer finds the effective value without
    // pre-merging every entry.
    String? authFilePath;
    for (var i = layers.length - 1; i >= 0; i--) {
      final v = layers[i].entries['npmrc-auth-file'];
      if (v != null && v.isNotEmpty) {
        authFilePath = v;
        break;
      }
    }
    if (authFilePath != null) {
      final resolved = _resolveAuthFile(authFilePath, project, home);
      final authEntries = await _readFile(resolved);
      if (authEntries != null) {
        final layerIndex = layers.length > 1 ? 1 : 0;
        layers.insert(layerIndex, NpmrcSource(authEntries));
      }
    }

    final merged = <String, String>{};
    for (final layer in layers) {
      merged.addAll(layer.entries);
    }
    return NpmrcConfig(merged);
  }

  String _resolveAuthFile(String raw, String project, String? home) {
    if (raw.startsWith('~/') && home != null) {
      return p.join(home, raw.substring(2));
    }
    if (p.isAbsolute(raw)) return raw;
    return p.normalize(p.join(project, raw));
  }

  Future<Map<String, String>?> _readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final body = await file.readAsString();
    return parseNpmrcBody(body, expandVar: _lookupEnv);
  }

  String _lookupEnv(String name) {
    final defaultIdx = name.indexOf('-');
    final base = defaultIdx >= 0 ? name.substring(0, defaultIdx) : name;
    final defaultValue = defaultIdx >= 0 ? name.substring(defaultIdx + 1) : '';
    final value = _environment[base];
    if (value != null) return value;
    return defaultValue;
  }

  String? _detectHome() => _environment['HOME'] ?? _environment['USERPROFILE'];

  Map<String, String> _envOverrides() {
    final out = <String, String>{};
    for (final entry in _environment.entries) {
      const prefix = 'KNOT_CONFIG_';
      if (!entry.key.toUpperCase().startsWith(prefix)) continue;
      final key = entry.key.substring(prefix.length).toLowerCase();
      out[key] = entry.value;
    }
    return out;
  }

  Iterable<String> _walkUp(String dir) sync* {
    var current = p.normalize(p.absolute(dir));
    while (true) {
      yield current;
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }
}
