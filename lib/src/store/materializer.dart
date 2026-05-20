import 'dart:io';

import 'package:knot/src/ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'impl.dart';
import 'worker_pool.dart';

/// Materialize a stored package tree into the project's `node_modules`.
///
/// Each platform picks the fastest primitive available:
/// - macOS: recursive APFS `clonefile(2)` — one syscall per package.
/// - Linux / Windows: per-file `link(2)` / `CreateHardLink` via a worker
///   pool — APFS's whole-tree clone is unique to that filesystem.
///
/// `materialize` is expected to leave the destination at `dest` as a
/// faithful copy of the package tree at `store/v1/extracted/<integrity>`.
abstract class StoreMaterializer {
  StoreMaterializer();

  /// Materialize the package identified by [integrity] to [dest].
  /// [dest] must not already exist.
  Future<void> materialize({required String integrity, required String dest});

  /// Materialize many packages. The default implementation maps over
  /// [materialize] sequentially; the macOS path overrides this to push
  /// `clonefile(2)` calls into the [WorkerPool] so the syscalls actually
  /// run in parallel (a `package:pool` semaphore on the main isolate
  /// can't parallelize synchronous FFI).
  Future<void> materializeAll(List<MaterializeTask> tasks) async {
    for (final task in tasks) {
      await materialize(integrity: task.integrity, dest: task.dest);
    }
  }

  /// Pick the right implementation for the running OS.
  factory StoreMaterializer.forPlatform(
    Store store, {
    required WorkerPool workerPool,
  }) {
    if (Platform.isMacOS && clonefileSupported) {
      return _MacosMaterializer(store, workerPool);
    }
    return _PerFileMaterializer(store, workerPool);
  }
}

/// One package to materialize into [dest], identified by [integrity].
class MaterializeTask {
  const MaterializeTask({required this.integrity, required this.dest});
  final String integrity;
  final String dest;
}

/// macOS path: one `clonefile(extracted/<integrity>, dest, 0)` syscall.
/// Falls back to per-file hardlinks on `EXDEV` (cross-volume).
class _MacosMaterializer extends StoreMaterializer {
  _MacosMaterializer(this._store, this._fallbackPool);
  final Store _store;
  final WorkerPool _fallbackPool;

  @override
  Future<void> materialize({
    required String integrity,
    required String dest,
  }) async {
    final source = _store.layout.extractedPackageDir(integrity);
    if (!Directory(source).existsSync()) {
      // The store may have been populated by an older knot version that
      // didn't write the extracted layer. Fall back to per-file linking.
      await _PerFileMaterializer(
        _store,
        _fallbackPool,
      ).materialize(integrity: integrity, dest: dest);
      return;
    }
    Directory(p.dirname(dest)).createSync(recursive: true);
    try {
      clonefileSync(source: source, target: dest);
    } on Object {
      // EXDEV or any other failure: rebuild via per-file hardlink.
      if (Directory(dest).existsSync()) {
        Directory(dest).deleteSync(recursive: true);
      }
      await _PerFileMaterializer(
        _store,
        _fallbackPool,
      ).materialize(integrity: integrity, dest: dest);
    }
  }

  @override
  Future<void> materializeAll(List<MaterializeTask> tasks) async {
    // Split: packages whose extracted/ tree exists go through the
    // parallel clone batch; the (rare) leftovers go through the
    // single-task path, which itself falls back to per-file hardlink.
    final mkdirs = <String>{};
    final clones = <CloneTask>[];
    final fallback = <MaterializeTask>[];
    for (final task in tasks) {
      final source = _store.layout.extractedPackageDir(task.integrity);
      if (!Directory(source).existsSync()) {
        fallback.add(task);
        continue;
      }
      mkdirs.add(p.dirname(task.dest));
      clones.add(
        CloneTask(integrity: task.integrity, source: source, target: task.dest),
      );
    }
    if (clones.isNotEmpty) {
      await _fallbackPool.cloneAll(mkdirs: mkdirs, tasks: clones);
    }
    for (final task in fallback) {
      await materialize(integrity: task.integrity, dest: task.dest);
    }
  }
}

/// Generic path: read the store manifest and hardlink every file via
/// the worker pool. Used on Linux, Windows, and as the macOS fallback
/// when `clonefile` fails (e.g. cross-volume).
class _PerFileMaterializer extends StoreMaterializer {
  _PerFileMaterializer(this._store, this._workerPool);
  final Store _store;
  final WorkerPool _workerPool;

  @override
  Future<void> materialize({
    required String integrity,
    required String dest,
  }) async {
    final manifest = _store.readIndexSync(integrity);
    if (manifest == null) {
      throw StateError('no store index for $integrity');
    }
    Directory(dest).createSync(recursive: true);
    final mkdirs = <String>{};
    final tasks = <LinkTask>[];
    for (final file in manifest.files) {
      final target = p.join(dest, file.relativePath);
      mkdirs.add(p.dirname(target));
      tasks.add(LinkTask(_store.layout.filePath(file.sha512Hex), target));
    }
    await _workerPool.linkAll(mkdirs: mkdirs, tasks: tasks);
  }
}
