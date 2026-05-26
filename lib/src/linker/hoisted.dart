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

  /// Materialize [packages] into `<root>/node_modules/`, each at the
  /// `installPath` the tree resolver assigned — top level when hoisted,
  /// or nested (`<parent>/node_modules/<name>`) when a conflicting
  /// version already holds the top-level slot. Multiple versions of one
  /// name coexist. [warnings] is accepted for call-site compatibility;
  /// the resolver, not the linker, now decides placement.
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

    // The tree resolver already decided each instance's place: top-level
    // (`installPath == name`) or nested under a conflicting version
    // (`b/node_modules/shared`). Materialize each at its path — multiple
    // versions of one name coexist, exactly as npm/pnpm install them.
    // Dedupe only by exact destination (the same instance can be reached
    // via several edges).
    final byDest = <String, LinkSpec>{};
    for (final spec in packages) {
      final rel = spec.installPath ?? spec.topLevelName;
      byDest.putIfAbsent(rel, () => spec);
    }

    // Materialize **shallowest-first**: a parent must be fully cloned
    // before its nested `node_modules` is created. Otherwise the mkdir
    // for a nested child (`b/node_modules/shared` → needs `node_modules/b`)
    // creates an empty `node_modules/b`, and the later recursive
    // `clonefile` of `b` then fails because its destination already
    // exists (and racing workers hit a delete-ENOENT). Within a depth the
    // materializer still fans the clones across its worker pool.
    final byDepth = <int, List<MapEntry<String, LinkSpec>>>{};
    for (final entry in byDest.entries) {
      final depth = '/node_modules/'.allMatches(entry.key).length;
      (byDepth[depth] ??= []).add(entry);
    }
    var materialized = 0;
    for (final depth in byDepth.keys.toList()..sort()) {
      final tasks = <MaterializeTask>[];
      for (final entry in byDepth[depth]!) {
        final dest = p.join(
          nodeModulesRoot,
          p.joinAll(p.posix.split(entry.key)),
        );
        if (Directory(dest).existsSync()) continue;
        tasks.add(
          MaterializeTask(integrity: entry.value.tarballSha512Hex, dest: dest),
        );
      }
      await materializer.materializeAll(tasks);
      materialized += tasks.length;
    }
    mark('materialize ($materialized packages)');

    // Bin shims live in the `.bin` of the node_modules directory that
    // contains the package (top-level for hoisted packages, the nested
    // `<parent>/node_modules/.bin` for nested ones), matching npm.
    for (final entry in byDest.entries) {
      final spec = entry.value;
      if (spec.bin.isEmpty) continue;
      final pkgDir = p.join(
        nodeModulesRoot,
        p.joinAll(p.posix.split(entry.key)),
      );
      final binDir = p.join(p.dirname(pkgDir), '.bin');
      for (final bin in spec.bin.entries) {
        _createBinShim(
          source: p.join(pkgDir, bin.value),
          linkPath: p.join(binDir, bin.key),
        );
      }
    }
    mark('bin shims');
  }

  void _createBinShim({required String source, required String linkPath}) {
    if (Link(linkPath).existsSync() || File(linkPath).existsSync()) return;
    Directory(p.dirname(linkPath)).createSync(recursive: true);
    if (Platform.isWindows) {
      File(
        '$linkPath.cmd',
      ).writeAsStringSync('@ECHO OFF\r\nnode "$source" %*\r\n');
      return;
    }
    File(linkPath).writeAsStringSync('#!/bin/sh\nexec node "$source" "\$@"\n');
    chmodExecutable(linkPath);
  }
}
