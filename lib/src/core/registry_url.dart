/// Join [relativePath] onto a registry [base] the way npm and pnpm build
/// registry URLs: the base is normalized to exactly one trailing slash
/// before concatenation.
///
/// `Uri.resolve` is the wrong tool here — against a base whose path has
/// no trailing slash (e.g. a private registry mounted at
/// `https://host/artifactory/api/npm/npm`) it strips the last path
/// segment, sending the request to the wrong endpoint. npm normalizes
/// with `registry.replace(/\/?$/, '/')` and pnpm appends `/` when
/// missing; both concatenate rather than resolve. This helper mirrors
/// that so knot reaches the same endpoint as npm and pnpm for any
/// registry, path-prefixed or not.
Uri joinRegistryUrl(String base, String relativePath) {
  final trimmed = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  final rel = relativePath.startsWith('/')
      ? relativePath.substring(1)
      : relativePath;
  return Uri.parse('$trimmed/$rel');
}
