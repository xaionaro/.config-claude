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
# Pass criterion (per fixture sidecar usr-NAME.expect.json):
#   { "expected_verdict": "pass" }                — verdict must be "pass"
#   { "expected_verdict": "fail",
#     "tail_contains":   "<substring>",           — model assistant_tail_quote
#                                                   (when emitted) substring match
#     "cite_regex":      "<extended regex>" }     — violations array must cite
#                                                   the rule class
#
# Per-run dumps land in runs/<wrapper-stem>__<fixture-stem>/run-N.json
# (gitignored). Exit 0 = harness ran cleanly; the per-run summary tells
# you whether the wrapper passes the criteria.

set -uo pipefail

WRAPPER="${1:-}"
N="${2:-3}"
USR="${3:-}"

if [ -z "$WRAPPER" ]; then
  echo "usage: $0 <wrapper-path> [N=runs] [usr-fixture]" >&2
  exit 2
fi

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

PASS=0; FAIL=0; HIT=0; PARSE_OK=0
LATENCIES=()
for i in $(seq 1 "$N"); do
  OPTIONS=$(reviewer_ollama_options $((i + 42)))
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
  T0=$(date +%s)
  OUT=$(timeout 240 curl -s --max-time 240 -X POST "$HOST/api/chat" \
    -H 'Content-Type: application/json' --data "$REQ" 2>/dev/null)
  T1=$(date +%s)
  ELAPSED=$((T1 - T0))
  LATENCIES+=("$ELAPSED")
  RAW=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
  VERDICT=$(echo "$RAW" | jq -r '.verdict // "?"' 2>/dev/null)
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

  printf 'run %d: verdict=%s elapsed=%ds tail_ok=%s cite_ok=%s\n' \
         "$i" "$VERDICT" "$ELAPSED" "$TAIL_OK" "$CITE_OK"
  echo "$RAW" | jq -r '.violations[]? | "    rule: \(.rule)\n    evid: \(.evidence|.[0:160])"' 2>/dev/null
  printf '%s\n' "$OUT" > "$RUN_DIR/run-$i.json"

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
printf 'summary wrapper=%s usr=%s expected=%s: pass=%d fail=%d hit=%d/%d parse_ok=%d/%d p50=%ds p95=%ds\n' \
       "$WRAPPER_STEM" "$USR_BASE" "$EXPECTED_VERDICT" \
       "$PASS" "$FAIL" "$HIT" "$N" "$PARSE_OK" "$N" "$P50" "$P95"
