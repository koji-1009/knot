/// Lockfile schema + read/write utilities.
///
/// knot's internal model is the npm v3 shape (`Lockfile`); the two
/// knot-specific fields (`_signatures` and `_scripts`) ride along as
/// underscore-prefixed extensions that npm preserves verbatim.
///
/// Lockfile format follows the project mode (see `project/mode.dart`):
/// npm/knot-mode reads and writes `package-lock.json`; pnpm-mode reads
/// and writes `pnpm-lock.yaml`, converting through the internal model
/// on either side (see `pnpm_convert.dart`). `bun.lock` is not
/// supported.
library;

export 'detect.dart';
export 'npm_writer.dart';
export 'pnpm_convert.dart';
export 'pnpm_reader.dart';
export 'pnpm_writer.dart';
export 'reader.dart';
export 'schema.dart';
