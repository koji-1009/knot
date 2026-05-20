import 'dart:io';

import 'package:knot/src/ffi/ffi.dart';
import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;

import 'impl.dart';

/// npm-compatible flat `node_modules` linker.
///
/// Materializes every package directly under `<root>/node_modules/<name>`
/// via [StoreMaterializer]. The materializer picks the fastest primitive
/// for the running OS — recursive `clonefile(2)` on macOS, per-file
/// hardlink on Linux/Windows.
class HoistedLinker {
  HoistedLinker({required this.materializer});
  final StoreMaterializer materializer;

  /// Materialize [packages] into a flat `<root>/node_modules/`.
  ///
  /// On conflict the highest-versioned spec wins; the lost ones are
  /// reported in [warnings].
  Future<void> link({
    required String projectRoot,
    required List<LinkSpec> packages,
    List<String>? warnings,
  }) async {
    final profile = Platform.environment['KNOT_PROFILE'] == '1';
    final phase = Stopwatch()..start();
    void mark(String label) {
      if (!profile) return;
      // ignore: avoid_print
      print('    LINK $label: ${phase.elapsedMilliseconds}ms');
      phase.reset();
    }

    final nodeModulesRoot = p.join(projectRoot, 'node_modules');
    final binsRoot = p.join(nodeModulesRoot, '.bin');
    Directory(nodeModulesRoot).createSync(recursive: true);
    Directory(binsRoot).createSync(recursive: true);
    mark('node_modules + .bin setup');

    // Pick the highest version per package name.
    final chosen = <String, LinkSpec>{};
    for (final spec in packages) {
      final current = chosen[spec.name];
      if (current == null) {
        chosen[spec.name] = spec;
        continue;
      }
      if (_versionGreater(spec.version, current.version)) {
        warnings?.add('hoisted: ${current.id} dropped in favor of ${spec.id}');
        chosen[spec.name] = spec;
      } else {
        warnings?.add('hoisted: ${spec.id} dropped in favor of ${current.id}');
      }
    }

    // Materialize every selected package's tree in one batch so the
    // materializer can push the syscalls into its worker pool in
    // parallel. On macOS that means N parallel `clonefile(2)` calls
    // instead of one-at-a-time on the main isolate (synchronous FFI
    // doesn't yield); elsewhere the per-file hardlink pool already
    // covered parallelism.
    final tasks = <MaterializeTask>[];
    for (final spec in chosen.values) {
      final dest = p.join(nodeModulesRoot, spec.name);
      if (Directory(dest).existsSync()) continue;
      tasks.add(MaterializeTask(integrity: spec.tarballSha512Hex, dest: dest));
    }
    await materializer.materializeAll(tasks);
    mark('materialize (${chosen.length} packages)');

    for (final spec in chosen.values) {
      for (final bin in spec.bin.entries) {
        _createBinShim(
          source: p.join(nodeModulesRoot, spec.name, bin.value),
          linkPath: p.join(binsRoot, bin.key),
        );
      }
    }
    mark('bin shims');
  }

  void _createBinShim({required String source, required String linkPath}) {
    if (Link(linkPath).existsSync() || File(linkPath).existsSync()) return;
    if (Platform.isWindows) {
      File(
        '$linkPath.cmd',
      ).writeAsStringSync('@ECHO OFF\r\nnode "$source" %*\r\n');
      return;
    }
    File(linkPath).writeAsStringSync('#!/bin/sh\nexec node "$source" "\$@"\n');
    chmodExecutable(linkPath);
  }

  bool _versionGreater(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      if (pa[i] != pb[i]) return pa[i] > pb[i];
    }
    return pa.length > pb.length;
  }
}
