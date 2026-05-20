import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:knot/src/archive/archive.dart';
import 'package:knot/src/core/core.dart';
import 'package:knot/src/ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'layout.dart';

final _tmpSuffixRandom = Random.secure();
int _tmpCounter = 0;

String _uniqueTmpSuffix() {
  _tmpCounter++;
  final rand = _tmpSuffixRandom.nextInt(1 << 32);
  return '$pid.$_tmpCounter.${rand.toRadixString(16)}';
}

/// Reference to a file stored under the content-addressable layout.
class StoredFile {
  StoredFile({
    required this.relativePath,
    required this.sha512Hex,
    required this.size,
    required this.mode,
  });

  final String relativePath;
  final String sha512Hex;
  final int size;
  final int mode;
}

/// Manifest emitted under `index/<aa>/<tarball-sha512>.json` after a tarball
/// is fully extracted.
class StoredTarball {
  StoredTarball({required this.files});
  final List<StoredFile> files;
}

/// Filesystem-backed content store.
class Store {
  Store(this.root) : layout = StoreLayout(root);

  final String root;
  final StoreLayout layout;

  Future<void> initialize() async {
    await Directory(layout.filesDir).create(recursive: true);
    await Directory(layout.indexDir).create(recursive: true);
    await Directory(layout.tmpDir).create(recursive: true);
  }

  Future<bool> hasTarball(String tarballSha512Hex) =>
      File(layout.indexPath(tarballSha512Hex)).exists();

  Future<StoredTarball?> readIndex(String tarballSha512Hex) async {
    final file = File(layout.indexPath(tarballSha512Hex));
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    return _parseIndex(tarballSha512Hex, raw);
  }

  /// Synchronous variant of [readIndex]. The async version's [File.exists]
  /// + [File.readAsString] each dispatch through the event loop; for the
  /// linker hot path that overhead dominates wall time.
  StoredTarball? readIndexSync(String tarballSha512Hex) {
    final file = File(layout.indexPath(tarballSha512Hex));
    if (!file.existsSync()) return null;
    return _parseIndex(tarballSha512Hex, file.readAsStringSync());
  }

  StoredTarball _parseIndex(String tarballSha512Hex, String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final files = (json['files'] as List).cast<Map<String, dynamic>>();
    return StoredTarball(
      files: [
        for (final f in files)
          StoredFile(
            relativePath: f['path'] as String,
            sha512Hex: f['sha512'] as String,
            size: f['size'] as int,
            mode: f['mode'] as int,
          ),
      ],
    );
  }

