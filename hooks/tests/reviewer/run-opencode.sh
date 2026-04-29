#!/bin/bash
# Reviewer test harness — OpenCode Zen variant.
#
# Mirrors run.sh but POSTs to /zen/v1/chat/completions (OpenAI-compatible)
# instead of Ollama's /api/chat. Used to benchmark free OpenCode Zen models
# (nemotron-3-super-free, big-pickle, minimax-m2.5-free) against the
# qwen3.5:9b-mxfp8 baseline that run.sh exercises.
#
# Why a parallel runner instead of refactoring run.sh:
#   - Smaller blast radius: run.sh is the trusted Ollama path; leave it alone.
#   - Different request shape (response_format vs format), different parse
#     path (.choices[0].message.content vs .message.content), different
#     auth header surface. A single pluggable runner would interleave two
#     code paths in every code block.
#
# Usage:
#   run-opencode.sh <wrapper-path> [N=runs] [usr-fixture]
#
# Env:
#   MODEL             Default nemotron-3-super-free
#   OPENCODE_HOST     Default https://opencode.ai
#   RUNS_PER_VERDICT  Inner calls per outer run; majority-vote verdict.
#                     Default 1.
#   OPENCODE_ZEN_API_KEY  When set, sent as Authorization: Bearer ... header.
#
# Pass criteria: identical to run.sh (fixture sidecar usr-NAME.expect.json).
# Per-run dumps land in runs/<wrapper-stem>__<fixture-stem>__opencode-<MODEL>/run-N.json
# (gitignored). When RUNS_PER_VERDICT>1, the dump wraps inner responses
# under {outer, inner:[...], majority_verdict, majority_violations}.
# Summary line shape is parse-compatible with run.sh.

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

USR="${USR:-$FIXTURES_DIR/usr-failing.md}"

[ -f "$WRAPPER" ] || { echo "no wrapper file: $WRAPPER" >&2; exit 2; }
[ -f "$USR" ]     || { echo "no user fixture: $USR" >&2; exit 2; }
[ -f "$LIB_DIR/compose-reviewer-prompt.sh" ] || { echo "missing $LIB_DIR/compose-reviewer-prompt.sh" >&2; exit 2; }
[ -f "$LIB_DIR/reviewer-schema.json" ]       || { echo "missing $LIB_DIR/reviewer-schema.json" >&2; exit 2; }
[ -f "$LIB_DIR/reviewer-call.sh" ]           || { echo "missing $LIB_DIR/reviewer-call.sh" >&2; exit 2; }
[ -f "$LIB_DIR/reviewer-filter.sh" ]         || { echo "missing $LIB_DIR/reviewer-filter.sh" >&2; exit 2; }

# shellcheck source=../../lib/compose-reviewer-prompt.sh
. "$LIB_DIR/compose-reviewer-prompt.sh"
# shellcheck source=../../lib/reviewer-call.sh
. "$LIB_DIR/reviewer-call.sh"
# shellcheck source=../../lib/reviewer-filter.sh
. "$LIB_DIR/reviewer-filter.sh"

OPENCODE_HOST="${OPENCODE_HOST:-https://opencode.ai}"
MODEL="${MODEL:-nemotron-3-super-free}"
MAX_TOKENS="${OPENCODE_MAX_TOKENS:-$REVIEWER_DEFAULT_MAX_TOKENS}"

# Compose system prompt the same way the production hook does.
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
  case "$USR_BASE" in
    usr-failing*) EXPECTED_VERDICT=fail ;;
    *)            EXPECTED_VERDICT=pass ;;
  esac
  TAIL_CONTAINS=""
  CITE_REGEX=""
fi

WRAPPER_STEM=$(basename "$WRAPPER" .md)
# Run dir name carries the model so concurrent benchmarks of different
# models don't overwrite each other's run-N.json.
MODEL_SLUG=$(printf '%s' "$MODEL" | tr '/:' '__')
RUN_DIR="$SCRIPT_DIR/runs/${WRAPPER_STEM}__${USR_BASE}__opencode-${MODEL_SLUG}"
mkdir -p "$RUN_DIR"

if [ "$RUNS_PER_VERDICT" -eq 1 ]; then
  MODE="single"
else
  MODE="N=${RUNS_PER_VERDICT}-majority"
