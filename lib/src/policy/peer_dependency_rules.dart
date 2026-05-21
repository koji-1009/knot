/// Project-level overrides for peer-dependency resolution (pnpm v11
/// `peerDependencyRules`).
///
/// Surface mirrors pnpm's three axes:
/// - [allowedVersions]: per-package map of explicit ranges that count
///   as satisfying the peer demand, even when the parent's declared
///   range disagrees. Keyed by peer-dep name; the list is OR-joined.
/// - [ignoreMissing]: peer deps whose absence is silently allowed.
/// - [allowAny]: peer deps whose version is unconstrained — equivalent
///   to declaring `*` for that peer.
///
/// The struct is data-only; the resolver consumes these to weaken
/// peer-dep failures. Phase B lands the struct + parser-layer support;
/// resolver integration arrives alongside the per-package conflict
/// reporter.
class PeerDependencyRules {
  const PeerDependencyRules({
    this.allowedVersions = const {},
    this.ignoreMissing = const [],
    this.allowAny = const [],
  });

  final Map<String, List<String>> allowedVersions;
  final List<String> ignoreMissing;
  final List<String> allowAny;

  static const PeerDependencyRules none = PeerDependencyRules();

  bool isMissingIgnored(String peerName) => ignoreMissing.contains(peerName);

  bool isAnyAllowed(String peerName) => allowAny.contains(peerName);

  /// All explicit allowed ranges for [peerName], in declared order.
  /// Returns an empty list when no rule covers the name.
  List<String> allowedFor(String peerName) =>
      allowedVersions[peerName] ?? const [];
}
