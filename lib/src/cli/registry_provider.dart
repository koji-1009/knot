import 'dart:async';

import 'package:knot/src/core/core.dart';
import 'package:knot/src/policy/release_age.dart';
import 'package:knot/src/registry/registry.dart';
import 'package:knot/src/resolver/resolver.dart';
import 'package:knot/src/semver/semver.dart';

/// Bridges [RegistryClient] to the resolver's [PackageProvider] interface.
///
/// Pubgrub asks for packuments one at a time as it makes decisions. Two
/// mechanisms keep the network busy ahead of those serial asks:
///
/// 1. [warmup] — called once before solve starts, walks the transitive
///    dep graph eagerly from a set of `(name, declared range)` seeds and
///    fans the resulting fetches across the HTTP pool. This covers
///    almost everything pubgrub will need.
/// 2. [_scheduleSpeculative] — a backup. Fires after any cache miss
///    inside [_packumentFor] and prefetches the `latest` slice's deps,
///    bounded by [_speculativeDepth]. Catches the occasional name a
///    warmup-time range-walk misses (stale lockfile entries, unusual
///    `nestedOverrides`, etc.).
class RegistryPackageProvider implements PackageProvider {
  RegistryPackageProvider(
    this.client, {
    Duration? minReleaseAge,
    MinReleaseAgePolicy? releaseAge,
    DateTime? now,
  })  : releaseAge = releaseAge ??
            (minReleaseAge != null
                ? MinReleaseAgePolicy(minimum: minReleaseAge)
                : const MinReleaseAgePolicy()),
        _now = now ?? DateTime.now().toUtc();

  final RegistryClient client;

  /// Release-age filter (Phase B): four axes covering the minimum, the
  /// strict/non-strict fallback, missing-time handling, and exclusion
  /// patterns. The slim packument does not carry `time`, so the
  /// underlying [RegistryClient] is asked for the full packument
  /// whenever the filter is enabled.
  final MinReleaseAgePolicy releaseAge;

  Duration? get minReleaseAge => releaseAge.minimum;

  /// Frozen "now" reference for release-age comparisons. Frozen so the
  /// resolver sees consistent results across many lookups during one
  /// install.
  final DateTime _now;

  bool get _filterByAge => releaseAge.enabled;

  final Map<String, Future<Packument>> _inflight = {};
  final Map<String, Packument> _packumentCache = {};
  final Set<String> _prefetched = {};

  /// Maximum hop count for the speculative prefetch graph walk.
  ///
  /// Uncapped, a `latest`-version cascade fans out across ecosystem
  /// boundaries and explodes (>2000 fetches for a small fixture). The
  /// cap bounds wasted work while still covering the typical npm
  /// dep depth.
  static const int _speculativeDepth = 5;

  /// Fetch a packument, optionally scheduling speculative prefetches of
  /// its latest slice's dependencies. [cascadeDepth] controls how many
  /// further hops the prefetch may recurse — pass 0 to disable, or
  /// `_speculativeDepth` for the default budget.
  Future<Packument> _packumentFor(
    String name, {
    int cascadeDepth = _speculativeDepth,
  }) {
    final cached = _packumentCache[name];
    if (cached != null) return Future.value(cached);
    final inflight = _inflight[name];
    if (inflight != null) return inflight;
    final future = client
        .packument(name, requirePublishTimes: _filterByAge)
        .then((pack) {
          _packumentCache[name] = pack;
          _inflight.remove(name);
          if (cascadeDepth > 0) _scheduleSpeculative(pack, cascadeDepth - 1);
          return pack;
        });
    _inflight[name] = future;
    return future;
  }

  /// Backup speculative cascade: prefetch the deps of [pack]'s
  /// `latest` version. Errors swallowed; [warmup] is the primary
  /// path and this fires only on cache misses inside [_packumentFor].
  ///
  /// Skips `peerDependenciesMeta.optional` peers — pubgrub won't
  /// force-install them, so prefetching their packuments is wasted.
  void _scheduleSpeculative(Packument pack, int remainingDepth) {
    final latest = pack.latest;
    final slice = latest == null ? null : pack.versions[latest];
    if (slice == null) return;
    final names = <String>{}
      ..addAll(slice.dependencies.keys)
      ..addAll(slice.optionalDependencies.keys);
    for (final peer in slice.peerDependencies.keys) {
      if (slice.optionalPeers.contains(peer)) continue;
      names.add(peer);
    }
    for (final name in names) {
      if (_packumentCache.containsKey(name)) continue;
      if (_inflight.containsKey(name)) continue;
      if (!_prefetched.add(name)) continue;
      unawaited(
        _packumentFor(
          name,
          cascadeDepth: remainingDepth,
        ).then((_) {}).catchError((_) {}),
      );
    }
  }

