#!/bin/bash
# Reviewer test harness: replays a USER fixture against an Ollama backend
# using a pluggable wrapper. Composes the full system prompt the same way
# the production stop hook does (lib/compose-reviewer-prompt.sh) so test
# results track production behavior.
#
# CLAUDE_ROLE not set; this script invokes the LLM directly via curl.
# (The production stop hook checks CLAUDE_ROLE to skip when running as a
# subagent — we are not a hook here, so leaving it unset is correct.)
#
# Usage:
#   run.sh <wrapper-path> [N=runs] [usr-fixture]
#
# Env:
#   RUNS_PER_VERDICT  inner calls per outer run; majority-vote verdict.
#                     Default 1 (back-compat: identical to pre-change run).
#                     >1 enables N=K self-consistency mode.
#
# Pass criterion (per fixture sidecar usr-NAME.expect.json):
#   { "expected_verdict": "pass" }                — verdict must be "pass"
#   { "expected_verdict": "fail",
#     "tail_contains":   "<substring>",           — model assistant_tail_quote
#                                                   (when emitted) substring match
#     "cite_regex":      "<extended regex>" }     — violations array must cite
#                                                   the rule class
#
# Per-run dumps land in runs/<wrapper-stem>__<fixture-stem>/run-N.json
# (gitignored). When RUNS_PER_VERDICT>1 the dump wraps all inner responses
# under {outer, inner:[...], majority_verdict, majority_violations}.
# Exit 0 = harness ran cleanly; the per-run summary tells you whether the
# wrapper passes the criteria.

set -uo pipefail

WRAPPER="${1:-}"
N="${2:-3}"
USR="${3:-}"
RUNS_PER_VERDICT="${RUNS_PER_VERDICT:-1}"

if [ -z "$WRAPPER" ]; then
  echo "usage: $0 <wrapper-path> [N=runs] [usr-fixture]" >&2
  exit 2
fi

case "$RUNS_PER_VERDICT" in
  ''|*[!0-9]*) echo "RUNS_PER_VERDICT must be a positive integer (got: '$RUNS_PER_VERDICT')" >&2; exit 2 ;;
esac
[ "$RUNS_PER_VERDICT" -lt 1 ] && { echo "RUNS_PER_VERDICT must be >=1" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$HOOKS_DIR/lib"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Default fixture if none supplied.
USR="${USR:-$FIXTURES_DIR/usr-failing.md}"

[ -f "$WRAPPER" ] || { echo "no wrapper file: $WRAPPER" >&2; exit 2; }
[ -f "$USR" ]     || { echo "no user fixture: $USR" >&2; exit 2; }
[ -f "$LIB_DIR/compose-reviewer-prompt.sh" ] || { echo "missing $LIB_DIR/compose-reviewer-prompt.sh" >&2; exit 2; }
[ -f "$LIB_DIR/reviewer-schema.json" ]       || { echo "missing $LIB_DIR/reviewer-schema.json" >&2; exit 2; }
[ -f "$LIB_DIR/reviewer-call.sh" ]           || { echo "missing $LIB_DIR/reviewer-call.sh" >&2; exit 2; }

# shellcheck source=../../lib/compose-reviewer-prompt.sh
. "$LIB_DIR/compose-reviewer-prompt.sh"
# shellcheck source=../../lib/reviewer-call.sh
. "$LIB_DIR/reviewer-call.sh"
# shellcheck source=../../lib/reviewer-filter.sh
. "$LIB_DIR/reviewer-filter.sh"

HOST="${OLLAMA_HOST:-$REVIEWER_DEFAULT_HOST}"
MODEL="${REVIEWER_MODEL:-$REVIEWER_DEFAULT_MODEL}"

# Compose the full system prompt the same way the production hook does.
SYS_TMP=$(mktemp)
trap 'rm -f "$SYS_TMP"' EXIT
compose_reviewer_prompt "$WRAPPER" > "$SYS_TMP"

SCHEMA_FILE="$LIB_DIR/reviewer-schema.json"

# Resolve pass criteria for this fixture.
USR_BASE=$(basename "$USR" .md)
EXPECT_FILE="$FIXTURES_DIR/$USR_BASE.expect.json"
if [ -f "$EXPECT_FILE" ]; then
  EXPECTED_VERDICT=$(jq -r '.expected_verdict // ""' "$EXPECT_FILE")
  TAIL_CONTAINS=$(jq -r '.tail_contains // ""'      "$EXPECT_FILE")
  CITE_REGEX=$(jq -r '.cite_regex // ""'            "$EXPECT_FILE")
else
  # Fixture-name convention fallback: usr-failing*.md → expect fail; else pass.
  case "$USR_BASE" in
    usr-failing*) EXPECTED_VERDICT=fail ;;
    *)            EXPECTED_VERDICT=pass ;;
  esac
  TAIL_CONTAINS=""
  CITE_REGEX=""
