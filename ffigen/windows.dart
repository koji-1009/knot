// Regenerate Windows kernel32 bindings with
// `dart run ffigen/windows.dart` from a Windows host with the
// Windows SDK headers available to clang.

import 'package:ffigen/ffigen.dart';

void main() {
  FfiGenerator(
    headers: Headers(
      entryPoints: [Uri.file('ffigen/headers/windows_kernel32.h')],
      include: (header) {
        // Restrict to the prototypes we care about — windows.h pulls in
        // thousands of unrelated declarations otherwise.
        return header.toFilePath().toLowerCase().endsWith('winbase.h') ||
            header.toFilePath().toLowerCase().endsWith('errhandlingapi.h');
      },
    ),
    functions: Functions(
      include: Declarations.includeSet({
        'CreateHardLinkW',
        'CreateSymbolicLinkW',
        'GetLastError',
      }),
    ),
    macros: Macros.includeSet({
      'SYMBOLIC_LINK_FLAG_DIRECTORY',
      'SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE',
    }),
    output: Output(
      dartFile: Uri.file('lib/src/ffi/generated/windows_kernel32.g.dart'),
    ),
  ).generate();
}
