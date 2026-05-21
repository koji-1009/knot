import '../cli/dependency_spec.dart';

/// Trusted GitHub repositories whose git / https-tarball references stay
/// allowed under `blockExoticSubdeps = true`. Entries are `owner/repo`,
/// lowercased. Mirrors the GitHub-repo subset of pnpm's
/// `NON_EXOTIC_RESOLVED_VIA` set.
const Set<String> trustedExoticRepos = {'denoland/deno', 'oven-sh/bun'};

/// Trusted hosts whose https-tarball URLs are allowed under
/// `blockExoticSubdeps = true`. Mirrors the host-keyed subset of pnpm's
/// `NON_EXOTIC_RESOLVED_VIA` set (the source-type tags like
/// `npm-registry`, `workspace`, `local-filesystem`, `named-registry`,
/// `jsr-registry`, `custom-resolver` are handled by knot's protocol
/// dispatch in [classifyExoticDep] and do not need to appear here).
const Set<String> trustedExoticHosts = {'nodejs.org'};

/// Outcome of an exotic-dep check.
enum ExoticDepRule {
  /// The spec is a registry / workspace dep — `blockExoticSubdeps`
  /// never affects these.
  notExotic,

  /// The spec is exotic (git / https tarball) and on the trusted
  /// whitelist, so install proceeds.
  trusted,

  /// The spec is exotic and transitive but NOT on the whitelist —
  /// install must refuse.
  blocked,

  /// The spec is exotic but declared as a *direct* dep — the policy
  /// permits this regardless of the whitelist.
  directExotic,
}

/// Evaluate [spec] under `blockExoticSubdeps`. [isDirect] indicates
/// whether the dep was declared by the project root (vs pulled in
/// transitively); only transitive exotic deps fall under the
/// whitelist gate.
///
/// Returns the rule's classification; callers translate `blocked` into
/// a user-facing error.
ExoticDepRule classifyExoticDep({
  required DependencySpec spec,
  required bool isDirect,
}) {
  if (!_isExotic(spec)) return ExoticDepRule.notExotic;
  if (isDirect) return ExoticDepRule.directExotic;
  return _isTrustedExotic(spec) ? ExoticDepRule.trusted : ExoticDepRule.blocked;
}

bool _isExotic(DependencySpec spec) {
  switch (spec.protocol) {
    case SpecifierProtocol.git:
    case SpecifierProtocol.https:
      return true;
    case SpecifierProtocol.file:
    case SpecifierProtocol.link:
    case SpecifierProtocol.semver:
    case SpecifierProtocol.workspace:
    case SpecifierProtocol.catalog:
      return false;
  }
}

bool _isTrustedExotic(DependencySpec spec) {
  final repo = _extractGithubRepo(spec);
  if (repo != null && trustedExoticRepos.contains(repo.toLowerCase())) {
    return true;
  }
  final host = _extractHost(spec);
  if (host != null && trustedExoticHosts.contains(host.toLowerCase())) {
    return true;
  }
  return false;
}

/// Extract the host (e.g. `nodejs.org`) of an https-tarball spec, or
/// null when the source is not an https URL we can parse.
String? _extractHost(DependencySpec spec) {
  final candidate = spec.url ?? spec.range;
  if (candidate.isEmpty) return null;
  var url = candidate;
  if (url.startsWith('git+')) url = url.substring(4);
  if (url.startsWith('github:')) return null;
  final hash = url.indexOf('#');
  if (hash >= 0) url = url.substring(0, hash);
  try {
    final parsed = Uri.parse(url);
    return parsed.host.isEmpty ? null : parsed.host;
  } on FormatException {
    return null;
  }
}

/// Extract the `owner/repo` slug for a github-style spec, or null if
/// the source is not a GitHub repository we can identify.
///
/// Handles:
/// - `github:owner/repo` and `github:owner/repo#ref`
/// - `git+ssh://git@github.com/owner/repo.git[#ref]`
/// - `git+https://github.com/owner/repo.git[#ref]`
/// - `https://github.com/owner/repo/...` tarball URLs
String? _extractGithubRepo(DependencySpec spec) {
  final candidate = spec.url ?? spec.range;
  if (candidate.isEmpty) return null;

  var url = candidate;
  if (url.startsWith('git+')) url = url.substring(4);
  if (url.startsWith('github:')) {
    final body = url.substring(7);
    final hash = body.indexOf('#');
    return hash < 0 ? body : body.substring(0, hash);
  }
  // Strip `#ref` suffix
  final hash = url.indexOf('#');
  if (hash >= 0) url = url.substring(0, hash);

  Uri? parsed;
  try {
    parsed = Uri.parse(url);
  } on FormatException {
    return null;
  }
  if (parsed.host != 'github.com') return null;
  final segments = parsed.pathSegments
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (segments.length < 2) return null;
  final owner = segments[0];
  var repo = segments[1];
  if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
  return '$owner/$repo';
}