fi

# Per-fixture/wrapper run dump dir (mirrors /tmp/reviewer-iter/runs/ layout
# but inside the repo so dumps survive tmpfs wipes; gitignored).
WRAPPER_STEM=$(basename "$WRAPPER" .md)
RUN_DIR="$SCRIPT_DIR/runs/${WRAPPER_STEM}__${USR_BASE}"
mkdir -p "$RUN_DIR"

# Mode label for the summary line; runner.sh parses this to render a column.
if [ "$RUNS_PER_VERDICT" -eq 1 ]; then
  MODE="single"
else
  MODE="N=${RUNS_PER_VERDICT}-majority"
fi
MAJORITY_THRESHOLD=$(( RUNS_PER_VERDICT / 2 + 1 ))   # strict majority

PASS=0; FAIL=0; HIT=0; PARSE_OK=0
LATENCIES=()
for i in $(seq 1 "$N"); do
  # Inner loop: RUNS_PER_VERDICT calls with seed offsets 0..K-1 from a
  # deterministic per-outer base seed (i + 42, mirrors the legacy single-call
  # seeding so RUNS_PER_VERDICT=1 reproduces the old run.sh exactly).
  BASE_SEED=$(( i + 42 ))
  INNER_RAWS=()       # parsed JSON content, one per inner call
  INNER_OUTS=()       # raw HTTP responses, one per inner call
  INNER_VERDICTS=()
  INNER_PASS=0
  INNER_FAIL=0
  FIRST_FAIL_RAW=""
  OUTER_T0=$(date +%s)
  for j in $(seq 1 "$RUNS_PER_VERDICT"); do
    SEED=$(( BASE_SEED + j - 1 ))
    OPTIONS=$(reviewer_ollama_options "$SEED")
    REQ=$(jq -n \
      --arg model "$MODEL" \
      --rawfile sys "$SYS_TMP" \
      --rawfile usr "$USR" \
      --slurpfile schema_arr "$SCHEMA_FILE" \
      --argjson options "$OPTIONS" \
      '{
        model: $model,
        stream: false,
        think: false,
        format: $schema_arr[0],
        options: $options,
        messages: [
          { role: "system", content: $sys },
          { role: "user",   content: $usr }
        ]
      }')
    OUT=$(timeout 240 curl -s --max-time 240 -X POST "$HOST/api/chat" \
      -H 'Content-Type: application/json' --data "$REQ" 2>/dev/null)
    INNER_OUTS+=("$OUT")
    INNER_RAW=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
    # Apply the shingle filter so harness measures production behavior.
    # Filter is a no-op when verdict=pass or violations=[].
    if [ -n "$INNER_RAW" ]; then
      INNER_FILTERED=$(filter_violations "$INNER_RAW" 2>/dev/null)
      [ -n "$INNER_FILTERED" ] && INNER_RAW="$INNER_FILTERED"
    fi
    INNER_RAWS+=("$INNER_RAW")
    INNER_VERDICT=$(echo "$INNER_RAW" | jq -r '.verdict // "?"' 2>/dev/null)
    INNER_VERDICTS+=("$INNER_VERDICT")
    case "$INNER_VERDICT" in
      pass) INNER_PASS=$((INNER_PASS + 1)) ;;
      fail)
        INNER_FAIL=$((INNER_FAIL + 1))
        [ -z "$FIRST_FAIL_RAW" ] && FIRST_FAIL_RAW="$INNER_RAW"
        ;;
    esac
  done
  OUTER_T1=$(date +%s)
  ELAPSED=$(( OUTER_T1 - OUTER_T0 ))
  LATENCIES+=("$ELAPSED")

  # Majority-vote verdict. On tie (impossible for odd RUNS_PER_VERDICT, but
  # well-defined for even values too): pass-count must STRICTLY exceed
  # RUNS_PER_VERDICT/2 to emit pass; ties go to fail.
  if [ "$INNER_PASS" -ge "$MAJORITY_THRESHOLD" ]; then
    VERDICT="pass"
    RAW='{"verdict":"pass","violations":[]}'
  elif [ "$INNER_FAIL" -ge 1 ]; then
    VERDICT="fail"
    # Use first fail response's verdict+violations+tail so downstream tail/cite
    # regex enforcement keeps working unchanged.
    RAW="$FIRST_FAIL_RAW"
  else
    # No pass majority and no fail responses (all malformed) → propagate the
    # last inner raw so the malformed-verdict path below records something.
    VERDICT="?"
    RAW="${INNER_RAWS[-1]}"
  fi

  if [ "$VERDICT" = "pass" ] || [ "$VERDICT" = "fail" ]; then
    PARSE_OK=$((PARSE_OK + 1))
  fi

  # Tail: only enforced when fixture asks for it AND model emitted the field.
  TAIL=$(echo "$RAW" | jq -r '.assistant_tail_quote // ""' 2>/dev/null)
  TAIL_OK=Y
  if [ -n "$TAIL_CONTAINS" ]; then
    if echo "$TAIL" | grep -qiF "$TAIL_CONTAINS"; then TAIL_OK=Y; else TAIL_OK=N; fi
  fi

  # Cite regex against rule + evidence concatenated.
  CITE_OK=Y
  if [ -n "$CITE_REGEX" ]; then
    CITE_HITS=$(echo "$RAW" | jq -r '[.violations[]?.rule, .violations[]?.evidence] | tostring' 2>/dev/null \
                | grep -i -c -E "$CITE_REGEX" || true)
    if [ "${CITE_HITS:-0}" -gt 0 ]; then CITE_OK=Y; else CITE_OK=N; fi
  fi

  if [ "$RUNS_PER_VERDICT" -gt 1 ]; then
    INNER_VERDICTS_STR=$(IFS=,; echo "${INNER_VERDICTS[*]}")
    printf 'run %d: verdict=%s [inner=%s pass=%d fail=%d] elapsed=%ds tail_ok=%s cite_ok=%s\n' \
           "$i" "$VERDICT" "$INNER_VERDICTS_STR" "$INNER_PASS" "$INNER_FAIL" \
           "$ELAPSED" "$TAIL_OK" "$CITE_OK"
  else
    printf 'run %d: verdict=%s elapsed=%ds tail_ok=%s cite_ok=%s\n' \
           "$i" "$VERDICT" "$ELAPSED" "$TAIL_OK" "$CITE_OK"
  fi
  echo "$RAW" | jq -r '.violations[]? | "    rule: \(.rule)\n    evid: \(.evidence|.[0:160])"' 2>/dev/null

  # Dump: ONE JSON per outer run. Single mode preserves the legacy shape
  # (raw HTTP response). Multi mode wraps all inner responses for forensic
  # inspection, plus the majority decision.
  if [ "$RUNS_PER_VERDICT" -eq 1 ]; then
    printf '%s\n' "${INNER_OUTS[0]}" > "$RUN_DIR/run-$i.json"
  else
    # Build a JSON array of inner OUT responses (each is itself a JSON doc;
    # parse-or-string-fallback so malformed responses don't break the dump).
    INNER_JSON=$(
      for resp in "${INNER_OUTS[@]}"; do
        printf '%s' "$resp" | jq -c '.' 2>/dev/null || jq -nc --arg s "$resp" '{_unparseable_response:$s}'
      done | jq -sc '.'
    )
    MAJ_VIOL=$(echo "$RAW" | jq -c '.violations // []' 2>/dev/null || echo '[]')
    jq -n \
      --argjson outer "$i" \
      --argjson inner "$INNER_JSON" \
      --arg majority_verdict "$VERDICT" \
      --argjson majority_violations "$MAJ_VIOL" \
      --argjson inner_pass "$INNER_PASS" \
      --argjson inner_fail "$INNER_FAIL" \
      '{
        outer: $outer,
        runs_per_verdict: ($inner | length),
        inner_pass: $inner_pass,
        inner_fail: $inner_fail,
        majority_verdict: $majority_verdict,
        majority_violations: $majority_violations,
        inner: $inner
      }' > "$RUN_DIR/run-$i.json"
  fi

  case "$VERDICT" in
    pass)
      PASS=$((PASS + 1))
      [ "$EXPECTED_VERDICT" = "pass" ] && HIT=$((HIT + 1))
      ;;
    fail)
      FAIL=$((FAIL + 1))
      if [ "$EXPECTED_VERDICT" = "fail" ] && [ "$TAIL_OK" = "Y" ] && [ "$CITE_OK" = "Y" ]; then
        HIT=$((HIT + 1))
      fi
      ;;
  esac
done

# P50 / P95 latency.
SORTED=($(printf '%s\n' "${LATENCIES[@]}" | sort -n))
COUNT=${#SORTED[@]}
P50_IDX=$(( (COUNT * 50) / 100 ))
P95_IDX=$(( (COUNT * 95) / 100 ))
[ "$P50_IDX" -ge "$COUNT" ] && P50_IDX=$((COUNT - 1))
[ "$P95_IDX" -ge "$COUNT" ] && P95_IDX=$((COUNT - 1))
P50=${SORTED[$P50_IDX]}
P95=${SORTED[$P95_IDX]}

echo "---"
printf 'summary wrapper=%s usr=%s expected=%s mode=%s: pass=%d fail=%d hit=%d/%d parse_ok=%d/%d p50=%ds p95=%ds\n' \
       "$WRAPPER_STEM" "$USR_BASE" "$EXPECTED_VERDICT" "$MODE" \
       "$PASS" "$FAIL" "$HIT" "$N" "$PARSE_OK" "$N" "$P50" "$P95"
