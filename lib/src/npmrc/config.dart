
/// Default npm registry endpoint.
const String defaultRegistry = 'https://registry.npmjs.org/';

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
