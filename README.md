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
is run N times and the table reports best / median / worst (so the network
floor and the tail are both visible alongside the typical observation).

```
./tools/bench/run.sh --fixture vite-react --tools knot,pnpm,npm,bun
```

| Flag | Default | Notes |
|------|---------|-------|
| `--fixture NAME` | `vite-react` | Any directory under `tools/compat_test/fixtures/` |
| `--cold-runs N` | `15` | Cold-scenario repetitions (network-bound; observed spreads of ~5x argue against fewer) |
| `--warm-runs N` | `20` | Warm-scenario repetitions (no network cost — packument freshness + store hits — so sampling more is free) |
| `--runs N` | — | Shortcut that sets both `--cold-runs` and `--warm-runs` to `N` |
| `--tools LIST` | `knot,pnpm` | Comma-separated subset of `knot,pnpm,npm,bun` |
| `--knot-bin PATH` | (auto-build) | Reuse an existing knot binary instead of running `dart build cli` |

Warm timings come from `/usr/bin/time` (`real` at 0.01s resolution), which
is too coarse for sub-100ms tools — run those through `hyperfine`
separately when you need ms precision:

```
hyperfine --warmup 2 --runs 20 --prepare 'rm -rf node_modules' \
  '<tool> install'
```

macOS and Linux are supported (`/usr/bin/time -lp` / `-v`); Windows is not.

### Reference run

Sample numbers from one author run on **macOS arm64 (MacBook Air M4,
10 cores)**, fixture `vite-react` (16 packages: react + react-dom +
vite with its transitive deps), measured 2026-05-23.

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

| tool | scenario | best      | center             | worst       | peak memory |
|------|----------|-----------|--------------------|-------------|-------------|
| **knot** | cold | **1450 ms**  | **1760 ms**           | 7830 ms     | **186 MB**  |
| **knot** | warm | **52.8 ms**  | **54.0 ± 0.6 ms**     | 55.1 ms     |  **11 MB**  |
| pnpm | cold | 1360 ms      | 1720 ms               | 3170 ms     | 395 MB      |
| pnpm | warm | 268.2 ms     | 272.3 ± 2.2 ms        | 278.7 ms    | 263 MB      |
| npm  | cold | 6150 ms      | 7310 ms               | 9210 ms     | 377 MB      |
| npm  | warm | 388.9 ms     | 423.6 ± 62.6 ms       | 666.1 ms    | 104 MB      |
| bun  | cold | **940 ms**   | **1710 ms**           | 5950 ms     | 134 MB      |
| bun  | warm | **7.6 ms**   | **7.9 ± 0.3 ms**      | 8.9 ms      |   **8 MB**  |

- `best` = min over N runs (the floor when the network and host
  cooperate — useful for "how fast can this go").
- `center` = median for cold, hyperfine `mean ± σ` for warm.
- `worst` = max over N runs (the tail; cold can spike to several
  times the median on a network-noisy session — treat the bracket as
  that session's spread, not a confidence interval).
- Cold from `tools/bench/run.sh --cold-runs 15`; warm from
  `hyperfine --warmup 2 --runs 20` with each tool seeded against its
  own lockfile.
- Peak memory is `/usr/bin/time -lp`'s `peak memory footprint`.

Rerun in your own environment with the current versions for an up-to-date
picture — bun's Zig→Rust migration in particular is in flux.

### Binary size

`dart build cli` produces a self-contained bundle under `build/bundle/`:

```
8.2M  bundle/bin/knot
505K  bundle/lib/libboringssl_dart.dylib
----
8.7M  total
```

(macOS arm64. Linux / Windows are within 10% of these numbers.) For
comparison, npm requires Node.js (~60 MB) plus its own ~30 MB of
JS modules; `pnpm`'s standalone build bundles a Node runtime and
sits around 50 MB; `bun`'s standalone binary is ~70 MB. knot ships
no JavaScript runtime — `dart build cli` produces the AOT binary
plus a 505 KiB BoringSSL dylib (ECDSA + SHA-512 only, the rest of
the upstream library is stripped at link time).

## License

knot itself is MIT-licensed — see [LICENSE](LICENSE).

The distributed binary statically links BoringSSL (Apache-2.0) and embeds
code from a number of Dart packages under Apache-2.0, BSD-3-Clause, and
MIT. The full notices required for redistribution are reproduced in
[THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt).
