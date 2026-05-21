import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:knot/src/ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'impl.dart';

/// Shared worker-isolate pool for all CPU- or syscall-bound work in an
/// install: tarball ingest (gzip + tar + sha512) and hardlink batches.
///
/// Why a single pool?
/// - Earlier drafts kept two pools, one per concern. Each install paid the
///   ~200 ms isolate-spawn cost twice. They never run concurrently in
///   practice (ingest happens during fetch phase, link happens after) so
///   one pool sized to `numberOfProcessors` is enough.
/// - Mixing `package:pool` (concurrency limiter inside main isolate) with
///   FFI work confused two distinct concerns. Pool throttles awaitables;
///   it doesn't unblock the isolate thread that FFI sits on. This pool
///   handles the actual parallelism; the main isolate keeps `package:pool`
///   only for HTTP request count limiting.
class WorkerPool {
  WorkerPool._(this._workers);

  final List<_Worker> _workers;
  final Queue<_Worker> _idle = Queue();
  final Queue<Completer<_Worker>> _waiting = Queue();
  bool _disposed = false;

  static Future<WorkerPool> spawn({
    required String storeRoot,
    required int size,
  }) async {
    // Spawn all isolates in parallel. The serial `for (await spawn)` form
    // multiplied isolate-creation latency by `size` — measured ~200 ms on
    // an 8-core macOS box. Parallel spawn keeps it to one isolate's
    // worth of latency.
    final workers = await Future.wait([
      for (var i = 0; i < size; i++) _Worker.spawn(storeRoot),
    ]);
    final pool = WorkerPool._(workers);
    pool._idle.addAll(workers);
    return pool;
  }

  /// Run `Store.ingestTarball` on a worker.
  Future<StoredTarball> ingest({
    required Uint8List bytes,
    required String tarballSha512Hex,
  }) async {
    final w = await _acquire();
    try {
      return await w.ingest(bytes, tarballSha512Hex);
    } finally {
      _release(w);
    }
  }

  /// Recursive `clonefile(2)` calls in parallel across worker isolates.
  /// `mkdirs` are pre-created on the main isolate so workers never race
  /// on `mkdir` of the same parent directory.
  ///
  /// Each worker falls back to per-file hardlink (using the store's
  /// index) if `clonefile` returns EXDEV — that's the only failure mode
  /// we expect in practice (source and target on different volumes).
  ///
  /// Why workers? `clonefileSync` is a synchronous FFI call, so a `Pool`
  /// on the main isolate cannot run them in parallel — each call blocks
  /// the event loop. Running 58 packages serially on a single isolate
  /// dominated the warm-install hot path (~63 ms). Pushing the syscalls
  /// to N isolates lets the kernel actually overlap them.
  ///
  /// Tasks are dispatched **dynamically** — each worker pulls the next
  /// task from a shared queue when it finishes the previous one. Static
  /// round-robin assignment left fast workers idle while a few slow
  /// workers (the ones that drew `@types/node`, `vite`, `rollup`, etc.)
  /// were still inside clonefile.
  Future<void> cloneAll({
    required Iterable<String> mkdirs,
    required List<CloneTask> tasks,
  }) async {
    final profile = Platform.environment['KNOT_PROFILE'] == '1';
    final phase = Stopwatch()..start();
    void mark(String label) {
      if (!profile) return;
      // ignore: avoid_print
      print('      POOL $label: ${phase.elapsedMilliseconds}ms');
      phase.reset();
    }

    for (final dir in mkdirs) {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
    }
    mark('mkdirs');
    if (tasks.isEmpty) return;

    final queue = Queue<CloneTask>.from(tasks);
    final n = _workers.length;

    // Send each worker one task at a time. Small batch IPC overhead
    // (~10–20 µs per round-trip) is comfortably below the per-task
    // clonefile cost (~1 ms), so dynamic dispatch is a clear win
    // over batched round-robin for skewed task durations.
    Future<void> drain(_Worker w) async {
      while (queue.isNotEmpty) {
        final task = queue.removeFirst();
        await w.cloneBatch([task]);
      }
    }

    await Future.wait([for (var i = 0; i < n; i++) drain(_workers[i])]);
    mark('${tasks.length} clonefiles across $n workers (dynamic dispatch)');
  }

