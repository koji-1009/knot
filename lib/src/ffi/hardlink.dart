import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:knot/src/core/core.dart';

import 'generated/posix_linux.g.dart' as linux;
import 'generated/posix_macos.g.dart' as macos;
import 'generated/windows_kernel32.g.dart' as win32;

/// Outcome of a hardlink attempt.
enum HardlinkOutcome { created, fallbackCopied, alreadyExists }

/// Create a hardlink from [source] to [target]. If the OS rejects the
/// operation (cross-device, missing permission, unsupported filesystem),
/// fall back to copying the file bytes.
Future<HardlinkOutcome> hardlinkOrCopy({
  required String source,
  required String target,
}) async {
  try {
    _linkSync(source, target);
    return HardlinkOutcome.created;
  } on IoError {
    await File(source).copy(target);
    return HardlinkOutcome.fallbackCopied;
  }
}

/// Synchronous hardlink-or-copy. Same semantics as [hardlinkOrCopy] but
/// avoids the event-loop dispatch that dominates wall time when called
/// thousands of times against tiny files.
HardlinkOutcome hardlinkOrCopySync({
  required String source,
  required String target,
}) {
  try {
    _linkSync(source, target);
    return HardlinkOutcome.created;
  } on IoError catch (e) {
    if (e.message.contains('errno 17')) return HardlinkOutcome.alreadyExists;
    File(source).copySync(target);
    return HardlinkOutcome.fallbackCopied;
  }
}

/// Create a hardlink from [source] to [target]. Throws [IoError] on failure.
void hardlinkSync(String source, String target) => _linkSync(source, target);

void _linkSync(String source, String target) {
  if (Platform.isMacOS) {
    _macosLink(source, target);
  } else if (Platform.isWindows) {
    _windowsLink(source, target);
  } else {
    _linuxLink(source, target);
  }
}

void _macosLink(String source, String target) {
  final src = source.toNativeUtf8().cast<Char>();
  final dst = target.toNativeUtf8().cast<Char>();
  try {
    final rc = macos.link(src, dst);
    if (rc != 0) {
      final err = macos.errnoLocation().value;
      throw IoError(
        'link($source, $target) failed with errno $err',
        path: target,
      );
    }
  } finally {
    malloc.free(src);
    malloc.free(dst);
  }
}

void _linuxLink(String source, String target) {
  final src = source.toNativeUtf8().cast<Char>();
  final dst = target.toNativeUtf8().cast<Char>();
  try {
    final rc = linux.link(src, dst);
    if (rc != 0) {
      final err = linux.errnoLocation().value;
      throw IoError(
        'link($source, $target) failed with errno $err',
        path: target,
      );
    }
  } finally {
    malloc.free(src);
    malloc.free(dst);
  }
}

void _windowsLink(String source, String target) {
  final newName = target.toNativeUtf16();
  final existing = source.toNativeUtf16();
  try {
    final ok = win32.CreateHardLinkW(newName.cast(), existing.cast(), nullptr);
    if (ok == 0) {
      final err = win32.GetLastError();
      throw IoError(
        'CreateHardLinkW($source -> $target) failed (GetLastError=$err)',
        path: target,
      );
    }
  } finally {
    malloc.free(newName);
    malloc.free(existing);
  }
}
