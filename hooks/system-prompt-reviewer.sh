#!/bin/bash
# Stop hook (synchronous block): runs an EXTERNAL Ollama reviewer to score
# the just-finished turn against CLAUDE.md + the curated reviewer-rules.md.
# On detected violations, prints {"decision":"block","reason":<violations>}
# to stdout and exits 0 — Claude Code holds the stop and feeds the reason
# back to the agent so it must actually correct the violations before the
# turn can end. (Earlier asyncRewake design proved too easy to ignore.)
#
# Coexists with stop-gate.sh: that one validates the proof's structure;
# this one critiques the conduct. Both fire on Stop in parallel.
#
# Cost / latency gates:
#   - skip on user-touched bypass marker
#   - timeout 240s on the model call
#   - track consecutive-fail streak (informational; bypass marker is the
#     escape hatch when the reviewer is wrong)
# Note: fires on every Stop pass (including stop_hook_active=true) so
# post-correction state is also verified.

set -uo pipefail

OLLAMA_HOST="http://192.168.0.171:11434"
MODEL="qwen3.5:9b-mxfp8"

# Invocation log: append one line per call regardless of outcome so the user
# can tell whether the hook fired and which branch it took. Lives outside
# $PROOF_DIR so it survives stop-cycle wipe.
LOG_DIR="$HOME/.cache/claude-proof/reviewer"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/invocations.log"
log() { printf '%s pid=%d %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*" >> "$LOG"; }

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // empty')

log "enter session=${SESSION_ID:-EMPTY} stop_active=${STOP_ACTIVE:-EMPTY}"

[ -z "$SESSION_ID" ] && { log "exit reason=empty-session"; exit 0; }
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) log "exit reason=unsafe-session-id"; exit 0 ;;
esac

# NOTE: previously skipped when stop_hook_active=true to save cost on
# second-pass stops. Under sync-block design that's wrong: the reviewer
# must verify the agent's *correction* work too, not only the pre-block
# state. Re-fire on every pass — cost is bounded by 240s timeout and
# warm-call latency (5-22s observed).

# Reviewer reads the transcript directly (per the rule-source-not-narrative
# redesign), so it does not need proof.md / summary-to-print.md to exist.
# The transcript JSONL is always present for any session that ever ran.

# State outside $PROOF_DIR so it survives stop-cycle wipe.
STATE_DIR="$HOME/.cache/claude-proof/reviewer/$SESSION_ID"
mkdir -p "$STATE_DIR"
BYPASS_MARKER="$STATE_DIR/bypass"
STREAK_FILE="$STATE_DIR/streak"

# User-acknowledged bypass: skip review until removed.
[ -f "$BYPASS_MARKER" ] && { log "exit reason=bypass-marker"; exit 0; }

RULES_WRAPPER="$HOME/.claude/hooks/reviewer-rules.md"
INSTRUCTIONS="$HOME/.claude/CLAUDE.md"
[ ! -f "$RULES_WRAPPER" ] && { log "exit reason=missing-wrapper"; exit 0; }
[ ! -f "$INSTRUCTIONS" ] && { log "exit reason=missing-claude-md"; exit 0; }

# Build the system message: wrapper preamble + user's CLAUDE.md as the
# instructions the reviewer scores against.
RULES=$(mktemp)
{
  cat "$RULES_WRAPPER"
  echo
  cat "$INSTRUCTIONS"
} > "$RULES"
trap 'rm -f "$RULES"' EXIT

