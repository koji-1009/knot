#!/usr/bin/env bash
# Build the knot CLI bundle once via `dart build cli` (so the
# boringssl_dart link hook produces a binary with the native library
# bundled; plain `dart compile exe` would SEGV on the first FFI call),
# then run `dart test` with the binary path exported via KNOT_TEST_BIN.
# CLI integration tests skip the per-test JIT `dart run` overhead.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

build_dir="$(mktemp -d -t knot-test-bin.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

echo "building knot bundle..."
dart build cli -o "$build_dir" >/dev/null

bin_name="knot"
if [[ "${OS:-}" == "Windows_NT" ]]; then
  bin_name="knot.exe"
fi

# With `-o <dir>`, `dart build cli` outputs to `<dir>/bundle/bin/<name>`.
bin="$build_dir/bundle/bin/$bin_name"

if [[ ! -x "$bin" ]]; then
  echo "failed to find compiled binary at $bin" >&2
  exit 1
fi

KNOT_TEST_BIN="$bin" exec dart test "$@"
