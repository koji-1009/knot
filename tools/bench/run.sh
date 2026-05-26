#!/usr/bin/env bash
# Install-time benchmark for knot vs other package managers.
#
# Measures cold + warm install time and peak memory for a chosen
# fixture across knot, pnpm, npm, bun.
#
# Cold is measured INTERLEAVED: each round installs every tool
# back-to-back, in a shuffled order, each into its own fresh temporary
# cache (the host's real caches are never touched), so all tools see the
# same network window. Measuring each tool in its own block instead lets
# a drifting connection hand whichever block hit the faster window a
# misleading lead — cold is network-bound. Warm clears only node_modules
# and reuses the seeded cache (network-independent, so a per-tool block
# is fine).
#
# Defaults are asymmetric on purpose:
#   - cold = 15 runs.  Network-bound; observed spreads of 5x are
#     common, so 15 samples is the minimum that yields a stable
#     median without pounding the CDN.
#   - warm = 20 runs.  No network cost (packument freshness window +
#     store hits make warm a pure local-CPU/IO scenario), so sampling
#     more is free.
#
# Warm timings here come from `/usr/bin/time`, which on macOS reports
# `real` at 0.01s resolution. That is too coarse for sub-100ms tools
# (bun warm pegs at 0). For ms-precise warm timings drive each tool
# through hyperfine separately:
#   hyperfine --warmup 2 --runs 20 --prepare 'rm -rf node_modules' \
#     '<tool> install'
#
# macOS and Linux are supported (different `/usr/bin/time` flags).
set -euo pipefail

show_help() {
  cat <<'EOF'
Usage: tools/bench/run.sh [options]

Options:
  --fixture NAME     fixture under tools/compat_test/fixtures (default: vite-react)
  --cold-runs N      cold-scenario repetitions (default: 15)
  --warm-runs N      warm-scenario repetitions (default: 20)
  --runs N           shortcut that sets both cold-runs and warm-runs to N
  --tools LIST       comma-separated subset of: knot,pnpm,npm,bun (default: knot,pnpm)
  --knot-bin PATH    use an existing knot binary; otherwise dart build cli is invoked
  -h, --help         this help

Example:
  tools/bench/run.sh --fixture vite-react --tools knot,pnpm,npm,bun
EOF
}

