// Regenerate macOS POSIX bindings with `dart run ffigen/macos.dart`.
//
// Output lives at `lib/src/ffi/generated/posix_macos.g.dart` and is
// committed to the repo so CI doesn't need libclang installed.

import 'dart:io';

import 'package:ffigen/ffigen.dart';

void main() {
  final sdk = _resolveSdk();
  FfiGenerator(
    headers: Headers(
      entryPoints: [Uri.file('ffigen/headers/posix_macos.h')],
      compilerOptions: ['-isysroot', sdk],
      include: (header) {
        // Only emit symbols whose declarations come from our stub file or
        // its direct includes. Without this filter ffigen drags in every
        // libc/SDK declaration the preprocessor touched.
        final path = header.toFilePath();
        return path.endsWith('posix_macos.h') ||
            path.endsWith('unistd.h') ||
            path.endsWith('clonefile.h') ||
            path.endsWith('sys/stat.h') ||
            path.endsWith('_chmod.h');
      },
    ),
    functions: Functions(
      include: Declarations.includeSet({
        'link',
        'unlink',
        'clonefile',
        'chmod',
        '__error',
      }),
      rename: (decl) =>
          decl.originalName == '__error' ? 'errnoLocation' : decl.originalName,
    ),
    macros: Macros.includeSet({
      'CLONE_NOFOLLOW',
      'CLONE_NOOWNERCOPY',
      'CLONE_ACL',
    }),
    output: Output(
      dartFile: Uri.file('lib/src/ffi/generated/posix_macos.g.dart'),
    ),
  ).generate();
}

String _resolveSdk() {
  final result = Process.runSync('xcrun', ['--show-sdk-path']);
  if (result.exitCode != 0) {
    throw StateError('xcrun --show-sdk-path failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}
