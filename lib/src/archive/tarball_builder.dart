import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knot/src/core/core.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

/// Build an npm-publishable tarball.
///
/// Honors the `files` field in `package.json` (if present) and falls back to
/// `.npmignore` / `.gitignore`. Output is a gzipped tar with every entry
/// nested under `package/`.
class TarballBuilder {
  TarballBuilder({required this.projectRoot, this.includeList});

  final String projectRoot;

  /// Explicit list of paths to include (overrides the `files` field).
  final List<String>? includeList;

  Future<Uint8List> build() async {
    final pkgJson = File(p.join(projectRoot, 'package.json'));
    if (!pkgJson.existsSync()) {
      throw UsageError('no package.json at $projectRoot');
    }
    final included = await _resolveIncluded();

    final entries = <TarEntry>[];
    for (final relative in included) {
      final fullPath = p.join(projectRoot, relative);
      final file = File(fullPath);
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      final stat = file.statSync();
      entries.add(
        TarEntry.data(
          TarHeader(
            name: 'package/$relative',
            mode: stat.mode,
            size: bytes.length,
            modified: stat.modified,
          ),
          bytes,
        ),
      );
    }

    final stream = Stream<TarEntry>.fromIterable(entries).transform(tarWriter);
    final gz = stream.transform(gzip.encoder);
    final buf = BytesBuilder(copy: false);
    await for (final chunk in gz) {
      buf.add(chunk);
    }
    return buf.toBytes();
  }

  Future<List<String>> _resolveIncluded() async {
    if (includeList != null) return includeList!;
    final pkg = jsonDecode(
      await File(p.join(projectRoot, 'package.json')).readAsString(),
    );
    if (pkg is Map && pkg['files'] is List) {
      return (pkg['files'] as List).cast<String>();
    }
    // Fallback: include everything except common ignores.
    final out = <String>[];
    final root = Directory(projectRoot);
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final rel = p.relative(entry.path, from: projectRoot);
      if (_isIgnored(rel)) continue;
      out.add(rel);
    }
    return out;
  }

  bool _isIgnored(String rel) {
    const ignoredPrefixes = ['node_modules/', '.git/', '.knot/', 'tmp/'];
    if (ignoredPrefixes.any(rel.startsWith)) return true;
    if (rel == '.gitignore' || rel == '.npmignore') return true;
    return false;
  }
}
