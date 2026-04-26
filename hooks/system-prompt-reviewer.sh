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
MODEL="gemma4:31b-nvfp4"

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
  git -C "$HOME/.claude" diff HEAD~1..HEAD 2>/dev/null | head -c 4096
  echo
  echo "## RECENT_TURNS"
  TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Last 20 entries from the transcript, formatted as role + text/tool calls
    # so the reviewer sees exactly what happened, not the agent's summary.
    # tool_use blocks reduce to the tool name + a short input snippet.
    jq -rs '
      .[-20:]
      | map(
          if .type == "user" then
            ( "USER: " +
              (
                if (.message.content | type) == "string" then .message.content
                elif (.message.content | type) == "array" then
                  ([.message.content[]
                    | if .type == "text" then .text
                      elif .type == "tool_result" then "[tool_result]"
                      else "" end] | join(""))
                else "" end
              )
            )
          elif .type == "assistant" then
            ( "ASSISTANT: " +
              (.message.content
               | if type == "array" then
                   [.[]
                    | if .type == "text" then .text
                      elif .type == "tool_use" then
                        "[tool_use=" + .name + " input=" + (.input | tostring | .[:200]) + "]"
                      else "" end]
                   | join(" ")
                 elif type == "string" then .
                 else "" end)
            )
          else "" end
        )
      | map(select(. != ""))
      | join("\n\n---\n\n")
    ' "$TRANSCRIPT" 2>/dev/null | head -c 12288
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

log "calling-ollama model=$MODEL host=$OLLAMA_HOST"
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
    REASON=$(printf 'External compliance reviewer (gemma4:31b-nvfp4 via ollama) flagged rule violations in your last turn. You must correct them before stopping.\n\nViolations:\n%s\n\nFix the violations in this turn (re-do the work correctly, do not just acknowledge). Streak=%d. To override: touch %s\n' "$VIOLATIONS" "$STREAK" "$BYPASS_MARKER")
    jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'
    exit 0
    ;;
  *)
    # Malformed verdict — fail-open with diagnostic.
    log "exit reason=malformed-verdict raw=\"$(printf '%s' "$RAW" | head -c 200)\""
    exit 0
    ;;
esac
