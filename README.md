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
deps), measured 2026-05-23.

Pinned versions (everything below is sensitive to the package manager's
implementation language and release, especially while bun is mid-migration
from Zig to Rust — these numbers belong to **this** set of versions):

| component | version |
|-----------|---------|
| Dart SDK (used to build knot) | 3.12.0 |
| knot | HEAD of this branch |
| pnpm | 11.1.3 |
| npm | 11.12.1 |
| bun | 1.3.14 |

| tool | scenario | time (center [min … max])           | peak memory |
|------|----------|--------------------------------------|-------------|
| **knot** | cold | **1470 ms** [1180 … 1740]            | **137 MB**  |
| **knot** | warm | **54.3 ± 0.6 ms** [53.1 … 55.0]      |  **11 MB**  |
| pnpm | cold | 2070 ms [1570 … 2670]                | 406 MB      |
| pnpm | warm | 281.0 ± 1.5 ms [277.8 … 283.2]       | 266 MB      |
| npm  | cold | 6890 ms [6520 … 7220]                | 381 MB      |
| npm  | warm | 432.5 ± 30.2 ms [408.7 … 507.6]      | 106 MB      |
| bun  | cold | 1740 ms [1340 … 4380]                | 125 MB      |
| bun  | warm | **8.2 ± 0.5 ms** [7.8 … 9.4]         |   **8 MB**  |

Cold = median of 5 `tools/bench/run.sh` runs (the range reflects how
network-bound cold installs are — single-digit reruns are not enough to
beat that noise; treat the bracket as the day's spread, not a confidence
interval). Warm = `hyperfine --warmup 2 --runs 10` (mean ± σ, plus
observed [min … max]) with each tool seeded against its own lockfile.
Peak memory is `/usr/bin/time -lp`'s `peak memory footprint`.

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
