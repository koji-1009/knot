#!/usr/bin/env bash
# Run `knot install` N times on a fixture with KNOT_PROFILE=1, parse
# the phase marks, and print min / median / max for each phase plus
# the total wall time.
#
# Each iteration wipes:
#   - $HOME/.knot/cache  + $HOME/.knot/store   (cold packument + tarball)
#   - <fixture>/node_modules + lockfiles        (forces resolve + link)
#
# Usage: tools/bench/install_phases.sh <knot-bin> <fixture-dir> [runs]
set -euo pipefail

knot_bin="${1:?usage: $0 <knot-bin> <fixture-dir> [runs]}"
fixture_dir="${2:?usage: $0 <knot-bin> <fixture-dir> [runs]}"
runs="${3:-5}"

[ -x "$knot_bin" ] || { echo "knot binary not executable: $knot_bin" >&2; exit 1; }
[ -d "$fixture_dir" ] || { echo "fixture not found: $fixture_dir" >&2; exit 1; }

raw=$(mktemp)
trap 'rm -f "$raw"' EXIT

for i in $(seq 1 "$runs"); do
  rm -rf "$HOME/.knot/cache" "$HOME/.knot/store" \
         "$fixture_dir/node_modules" \
         "$fixture_dir/package-lock.json" \
         "$fixture_dir/pnpm-lock.yaml"
  echo "=== run $i ===" >> "$raw"
  (cd "$fixture_dir" && KNOT_PROFILE=1 "$knot_bin" install 2>&1) >> "$raw"
done

# Phases of interest, in install_operation.dart `mark()` call order.
# Each entry: <label-regex> <display-name>
declare -a phases=(
  "warmup packuments|warmup"
  "resolver \(packument fetches|resolver"
  "fetch tarballs \+ ingest|fetch_tarballs"
  "linker \(materialize|linker"
)

extract_ms() {
  # Pulls the trailing "<N>ms" off a line.
  awk -F'[: ]' '{
    for (i = NF; i > 0; i--) {
      if (match($i, /^[0-9]+ms$/)) {
        sub("ms", "", $i); print $i; next
      }
    }
  }'
}

median() {
  sort -n | awk '{a[NR]=$1} END{
    if (NR == 0) {print "N/A"}
    else if (NR % 2) {print a[(NR+1)/2]}
    else {print (a[NR/2] + a[NR/2+1]) / 2}
  }'
}

printf '%-20s %8s %8s %8s\n' "phase" "min" "median" "max"
printf '%-20s %8s %8s %8s\n' "-----" "---" "------" "---"
for entry in "${phases[@]}"; do
  pattern="${entry%%|*}"
  name="${entry##*|}"
  values=$(grep -E "PHASE $pattern" "$raw" | extract_ms)
  if [ -z "$values" ]; then
    printf '%-20s %8s %8s %8s\n' "$name" "-" "-" "-"
    continue
  fi
  min=$(echo "$values" | sort -n | head -1)
  med=$(echo "$values" | median)
  max=$(echo "$values" | sort -n | tail -1)
  printf '%-20s %8s %8s %8s\n' "$name" "$min" "$med" "$max"
done

# Total: from `installed N packages (removed M, <X>ms)`.
totals=$(grep -oE 'installed [0-9]+ packages \(removed [0-9]+, [0-9]+ms\)' "$raw" \
         | grep -oE '[0-9]+ms\)' | tr -d 'ms)')
if [ -n "$totals" ]; then
  min=$(echo "$totals" | sort -n | head -1)
  med=$(echo "$totals" | median)
  max=$(echo "$totals" | sort -n | tail -1)
  printf '%-20s %8s %8s %8s\n' "total" "$min" "$med" "$max"
fi
