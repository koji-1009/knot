#!/usr/bin/env bash
# Install-time benchmark for knot vs other package managers.
#
# Measures cold + warm install time and peak memory for a chosen
# fixture across knot, pnpm, npm, bun. Cold runs wipe each tool's
# global cache/store first; warm runs only clear node_modules.
#
# macOS and Linux are supported (different `/usr/bin/time` flags).
set -euo pipefail

show_help() {
  cat <<'EOF'
Usage: tools/bench/run.sh [options]

Options:
  --fixture NAME   fixture under tools/compat_test/fixtures (default: vite-react)
  --runs N         repetitions per scenario; medians are reported (default: 3)
  --tools LIST     comma-separated subset of: knot,pnpm,npm,bun (default: knot,pnpm)
  --knot-bin PATH  use an existing knot binary; otherwise dart build cli is invoked
  -h, --help       this help

Example:
  tools/bench/run.sh --fixture vite-react --tools knot,pnpm --runs 5
EOF
}

fixture="vite-react"
runs=3
tools_csv="knot,pnpm"
knot_bin="${KNOT_BIN:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixture) fixture="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --tools) tools_csv="$2"; shift 2 ;;
    --knot-bin) knot_bin="$2"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# --- platform-specific `/usr/bin/time` plumbing ------------------------------

case "$(uname -s)" in
  Darwin)
    # `/usr/bin/time -lp` prints `real`, `user`, `sys` plus extended
    # stats including `peak memory footprint` (in bytes).
    time_flag="-lp"
    parse_real() { awk '/^real/ {print $2}'; }
    parse_peak() { awk '/peak memory footprint/ {print $1}'; }
    ;;
  Linux)
    # `/usr/bin/time -v` prints `Elapsed (wall clock) time` (HH:MM:SS.SS)
    # and `Maximum resident set size (kbytes)`.
    time_flag="-v"
    parse_real() {
      awk '/Elapsed \(wall/ {
        n=split($NF, parts, ":")
        if (n == 3) print parts[1]*3600 + parts[2]*60 + parts[3]
        else        print parts[1]*60 + parts[2]
      }'
    }
    parse_peak() {
      awk '/Maximum resident set size/ {printf "%d", $NF * 1024}'
    }
    ;;
  *)
    echo "unsupported OS: $(uname -s) (macOS / Linux only)" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_dir="$repo_root/tools/compat_test/fixtures/$fixture"
[ -d "$fixture_dir" ] || { echo "fixture not found: $fixture_dir" >&2; exit 64; }

# Build knot if no binary was supplied.
if [ -z "$knot_bin" ]; then
  build_dir="$(mktemp -d -t knot-bench.XXXXXX)"
  trap 'rm -rf "$build_dir"' EXIT
  echo "building knot binary (one-time)..." >&2
  (cd "$repo_root" && dart build cli -o "$build_dir" >/dev/null)
  bin_name="knot"
  [ "$(uname -s)" = "Windows_NT" ] && bin_name="knot.exe"
  knot_bin="$build_dir/bundle/bin/$bin_name"
fi
[ -x "$knot_bin" ] || { echo "knot binary not executable: $knot_bin" >&2; exit 1; }

# --- per-tool helpers --------------------------------------------------------

clear_global_cache() {
  case "$1" in
    knot)
      rm -rf "$HOME/.knot/cache" "$HOME/.knot/store"
      ;;
    pnpm)
      rm -rf "$HOME/Library/pnpm/store" \
             "$HOME/.local/share/pnpm/store" \
             "$HOME/Library/Caches/pnpm" \
             "$HOME/.cache/pnpm"
      ;;
    npm)
      rm -rf "$HOME/.npm/_cacache"
      ;;
    bun)
      rm -rf "$HOME/.bun/install/cache"
      ;;
  esac
}

clear_project() {
  rm -rf "$fixture_dir/node_modules" \
         "$fixture_dir/package-lock.json" \
         "$fixture_dir/pnpm-lock.yaml" \
         "$fixture_dir/bun.lock" \
         "$fixture_dir/bun.lockb" \
         "$fixture_dir/yarn.lock"
}

tool_command() {
  case "$1" in
    knot) echo "$knot_bin install" ;;
    pnpm) echo "pnpm install --ignore-scripts" ;;
    npm)  echo "npm install --ignore-scripts" ;;
    bun)  echo "bun install --ignore-scripts" ;;
  esac
}

# Run one install, print "<seconds> <peak_bytes>".
run_once() {
  local cmd
  cmd="$(tool_command "$1")"
  local stderr_log
  stderr_log="$(mktemp)"
  (cd "$fixture_dir" && /usr/bin/time $time_flag $cmd >/dev/null 2>"$stderr_log") \
    || { echo "install failed for $1:" >&2; cat "$stderr_log" >&2; rm -f "$stderr_log"; return 1; }
  local real peak
  real="$(parse_real < "$stderr_log")"
  peak="$(parse_peak < "$stderr_log")"
  rm -f "$stderr_log"
  echo "$real $peak"
}

median() {
  # numbers on stdin, one per line.
  sort -n | awk '
    {a[NR]=$1}
    END {
      if (NR == 0)        {print "0"}
      else if (NR % 2)    {print a[(NR+1)/2]}
      else                {print (a[NR/2] + a[NR/2+1]) / 2}
    }'
}

format_ms() { awk -v s="$1" 'BEGIN {printf "%d ms", s * 1000}'; }
format_mb() { awk -v b="$1" 'BEGIN {printf "%.1f MB", b / 1024 / 1024}'; }

# --- main loop ---------------------------------------------------------------

echo "## bench: $fixture (median of $runs runs)"
echo
echo "| tool | scenario | time | peak memory |"
echo "|------|----------|------|-------------|"

IFS=',' read -ra tool_list <<< "$tools_csv"
for tool in "${tool_list[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1 && [ "$tool" != "knot" ]; then
    echo "| $tool | — | (not on PATH, skipped) | |"
    continue
  fi
  for scenario in cold warm; do
    times=() peaks=()
    for _ in $(seq 1 "$runs"); do
      clear_project
      [ "$scenario" = "cold" ] && clear_global_cache "$tool"
      # warm scenarios need an established lockfile/cache from a
      # prior run; do a single seed install when needed.
      if [ "$scenario" = "warm" ] && [ ! -d "$fixture_dir/node_modules" ]; then
        (cd "$fixture_dir" && $(tool_command "$tool") >/dev/null 2>&1 || true)
        rm -rf "$fixture_dir/node_modules"
      fi
      read -r t p <<< "$(run_once "$tool")"
      times+=("$t")
      peaks+=("$p")
    done
    median_t=$(printf '%s\n' "${times[@]}" | median)
    median_p=$(printf '%s\n' "${peaks[@]}" | median)
    echo "| $tool | $scenario | $(format_ms "$median_t") | $(format_mb "$median_p") |"
  done
done
