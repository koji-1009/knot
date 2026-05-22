import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:knot/src/ffi/ffi.dart';
import 'package:knot/src/registry/packument.dart';
import 'package:path/path.dart' as p;

import 'impl.dart';

/// Shared worker-isolate pool for every CPU- or syscall-bound task an
/// install runs: tarball ingest (gzip + tar + sha512), hardlink /
/// clonefile batches, and packument JSON decode. The pool holds no
/// per-install state itself — `storeRoot` travels in the message so
/// the same pool could serve multiple stores. Each worker caches a
/// `Store` per `storeRoot` so `Store.initialize()`'s mkdir cost is
/// paid once per (worker, storeRoot) pair, not once per task.
///
/// One pool, not two: ingest and link never run concurrently in
/// practice (ingest during fetch, link after), so sizing one to
/// `numberOfProcessors` is enough. `package:pool` is kept only on the
/// main isolate as an HTTP request count limiter; it can't unblock
/// the isolate thread that sync FFI sits on, which is what this pool
/// is for.
class WorkerPool {
  WorkerPool._(this._workers);

  final List<_Worker> _workers;
  final Queue<_Worker> _idle = Queue();
  final Queue<Completer<_Worker>> _waiting = Queue();
  bool _disposed = false;

  static Future<WorkerPool> spawn({required int size}) async {
    // Spawn all isolates in parallel so the wall time is one isolate's
    // worth, not `size` isolates' worth.
    final workers = await Future.wait([
      for (var i = 0; i < size; i++) _Worker.spawn(),
    ]);
    final pool = WorkerPool._(workers);
    pool._idle.addAll(workers);
    return pool;
  }

  Future<StoredTarball> ingest({
    required String storeRoot,
    required Uint8List bytes,
    required String tarballSha512Hex,
  }) async {
    final w = await _acquire();
    try {
      return await w.ingest(storeRoot, bytes, tarballSha512Hex);
    } finally {
      _release(w);
    }
  }

  /// utf8 + JSON decode of a packument response body and construct
  /// the [Packument] all on the worker. The whole parse cost (utf8 +
  /// JSON + `Packument.fromJson`) stays off the main isolate.
  Future<Packument> decodePackument(Uint8List bytes) async {
    final w = await _acquire();
    try {
      return await w.decodePackument(bytes);
    } finally {
      _release(w);
    }
  }

  /// gzip + utf8 + JSON decode of a raw packument response body on a
  /// worker. Lets the caller skip `autoUncompress` on its HttpClient
  /// and ship the compressed bytes (smaller payload across the isolate
  /// boundary) without paying the gzip cost on the main isolate.
  Future<Packument> decodePackumentGzipped(Uint8List bytes) async {
    final w = await _acquire();
    try {
      return await w.decodePackumentGzipped(bytes);
    } finally {
      _release(w);
    }
  }

