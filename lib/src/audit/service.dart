import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:knot/src/lockfile/lockfile.dart';
import 'package:knot/src/npmrc/npmrc.dart';
import 'package:knot/src/semver/semver.dart';

import 'advisory.dart';

/// One actionable finding: an installed package version that falls
/// inside an advisory's `vulnerable_versions` range.
class AuditFinding {
  AuditFinding({
    required this.packageName,
    required this.installedVersion,
    required this.advisory,
  });
  final String packageName;
  final String installedVersion;
  final Advisory advisory;
}

class AuditReport {
  AuditReport({required this.findings, required this.advisoryFetchErrors});

  final List<AuditFinding> findings;

  /// Endpoint failures kept on the report so callers can render a
  /// warning rather than silently treating a broken network as
  /// "clean". An empty list means the audit completed cleanly.
  final List<String> advisoryFetchErrors;

  Map<AuditSeverity, int> get countsBySeverity {
    final out = {for (final s in AuditSeverity.values) s: 0};
    for (final f in findings) {
      out[AuditSeverity.parse(f.advisory.severity)] =
          (out[AuditSeverity.parse(f.advisory.severity)] ?? 0) + 1;
    }
    return out;
  }

  int get total => findings.length;

  /// True when at least one finding has severity at-or-above
  /// [threshold]. Used to decide the audit command's exit code.
  bool meetsThreshold(AuditSeverity threshold) {
    for (final f in findings) {
      if (AuditSeverity.parse(f.advisory.severity).atLeast(threshold)) {
        return true;
      }
    }
    return false;
  }
}

/// Queries the npm registry's bulk advisory endpoint for vulnerabilities
/// affecting the resolved packages in a lockfile.
///
/// Endpoint contract (`POST /-/npm/v1/security/advisories/bulk`):
/// - Request body: `{ "<name>": ["<version1>", "<version2>", ...] }`
/// - Response: `{ "<name>": [<advisory>, ...] }` with each advisory
///   already filtered to the supplied versions server-side. We
///   *re-verify* client-side via the semver range because we've
///   historically seen overlap drift on private registries.
class AuditService {
  AuditService({required this.config, required this.userAgent})
    : _http = HttpClient()..idleTimeout = const Duration(seconds: 30);

  final NpmrcConfig config;
  final String userAgent;
  final HttpClient _http;

  void close() {
    _http.close(force: true);
  }

  Future<AuditReport> audit(Lockfile lock) async {
    // Group installed packages by name -> set of versions. The endpoint
    // is shaped that way; one POST is enough regardless of dep count.
    final byName = <String, Set<String>>{};
    for (final pkg in lock.packages.values) {
      // Only registry-resolved packages have advisories on the npm
      // database — skip workspace/file/git entries.
      if (pkg.resolution.tarball == null) continue;
      byName.putIfAbsent(pkg.name, () => <String>{}).add(pkg.version);
    }
    if (byName.isEmpty) {
      return AuditReport(findings: const [], advisoryFetchErrors: const []);
    }

    // Group requests per registry (scoped packages may live on a
    // private registry). The bulk endpoint is registry-relative.
    final byRegistry = <Uri, Map<String, Set<String>>>{};
    for (final entry in byName.entries) {
      final reg = _registryForName(entry.key);
      byRegistry.putIfAbsent(reg, () => {})[entry.key] = entry.value;
    }

    final findings = <AuditFinding>[];
    final errors = <String>[];
    await Future.wait([
      for (final entry in byRegistry.entries)
        _queryRegistry(entry.key, entry.value, byName, findings, errors),
    ]);

    return AuditReport(findings: findings, advisoryFetchErrors: errors);
  }

  Future<void> _queryRegistry(
    Uri registry,
    Map<String, Set<String>> groupedByName,
    Map<String, Set<String>> allInstalled,
    List<AuditFinding> findings,
    List<String> errors,
  ) async {
    final endpoint = registry.resolve('-/npm/v1/security/advisories/bulk');
    final body = jsonEncode({
      for (final e in groupedByName.entries) e.key: e.value.toList(),
    });
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
      'user-agent': userAgent,
      ..._authHeaders(registry),
    };
    final int statusCode;
    final String responseBody;
    try {
      final request = await _http.postUrl(endpoint);
      headers.forEach((k, v) => request.headers.set(k, v));
      final encoded = utf8.encode(body);
      request.contentLength = encoded.length;
      request.add(encoded);
      final response = await request.close();
      statusCode = response.statusCode;
      responseBody = await response.transform(utf8.decoder).join();
    } on Object catch (e) {
      errors.add('${registry.host}: $e');
      return;
    }
    if (statusCode >= 400) {
      errors.add('${registry.host}: HTTP $statusCode on advisories/bulk');
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(responseBody);
    } on FormatException catch (e) {
      errors.add('${registry.host}: malformed JSON: ${e.message}');
      return;
    }
    if (decoded is! Map) {
      errors.add('${registry.host}: response was not a JSON object');
      return;
    }
    for (final entry in decoded.entries) {
      final name = entry.key as String;
      final list = entry.value;
      if (list is! List) continue;
      final installed = allInstalled[name] ?? const <String>{};
      for (final raw in list) {
        if (raw is! Map) continue;
        final advisory = Advisory.fromJson(Map<String, dynamic>.from(raw));
        // Re-verify range client-side; server-side filter has drifted
        // on private mirrors in the past.
        NpmRange? range;
        try {
          range = NpmRange.parse(advisory.vulnerableVersions);
        } on FormatException {
          range = null;
        }
        for (final v in installed) {
          final parsed = tryParseVersion(v);
          if (parsed == null) continue;
          if (range != null && !range.satisfies(parsed)) continue;
          findings.add(
            AuditFinding(
              packageName: name,
              installedVersion: v,
              advisory: advisory,
            ),
          );
        }
      }
    }
  }

  Map<String, String> _authHeaders(Uri uri) {
    final token = config.authTokenFor(uri);
    if (token != null) return {'authorization': 'Bearer $token'};
    final basic = config.basicAuthFor(uri);
    if (basic != null) {
      final encoded = base64.encode(
        utf8.encode('${basic.username}:${basic.password}'),
      );
      return {'authorization': 'Basic $encoded'};
    }
    final legacy = config.legacyAuthFor(uri);
    if (legacy != null) return {'authorization': 'Basic $legacy'};
    return const {};
  }

  Uri _registryForName(String name) {
    if (name.startsWith('@')) {
      final slash = name.indexOf('/');
      final scope = slash > 0 ? name.substring(0, slash) : name;
      final scoped = config.registryFor(scope);
      if (scoped != null) return Uri.parse(scoped);
    }
    return Uri.parse(config.registry);
  }
}
