import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'generated/posix_linux.g.dart' as linux;
import 'generated/posix_macos.g.dart' as macos;

/// Equivalent of `chmod 0755 path`: rwxr-xr-x. Used to flip the execute
/// bit on shim scripts after they're written.
///
/// Direct `chmod(2)` via FFI rather than `Process.runSync('chmod')` —
/// each fork+exec costs ~3ms, and a project with many bin entries
/// (vite-react has 5) accumulates ~15ms of pure syscall startup.
///
/// On Windows the execute bit is not a concept; shims are `.cmd` files
/// that the shell treats as executable by extension, so this is a no-op.
void chmodExecutable(String path) {
  if (Platform.isWindows) return;
  final cStr = path.toNativeUtf8().cast<Char>();
  try {
    // 0755 = rwxr-xr-x.
    const mode = 0x1ED;
    final rc = Platform.isMacOS
        ? macos.chmod(cStr, mode)
        : linux.chmod(cStr, mode);
    if (rc != 0) {
      final err = Platform.isMacOS
          ? macos.errnoLocation().value
          : linux.errnoLocation().value;
      throw FileSystemException('chmod(0755) failed with errno $err', path);
    }
  } finally {
    malloc.free(cStr);
  }
}