  /// `clonefile(2)` every (source, target) pair in parallel across
  /// workers. `mkdirs` are pre-created on the main isolate so workers
  /// never race on `mkdir` of the same parent.
  ///
  /// EXDEV (cross-volume) → per-file hardlink fallback inside the
  /// worker, using the store's index.
  ///
  /// Dispatch is dynamic: each worker pulls the next task from a
  /// shared queue, so slow tasks (large packages) don't strand fast
  /// workers on a round-robin slice. Per-task IPC (~10-20 µs) is well
  /// below per-task clonefile cost (~1 ms), so the round-trip is paid
  /// gladly.
  Future<void> cloneAll({
    required String storeRoot,
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

    Future<void> drain(_Worker w) async {
      while (queue.isNotEmpty) {
        final task = queue.removeFirst();
        await w.cloneBatch(storeRoot, [task]);
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

  static Future<_Worker> spawn() async {
    final boot = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      boot.sendPort,
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

  Future<StoredTarball> ingest(
    String storeRoot,
    Uint8List bytes,
    String sha,
  ) async {
    final response = await _send(
      (sendPort) => _IngestMsg(
        storeRoot,
        TransferableTypedData.fromList([bytes]),
        sha,
        sendPort,
      ),
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

  Future<void> cloneBatch(String storeRoot, List<CloneTask> tasks) async {
    final response = await _send(
      (sendPort) => _CloneBatchMsg(storeRoot, tasks, sendPort),
    );
    if (response is _Err) {
      throw StateError('worker clone batch failed: ${response.message}');
    }
  }

  Future<Packument> decodePackument(Uint8List bytes) async {
    final response = await _send(
      (sendPort) => _DecodePackumentMsg(
        TransferableTypedData.fromList([bytes]),
        sendPort,
      ),
    );
    if (response is _Err) {
      throw StateError('worker decodePackument failed: ${response.message}');
    }
    return response as Packument;
  }

  Future<Packument> decodePackumentGzipped(Uint8List bytes) async {
    final response = await _send(
      (sendPort) => _DecodePackumentGzippedMsg(
        TransferableTypedData.fromList([bytes]),
        sendPort,
      ),
    );
    if (response is _Err) {
      throw StateError(
        'worker decodePackumentGzipped failed: ${response.message}',
      );
    }
    return response as Packument;
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

class _IngestMsg implements _WorkerMsg {
  _IngestMsg(this.storeRoot, this.bytes, this.tarballSha, this.replyTo);
  final String storeRoot;
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
  _CloneBatchMsg(this.storeRoot, this.tasks, this.replyTo);
  final String storeRoot;
  final List<CloneTask> tasks;
  final SendPort replyTo;
}

class _DecodePackumentMsg implements _WorkerMsg {
  _DecodePackumentMsg(this.bytes, this.replyTo);
  final TransferableTypedData bytes;
  final SendPort replyTo;
}

class _DecodePackumentGzippedMsg implements _WorkerMsg {
  _DecodePackumentGzippedMsg(this.bytes, this.replyTo);
  final TransferableTypedData bytes;
  final SendPort replyTo;
}

class _Err {
  _Err(this.message);
  final String message;
}

Future<void> _workerMain(SendPort bootReply) async {
  final mailbox = ReceivePort();
  bootReply.send(mailbox.sendPort);

  // One `Store` per `storeRoot` per worker. `Store.initialize()`'s
  // mkdir cost is paid once per (worker, storeRoot) pair instead of
  // once per ingest call.
  final stores = <String, Store>{};
  Future<Store> storeFor(String root) async {
    final cached = stores[root];
    if (cached != null) return cached;
    final s = Store(root);
    await s.initialize();
    stores[root] = s;
    return s;
  }

  await for (final msg in mailbox) {
    switch (msg) {
      case final _IngestMsg m:
        try {
          final store = await storeFor(m.storeRoot);
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
          final store = await storeFor(m.storeRoot);
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
      case final _DecodePackumentMsg m:
        try {
          final raw = m.bytes.materialize().asUint8List();
          final decoded = jsonDecode(utf8.decode(raw));
          if (decoded is! Map) {
            m.replyTo.send(_Err('packument is not a JSON object'));
            break;
          }
          final pkg = Packument.fromJson(Map<String, dynamic>.from(decoded));
          m.replyTo.send(pkg);
        } on Object catch (e) {
          m.replyTo.send(_Err('$e'));
        }
      case final _DecodePackumentGzippedMsg m:
        try {
          final compressed = m.bytes.materialize().asUint8List();
          final raw = gzip.decode(compressed) as Uint8List;
          final decoded = jsonDecode(utf8.decode(raw));
          if (decoded is! Map) {
            m.replyTo.send(_Err('packument is not a JSON object'));
            break;
          }
          final pkg = Packument.fromJson(Map<String, dynamic>.from(decoded));
          m.replyTo.send(pkg);
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
