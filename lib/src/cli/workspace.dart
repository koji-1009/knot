import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;

import 'package_json.dart';

/// A single workspace package discovered under the root project.
class Workspace {
  Workspace({
    required this.name,
    required this.rootPath,
    required this.packageJson,
  });

  /// Workspace `package.json` name field.
  final String name;

  /// Absolute path to the workspace directory.
  final String rootPath;
  final PackageJson packageJson;
}

/// Discover workspace packages declared in [rootProjectRoot]/package.json.
///
/// Honors:
/// - `"workspaces": ["packages/*", "apps/*"]`
/// - `"workspaces": { "packages": ["..."] }`
/// - `!` prefix for exclusions
class WorkspaceResolver {
  WorkspaceResolver(this.rootProjectRoot);
  final String rootProjectRoot;

  Future<List<Workspace>> resolve(List<String> patterns) async {
    if (patterns.isEmpty) return const [];
    final include = <String>[];
    final exclude = <Glob>[];
    for (final raw in patterns) {
      if (raw.startsWith('!')) {
        exclude.add(Glob(raw.substring(1)));
      } else {
        include.add(raw);
      }
    }

    final found = <String>{};
    for (final pattern in include) {
      // Workspaces conventionally point to directories. Expand `<pattern>`
      // (top-level dirs). When the user writes `packages/**` we still pick
      // every directory containing a `package.json`.
      final glob = Glob(pattern, context: p.context);
      await for (final entity in glob.list(root: rootProjectRoot)) {
        if (entity is! Directory) continue;
        if (exclude.any(
          (g) => g.matches(p.relative(entity.path, from: rootProjectRoot)),
        )) {
          continue;
        }
        final pkgPath = p.join(entity.path, 'package.json');
        if (await File(pkgPath).exists()) {
          found.add(p.normalize(entity.path));
        }
      }
    }

    final workspaces = <Workspace>[];
    for (final dir in found) {
      final pkg = await PackageJson.read(p.join(dir, 'package.json'));
      workspaces.add(
        Workspace(name: pkg.name, rootPath: dir, packageJson: pkg),
      );
    }
    workspaces.sort((a, b) => a.name.compareTo(b.name));
    return workspaces;
  }
}