fi
MAJORITY_THRESHOLD=$(( RUNS_PER_VERDICT / 2 + 1 ))

# Auth header: only added when OPENCODE_ZEN_API_KEY is set.
OPENCODE_AUTH_HEADER=()
if [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
  OPENCODE_AUTH_HEADER=(-H "Authorization: Bearer $OPENCODE_ZEN_API_KEY")
fi

PASS=0; FAIL=0; HIT=0; PARSE_OK=0
LATENCIES=()
for i in $(seq 1 "$N"); do
  BASE_SEED=$(( i + 42 ))
  INNER_RAWS=()
  INNER_OUTS=()
  INNER_VERDICTS=()
  INNER_PASS=0
  INNER_FAIL=0
  FIRST_FAIL_RAW=""
  OUTER_T0=$(date +%s)
  for j in $(seq 1 "$RUNS_PER_VERDICT"); do
    SEED=$(( BASE_SEED + j - 1 ))
    REQ=$(jq -n \
      --arg model "$MODEL" \
      --rawfile sys "$SYS_TMP" \
      --rawfile usr "$USR" \
      --slurpfile schema_arr "$SCHEMA_FILE" \
      --argjson seed "$SEED" \
      --argjson max_tokens "$MAX_TOKENS" \
      '{
        model: $model,
        stream: false,
        max_tokens: $max_tokens,
        max_completion_tokens: $max_tokens,
        temperature: 0.3,
        top_p: 0.9,
        seed: $seed,
        response_format: {
          type: "json_schema",
          json_schema: { name: "reviewer_verdict", schema: $schema_arr[0], strict: false }
        },
        messages: [
          { role: "system", content: $sys },
          { role: "user",   content: $usr }
        ]
      }')
    SEND_PATH=$(mktemp)
    printf '%s' "$REQ" > "$SEND_PATH"
    OUT=$(timeout 240 curl -s --max-time 240 -X POST "$OPENCODE_HOST/zen/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      ${OPENCODE_AUTH_HEADER[@]+"${OPENCODE_AUTH_HEADER[@]}"} \
      --data-binary "@$SEND_PATH" 2>/dev/null)
    rm -f "$SEND_PATH"
    INNER_OUTS+=("$OUT")
    # Extract content; strip optional ```json / ``` fences (same sed pattern
    # as system-prompt-reviewer.sh's RAW->RESULT step) so we get the verdict
    # JSON cleanly even when the model wraps it in a code fence.
    INNER_RAW=$(echo "$OUT" | jq -r '.choices[0].message.content // empty' 2>/dev/null \
                | sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d' \
                | sed -E '/^[[:space:]]*```[[:space:]]*$/d')
    # Apply the shingle filter so harness measures production behavior.
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

  if [ "$INNER_PASS" -ge "$MAJORITY_THRESHOLD" ]; then
    VERDICT="pass"
    RAW='{"verdict":"pass","violations":[]}'
  elif [ "$INNER_FAIL" -ge 1 ]; then
    VERDICT="fail"
    RAW="$FIRST_FAIL_RAW"
  else
    VERDICT="?"
    RAW="${INNER_RAWS[-1]}"
  fi

  if [ "$VERDICT" = "pass" ] || [ "$VERDICT" = "fail" ]; then
    PARSE_OK=$((PARSE_OK + 1))
  fi

  TAIL=$(echo "$RAW" | jq -r '.assistant_tail_quote // ""' 2>/dev/null)
  TAIL_OK=Y
  if [ -n "$TAIL_CONTAINS" ]; then
    if echo "$TAIL" | grep -qiF "$TAIL_CONTAINS"; then TAIL_OK=Y; else TAIL_OK=N; fi
  fi

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

  if [ "$RUNS_PER_VERDICT" -eq 1 ]; then
    printf '%s\n' "${INNER_OUTS[0]}" > "$RUN_DIR/run-$i.json"
  else
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
printf 'summary wrapper=%s usr=%s expected=%s mode=%s model=%s: pass=%d fail=%d hit=%d/%d parse_ok=%d/%d p50=%ds p95=%ds\n' \
       "$WRAPPER_STEM" "$USR_BASE" "$EXPECTED_VERDICT" "$MODE" "$MODEL" \
       "$PASS" "$FAIL" "$HIT" "$N" "$PARSE_OK" "$N" "$P50" "$P95"
