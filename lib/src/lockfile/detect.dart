import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../npmrc/npmrc.dart' show defaultRegistry;
import '../project/mode.dart';
import 'npm_writer.dart' as npm;
import 'pnpm_convert.dart';
import 'pnpm_reader.dart';
import 'pnpm_writer.dart' as pnpm;
import 'reader.dart';
import 'schema.dart';

/// Path to a project's on-disk lockfile. The format is chosen by the
/// project mode: pnpm-mode uses `pnpm-lock.yaml`; npm/knot-mode use
/// `package-lock.json` (the npm v3 shape knot's resolver targets).
class DetectedLockfile {
  DetectedLockfile({required this.path});
  final String path;
}

/// On-disk lockfile filename for [mode].
String projectLockfileName(ProjectMode mode) =>
    mode == ProjectMode.pnpm ? 'pnpm-lock.yaml' : 'package-lock.json';

/// Return the existing project lockfile (format chosen by mode) when one
/// is present. Returns null on miss; callers fall back to writing a
/// fresh lockfile on the first install.
DetectedLockfile? detectExistingLockfile(String projectRoot) {
  final path = p.join(
    projectRoot,
    projectLockfileName(detectProjectMode(projectRoot)),
  );
  if (File(path).existsSync()) {
    return DetectedLockfile(path: path);
  }
  return null;
}

/// Parse already-read lockfile [bytes] into the internal [Lockfile],
/// dispatching on [mode].
///
/// pnpm bodies are converted through [pnpmToLockfile]; that path needs
/// [registry] to rebuild the tarball URL pnpm leaves implicit for
/// registry packages (the integrity hash is the real guarantee).
Lockfile parseProjectLockfile(
  Uint8List bytes, {
  required String path,
  required ProjectMode mode,
  required Uri registry,
}) {
  if (mode == ProjectMode.pnpm) {
    return pnpmToLockfile(
      parsePnpmLockfile(utf8.decode(bytes)),
      registry: registry,
    );
  }
  return importNpmLockfileFromBytes(bytes, path: path);
}

/// Read the project's lockfile (format chosen by mode), if present.
///
/// [registry] is consulted only in pnpm-mode for tarball-URL
/// reconstruction; inspection commands that never fetch can leave it at
/// the npm default.
Future<Lockfile?> readProjectLockfile(
  String projectRoot, {
  Uri? registry,
}) async {
  final mode = detectProjectMode(projectRoot);
  final path = p.join(projectRoot, projectLockfileName(mode));
  final file = File(path);
  if (!await file.exists()) return null;
  final bytes = await file.readAsBytes();
  return parseProjectLockfile(
    bytes,
    path: path,
    mode: mode,
    registry: registry ?? Uri.parse(defaultRegistry),
  );
}

/// Write [lockfile] to the project's lockfile (format chosen by mode).
///
/// [projectName] / [projectVersion] populate the npm shape's importer
/// root; pnpm derives importer specifiers from the lockfile itself, so
/// they are ignored in pnpm-mode. Pass [mode] to skip re-detection when
/// the caller already knows it.
Future<DetectedLockfile> writeProjectLockfile({
  required String projectRoot,
  required Lockfile lockfile,
  required String projectName,
  String? projectVersion,
  ProjectMode? mode,
}) async {
  final resolved = mode ?? detectProjectMode(projectRoot);
  final path = p.join(projectRoot, projectLockfileName(resolved));
  if (resolved == ProjectMode.pnpm) {
    await pnpm.writePnpmLockfile(path, lockfileToPnpm(lockfile));
  } else {
    await npm.writeNpmLockfileToFile(
      lockfile,
      path,
      projectName: projectName,
      projectVersion: projectVersion,
    );
  }
  return DetectedLockfile(path: path);
}
