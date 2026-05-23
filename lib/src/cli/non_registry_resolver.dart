import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/core/core.dart';
import 'package:knot/src/linker/linker.dart';
import 'package:knot/src/archive/archive.dart';
import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;

import 'dependency_spec.dart';
import 'package_json.dart';

/// Outcome of resolving a non-registry [DependencySpec]: either a
/// [LinkSpec] backed by the store, or a direct symlink path (for `link:`).
class NonRegistryResolution {
  NonRegistryResolution.store(this.linkSpec) : directSymlinkTarget = null;
  NonRegistryResolution.link({
    required this.linkSpec,
    required this.directSymlinkTarget,
  });

  /// LinkSpec carrying the package's identity. For `link:` resolutions the
  /// store-backed parts (sha512, tarball) are zero-sized placeholders.
  final LinkSpec linkSpec;

  /// When non-null, the linker should `node_modules/<name>` directly to
  /// this target path instead of materializing from the store.
  final String? directSymlinkTarget;
}

/// Resolves `file:`, `link:`, `https:`, and `git+`/`github:` dependency
/// specifiers into materialized packages, returning a list of
/// [NonRegistryResolution]s ready for the linker.
class NonRegistryResolver {
  NonRegistryResolver({required this.projectRoot, required this.store})
    : _http = HttpClient()..idleTimeout = const Duration(seconds: 30);

  final String projectRoot;
  final Store store;
  final HttpClient _http;

  void close() {
    _http.close(force: true);
  }

  Future<NonRegistryResolution> resolve(DependencySpec spec) =>
      switch (spec.protocol) {
        SpecifierProtocol.file => _resolveFile(spec),
        SpecifierProtocol.link => _resolveLink(spec),
        SpecifierProtocol.https => _resolveHttps(spec),
        SpecifierProtocol.git => _resolveGit(spec),
        SpecifierProtocol.semver ||
        SpecifierProtocol.workspace ||
        SpecifierProtocol.catalog => throw StateError(
          'NonRegistryResolver received a ${spec.protocol.name} spec',
        ),
      };

  // ---- file: ------------------------------------------------------------
  Future<NonRegistryResolution> _resolveFile(DependencySpec spec) async {
    final absPath = _absolute(spec.range);
    final pkgJson = await PackageJson.read(p.join(absPath, 'package.json'));
    final builder = TarballBuilder(projectRoot: absPath);
    final bytes = await builder.build();
    final sha = _sha512(bytes);
    await store.ingestTarball(bytes: bytes, tarballSha512Hex: sha);
    return NonRegistryResolution.store(
      LinkSpec(
        name: pkgJson.name.isEmpty ? spec.logicalName : pkgJson.name,
        version: pkgJson.version,
        tarballSha512Hex: sha,
        dependencies: const {},
        bin: pkgJson.bin,
        scripts: pkgJson.scripts,
        isDirect: true,
        linkAlias: spec.logicalName != pkgJson.name ? spec.logicalName : null,
        engines: pkgJson.engines,
      ),
    );
  }

  // ---- link: ------------------------------------------------------------
  Future<NonRegistryResolution> _resolveLink(DependencySpec spec) async {
    final absPath = _absolute(spec.range);
    final pkgJson = await PackageJson.read(p.join(absPath, 'package.json'));
    return NonRegistryResolution.link(
      linkSpec: LinkSpec(
        name: pkgJson.name.isEmpty ? spec.logicalName : pkgJson.name,
        version: pkgJson.version,
        tarballSha512Hex: '',
        dependencies: const {},
        bin: pkgJson.bin,
        scripts: pkgJson.scripts,
        isDirect: true,
        linkAlias: spec.logicalName != pkgJson.name ? spec.logicalName : null,
        engines: pkgJson.engines,
      ),
      directSymlinkTarget: absPath,
    );
  }

