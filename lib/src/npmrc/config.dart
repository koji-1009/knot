/// Default npm registry endpoint.
const String defaultRegistry = 'https://registry.npmjs.org/';

/// Built-in named-registry aliases per pnpm v11.1.0. Currently a single
/// entry: `gh` → GitHub Packages registry. User-defined aliases (via
/// `named-registry-<name>=<url>` in `.npmrc` or `namedRegistries:` in
/// `pnpm-workspace.yaml`) override these defaults.
const Map<String, String> builtinNamedRegistries = {
  'gh': 'https://npm.pkg.github.com/',
};

/// A merged, resolved .npmrc configuration.
class NpmrcConfig {
  const NpmrcConfig(this._entries);

  final Map<String, String> _entries;

  Map<String, String> get raw => Map.unmodifiable(_entries);

  String get registry => _entries['registry'] ?? defaultRegistry;

  String? registryFor(String scope) {
    final key = '${_normalizeScope(scope)}:registry';
    return _entries[key];
  }

  /// Resolve a named-registry alias to its URL.
  ///
  /// Lookup order: explicit user override (`named-registry-<alias>=`),
  /// then [builtinNamedRegistries]. Returns null when the alias is
  /// unknown. The trailing slash is preserved from the source value.
  ///
  /// Named registries (pnpm v11.1.0) are non-scope aliases (e.g. `gh:`)
  /// usable in dependency specifiers and `--registry` selectors. This
  /// API is consumed by Phase N (registry/auth) and pack-app's runtime
  /// lookups; downstream features layer auth + tarball normalization on
  /// top of the URL returned here.
  String? namedRegistry(String alias) {
    final key = 'named-registry-${alias.toLowerCase()}';
    final override = _entries[key];
    if (override != null) return override;
    return builtinNamedRegistries[alias.toLowerCase()];
  }

  /// All known named-registry aliases — explicit overrides plus
  /// built-ins, with overrides winning. Returned map is unmodifiable.
  Map<String, String> get namedRegistries {
    final out = <String, String>{...builtinNamedRegistries};
    for (final entry in _entries.entries) {
      const prefix = 'named-registry-';
      if (!entry.key.startsWith(prefix)) continue;
      final alias = entry.key.substring(prefix.length);
      if (alias.isEmpty) continue;
      out[alias] = entry.value;
    }
    return Map.unmodifiable(out);
  }

  String? authTokenFor(Uri registryUri) {
    final candidates = _registryKeyCandidates(registryUri);
    for (final base in candidates) {
      final v = _entries['$base:_authtoken'] ?? _entries['$base:_authToken'];
      if (v != null) return v;
    }
    return null;
  }

  ({String username, String password})? basicAuthFor(Uri registryUri) {
    final candidates = _registryKeyCandidates(registryUri);
    for (final base in candidates) {
      final user = _entries['$base:username'];
      final pass = _entries['$base:_password'];
      if (user != null && pass != null) {
        return (username: user, password: pass);
      }
    }
    return null;
  }

  /// Legacy registry-wide `_auth` value (base64 of `user:password`).
  /// Used by older Artifactory / Nexus deployments.
  String? legacyAuthFor(Uri registryUri) {
    final candidates = _registryKeyCandidates(registryUri);
    for (final base in candidates) {
      final v = _entries['$base:_auth'];
      if (v != null) return v;
    }
    return _entries['_auth'];
  }

  /// Raw entry lookup — used for keys without typed accessors
  /// (e.g. `node-linker`). Case-insensitive on the npmrc convention.
  String? operator [](String key) => _entries[key.toLowerCase()];

  int integer(String key, {int fallback = 0}) {
    final v = _entries[key.toLowerCase()];
    if (v == null) return fallback;
    return int.tryParse(v.trim()) ?? fallback;
  }

  static String _normalizeScope(String scope) =>
      scope.startsWith('@') ? scope : '@$scope';

  List<String> _registryKeyCandidates(Uri uri) {
    final hostPort = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final results = <String>[];
    for (var i = segments.length; i >= 0; i--) {
      final pathPart = segments.isEmpty || i == 0
          ? ''
          : '${segments.take(i).join('/')}/';
      results.add('//$hostPort/$pathPart'.toLowerCase());
    }
    return results;
  }
}

/// Parse a single .npmrc file body.
Map<String, String> parseNpmrcBody(
  String content, {
  required String Function(String) expandVar,
}) {
  final out = <String, String>{};
  final lines = content.split(RegExp(r'\r?\n'));
  for (final line in lines) {
    final stripped = _stripComment(line).trim();
    if (stripped.isEmpty) continue;
    final eq = stripped.indexOf('=');
    if (eq < 0) continue;
    final key = stripped.substring(0, eq).trim().toLowerCase();
    var value = stripped.substring(eq + 1).trim();
    value = _unquote(value);
    value = _expandVariables(value, expandVar);
    out[key] = value;
  }
  return out;
}

String _stripComment(String line) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == "'" && !inDouble) inSingle = !inSingle;
    if (ch == '"' && !inSingle) inDouble = !inDouble;
    if (!inSingle && !inDouble && (ch == '#' || ch == ';')) {
      return line.substring(0, i);
    }
  }
  return line;
}

String _unquote(String s) {
  if (s.length >= 2) {
    final first = s[0];
    final last = s[s.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return s.substring(1, s.length - 1);
    }
  }
  return s;
}

final RegExp _varRefRe = RegExp(r'\$\{([^}]+)\}');

String _expandVariables(String value, String Function(String) lookup) {
  return value.replaceAllMapped(_varRefRe, (m) {
    final body = m.group(1)!;
    return lookup(body);
  });
}