fixture="vite-react"
cold_runs=15
warm_runs=20
tools_csv="knot,pnpm"
knot_bin="${KNOT_BIN:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixture)   fixture="$2"; shift 2 ;;
    --cold-runs) cold_runs="$2"; shift 2 ;;
    --warm-runs) warm_runs="$2"; shift 2 ;;
    --runs)      cold_runs="$2"; warm_runs="$2"; shift 2 ;;
    --tools)     tools_csv="$2"; shift 2 ;;
    --knot-bin)  knot_bin="$2"; shift 2 ;;
    -h|--help)   show_help; exit 0 ;;
    *)           echo "unknown arg: $1" >&2; exit 64 ;;
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
# Absolutize: install commands run after `cd "$fixture_dir"`, so a relative
# --knot-bin (e.g. build/bundle/bin/knot) would otherwise fail to resolve.
case "$knot_bin" in
  /*) ;;
  *) knot_bin="$(cd "$(dirname "$knot_bin")" && pwd)/$(basename "$knot_bin")" ;;
esac

# --- per-tool helpers --------------------------------------------------------

# Cold install command pointed at a *fresh, empty* per-tool cache, so the
# run is genuinely cold without wiping the host's real caches. Each tool
# takes its cache location differently.
cold_command() {
  case "$1" in
    knot) echo "env HOME=$2 $knot_bin install" ;;
    pnpm) echo "pnpm install --ignore-scripts --store-dir $2" ;;
    npm)  echo "npm install --ignore-scripts --cache $2" ;;
    bun)  echo "env BUN_INSTALL_CACHE_DIR=$2 bun install --ignore-scripts" ;;
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

# Run one install (warm, via the tool's standard command), print
# "<seconds> <peak_bytes>".
run_once() { run_once_cmd "$1" "$(tool_command "$1")"; }

# Run one install from an explicit command string (used for cold, where
# the command carries a per-run temp-cache flag). Print "<seconds> <peak_bytes>".
run_once_cmd() {
  local label="$1" cmd="$2"
  local stderr_log
  stderr_log="$(mktemp)"
  (cd "$fixture_dir" && /usr/bin/time $time_flag $cmd >/dev/null 2>"$stderr_log") \
    || { echo "install failed for $label:" >&2; cat "$stderr_log" >&2; rm -f "$stderr_log"; return 1; }
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

min() { sort -n | head -1; }
max() { sort -n | tail -1; }

format_ms() {
  # `%d` truncates to zero for sub-ms runs (bun-warm hits this);
  # `%.1f` keeps a digit for small values without faking precision
  # at the second scale.
  awk -v s="$1" 'BEGIN {
    ms = s * 1000
    if (ms >= 100) printf "%d ms", ms
    else           printf "%.1f ms", ms
  }'
}
format_mb() { awk -v b="$1" 'BEGIN {printf "%.1f MB", b / 1024 / 1024}'; }

# --- main loop ---------------------------------------------------------------

# Resolve the requested tools to those actually runnable.
IFS=',' read -ra requested <<< "$tools_csv"
tool_list=()
for tool in "${requested[@]}"; do
  if [ "$tool" = knot ] || command -v "$tool" >/dev/null 2>&1; then
    tool_list+=("$tool")
  else
    echo "skipping $tool (not on PATH)" >&2
  fi
done

# Per-tool result files: <tool>.<scenario>.{t,p} = one time / peak per line.
resdir="$(mktemp -d -t knot-bench-res.XXXXXX)"
collect() { # collect <tool> <scenario> < "real peak"
  read -r t p
  echo "$t" >> "$resdir/$1.$2.t"
  echo "$p" >> "$resdir/$1.$2.p"
}

# --- cold: interleaved -------------------------------------------------------
# Cold is network-bound and the connection drifts over minutes, so measuring
# each tool in its own block can hand whichever block hit the faster window a
# misleading lead. Instead, each round installs every tool back-to-back (in a
# shuffled order) into its own *fresh temp cache* — host caches untouched — so
# all tools share one network window.
for _ in $(seq 1 "$cold_runs"); do
  shuffled="$(printf '%s\n' "${tool_list[@]}" \
    | awk 'BEGIN{srand()}{print rand()"\t"$0}' | sort -n | cut -f2-)"
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    clear_project
    cache="$(mktemp -d -t knot-bench-cache.XXXXXX)"
    if out="$(run_once_cmd "$tool" "$(cold_command "$tool" "$cache")")"; then
      printf '%s\n' "$out" | collect "$tool" cold
    fi
    rm -rf "$cache"
  done <<< "$shuffled"
done

# --- warm: per-tool block ----------------------------------------------------
# Warm is network-independent (packument freshness + store hits), so a block
# per tool is fine. Seed once to establish the lockfile + host cache, then time
# repeated relinks (node_modules cleared each run, lockfile/cache kept).
for tool in "${tool_list[@]}"; do
  clear_project
  (cd "$fixture_dir" && $(tool_command "$tool") >/dev/null 2>&1 || true)
  for _ in $(seq 1 "$warm_runs"); do
    rm -rf "$fixture_dir/node_modules"
    if out="$(run_once "$tool")"; then
      printf '%s\n' "$out" | collect "$tool" warm
    fi
  done
done

# --- table -------------------------------------------------------------------
echo "## bench: $fixture (cold N=$cold_runs interleaved / warm N=$warm_runs)"
echo
echo "| tool | scenario | best | median | worst | peak memory |"
echo "|------|----------|------|--------|-------|-------------|"
for tool in "${tool_list[@]}"; do
  for scenario in cold warm; do
    tf="$resdir/$tool.$scenario.t"
    pf="$resdir/$tool.$scenario.p"
    [ -s "$tf" ] || continue
    min_t=$(min < "$tf")
    median_t=$(median < "$tf")
    max_t=$(max < "$tf")
    median_p=$(median < "$pf")
    echo "| $tool | $scenario | $(format_ms "$min_t") | $(format_ms "$median_t") | $(format_ms "$max_t") | $(format_mb "$median_p") |"
  done
done

rm -rf "$resdir"