  /// Hardlink (or copy on failure) the given file pairs in parallel
  /// across workers. `mkdirs` are pre-created on the main isolate so
  /// nested-directory races between workers never happen.
  ///
  /// Below [inProcessThreshold] tasks the work runs synchronously in the
  /// main isolate — the per-worker round-trip cost dominates when the
  /// batch is small.
  Future<void> linkAll({
    required Iterable<String> mkdirs,
    required List<LinkTask> tasks,
    int inProcessThreshold = 200,
  }) async {
    final profile = Platform.environment['KNOT_PROFILE'] == '1';
    final phase = Stopwatch()..start();
    void mark(String label) {
      if (!profile) return;
      // ignore: avoid_print
      print('      POOL $label: ${phase.elapsedMilliseconds}ms');
      phase.reset();
    }

    for (final dir in mkdirs) {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
    }
    mark('mkdirs');
    if (tasks.isEmpty) return;

    if (tasks.length < inProcessThreshold) {
      for (final t in tasks) {
        hardlinkOrCopySync(source: t.source, target: t.target);
      }
      mark('${tasks.length} hardlinks in-process');
      return;
    }

    final n = _workers.length;
    final batches = List.generate(n, (_) => <LinkTask>[]);
    for (var i = 0; i < tasks.length; i++) {
      batches[i % n].add(tasks[i]);
    }
    await Future.wait([
      for (var i = 0; i < n; i++)
        if (batches[i].isNotEmpty) _workers[i].linkBatch(batches[i]),
    ]);
    mark('${tasks.length} hardlinks across $n workers');
  }

  Future<_Worker> _acquire() {
    if (_disposed) {
      return Future.error(StateError('WorkerPool is disposed'));
    }
    if (_idle.isNotEmpty) return Future.value(_idle.removeFirst());
    final c = Completer<_Worker>();
    _waiting.add(c);
    return c.future;
  }

  void _release(_Worker w) {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(w);
    } else {
      _idle.add(w);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final w in _workers) {
      w.close();
    }
    _idle.clear();
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completeError(StateError('WorkerPool disposed'));
    }
  }
}

/// One hardlink target.
class LinkTask {
  const LinkTask(this.source, this.target);
  final String source;
  final String target;
}

/// One `clonefile(2)` target. Worker falls back to per-file hardlinking
/// the package referenced by [integrity] when the syscall fails.
class CloneTask {
  const CloneTask({
    required this.integrity,
    required this.source,
    required this.target,
  });
  final String integrity;
  final String source;
  final String target;
}

// --- worker side ----------------------------------------------------------

class _Worker {
  _Worker._(this._sendPort, this._isolate);
  final SendPort _sendPort;
  final Isolate _isolate;
  final List<ReceivePort> _pending = [];

  static Future<_Worker> spawn(String storeRoot) async {
    final boot = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      _BootMsg(storeRoot, boot.sendPort),
      debugName: 'knot-worker',
    );
    final firstMsg = await boot.first;
    boot.close();
    if (firstMsg is _Err) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError(
        'knot worker isolate failed to start: ${firstMsg.message}',
      );
    }
    return _Worker._(firstMsg as SendPort, isolate);
  }

  Future<Object?> _send(_WorkerMsg Function(SendPort) build) async {
    final reply = ReceivePort();
    _pending.add(reply);
    try {
      _sendPort.send(build(reply.sendPort));
      return await reply.first;
    } finally {
      _pending.remove(reply);
      reply.close();
    }
  }

  Future<StoredTarball> ingest(Uint8List bytes, String sha) async {
    final response = await _send(
      (sendPort) =>
          _IngestMsg(TransferableTypedData.fromList([bytes]), sha, sendPort),
    );
    if (response is _Err) {
      throw StateError('worker ingest failed: ${response.message}');
    }
    return response as StoredTarball;
  }

  Future<void> linkBatch(List<LinkTask> tasks) async {
    final response = await _send((sendPort) => _LinkBatchMsg(tasks, sendPort));
    if (response is _Err) {
      throw StateError('worker link batch failed: ${response.message}');
    }
  }

  Future<void> cloneBatch(List<CloneTask> tasks) async {
    final response = await _send((sendPort) => _CloneBatchMsg(tasks, sendPort));
    if (response is _Err) {
      throw StateError('worker clone batch failed: ${response.message}');
    }
  }

  void close() {
    for (final p in _pending) {
      p.close();
    }
    _pending.clear();
    _isolate.kill(priority: Isolate.immediate);
  }
}