  // ---- https tarball ----------------------------------------------------
  Future<NonRegistryResolution> _resolveHttps(DependencySpec spec) async {
    final url = spec.url ?? '';
    if (url.isEmpty) {
      throw UsageError('https specifier missing URL: ${spec.logicalName}');
    }
    final uri = Uri.parse(url);
    final bytes = await _getBytes(uri);
    final sha = _sha512(bytes);
    await store.ingestTarball(bytes: bytes, tarballSha512Hex: sha);

    // Read the tarball's `package/package.json` after ingestion via the
    // store layout — simpler: re-extract package.json from the manifest.
    final manifest = await store.readIndex(sha);
    String name = spec.logicalName;
    String version = '0.0.0';
    Map<String, String> bin = const {};
    Map<String, String> scripts = const {};
    if (manifest != null) {
      for (final f in manifest.files) {
        if (f.relativePath == 'package.json') {
          final bodyBytes = await File(
            store.layout.filePath(f.sha512Hex),
          ).readAsBytes();
          final json = jsonDecode(utf8.decode(bodyBytes));
          if (json is Map) {
            final m = Map<String, dynamic>.from(json);
            final parsed = PackageJson.fromJson(m);
            if (parsed.name.isNotEmpty) name = parsed.name;
            if (parsed.version.isNotEmpty) version = parsed.version;
            bin = parsed.bin;
            scripts = parsed.scripts;
          }
          break;
        }
      }
    }
    return NonRegistryResolution.store(
      LinkSpec(
        name: name,
        version: version,
        tarballSha512Hex: sha,
        dependencies: const {},
        bin: bin,
        scripts: scripts,
        isDirect: true,
        linkAlias: spec.logicalName != name ? spec.logicalName : null,
      ),
    );
  }

  // ---- git / github: ----------------------------------------------------
  Future<NonRegistryResolution> _resolveGit(DependencySpec spec) async {
    final (gitUrl, ref) = _parseGitSpec(spec.url ?? spec.range);
    final tmp = await Directory.systemTemp.createTemp('knot-git-');
    try {
      final cloneArgs = ['clone', '--depth', '1', gitUrl, tmp.path];
      final clone = await Process.run('git', cloneArgs);
      if (clone.exitCode != 0) {
        throw NetworkError(
          'git clone $gitUrl failed: ${clone.stderr}',
          uri: Uri.parse(gitUrl),
        );
      }
      if (ref != null) {
        final fetch = await Process.run('git', [
          'fetch',
          '--depth',
          '1',
          'origin',
          ref,
        ], workingDirectory: tmp.path);
        if (fetch.exitCode == 0) {
          await Process.run('git', [
            'checkout',
            'FETCH_HEAD',
          ], workingDirectory: tmp.path);
        }
      }
      final builder = TarballBuilder(projectRoot: tmp.path);
      final bytes = await builder.build();
      final sha = _sha512(bytes);
      await store.ingestTarball(bytes: bytes, tarballSha512Hex: sha);
      final pkgJson = await PackageJson.read(p.join(tmp.path, 'package.json'));
      return NonRegistryResolution.store(
        LinkSpec(
          name: pkgJson.name.isEmpty ? spec.logicalName : pkgJson.name,
          version: pkgJson.version,
          tarballSha512Hex: sha,
          dependencies: const {},
          bin: pkgJson.bin,
          scripts: pkgJson.scripts,
          isDirect: true,
          linkAlias: spec.logicalName != pkgJson.name ? spec.logicalName : null,
        ),
      );
    } finally {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // ignore
      }
    }
  }

  (String, String?) _parseGitSpec(String raw) {
    var url = raw;
    if (url.startsWith('git+')) url = url.substring(4);
    if (url.startsWith('github:')) {
      final body = url.substring(7);
      final hash = body.indexOf('#');
      final repo = hash < 0 ? body : body.substring(0, hash);
      final ref = hash < 0 ? null : body.substring(hash + 1);
      return ('https://github.com/$repo.git', ref);
    }
    final hash = url.indexOf('#');
    if (hash >= 0) {
      return (url.substring(0, hash), url.substring(hash + 1));
    }
    return (url, null);
  }

  String _absolute(String pathLike) {
    if (p.isAbsolute(pathLike)) return p.normalize(pathLike);
    return p.normalize(p.join(projectRoot, pathLike));
  }

  String _sha512(Uint8List bytes) => KnotHash.sha512Hex(bytes);

  Future<Uint8List> _getBytes(Uri uri) async {
    final request = await _http.getUrl(uri);
    final response = await request.close();
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw NetworkError(
        'GET $uri failed (${response.statusCode})',
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
