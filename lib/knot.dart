/// Public API entry point for the knot package manager.
///
/// CLI consumers should use `KnotCommandRunner` from this library. Library
/// consumers who only need types (errors, lockfile schema, progress events)
/// can import the specific `src/<area>/...` files directly.
library;

export 'src/cli/runner.dart' show KnotCommandRunner, knotVersion;
export 'src/core/core.dart';
