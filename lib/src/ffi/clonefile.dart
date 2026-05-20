import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:knot/src/core/core.dart';

import 'generated/posix_macos.g.dart' as macos;

/// True when `clonefile(2)` is available on the current platform.
///
/// Only macOS exposes a recursive directory clone primitive that we can
/// drive from a single syscall. Linux's `ioctl_ficlone` is per-file only.
/// Windows ReFS has block-level extents duplication but is rarely used in
/// developer environments.
bool get clonefileSupported => Platform.isMacOS;

/// Recursively clone the directory tree at [source] to [target] using
/// APFS copy-on-write. Equivalent to `cp -R` semantically but `O(1)` in
/// disk usage because the resulting tree shares extents with [source].
///
/// Throws [IoError] when the syscall fails (typically when the source
/// and target live on different volumes — errno `EXDEV`).
void clonefileSync({required String source, required String target}) {
  if (!Platform.isMacOS) {
    throw StateError('clonefile is only available on macOS');
  }
  final src = source.toNativeUtf8().cast<Char>();
  final dst = target.toNativeUtf8().cast<Char>();
  try {
    final rc = macos.clonefile(src, dst, 0);
    if (rc != 0) {
      final err = macos.errnoLocation().value;
      throw IoError(
        'clonefile($source -> $target) failed with errno $err',
        path: target,
      );
    }
  } finally {
    malloc.free(src);
    malloc.free(dst);
  }
}
