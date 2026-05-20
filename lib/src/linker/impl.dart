import 'dart:io';

import 'package:knot/src/ffi/ffi.dart';
import 'package:knot/src/store/store.dart';
import 'package:path/path.dart' as p;

/// A resolved package ready to be linked into `node_modules`.
class LinkSpec {
  LinkSpec({
    required this.name,
    required this.version,
    required this.tarballSha512Hex,
    required this.dependencies,
    this.bin = const {},
    this.isDirect = false,
    this.linkAlias,
    this.scripts = const {},
    this.engines = const {},
  });

  final String name;
  final String version;
  final String tarballSha512Hex;
  final Map<String, String> dependencies;
  final Map<String, String> bin;
  final bool isDirect;

  /// When non-null, the top-level `node_modules/<linkAlias>` symlink should
  /// be created instead of using [name]. Set for `npm:<pkg>@<range>` aliases.
  final String? linkAlias;

  final Map<String, String> scripts;
  final Map<String, String> engines;

  String get id => '$name@$version';

  /// Name as it should appear under top-level `node_modules/`.
  String get topLevelName => linkAlias ?? name;
}

/// The on-disk layout knot uses to materialize packages.
///
/// - [isolated]: pnpm-style. Every package lives under
///   `node_modules/.knot/<pkg@ver>/node_modules/<pkg>` and is symlinked into
///   place. Strict — packages cannot accidentally require unrelated deps.
/// - [hoisted]: npm-style flat. Packages sit at
///   `node_modules/<pkg>` directly. Less strict but matches the typical
///   Node ecosystem assumption.
enum LinkerKind { isolated, hoisted }

/// pnpm-style node_modules linker.
class NodeModulesLinker {
  NodeModulesLinker({required this.materializer});

  /// Materializer used to clone each package's extracted tree from the
  /// store into its per-package `.knot/<id>/node_modules/<name>` slot.
  final StoreMaterializer materializer;

  /// Compute the materialized root for [spec] inside the linked tree.
  static String linkedPathOf(
    String projectRoot,
    LinkSpec spec, {
    LinkerKind kind = LinkerKind.isolated,
  }) {
    if (kind == LinkerKind.hoisted) {
      return p.join(projectRoot, 'node_modules', spec.name);
    }
    return p.join(
      projectRoot,
      'node_modules',
      '.knot',
      _staticSafeId(spec.id),
      'node_modules',
      spec.name,
    );
  }

  /// `.bin` directory visible to a package's lifecycle scripts. For the
  /// hoisted layout this is just the top-level `.bin`.
  static String binPathFor(
    String projectRoot,
    LinkSpec spec, {
    LinkerKind kind = LinkerKind.isolated,
  }) {
    if (kind == LinkerKind.hoisted) {
      return topLevelBinPath(projectRoot);
    }
    return p.join(
      projectRoot,
      'node_modules',
      '.knot',
      _staticSafeId(spec.id),
      'node_modules',
      '.bin',
    );
  }

  /// Top-level `node_modules/.bin` directory.
  static String topLevelBinPath(String projectRoot) =>
      p.join(projectRoot, 'node_modules', '.bin');

  Future<void> link({
    required String projectRoot,
    required List<LinkSpec> packages,
  }) async {
    final nodeModulesRoot = p.join(projectRoot, 'node_modules');
    final knotRoot = p.join(nodeModulesRoot, '.knot');
    final binsRoot = p.join(nodeModulesRoot, '.bin');
    Directory(knotRoot).createSync(recursive: true);
    Directory(binsRoot).createSync(recursive: true);

    // Materialize every package in one batch so the materializer can
    // push N parallel `clonefile(2)` calls (macOS) or per-file hardlink
    // tasks (Linux/Windows) into the worker pool. Synchronous FFI on
    // the main isolate would otherwise run them serially.
    final tasks = <MaterializeTask>[];
    for (final pkg in packages) {
      final pkgRoot = p.join(
        knotRoot,
        _safeId(pkg.id),
        'node_modules',
        pkg.name,
      );
      if (Directory(pkgRoot).existsSync()) continue;
      tasks.add(
        MaterializeTask(integrity: pkg.tarballSha512Hex, dest: pkgRoot),
      );
    }
    await materializer.materializeAll(tasks);

    for (final pkg in packages) {
      await _wirePeerSymlinks(knotRoot, pkg, packages);
    }
    for (final pkg in packages.where((p) => p.isDirect)) {
      await _createTopLevelSymlink(nodeModulesRoot, knotRoot, pkg);
    }
    for (final pkg in packages) {
      _createBinSymlinks(knotRoot, binsRoot, pkg);
    }
  }

  Future<void> _wirePeerSymlinks(
    String knotRoot,
    LinkSpec pkg,
    List<LinkSpec> all,
  ) async {
    final byId = {for (final p in all) p.id: p};
    final pkgNodeModules = Directory(
      p.join(knotRoot, _safeId(pkg.id), 'node_modules'),
    );
    for (final dep in pkg.dependencies.entries) {
      final depId = '${dep.key}@${dep.value}';
      final depSpec = byId[depId];
      if (depSpec == null) continue;
      final link = Link(p.join(pkgNodeModules.path, dep.key));
      await Directory(p.dirname(link.path)).create(recursive: true);
      if (await link.exists() ||
          await Directory(link.path).exists() ||
          await File(link.path).exists()) {
        continue;
      }
      final target = p.join(
        knotRoot,
        _safeId(depSpec.id),
        'node_modules',
        dep.key,
      );
      await createDirSymlinkOrJunction(
        linkPath: link.path,
        target: _relativeTo(p.dirname(link.path), target),
      );
    }
  }

  Future<void> _createTopLevelSymlink(
    String nodeModulesRoot,
    String knotRoot,
    LinkSpec pkg,
  ) async {
    final linkPath = p.join(nodeModulesRoot, pkg.topLevelName);
    await Directory(p.dirname(linkPath)).create(recursive: true);
    final link = Link(linkPath);
    if (await link.exists() ||
        await Directory(linkPath).exists() ||
        await File(linkPath).exists()) {
      return;
    }
    final target = p.join(knotRoot, _safeId(pkg.id), 'node_modules', pkg.name);
    await createDirSymlinkOrJunction(
      linkPath: link.path,
      target: _relativeTo(p.dirname(linkPath), target),
    );
  }

  void _createBinSymlinks(String knotRoot, String binsRoot, LinkSpec pkg) {
    if (pkg.bin.isEmpty) return;
    for (final entry in pkg.bin.entries) {
      final source = p.join(
        knotRoot,
        _safeId(pkg.id),
        'node_modules',
        pkg.name,
        entry.value,
      );
      final linkPath = p.join(binsRoot, entry.key);
      if (Link(linkPath).existsSync() || File(linkPath).existsSync()) continue;
      _writeShim(source: source, target: linkPath);
    }
  }

  void _writeShim({required String source, required String target}) {
    final isWindows = Platform.isWindows;
    if (!isWindows) {
      File(target).writeAsStringSync('#!/bin/sh\nexec node "$source" "\$@"\n');
      chmodExecutable(target);
      return;
    }
    File('$target.cmd').writeAsStringSync('@ECHO OFF\r\nnode "$source" %*\r\n');
    File('$target.ps1').writeAsStringSync(
      '\$ErrorActionPreference = "Stop"\n'
      '& node "$source" \$args\n'
      'exit \$LASTEXITCODE\n',
    );
  }

  String _safeId(String id) => _staticSafeId(id);

  static String _staticSafeId(String id) => id.replaceAll('/', '+');

  String _relativeTo(String from, String to) => p.relative(to, from: from);
}