sealed class _WorkerMsg {}

class _BootMsg {
  _BootMsg(this.storeRoot, this.replyTo);
  final String storeRoot;
  final SendPort replyTo;
}

class _IngestMsg implements _WorkerMsg {
  _IngestMsg(this.bytes, this.tarballSha, this.replyTo);
  final TransferableTypedData bytes;
  final String tarballSha;
  final SendPort replyTo;
}

class _LinkBatchMsg implements _WorkerMsg {
  _LinkBatchMsg(this.tasks, this.replyTo);
  final List<LinkTask> tasks;
  final SendPort replyTo;
}

class _CloneBatchMsg implements _WorkerMsg {
  _CloneBatchMsg(this.tasks, this.replyTo);
  final List<CloneTask> tasks;
  final SendPort replyTo;
}

class _Err {
  _Err(this.message);
  final String message;
}

Future<void> _workerMain(_BootMsg boot) async {
  final Store store;
  try {
    store = Store(boot.storeRoot);
    await store.initialize();
  } on Object catch (e) {
    boot.replyTo.send(_Err('$e'));
    return;
  }
  final mailbox = ReceivePort();
  boot.replyTo.send(mailbox.sendPort);
  await for (final msg in mailbox) {
    switch (msg) {
      case final _IngestMsg m:
        try {
          final bytes = m.bytes.materialize().asUint8List();
          final result = await store.ingestTarball(
            bytes: bytes,
            tarballSha512Hex: m.tarballSha,
          );
          m.replyTo.send(result);
        } on Object catch (e) {
          m.replyTo.send(_Err('$e'));
        }
      case final _LinkBatchMsg m:
        try {
          for (final t in m.tasks) {
            hardlinkOrCopySync(source: t.source, target: t.target);
          }
          m.replyTo.send(true);
        } on Object catch (e) {
          m.replyTo.send(_Err('$e'));
        }
      case final _CloneBatchMsg m:
        try {
          for (final t in m.tasks) {
            try {
              clonefileSync(source: t.source, target: t.target);
            } on Object {
              // EXDEV or other non-recoverable clone failure: rebuild
              // this package's tree via per-file hardlink using the
              // store's index (the same fallback the main-isolate path
              // used before this batched path existed).
              _perFileFallback(store, t.integrity, t.target);
            }
          }
          m.replyTo.send(true);
        } on Object catch (e) {
          m.replyTo.send(_Err('$e'));
        }
    }
  }
}

/// Per-file hardlink fallback used when a worker's `clonefile` fails.
/// Lives at top level so the worker isolate can reach it; mirrors what
/// `_PerFileMaterializer.materialize` does on the main isolate.
void _perFileFallback(Store store, String integrity, String dest) {
  final manifest = store.readIndexSync(integrity);
  if (manifest == null) {
    throw StateError('no store index for $integrity');
  }
  final destDir = Directory(dest);
  if (destDir.existsSync()) destDir.deleteSync(recursive: true);
  destDir.createSync(recursive: true);
  final mkdirs = <String>{};
  for (final f in manifest.files) {
    mkdirs.add(p.dirname(p.join(dest, f.relativePath)));
  }
  for (final d in mkdirs) {
    Directory(d).createSync(recursive: true);
  }
  for (final f in manifest.files) {
    hardlinkOrCopySync(
      source: store.layout.filePath(f.sha512Hex),
      target: p.join(dest, f.relativePath),
    );
  }
}
