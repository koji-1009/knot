# knot

A Dart-based, npm-compatible package manager.

- **npm registry compatible**: fetch, resolve, and install hosted packages
- **Content-addressable store + hardlinks**: pnpm-style global store, one copy
  per unique file across every project
- **Native binary**: compiled via `dart build cli` so `boringssl_dart`'s
  ECDSA signature verification ships with the install

## Layout

```
lib/src/
  core/        # shared types, errors, logging, native SHA-2 helpers
  semver/      # npm semver dialect
  npmrc/       # .npmrc parser
  lockfile/    # package-lock.json (v3) + knot-lock.yaml
  archive/     # tar/gzip streaming
  ffi/         # cross-platform hardlinks, clonefile, chmod
  registry/    # npm registry HTTP client
  resolver/    # pubgrub + npm extensions
  store/       # content-addressable store + worker isolate pool
  linker/      # node_modules builder (hoisted + isolated)
  scripts/     # lifecycle script runner
  audit/       # advisory database
  signature/   # ECDSA tarball signature verification
  cli/         # CLI entrypoint
bin/
  knot.dart       # main CLI binary
  aot_smoke.dart  # CI-only: smoke-tests boringssl_dart bindings under AOT
```

## Build

```
dart pub get
dart build cli --target bin/knot.dart -o build
```

The output bundle at `build/bundle/bin/knot` includes the native BoringSSL
library produced by the `boringssl_dart` build hook. Plain `dart compile exe`
will produce a binary that loads at startup but crashes when verification
runs, because the link hook is not invoked.

## License

knot itself is MIT-licensed — see [LICENSE](LICENSE).

The distributed binary statically links BoringSSL (Apache-2.0) and embeds
code from a number of Dart packages under Apache-2.0, BSD-3-Clause, and
MIT. The full notices required for redistribution are reproduced in
[THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt).
