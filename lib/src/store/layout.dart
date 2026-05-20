import 'package:path/path.dart' as p;

/// Filesystem layout helpers for the content-addressable store.
///
/// Layout:
/// ```
/// <root>/v1/files/<aa>/<sha512>
/// <root>/v1/index/<aa>/<sha512>.json
/// <root>/v1/extracted/<aa>/<sha512>/<package files…>
/// <root>/v1/tmp/
/// ```
///
/// `extracted/` holds a ready-to-clone directory tree per tarball. Each
/// file inside is a hardlink onto its dedup-by-content twin in `files/`,
/// so the per-package tree costs no extra disk space. Materializing a
/// package into `node_modules/<name>` becomes a single recursive
/// `clonefile(2)` on macOS or a `cp -R --link` equivalent on other OSes.
class StoreLayout {
  StoreLayout(this.root);

  /// Root directory of the store (e.g. `~/.knot/store`).
  final String root;

  String get version => 'v1';

  String get base => p.join(root, version);
  String get filesDir => p.join(base, 'files');
  String get indexDir => p.join(base, 'index');
  String get extractedDir => p.join(base, 'extracted');
  String get tmpDir => p.join(base, 'tmp');

  String filePath(String sha512Hex) =>
      p.join(filesDir, _prefix(sha512Hex), sha512Hex);

  String indexPath(String sha512Hex) =>
      p.join(indexDir, _prefix(sha512Hex), '$sha512Hex.json');

  /// Directory holding the ready-to-clone extracted tree for the tarball
  /// identified by [sha512Hex] (the tarball's integrity hash).
  String extractedPackageDir(String sha512Hex) =>
      p.join(extractedDir, _prefix(sha512Hex), sha512Hex);

  String _prefix(String hex) => hex.length >= 2 ? hex.substring(0, 2) : 'xx';
}
