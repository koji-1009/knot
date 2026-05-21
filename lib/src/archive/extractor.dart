import 'dart:async';
import 'dart:io';

import 'package:knot/src/ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

import 'sanitize.dart';

/// Streamed npm tarball extractor.
///
/// Strips the leading `package/` directory and writes each remaining entry
/// under `destination`. Path traversal is rejected via `ArchiveSanitizer`.
class TarExtractor {
  TarExtractor();

  /// Extract a gzipped tar [stream] (raw tarball bytes) into [destination].
  ///
  /// Returns metadata about each emitted file. Symbolic links are recorded
  /// but not materialized — the store treats them as advisory.
  Future<List<ExtractedEntry>> extract(
    Stream<List<int>> stream, {
    required String destination,
  }) async {
    await Directory(destination).create(recursive: true);
    final reader = TarReader(
      stream.transform(gzip.decoder),
      disallowTrailingData: true,
    );
    final sanitizer = ArchiveSanitizer(destination);
    final emitted = <ExtractedEntry>[];
    while (await reader.moveNext()) {
      final entry = reader.current;
      final stripped = _stripPackagePrefix(entry.name);
      if (stripped.isEmpty) continue;

      switch (entry.type) {
        case TypeFlag.dir:
          final dest = sanitizer.resolve(stripped);
          await Directory(dest).create(recursive: true);
          continue;
        case TypeFlag.symlink:
        case TypeFlag.link:
          emitted.add(
            ExtractedEntry.link(
              relativePath: stripped,
              target: entry.header.linkName ?? '',
            ),
          );
          continue;
        default:
          break;
      }
      final dest = sanitizer.resolve(stripped);
      await Directory(p.dirname(dest)).create(recursive: true);
      final size = await _writeFile(entry.contents, File(dest));
      // Preserve the executable bit from the tar header. Without
      // this, native binaries shipped via npm (esbuild, rollup's
      // per-platform `bin/`, swc, etc.) extract as 0644 and the
      // first `node_modules/.bin/<x>` invocation fails with EACCES.
      // We only honor the *executable* bit; setuid/setgid in the
      // header are untrustworthy from a tarball and would be a
      // privilege-escalation lever if we applied them verbatim.
      if (!Platform.isWindows && (entry.header.mode & 0x49) != 0) {
        chmodExecutable(dest);
      }
      emitted.add(
        ExtractedEntry.file(
          relativePath: stripped,
          absolutePath: dest,
          size: size,
        ),
      );
    }
    return emitted;
  }

  Future<int> _writeFile(Stream<List<int>> source, File target) async {
    final sink = target.openWrite();
    var written = 0;
    try {
      // Pass each chunk through verbatim — do NOT pool a single
      // Uint8List buffer and forward `sublistView`s into the sink.
      // `sink.add` is async; the buffer gets overwritten before the
      // previous slice has drained and large files corrupt.
      await for (final chunk in source) {
        sink.add(chunk);
        written += chunk.length;
      }
    } finally {
      await sink.close();
    }
    return written;
  }
}

String _stripPackagePrefix(String name) {
  const prefix = 'package/';
  if (name.startsWith(prefix)) return name.substring(prefix.length);
  return name;
}

/// Metadata about an extracted tarball entry.
class ExtractedEntry {
  const ExtractedEntry.file({
    required this.relativePath,
    required this.absolutePath,
    required this.size,
  }) : target = null,
       isLink = false;

  const ExtractedEntry.link({
    required this.relativePath,
    required String this.target,
  }) : absolutePath = null,
       size = 0,
       isLink = true;

  final String relativePath;
  final String? absolutePath;
  final int size;
  final bool isLink;
  final String? target;
}
