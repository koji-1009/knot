import 'dart:convert';

/// Fused UTF-8 + JSON decoder for registry / cache packument bytes.
///
/// Decodes bytes straight to an object in a single pass, skipping the
/// intermediate multi-MB `String` that `jsonDecode(utf8.decode(bytes))`
/// materializes. Measured ~28% faster (28 ms → 20 ms) on a 9.4 MB warm
/// packument-cache read. Reused (not rebuilt per call) since `fuse`
/// allocates a converter.
final Converter<List<int>, Object?> packumentJsonDecoder = const Utf8Decoder()
    .fuse(const JsonDecoder());

/// A simplified npm packument — only the fields knot consumes during
/// resolution. Storing the full packument as `Map<String, dynamic>` wastes
/// memory and pins JSON strings.
class Packument {
  const Packument({
    required this.name,
    required this.versions,
    required this.distTags,
    this.publishTimes = const {},
  });

  factory Packument.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final rawVersions = json['versions'];
    final versions = <String, PackumentVersion>{};
    if (rawVersions is Map) {
      for (final entry in rawVersions.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        // `.cast` is a zero-copy view over the decoded map; `.from`
        // would deep-copy every version slice. A full packument carries
        // ~30 fields per version (readme, maintainers, _npmVersion, …)
        // that `fromJson` never reads, so copying them is pure waste on
        // a hot path that runs once per published version.
        versions[entry.key as String] = PackumentVersion.fromJson(
          value.cast<String, dynamic>(),
        );
      }
    }
    final tags = <String, String>{};
    final rawTags = json['dist-tags'];
    if (rawTags is Map) {
      for (final e in rawTags.entries) {
        tags[e.key as String] = '${e.value}';
      }
    }
    final times = <String, DateTime>{};
    final rawTime = json['time'];
    if (rawTime is Map) {
      for (final e in rawTime.entries) {
        final key = e.key as String;
        // The `time` map carries two non-version metadata keys —
        // `created` and `modified` — for the package as a whole; the
        // rest are per-version publish timestamps. We keep only the
        // per-version entries, indexed by version string.
        if (key == 'created' || key == 'modified') continue;
        final dt = DateTime.tryParse('${e.value}');
        if (dt != null) times[key] = dt;
      }
    }
    return Packument(
      name: name,
      versions: versions,
      distTags: tags,
      publishTimes: times,
    );
  }

  /// Slim JSON serialization — only the fields the resolver and linker
  /// actually consume. Used as the on-disk cache format so we never have
  /// to re-parse multi-MB npm packument bodies on warm installs.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'dist-tags': distTags,
    'versions': <String, dynamic>{
      for (final e in versions.entries) e.key: e.value.toJson(),
    },
    if (publishTimes.isNotEmpty)
      'time': <String, dynamic>{
        for (final e in publishTimes.entries) e.key: e.value.toIso8601String(),
      },
  };

  final String name;
  final Map<String, PackumentVersion> versions;
  final Map<String, String> distTags;

  /// Per-version publish timestamps (UTC). Sourced from the registry's
  /// `time` map. Used by the install path to filter versions younger
  /// than a configured `minimum-release-age` — a defence against
  /// recently-published malicious releases that haven't had time to
  /// be reported and unpublished.
  final Map<String, DateTime> publishTimes;

  String? get latest => distTags['latest'];
}

/// One version slice within a packument.
class PackumentVersion {
  const PackumentVersion({
    required this.name,
    required this.version,
    required this.tarball,
    required this.integrity,
    this.dependencies = const {},
    this.optionalDependencies = const {},
    this.peerDependencies = const {},
    this.optionalPeers = const {},
    this.os = const [],
    this.cpu = const [],
    this.libc = const [],
    this.deprecated,
    this.hasBin = false,
    this.bin = const {},
    this.scripts = const {},
    this.engines = const {},
    this.bundledDependencies = const [],
    this.hasInstallScript = false,
    this.signatures = const [],
  });

  factory PackumentVersion.fromJson(Map<String, dynamic> json) {
    final dist = json['dist'];
    // Zero-copy view, mirroring the version-map handling above.
    final distMap = dist is Map
        ? dist.cast<String, dynamic>()
        : const <String, dynamic>{};
    final rawSignatures = distMap['signatures'];
    final signatures = <DistSignature>[];
    if (rawSignatures is List) {
      for (final entry in rawSignatures) {
        if (entry is! Map) continue;
        final keyid = entry['keyid'];
        final sig = entry['sig'];
        if (keyid is String && sig is String) {
          signatures.add(DistSignature(keyid: keyid, sig: sig));
        }
      }
    }
    final rawBin = json['bin'];
    final name = json['name'] as String? ?? '';
    final binMap = _normalizeBin(rawBin, name);
    final bundled = <String>[];
    final rawBundled =
        json['bundledDependencies'] ?? json['bundleDependencies'];
    if (rawBundled is List) {
      bundled.addAll(rawBundled.map((e) => '$e'));
    } else if (rawBundled is Map) {
      bundled.addAll(rawBundled.keys.map((e) => '$e'));
    }
    return PackumentVersion(
      name: name,
      version: json['version'] as String? ?? '',
      tarball: distMap['tarball'] as String?,
      integrity: distMap['integrity'] as String?,
      dependencies: _stringMap(json['dependencies']),
      optionalDependencies: _stringMap(json['optionalDependencies']),
      peerDependencies: _stringMap(json['peerDependencies']),
      optionalPeers: _optionalPeerNames(json['peerDependenciesMeta']),
      os: _stringList(json['os']),
      cpu: _stringList(json['cpu']),
      libc: _stringList(json['libc']),
      deprecated: json['deprecated'] as String?,
      hasBin: rawBin != null,
      bin: binMap,
      // The slim packument carries `hasInstallScript` (bool) but
      // omits the actual `scripts` map. Treat that as a signal so
      // the install path knows to fall back to reading the
      // extracted `package.json` from the store.
      scripts: _stringMap(json['scripts']),
      engines: _stringMap(json['engines']),
      bundledDependencies: bundled,
      hasInstallScript: json['hasInstallScript'] == true,
      signatures: signatures,
    );
  }

