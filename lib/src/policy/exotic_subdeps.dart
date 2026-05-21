import '../cli/dependency_spec.dart';

/// Whitelist of trusted GitHub repositories whose git/https-tarball
/// references stay allowed even under `blockExoticSubdeps = true`.
///
/// pnpm v11 ships a fixed 9-entry list (verified per plan §5); the
/// exact membership is read from the pnpm source at Phase D source
/// spike time. The three names below — Node.js, bun, and deno — are
/// the ones we are confident in from the project memory. The list is
/// **closed**: anything outside it triggers the block.
///
/// Entries are `owner/repo`, lowercased.
// TODO(phase-d): reconcile the remaining 6 entries from pnpm source.
const Set<String> trustedExoticRepos = {
  'nodejs/node',
  'oven-sh/bun',
  'denoland/deno',
};

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
  return _isTrustedExotic(spec)
      ? ExoticDepRule.trusted
      : ExoticDepRule.blocked;
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
  if (repo == null) return false;
  return trustedExoticRepos.contains(repo.toLowerCase());
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
