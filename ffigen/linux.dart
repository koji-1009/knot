// Regenerate Linux POSIX bindings with `dart run ffigen/linux.dart`.

import 'package:ffigen/ffigen.dart';

void main() {
  FfiGenerator(
    headers: Headers(
      entryPoints: [Uri.file('ffigen/headers/posix_linux.h')],
      include: (header) {
        final path = header.toFilePath();
        return path.endsWith('posix_linux.h') ||
            path.endsWith('unistd.h') ||
            path.endsWith('fcntl.h') ||
            path.endsWith('sys/stat.h');
      },
    ),
    functions: Functions(
      include: Declarations.includeSet({
        'link',
        'linkat',
        'unlink',
        'chmod',
        '__errno_location',
      }),
      rename: (decl) => decl.originalName == '__errno_location'
          ? 'errnoLocation'
          : decl.originalName,
    ),
    output: Output(
      dartFile: Uri.file('lib/src/ffi/generated/posix_linux.g.dart'),
    ),
  ).generate();
}
