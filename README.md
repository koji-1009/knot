# knot

A Dart-based, npm-compatible package manager.

- **npm registry compatible**: fetch, resolve, and install hosted packages
- **Content-addressable store + hardlinks**: pnpm-style global store, one copy
  per unique file across every project
- **Native binary**: compiled via `dart build cli` so `boringssl_dart`'s
  ECDSA signature verification ships with the install

## Layout

```
bin/
  knot.dart        # CLI entrypoint
lib/src/
  core/            # shared types, errors, logging, native SHA-2 helpers
  semver/          # npm semver dialect
  npmrc/           # .npmrc parser
  lockfile/        # package-lock.json (v3) read / write
  archive/         # tar/gzip streaming
  ffi/             # cross-platform hardlinks, clonefile, chmod
  registry/        # npm registry HTTP client
  resolver/        # pubgrub + npm extensions
  store/           # content-addressable store + worker isolate pool
  linker/          # node_modules builder (hoisted + isolated)
  scripts/         # lifecycle script runner
  audit/           # advisory database
  signature/       # ECDSA tarball signature verification
  cli/             # CLI command dispatch
ffigen/            # FFI binding regeneration scripts + stub headers
tools/             # dev / CI utilities (test.sh, aot_smoke, compat_test, bench)
```

## Build

```
dart pub get
dart build cli -o build
```

The output bundle at `build/bundle/bin/knot` includes the native BoringSSL
library produced by the `boringssl_dart` build hook. Plain `dart compile exe`
will produce a binary that loads at startup but crashes when verification
runs, because the link hook is not invoked.

## Benchmark

`tools/bench/run.sh` measures cold + warm install time and peak memory for
a chosen fixture across knot and other package managers. Cold runs wipe each
tool's global cache/store first; warm runs only clear `node_modules`.

```
./tools/bench/run.sh --fixture vite-react --tools knot,pnpm,bun --runs 5
```

Options:

| Flag | Default | Notes |
|------|---------|-------|
| `--fixture NAME` | `vite-react` | Any directory under `tools/compat_test/fixtures/` |
| `--runs N` | `3` | Repetitions per scenario; medians reported |
| `--tools LIST` | `knot,pnpm` | Comma-separated subset of `knot,pnpm,npm,bun` |
| `--knot-bin PATH` | (auto-build) | Reuse an existing knot binary instead of running `dart build cli` |

The script reports a markdown table of medians, e.g.

```
## bench: vite-react (median of 5 runs)

| tool | scenario | time | peak memory |
|------|----------|------|-------------|
| knot | cold     | 300 ms  | ~100 MB |
| knot | warm     | 55 ms   | ~12 MB  |
| pnpm | cold     | 5700 ms | ~400 MB |
| pnpm | warm     | 230 ms  | ~275 MB |
```

Numbers depend on hardware, network conditions, and tool versions; the table
above is from a macOS arm64 laptop fetching against the public npm registry
and is illustrative, not normative. macOS and Linux are supported (different
`/usr/bin/time` flags); Windows is not.

## License

knot itself is MIT-licensed — see [LICENSE](LICENSE).

The distributed binary statically links BoringSSL (Apache-2.0) and embeds
code from a number of Dart packages under Apache-2.0, BSD-3-Clause, and
MIT. The full notices required for redistribution are reproduced in
[THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt).