  @override
  Future<List<Version>> versions(String package) async {
    final pack = await _packumentFor(package);
    final mature = <Version>[];
    final immature = <Version>[];
    final excluded = _filterByAge && releaseAge.isExcluded(package);
    // Hoist the cutoff: loop-invariant for one resolve, so compute it
    // once instead of allocating a new DateTime inside every iteration.
    final cutoff = _filterByAge ? _now.subtract(releaseAge.minimum!) : null;
    final ignoreMissing = releaseAge.ignoreMissingTime;
    var hiddenByAge = 0;
    for (final v in pack.versions.keys) {
      final parsed = tryParseVersion(v);
      if (parsed == null) continue;
      if (!_filterByAge || excluded) {
        mature.add(parsed);
        continue;
      }
      final verdict = evaluateReleaseAge(
        cutoff: cutoff!,
        publishedAt: pack.publishTimes[v],
        ignoreMissingTime: ignoreMissing,
      );
      switch (verdict) {
        case ReleaseAgeVerdict.mature:
          mature.add(parsed);
        case ReleaseAgeVerdict.immature:
          hiddenByAge++;
          immature.add(parsed);
        case ReleaseAgeVerdict.unknownTime:
          // ignoreMissingTime=false: treat as "too new to verify"
          hiddenByAge++;
      }
    }
    if (_filterByAge && mature.isEmpty && hiddenByAge > 0) {
      if (releaseAge.strict || immature.isEmpty) {
        throw NetworkError(
          '$package: every version is younger than '
          '${minReleaseAge!.inHours}h (minimum-release-age filter '
          'hid $hiddenByAge candidates)',
        );
      }
      // Non-strict + at least one immature candidate: fall back to the
      // lowest-versioned immature release so installs don't stall
      // behind a freshly published package.
      immature.sort();
      mature.add(immature.first);
    }
    mature.sort();
    return mature;
  }

  @override
  Future<PackageDependencies> dependenciesOf(
    String package,
    Version version,
  ) async {
    final pack = await _packumentFor(package);
    final slice = pack.versions[version.toString()];
    if (slice == null) {
      throw StateError('packument has no $package@$version');
    }
    return PackageDependencies(
      dependencies: slice.dependencies,
      optionalDependencies: slice.optionalDependencies,
      peerDependencies: slice.peerDependencies,
      optionalPeers: slice.optionalPeers,
    );
  }

  /// Lookup tarball metadata after resolution.
  Future<PackumentVersion?> sliceOf(String name, Version version) async {
    final pack = await _packumentFor(name);
    return pack.versions[version.toString()];
  }

  /// Resolve a dist-tag (`latest`, `next`, `beta`, …) to a concrete version
  /// range (`=<version>`). Returns null if the tag is unknown.
  Future<String?> resolveDistTag(String name, String tag) async {
    final pack = await _packumentFor(name);
    final v = pack.distTags[tag];
    return v == null ? null : '=$v';
  }

  /// Eagerly fetch packuments along the transitive dep graph rooted
  /// at [seeds], honoring each `(name, declared range)` so the walk
  /// follows the same versions pubgrub will eventually pick.
  ///
  /// The range matters: a `latest`-only walk follows vite@8 →
  /// rolldown even when the project declares `vite: ^5` → rollup,
  /// inflating the fetch set by ~40 packuments per install. Picking
  /// the highest version satisfying the parent's range mirrors
  /// pubgrub's own first guess and keeps the walk near-exact.
  ///
  /// Drains a self-extending worklist: every fetched packument
  /// schedules its children the moment it parses, without awaiting
  /// siblings. All pending fetches run concurrently against the
  /// 64-connection HTTP pool, so the downloads compress into one
  /// continuous parallel stream rather than a sequence of layer
  /// bursts.
  Future<void> warmup(Map<String, String> seeds) async {
    final pending = <Future<void>>[];

    void schedule(String name, String range, int budget) {
      if (budget <= 0) return;
      if (_packumentCache.containsKey(name)) {
        // We've already fetched this packument; still walk its deps
        // with the new range so a different parent's range can
        // unlock previously-unwalked branches.
        final pack = _packumentCache[name]!;
        _walkSlice(pack, range, budget, schedule);
        return;
      }
      if (_inflight.containsKey(name)) return;
      pending.add(
        _packumentFor(name, cascadeDepth: 0)
            .then((pack) {
              _walkSlice(pack, range, budget, schedule);
            })
            .catchError((_) {}),
      );
    }

    for (final entry in seeds.entries) {
      schedule(entry.key, entry.value, _speculativeDepth);
    }

    // `pending` grows as in-flight fetches schedule their children.
    // Drain it in waves until no new work is left.
    while (pending.isNotEmpty) {
      final batch = [...pending];
      pending.clear();
      await Future.wait(batch);
    }
  }

  /// Pick the highest version of [pack] that satisfies [range] and
  /// schedule prefetches for its dependencies via [schedule]. Falls
  /// back to `pack.latest` when the range is unparseable or no
  /// version matches (e.g. a stale lockfile range).
  void _walkSlice(
    Packument pack,
    String range,
    int budget,
    void Function(String, String, int) schedule,
  ) {
    PackumentVersion? slice;
    NpmRange? parsedRange;
    if (range.isNotEmpty) {
      try {
        parsedRange = NpmRange.parse(range);
      } on FormatException {
        // Treat as "no constraint" — fall back to latest below.
      }
    }
    if (parsedRange != null) {
      Version? best;
      for (final vStr in pack.versions.keys) {
        final v = tryParseVersion(vStr);
        if (v == null) continue;
        if (!parsedRange.satisfies(v)) continue;
        if (best == null || v > best) best = v;
      }
      if (best != null) slice = pack.versions[best.toString()];
    }
    slice ??= pack.latest == null ? null : pack.versions[pack.latest!];
    if (slice == null) return;

    for (final dep in slice.dependencies.entries) {
      schedule(dep.key, dep.value, budget - 1);
    }
    for (final dep in slice.optionalDependencies.entries) {
      schedule(dep.key, dep.value, budget - 1);
    }
    for (final peer in slice.peerDependencies.entries) {
      if (slice.optionalPeers.contains(peer.key)) continue;
      schedule(peer.key, peer.value, budget - 1);
    }
  }
}
