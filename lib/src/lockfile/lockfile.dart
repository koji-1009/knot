/// Lockfile schema + read/write utilities.
///
/// knot reads and writes `package-lock.json` (npm v3 shape)
/// exclusively. The two knot-specific fields (`_signatures` and
/// `_scripts`) ride along as underscore-prefixed extensions that npm
/// preserves verbatim. `pnpm-lock.yaml` / `bun.lock` are not
/// supported — running `knot install` on a project with one of those
/// resolves from `package.json` and writes a fresh
/// `package-lock.json`.
library;

export 'detect.dart';
export 'npm_writer.dart';
export 'reader.dart';
export 'schema.dart';
