import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:knot/src/core/core.dart';

import 'generated/windows_kernel32.g.dart' as win32;

/// Create a directory symlink (or junction on Windows) from [linkPath] to
/// [target].
///
/// - POSIX: delegates to `dart:io` `Link.create`.
/// - Windows: tries `CreateSymbolicLinkW` with the
///   `ALLOW_UNPRIVILEGED_CREATE` flag (works on Windows 10+ with
///   Developer Mode), then falls back to `cmd /c mklink /J` (a
///   directory junction, which doesn't require elevation).
Future<void> createDirSymlinkOrJunction({
  required String linkPath,
  required String target,
}) async {
  if (!Platform.isWindows) {
    await Link(linkPath).create(target, recursive: false);
    return;
  }

  if (_windowsCreateSymbolicLink(linkPath, target)) return;

  final result = await Process.run('cmd', [
    '/c',
    'mklink',
    '/J',
    linkPath,
    target,
  ], runInShell: false);
  if (result.exitCode != 0) {
    throw IoError(
      'failed to symlink/junction $linkPath -> $target: ${result.stderr}',
      path: linkPath,
    );
  }
}

bool _windowsCreateSymbolicLink(String linkPath, String target) {
  final linkPtr = linkPath.toNativeUtf16();
  final targetPtr = target.toNativeUtf16();
  try {
    final result = win32.CreateSymbolicLinkW(
      linkPtr.cast(),
      targetPtr.cast(),
      win32.SYMBOLIC_LINK_FLAG_DIRECTORY |
          win32.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE,
    );
    return result != 0;
  } on Object {
    return false;
  } finally {
    malloc.free(linkPtr);
    malloc.free(targetPtr);
  }
}
