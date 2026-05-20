/// Schema version emitted by this build's lockfile writer.
const int knotLockfileVersion = 1;

/// In-memory representation of a `package-lock.json` (npm v3) file.
class Lockfile {
  Lockfile({
    required this.lockfileVersion,
    required Map<String, Importer> importers,
    required Map<String, LockedPackage> packages,
  }) : importers = Map.unmodifiable(importers),
       packages = Map.unmodifiable(packages),
       snapshots = Map.unmodifiable({
         for (final entry in packages.entries)
           if (entry.value.integrity != null)
             entry.value.integrity!: entry.value,
       });

  final int lockfileVersion;
  final Map<String, Importer> importers;
  final Map<String, LockedPackage> packages;
  final Map<String, LockedPackage> snapshots;
}

/// Direct dependency selectors declared by a workspace member.
class Importer {
  const Importer({
    this.dependencies = const {},
    this.devDependencies = const {},
    this.optionalDependencies = const {},
    this.peerDependencies = const {},
  });

  final Map<String, String> dependencies;
  final Map<String, String> devDependencies;
  final Map<String, String> optionalDependencies;
  final Map<String, String> peerDependencies;
}

class LockedPackage {
  const LockedPackage({
    required this.name,
    required this.version,
    required this.resolution,
    this.integrity,
    this.dependencies = const {},
    this.optionalDependencies = const {},
    this.peerDependencies = const {},
    this.peerDependenciesMeta = const {},
    this.os = const [],
    this.cpu = const [],
    this.hasBin = false,
    this.hasInstallScript = false,
    this.bin = const {},
    this.scripts = const {},
    this.engines = const {},
    this.signatures = const [],
  });

  final String name;
  final String version;
  final Resolution resolution;
  final String? integrity;
  final Map<String, String> dependencies;
  final Map<String, String> optionalDependencies;
  final Map<String, String> peerDependencies;
  final Map<String, PeerDependencyMeta> peerDependenciesMeta;
  final List<String> os;
  final List<String> cpu;
  final bool hasBin;

  /// Mirrors the slim packument's `hasInstallScript` flag. When the
  /// flag is set but [scripts] is empty in the lockfile (slim format
  /// omits the script bodies), the install path reads the actual
  /// scripts from the store's extracted `package.json`.
  final bool hasInstallScript;

  /// `bin` map from the package's `package.json` (executable name →
  /// path inside the package). Cached here so the warm-install path
  /// can build `.bin` shims without re-reading every package's
  /// `package.json` from the store — 17 ms across 58 packages on
  /// `vite-react` before this was inlined.
  final Map<String, String> bin;
  final Map<String, String> scripts;
  final Map<String, String> engines;

  /// Registry-attached ECDSA signatures, persisted so warm installs
  /// can re-verify a freshly downloaded tarball against the same key
  /// material the lockfile was written under. Stored as a list of
  /// `(keyid, sig)` pairs — `sig` is base64(DER) exactly as the
  /// registry advertised it.
  final List<LockedSignature> signatures;
}

class LockedSignature {
  const LockedSignature({required this.keyid, required this.sig});
  final String keyid;
  final String sig;
}

class Resolution {
  const Resolution.tarball({required this.tarball});

  final String? tarball;
}

class PeerDependencyMeta {
  const PeerDependencyMeta({this.optional = false});
  final bool optional;
}
