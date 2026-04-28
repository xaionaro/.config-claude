#!/usr/bin/env bash
# Reviewer aggregator: runs every (wrapper x fixture) pair through run.sh,
# parses each per-pair summary line, and prints a table plus an OVERALL
# score. Exits 0 iff overall percentage >= THRESHOLD (default 80).
#
# Usage:
#   runner.sh [N=runs] [THRESHOLD=percent]
#
# Env overrides:
#   RUNS       — runs per pair (default 10; CLI arg wins over env)
#   THRESHOLD  — pass/fail percentage cutoff (default 80; CLI arg wins)
#
# Discovers:
#   wrappers : hooks/tests/reviewer/wrappers/*.md
#   fixtures : hooks/tests/reviewer/fixtures/usr-*.md
#
# Each per-pair summary line from run.sh looks like:
#   summary wrapper=<stem> usr=<stem> expected=<v>: pass=N fail=N hit=H/T parse_ok=P/T p50=Xs p95=Ys
# We extract `wrapper=`, `usr=`, and `hit=H/T`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="$SCRIPT_DIR/run.sh"
WRAPPERS_DIR="$SCRIPT_DIR/wrappers"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

[ -x "$RUN_SH" ] || { echo "missing or non-exec: $RUN_SH" >&2; exit 2; }

N="${1:-${RUNS:-10}}"
THRESHOLD="${2:-${THRESHOLD:-80}}"

# Collect inputs.
shopt -s nullglob
WRAPPERS=( "$WRAPPERS_DIR"/*.md )
FIXTURES=( "$FIXTURES_DIR"/usr-*.md )
shopt -u nullglob

if [ "${#WRAPPERS[@]}" -eq 0 ]; then
  echo "no wrappers found in $WRAPPERS_DIR" >&2; exit 2
fi
if [ "${#FIXTURES[@]}" -eq 0 ]; then
  echo "no fixtures found in $FIXTURES_DIR" >&2; exit 2
fi

# Per-pair results keyed by "wrapper_stem|fixture_stem".
declare -a ROWS=()
TOTAL_HIT=0
TOTAL_RUNS=0

for w in "${WRAPPERS[@]}"; do
  for f in "${FIXTURES[@]}"; do
    w_stem=$(basename "$w" .md)
    f_stem=$(basename "$f" .md)
    echo "=== $w_stem x $f_stem (N=$N) ==="
    # Capture run.sh stdout while still streaming it to the user.
    out_file=$(mktemp)
    # shellcheck disable=SC2024
    "$RUN_SH" "$w" "$N" "$f" 2>&1 | tee "$out_file"
    # Parse the summary line.
    sum_line=$(grep -E '^summary ' "$out_file" | tail -n 1)
    rm -f "$out_file"
    if [ -z "$sum_line" ]; then
      echo "warn: no summary line for $w_stem x $f_stem" >&2
      ROWS+=( "$w_stem|$f_stem|0|$N" )
      TOTAL_RUNS=$((TOTAL_RUNS + N))
      continue
    fi
    # hit=H/T
    hit_pair=$(echo "$sum_line" | grep -oE 'hit=[0-9]+/[0-9]+' | head -n 1 | sed 's/^hit=//')
    H="${hit_pair%/*}"
    T="${hit_pair#*/}"
    : "${H:=0}" "${T:=$N}"
    ROWS+=( "$w_stem|$f_stem|$H|$T" )
    TOTAL_HIT=$((TOTAL_HIT + H))
    TOTAL_RUNS=$((TOTAL_RUNS + T))
  done
done

# Render table.
echo
echo "===== AGGREGATED SCORES ====="
printf '%-20s %-22s %s\n' "wrapper" "fixture" "score"
printf '%-20s %-22s %s\n' "-------" "-------" "-----"
for row in "${ROWS[@]}"; do
  IFS='|' read -r w_stem f_stem H T <<<"$row"
  printf '%-20s %-22s %d/%d\n' "$w_stem" "$f_stem" "$H" "$T"
done
echo "----------------------------------------------------------"

if [ "$TOTAL_RUNS" -eq 0 ]; then
  echo "OVERALL                                      0/0  (0%)"
  echo "no runs executed" >&2
  exit 2
fi

# Integer percent (floor). Use bash arithmetic (no bc dependency).
PCT=$(( (TOTAL_HIT * 100) / TOTAL_RUNS ))
printf 'OVERALL                                      %d/%d  (%d%%)\n' \
       "$TOTAL_HIT" "$TOTAL_RUNS" "$PCT"
echo "threshold: ${THRESHOLD}%"

if [ "$PCT" -ge "$THRESHOLD" ]; then
  exit 0
else
  exit 1
fi
