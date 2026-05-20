import 'dart:io';

import 'package:path/path.dart' as p;

import 'npm_writer.dart' as npm;
import 'reader.dart';
import 'schema.dart';

/// Lockfile path inside a project root. knot operates on
/// `package-lock.json` exclusively — the npm v3 shape covers the
/// information knot needs and gives universal interop with the rest
/// of the JavaScript ecosystem.
class DetectedLockfile {
  DetectedLockfile({required this.path});
  final String path;
}

/// Return the `package-lock.json` path under [projectRoot] when one
/// is present. Returns null on miss; callers fall back to writing a
/// fresh lockfile on the first install.
DetectedLockfile? detectExistingLockfile(String projectRoot) {
  final path = p.join(projectRoot, 'package-lock.json');
  if (File(path).existsSync()) {
    return DetectedLockfile(path: path);
  }
  return null;
}

/// Read the project's `package-lock.json`, if present.
Future<Lockfile?> readProjectLockfile(String projectRoot) async {
  final detected = detectExistingLockfile(projectRoot);
  if (detected == null) return null;
  return importNpmLockfile(detected.path);
}

/// Write [lockfile] to `<projectRoot>/package-lock.json`.
///
/// [projectName] / [projectVersion] are required for the npm shape;
/// pass `package.json`'s `name`/`version`.
Future<DetectedLockfile> writeProjectLockfile({
  required String projectRoot,
  required Lockfile lockfile,
  required String projectName,
  String? projectVersion,
}) async {
  final path = p.join(projectRoot, 'package-lock.json');
  await npm.writeNpmLockfileToFile(
    lockfile,
    path,
    projectName: projectName,
    projectVersion: projectVersion,
  );
  return DetectedLockfile(path: path);
}