  Future<StoredTarball> ingest({
    required Directory extracted,
    required String tarballSha512Hex,
  }) async {
    await initialize();
    final files = <StoredFile>[];

    final extractedRoot = Directory(p.normalize(extracted.path));
    final entries = await extractedRoot
        .list(recursive: true, followLinks: false)
        .toList();
    for (final entry in entries) {
      if (entry is! File) continue;
      // Stream-hash the file rather than reading the full body into
      // memory. The bytes are already on disk in the extract tmp dir —
      // no reason to materialize them in the heap just to hash. The
      // post-hash step is an atomic rename onto the content-addressed
      // slot, avoiding a full-buffer rewrite.
      final hasher = IncrementalHash.forAlgorithm('sha512');
      var size = 0;
      await for (final chunk in entry.openRead()) {
        hasher.update(chunk);
        size += chunk.length;
      }
      final hex = hasher.finishHex();
      final dest = File(layout.filePath(hex));
      final stat = await entry.stat();
      // npm ships native binaries (esbuild, rollup's per-platform
      // builds, swc, …) with the exec bit set on `bin/<name>`; without
      // honoring it the first `node_modules/.bin/<x>` invocation fails
      // with EACCES. We honor *only* the exec bit — setuid/setgid in a
      // tar header are untrustworthy. The extractor already chmod'd
      // the source file, so a successful rename preserves the mode.
      final isExecutable = !Platform.isWindows && (stat.mode & 0x49) != 0;
      // Index entries persist across platforms; force forward-slash
      // separators so a tree ingested on Windows materializes
      // correctly when the same store is read on POSIX (and vice
      // versa). All consumers re-join via `p.join`, which accepts
      // either separator regardless of host OS.
      final relativePath = p.posix.joinAll(
        p.split(p.relative(entry.path, from: extractedRoot.path)),
      );
      if (!await dest.exists()) {
        await Directory(p.dirname(dest.path)).create(recursive: true);
        // POSIX rename atomically replaces dest if a concurrent ingest
        // got there first — content is identical, so either copy is
        // correct. Tmp dir and files dir share the store root so
        // EXDEV (cross-FS) is unreachable in practice.
        try {
          await entry.rename(dest.path);
        } on FileSystemException {
          // Defensive fallback for the EXDEV / permission edge case.
          final bytes = await entry.readAsBytes();
          final tmp = File('${dest.path}.tmp.${_uniqueTmpSuffix()}');
          await tmp.writeAsBytes(bytes, flush: true);
          if (isExecutable) chmodExecutable(tmp.path);
          try {
            await tmp.rename(dest.path);
          } on FileSystemException {
            if (!await dest.exists()) rethrow;
            try {
              await tmp.delete();
            } on FileSystemException {
              // tmp may have already been cleaned up.
            }
          }
        }
      } else if (isExecutable) {
        // Store entry already exists but may have been written by an
        // earlier path that didn't honor the mode bit. chmod is
        // idempotent on an already-0755 file.
        chmodExecutable(dest.path);
      }
      files.add(
        StoredFile(
          relativePath: relativePath,
          sha512Hex: hex,
          size: size,
          mode: stat.mode,
        ),
      );
    }

    final indexFile = File(layout.indexPath(tarballSha512Hex));
    await Directory(p.dirname(indexFile.path)).create(recursive: true);
    final body = jsonEncode({
      'tarball': tarballSha512Hex,
      'files': [
        for (final f in files)
          {
            'path': f.relativePath,
            'sha512': f.sha512Hex,
            'size': f.size,
            'mode': f.mode,
          },
      ],
    });
    final tmp = File('${indexFile.path}.tmp.${_uniqueTmpSuffix()}');
    await tmp.writeAsString(body, flush: true);
    try {
      await tmp.rename(indexFile.path);
    } on FileSystemException {
      if (!await indexFile.exists()) rethrow;
      try {
        await tmp.delete();
      } on FileSystemException {
        // ignore
      }
    }

    // Build the ready-to-clone extracted tree under `extracted/<sha>/`.
    // Each file inside is a hardlink onto its `files/<contentHash>` twin
    // so the tree costs no extra disk space. Materializing the package
    // into `node_modules/<name>` later is then a single recursive
    // `clonefile(2)` on macOS (or per-file hardlink elsewhere).
    await _populateExtracted(tarballSha512Hex, files);

    return StoredTarball(files: files);
  }

  Future<void> _populateExtracted(
    String tarballSha512Hex,
    List<StoredFile> files,
  ) async {
    final extractedRoot = Directory(
      layout.extractedPackageDir(tarballSha512Hex),
    );
    if (extractedRoot.existsSync()) return;
    final stagingRoot = Directory(
      '${extractedRoot.path}.tmp.${_uniqueTmpSuffix()}',
    );
    stagingRoot.createSync(recursive: true);
    try {
      final mkdirs = <String>{};
      for (final f in files) {
        mkdirs.add(p.dirname(p.join(stagingRoot.path, f.relativePath)));
      }
      for (final d in mkdirs) {
        Directory(d).createSync(recursive: true);
      }
      for (final f in files) {
        final dst = p.join(stagingRoot.path, f.relativePath);
        if (File(dst).existsSync()) continue;
        hardlinkOrCopySync(source: layout.filePath(f.sha512Hex), target: dst);
      }
      Directory(p.dirname(extractedRoot.path)).createSync(recursive: true);
      try {
        stagingRoot.renameSync(extractedRoot.path);
      } on FileSystemException {
        // Lost the race: another ingest of the same tarball won.
        try {
          stagingRoot.deleteSync(recursive: true);
        } on FileSystemException {
          // best-effort
        }
      }
    } catch (_) {
      try {
        stagingRoot.deleteSync(recursive: true);
      } on FileSystemException {
        // best-effort
      }
      rethrow;
    }
  }

  Future<StoredTarball> ingestTarball({
    required Uint8List bytes,
    required String tarballSha512Hex,
  }) async {
    await initialize();
    if (await hasTarball(tarballSha512Hex)) {
      return (await readIndex(tarballSha512Hex))!;
    }
    final tmp = await Directory(layout.tmpDir).createTemp('ext-');
    try {
      final extractor = TarExtractor();
      await extractor.extract(Stream.value(bytes), destination: tmp.path);
      return await ingest(extracted: tmp, tarballSha512Hex: tarballSha512Hex);
    } finally {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // tmp may already be cleaned up by another runner.
      }
    }
  }
}