  /// Slim JSON serialization, mirroring `fromJson`. Skips anything the
  /// resolver / linker doesn't read.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'version': version,
    if (tarball != null || integrity != null || signatures.isNotEmpty)
      'dist': <String, dynamic>{
        if (tarball != null) 'tarball': tarball,
        if (integrity != null) 'integrity': integrity,
        if (signatures.isNotEmpty)
          'signatures': [
            for (final s in signatures) {'keyid': s.keyid, 'sig': s.sig},
          ],
      },
    if (dependencies.isNotEmpty) 'dependencies': dependencies,
    if (optionalDependencies.isNotEmpty)
      'optionalDependencies': optionalDependencies,
    if (peerDependencies.isNotEmpty) 'peerDependencies': peerDependencies,
    if (optionalPeers.isNotEmpty)
      'peerDependenciesMeta': <String, dynamic>{
        for (final name in optionalPeers)
          name: <String, bool>{'optional': true},
      },
    if (os.isNotEmpty) 'os': os,
    if (cpu.isNotEmpty) 'cpu': cpu,
    if (libc.isNotEmpty) 'libc': libc,
    if (deprecated != null) 'deprecated': deprecated,
    if (bin.isNotEmpty) 'bin': bin,
    if (scripts.isNotEmpty) 'scripts': scripts,
    if (engines.isNotEmpty) 'engines': engines,
    if (bundledDependencies.isNotEmpty)
      'bundledDependencies': bundledDependencies,
    if (hasInstallScript) 'hasInstallScript': true,
  };

  final String name;
  final String version;
  final String? tarball;
  final String? integrity;
  final Map<String, String> dependencies;
  final Map<String, String> optionalDependencies;
  final Map<String, String> peerDependencies;

  /// Subset of `peerDependencies` names that the package marks
  /// `peerDependenciesMeta[name].optional = true`. The resolver uses
  /// this to skip forcing inclusion of peers a package treats as
  /// "use if present, ignore if absent" — vite's CSS preprocessor
  /// peers (`less`, `sass`, `stylus`, …) are the canonical example.
  final Set<String> optionalPeers;

  final List<String> os;
  final List<String> cpu;
  final List<String> libc;
  final String? deprecated;
  final bool hasBin;
  final Map<String, String> bin;
  final Map<String, String> scripts;
  final Map<String, String> engines;
  final List<String> bundledDependencies;

  /// `true` when the registry advertised that this version defines
  /// install-time lifecycle scripts. The slim packument exposes this
  /// flag without the script bodies — used by the install path to
  /// decide whether warm installs need to back-fill scripts from the
  /// store's extracted package.json.
  final bool hasInstallScript;

  /// ECDSA signatures the registry attached to this version. Each
  /// entry is `{keyid, sig}` where `sig` is base64(DER(ECDSA-Sig{r,s}))
  /// and `keyid` matches one of the registry's `/-/npm/v1/keys`
  /// entries. Consumed by `--verify-signatures` to authenticate the
  /// tarball against the registry's signing key.
  final List<DistSignature> signatures;
}

/// One `(keyid, sig)` pair as advertised by the registry in
/// `dist.signatures`.
class DistSignature {
  const DistSignature({required this.keyid, required this.sig});
  final String keyid;
  final String sig;
}

Map<String, String> _normalizeBin(Object? raw, String packageName) {
  if (raw == null) return const {};
  if (raw is String) {
    final slash = packageName.lastIndexOf('/');
    final binName = slash < 0 ? packageName : packageName.substring(slash + 1);
    return {binName: raw};
  }
  if (raw is Map) {
    return {for (final e in raw.entries) e.key as String: '${e.value}'};
  }
  return const {};
}

Map<String, String> _stringMap(Object? node) {
  if (node is! Map) return const {};
  return {for (final e in node.entries) e.key as String: '${e.value}'};
}

/// Extract the set of peer-dependency names that the package marks
/// `{optional: true}` in its `peerDependenciesMeta` block.
Set<String> _optionalPeerNames(Object? node) {
  if (node is! Map) return const {};
  final out = <String>{};
  for (final entry in node.entries) {
    final value = entry.value;
    if (value is Map && value['optional'] == true) {
      out.add(entry.key as String);
    }
  }
  return out;
}

List<String> _stringList(Object? node) {
  if (node is! List) return const [];
  return [for (final e in node) '$e'];
}
