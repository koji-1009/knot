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

`tools/bench/run.sh` measures cold + warm install time and peak memory across
knot, pnpm, npm, and bun on a chosen fixture. Cold runs wipe each tool's
global cache/store first; warm runs only clear `node_modules`. Each scenario
is run N times and the median is reported.

```
./tools/bench/run.sh --fixture vite-react --tools knot,pnpm,npm,bun --runs 3
```

| Flag | Default | Notes |
|------|---------|-------|
| `--fixture NAME` | `vite-react` | Any directory under `tools/compat_test/fixtures/` |
| `--runs N` | `3` | Repetitions per scenario; medians reported |
| `--tools LIST` | `knot,pnpm` | Comma-separated subset of `knot,pnpm,npm,bun` |
| `--knot-bin PATH` | (auto-build) | Reuse an existing knot binary instead of running `dart build cli` |

macOS and Linux are supported (`/usr/bin/time -lp` / `-v`); Windows is not.

### Reference run

Sample numbers from one author run on **macOS arm64 (M2)**, fixture
`vite-react` (16 packages: react + react-dom + vite with its transitive
deps), measured 2026-05-20.

Pinned versions (everything below is sensitive to the package manager's
implementation language and release, especially while bun is mid-migration
from Zig to Rust — these numbers belong to **this** set of versions):

| component | version |
|-----------|---------|
| Dart SDK (used to build knot) | 3.12.0 |
| knot | HEAD of this branch |
| pnpm | 11.1.3 |
| npm | 11.11.0 |
| bun | 1.3.14 |

| tool | scenario | time | peak memory |
|------|----------|------|-------------|
| knot | cold     | 1730 ms        | 207 MB |
| knot | warm     | 59.4 ± 1.0 ms  |  10 MB |
| pnpm | cold     | 1930 ms        | 396 MB |
| pnpm | warm     | 290.6 ± 1.9 ms | 267 MB |
| npm  | cold     | 8830 ms        | 380 MB |
| npm  | warm     | 424.3 ± 19.9 ms | 107 MB |
| bun  | cold     | 1950 ms        | 131 MB |
| bun  | warm     | 8.5 ± 0.3 ms   |   7 MB |

Cold times are the median of 3 `tools/bench/run.sh` runs (network-bound, day
to day variance dwarfs measurement precision). Warm times come from
`hyperfine --warmup 2 --runs 10` (mean ± σ). Peak memory is `/usr/bin/time
-lp`'s `peak memory footprint`.

Rerun in your own environment with the current versions for an up-to-date
picture — bun's Zig→Rust migration in particular is in flux.

### Binary size

`dart build cli` produces a self-contained bundle under `build/bundle/`:

```
7.9M  bundle/bin/knot
505K  bundle/lib/libboringssl_dart.dylib
----
8.4M  total
```

(macOS arm64. Linux / Windows are within 10% of these numbers.) For
comparison, a typical `node_modules/pnpm/` install on Linux x64 is ~30 MB;
`bun`'s standalone binary is ~70 MB.

## License

knot itself is MIT-licensed — see [LICENSE](LICENSE).

The distributed binary statically links BoringSSL (Apache-2.0) and embeds
code from a number of Dart packages under Apache-2.0, BSD-3-Clause, and
MIT. The full notices required for redistribution are reproduced in
[THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt).