# Build user-message body: raw transcript turns (user prompts + assistant
# text + tool-use names/inputs) + repo diff. Intentionally does NOT feed
# the agent's own proof.md — the reviewer scores the agent's *conduct*
# from the raw transcript, not the agent's self-narrative which is the
# unreliable thing we're trying to externalize.
USER_BODY=$(mktemp)
{
  echo "## DIFF"
  git -C "$HOME/.claude" log --pretty=format:"%H %s" -5 2>/dev/null
  echo
  # Bound diff bytes: a huge diff (large refactor, generated files) blows
  # past Ollama's num_ctx and causes timeouts. Probe size first; if over
  # threshold, omit the diff body entirely — commit titles above are
  # enough context, and a mid-line truncation is misleading.
  DIFF_RAW=$(git -C "$HOME/.claude" diff HEAD~1..HEAD 2>/dev/null)
  DIFF_BYTES=$(printf %s "$DIFF_RAW" | wc -c | awk '{print $1}')
  DIFF_LIMIT=4096
  if [ "$DIFF_BYTES" -gt "$DIFF_LIMIT" ]; then
    printf '(diff body omitted: %s bytes raw, exceeds %s-byte budget — see commit titles above)\n' \
      "$DIFF_BYTES" "$DIFF_LIMIT"
  else
    printf '%s' "$DIFF_RAW"
  fi
  echo
  echo "## RECENT_TURNS"
  TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Slice the transcript by *turn*, not by raw JSONL entry. A turn boundary
    # is a user message that contains text (the human typed something);
    # tool_use/tool_result entries between turns belong to the assistant's
    # work within the current turn. Take the last 100 turns (or all of them
    # when fewer exist).
    #
    # Three role labels:
    #   USER:        — human-typed text (truncated per-block to 1000 chars)
    #   TOOL_RESULT: — auto-generated tool outputs ([N result(s)] marker only)
    #   ASSISTANT:   — model output, text truncated to 500 chars per block,
    #                  tool_use shown as [tool_use=<name> input=<200-char>].
    # Drop entries whose body collapses to empty (thinking-only turns).
    # Final body capped via `tail -c 40000` so over-budget transcripts lose
    # their *oldest* entries first; the reviewer always keeps the most
    # recent context.
    jq -rs '
      . as $all
      | [ $all | to_entries[]
            | select(.value.type == "user"
                     and ((.value.message.content // [] | type) == "array")
                     and (.value.message.content | map(select(.type == "text")) | length > 0))
            | .key
        ] as $starts
      | (if ($starts | length) > 100 then $starts[-100] else ($starts[0] // 0) end) as $cutoff
      | $all[$cutoff:]
      | map(
          if .type == "user" then
            (.message.content) as $c
            | (
                if ($c | type) == "string" then ($c | tostring)[:1000]
                elif ($c | type) == "array" then
                  ([$c[] | select(.type == "text") | .text[:1000]] | join(""))
                else "" end
              ) as $text
            | (
                if ($c | type) == "array" then
                  [$c[] | select(.type == "tool_result")] | length
                else 0 end
              ) as $tr_count
            | if ($text | length) > 0 then
                "USER: " + $text
              elif $tr_count > 0 then
                "TOOL_RESULT: [" + ($tr_count | tostring) + " result(s)]"
              else null end
          elif .type == "assistant" then
            (.message.content
             | if type == "array" then
                 [.[]
                  | if .type == "text" then .text[:500]
                    elif .type == "tool_use" then
                      "[tool_use=" + .name + " input=" + (.input | tostring | .[:200]) + "]"
                    else "" end]
                 | join(" ")
               elif type == "string" then .[:500]
               else "" end) as $body
            | if ($body | length) == 0 then null else "ASSISTANT: " + $body end
          else null end
        )
      | map(select(. != null))
      | join("\n\n---\n\n")
    ' "$TRANSCRIPT" 2>/dev/null | tail -c 40000
  fi
} > "$USER_BODY"

# Build Ollama /api/chat request. format= a JSON schema enforces structured
# output server-side (Ollama 0.5+). messages: system = rules digest, user =
# the assembled review input.
REQ=$(jq -n \
  --arg model "$MODEL" \
  --rawfile sys "$RULES" \
  --rawfile usr "$USER_BODY" \
  '{
    model: $model,
    stream: false,
    think: false,
    format: {
      type: "object",
      required: ["verdict", "violations"],
      properties: {
        verdict: { type: "string", enum: ["pass", "fail"] },
        violations: {
          type: "array",
          items: {
            type: "object",
            required: ["rule", "evidence"],
            properties: {
              rule:     { type: "string" },
              evidence: { type: "string" }
            }
          }
        }
      }
    },
    options: {
      temperature: 0,
      top_k: 1,
      top_p: 1.0,
      seed: 42,
      num_ctx: 16384,
      num_predict: 2048,
      repeat_penalty: 1.0
    },
    messages: [
      { role: "system", content: $sys },
      { role: "user",   content: $usr }
    ]
  }')

# Archive the request body so the user can inspect what was sent without
# having to reconstruct it. Keep last 20 dumps per session.
DUMP_DIR="$HOME/.cache/claude-proof/reviewer-dumps/$SESSION_ID"
mkdir -p "$DUMP_DIR"
DUMP_PATH="$DUMP_DIR/$(date -u +%Y%m%dT%H%M%SZ).json"
printf '%s' "$REQ" > "$DUMP_PATH"
# Bounded retention: keep only the 20 newest dumps per session.
ls -1t "$DUMP_DIR"/*.json 2>/dev/null | tail -n +21 | xargs -r rm -f --

log "calling-ollama model=$MODEL host=$OLLAMA_HOST dump=$DUMP_PATH"
START_CALL=$(date +%s)
OUT=$(timeout 240 curl -s --max-time 240 -X POST "$OLLAMA_HOST/api/chat" \
  -H 'Content-Type: application/json' \
  -d "$REQ" 2>/dev/null)
EXIT_CALL=$?
ELAPSED_CALL=$(( $(date +%s) - START_CALL ))
rm -f "$USER_BODY"

# curl/timeout failure → fail-open with diagnostic.
if [ $EXIT_CALL -ne 0 ] || [ -z "$OUT" ]; then
  log "exit reason=ollama-call-failed exit=$EXIT_CALL elapsed=${ELAPSED_CALL}s"
  printf 'system-prompt-reviewer: ollama call failed (exit=%s, host=%s) — review skipped.\n' "$EXIT_CALL" "$OLLAMA_HOST"
  exit 0
fi

# Ollama errors come back as {"error":"..."} with HTTP 200. Detect.
OLLAMA_ERR=$(echo "$OUT" | jq -r '.error // empty' 2>/dev/null)
if [ -n "$OLLAMA_ERR" ]; then
  log "exit reason=ollama-error err=\"$OLLAMA_ERR\" elapsed=${ELAPSED_CALL}s"
  printf 'system-prompt-reviewer: ollama error: %s — review skipped.\n' "$OLLAMA_ERR"
  exit 0
fi

# Extract the model's structured JSON from message.content.
RAW=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
[ -z "$RAW" ] && { log "exit reason=empty-message-content elapsed=${ELAPSED_CALL}s"; exit 0; }

# Strip optional markdown code fences that some models (gemma4) emit even
# when Ollama's format-schema is supplied. Accept ``` or ```json fences.
RESULT=$(printf '%s' "$RAW" | sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d' | sed -E '/^[[:space:]]*```[[:space:]]*$/d')

VERDICT=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)

# Persist the last result so stop-gate.sh can append it to the next stop's
# summary-to-print.md. Markdown so it concatenates cleanly.
LAST_RESULT="$STATE_DIR/last-result.md"
NOW_HUMAN=$(date -u +'%Y-%m-%d %H:%M:%S UTC')
write_last_result() {
  local verdict=$1; local body=$2
  {
    echo
    echo "---"
    echo
    echo "## External-reviewer result"
    echo
    echo "- Reviewed at: $NOW_HUMAN"
    echo "- Elapsed: ${ELAPSED_CALL}s"
    echo "- Model: $MODEL"
    echo "- Verdict: $verdict"
    if [ -n "$body" ]; then
      echo
      echo "$body"
    fi
  } > "$LAST_RESULT"
}

case "$VERDICT" in
  pass)
    log "verdict=pass elapsed=${ELAPSED_CALL}s — streak reset"
    rm -f "$STREAK_FILE"
    write_last_result "pass" ""
    exit 0
    ;;
  fail)
    STREAK=$(( $(cat "$STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$STREAK" > "$STREAK_FILE"
    log "verdict=fail streak=$STREAK elapsed=${ELAPSED_CALL}s — blocking stop"

    VIOLATIONS=$(printf '%s' "$RESULT" | jq -r '.violations[] | "- \(.rule)\n  evidence: \(.evidence)"' 2>/dev/null)
    if [ -z "$VIOLATIONS" ]; then
      VIOLATIONS="(reviewer returned fail without enumerating violations)"
    fi
    write_last_result "fail (streak=$STREAK)" "$VIOLATIONS"

    # Synchronous block: hold the stop until verdict=pass. The agent must
    # actually fix the violations (or the user must touch $BYPASS_MARKER) —
    # an asyncRewake-style nudge is too easy to ignore with acknowledgement
    # prose that doesn't fix anything.
    REASON=$(printf 'External compliance reviewer (%s via ollama) flagged rule violations in your last turn. You must correct them before stopping.\n\nViolations:\n%s\n\nFix the violations in this turn (re-do the work correctly, do not just acknowledge). Streak=%d. To override: touch %s\n' "$MODEL" "$VIOLATIONS" "$STREAK" "$BYPASS_MARKER")
    jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'
    exit 0
    ;;
  *)
    # Malformed verdict — fail-open with diagnostic.
    log "exit reason=malformed-verdict raw=\"$(printf '%s' "$RAW" | head -c 200)\""
    exit 0
    ;;
esac
