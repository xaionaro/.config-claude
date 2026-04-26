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

# Build the system message. The agent must obey *all* of these rule
# sources, so the reviewer scores against all of them. Each is a single
# source-of-truth file the agent is also supposed to follow:
#   - reviewer-rules.md  : wrapper / framing for the reviewer LLM
#   - CLAUDE.md          : user's global instructions (the master rules)
#   - stop-checklist.md  : acceptance criteria for ending a turn — the
#                          agent's last ASSISTANT text must show evidence
#                          that each applicable item was met
#   - MEMORY.md          : index of cross-session lessons-learned (full
#                          feedback bodies live in sibling files but the
#                          one-line summaries here name each rule)
RULES=$(mktemp)
{
  cat "$RULES_WRAPPER"
  echo
  echo
  echo "============================================================"
  echo "# CLAUDE.md (user's global instructions)"
  echo "============================================================"
  echo
  cat "$INSTRUCTIONS"
  echo
  if [ -f "$HOME/.claude/hooks/stop-checklist.md" ]; then
    echo
    echo "============================================================"
    echo "# stop-checklist.md (acceptance criteria for ending a turn)"
    echo "============================================================"
    echo
    cat "$HOME/.claude/hooks/stop-checklist.md"
    echo
  fi
  MEMORY_INDEX="$HOME/.claude/projects/-home-streaming--claude/memory/MEMORY.md"
  if [ -f "$MEMORY_INDEX" ]; then
    echo
    echo "============================================================"
    echo "# MEMORY.md (cross-session lessons-learned, one-line summaries)"
    echo "============================================================"
    echo
    cat "$MEMORY_INDEX"
    echo
  fi
} > "$RULES"
trap 'rm -f "$RULES"' EXIT

# Build user-message body. Order is RECENT_TURNS first, DIFF last — DIFF
# changes per commit (every turn or two) and would invalidate the KV
# cache for everything after it if it sat at the front; placing it last
# keeps the long, slow-changing RECENT_TURNS prefix cacheable across
# consecutive reviewer calls. Reviewer reads raw transcript turns, NOT
# the agent's proof.md (the unreliable narrative we're externalizing).
USER_BODY=$(mktemp)

# --- Anchor (hysteresis) for KV-cache stability ------------------------
# Slice start is anchored at a chosen turn-start entry-index, persisted
# per session. The slice grows from that anchor as new turns arrive.
# When the slice exceeds 150 turn-starts, we rebase the anchor forward
# to the last 100 — so the prefix is stable for ~50 calls between rebases
# and Ollama can reuse the KV cache.
TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
ANCHOR_FILE="$STATE_DIR/anchor"
ANCHOR_IDX=""
if [ -f "$ANCHOR_FILE" ]; then
  ANCHOR_IDX=$(cat "$ANCHOR_FILE" 2>/dev/null || echo "")
  case "$ANCHOR_IDX" in *[!0-9]*) ANCHOR_IDX="" ;; esac
fi
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # Turn-start = a real human-typed user message. The signal in Claude
  # Code transcripts: content is a string AND isMeta is not true. (Array
  # content + isMeta=true is a skill-load body; string content + isMeta
  # =true is synthetic stop-hook feedback. Neither counts as a turn.)
  TS_LIST=$(jq -s '
    [ to_entries[]
      | select(.value.type == "user"
               and ((.value.message.content | type) == "string")
               and ((.value.isMeta // false) | not))
      | .key
    ]
  ' "$TRANSCRIPT" 2>/dev/null || echo "[]")
  TS_COUNT=$(printf '%s' "$TS_LIST" | jq 'length')
  # Validate anchor still points to one of the current turn-starts.
  ANCHOR_VALID=0
  if [ -n "$ANCHOR_IDX" ]; then
    ANCHOR_VALID=$(printf '%s' "$TS_LIST" | jq --argjson a "$ANCHOR_IDX" 'index($a) != null | if . then 1 else 0 end')
  fi
  if [ "$ANCHOR_VALID" != "1" ]; then
    # Initialize: last 100 turn-starts (or all when fewer).
    if [ "$TS_COUNT" -le 100 ]; then
      ANCHOR_IDX=$(printf '%s' "$TS_LIST" | jq '.[0] // 0')
    else
      ANCHOR_IDX=$(printf '%s' "$TS_LIST" | jq '.[-100]')
    fi
  else
    ANCHOR_POS=$(printf '%s' "$TS_LIST" | jq --argjson a "$ANCHOR_IDX" 'index($a)')
    SLICE_TURNS=$(( TS_COUNT - ANCHOR_POS ))
    if [ "$SLICE_TURNS" -gt 150 ]; then
      # Rebase: drop oldest 50 turns, slice resumes at last-100.
      ANCHOR_IDX=$(printf '%s' "$TS_LIST" | jq '.[-100]')
    fi
  fi
  echo "$ANCHOR_IDX" > "$ANCHOR_FILE"
fi
ANCHOR_IDX=${ANCHOR_IDX:-0}

{
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Two explicit sections:
    #   ## USER_HISTORY   — every USER text entry from `$cutoff` up to
    #                       the start of the last turn. The agent's
    #                       actions in those past turns are intentionally
    #                       NOT shown — they were already audited in
    #                       their own stops; we keep only the human's
    #                       requests/corrections so the reviewer knows
    #                       the agreements that bind the current turn.
    #   ## CURRENT_TURN   — every entry from the last user-text message
    #                       onward (USER text, ASSISTANT text+tool_use,
    #                       TOOL_RESULT bodies). This is the only turn
    #                       whose conduct is up for review.
    # Per-tool input budgets:
    #   - Agent: full prompt (no truncation) — subagent contracts are
    #            critical reviewable surface.
    #   - Bash:  full command — shell scripts must be auditable.
    #   - other: 1500 chars.
    # Tool outputs: first 200 chars per block.
    # Final body capped via `tail -c 120000`.
    jq -rs --argjson cutoff "$ANCHOR_IDX" '
      . as $all
      | (
          [ $all | to_entries[]
              | select(.value.type == "user"
                       and ((.value.message.content | type) == "string")
                       and ((.value.isMeta // false) | not))
              | .key
          ] | last // 0
        ) as $lts
      | def is_real_user($e):
          $e.type == "user"
          and ($e.message.content | type) == "string"
          and (($e.isMeta // false) | not);
        def render_user_text($e):
          ($e.message.content | tostring | .[:1000]) as $text
          | if ($text | length) > 0 then "USER: " + $text else null end;
        def render_user_tr($e):
          ($e.message.content) as $c
          | (
              if ($c | type) == "array" then
                [$c[] | select(.type == "tool_result")
                  | (.content
                     | if type == "string" then .[:200]
                       elif type == "array" then
                         ([.[] | if .type == "text" then .text[:200] else "" end] | join(" "))[:200]
                       else "" end)]
              else [] end
            ) as $tr
          | if ($tr | length) > 0 then
              "TOOL_RESULT: " + ($tr | map(if . == "" then "[empty]" else "[" + . + "]" end) | join(" "))
            else null end;
        def render_assistant($e):
          ($e.message.content
           | if type == "array" then
             [.[]
              | if .type == "text" then .text[:1500]
                elif .type == "tool_use" then
                  ( .name as $n
                    | .input as $in
                    | if $n == "Agent" then
                        "[tool_use=Agent input=" + ($in | tostring) + "]"
                      elif $n == "Bash" then
                        "[tool_use=Bash input=" + ($in | tostring) + "]"
                      else
                        "[tool_use=" + $n + " input=" + ($in | tostring | .[:1500]) + "]"
                      end )
                else "" end]
             | join(" ")
           elif type == "string" then .[:1500]
           else "" end) as $body
          | if ($body | length) == 0 then null else "ASSISTANT: " + $body end;
        # Wrap each rendered entry in <entry>…</entry>. Escape both
        # </entry> AND <entry> in user content via split/join (literal
        # semantics, not regex — immune to future tag-rename mishaps).
        # The reviewer-controlled boundary stays unambiguous.
        def wrap_entries:
          map("<entry>"
              + (split("</entry>") | join("</_entry>")
                 | split("<entry>")  | join("<_entry>"))
              + "</entry>")
          | join("\n");
        ($all | to_entries
         | map(select(.key >= $cutoff and .key < $lts))
         | map(if is_real_user(.value) then render_user_text(.value) else null end)
         | map(select(. != null))
         | wrap_entries) as $history
      | ($all | to_entries
         | map(select(.key >= $lts))
         | map(
             if is_real_user(.value) then
               render_user_text(.value)
             elif .value.type == "user" then
               render_user_tr(.value)
             elif .value.type == "assistant" then
               render_assistant(.value)
             else null end)
         | map(select(. != null))
         | wrap_entries) as $current
      | "## USER_HISTORY (USER messages from earlier turns; the agent'"'"'s actions in those turns were already audited and are intentionally not shown)\n\n"
        + $history
        + "\n\n## CURRENT_TURN (the only turn under review now — all activity since the last USER message)\n\n"
        + $current
    ' "$TRANSCRIPT" 2>/dev/null | tail -c 120000
  fi
  echo
  echo "## DIFF"
  git -C "$HOME/.claude" log --pretty=format:"%H %s" -5 2>/dev/null
  echo
  # Diff base = HEAD recorded by the UserPromptSubmit hook for this
  # session, so the reviewer sees ALL commits made in the current turn
  # (not just HEAD~1..HEAD). Falls back to HEAD~1 when the prompt-head
  # file is missing (first prompt of a session, or pre-hook session) or
  # when the recorded SHA is no longer reachable (force-push, rebase).
  PROMPT_HEAD_FILE="$STATE_DIR/prompt_head"
  DIFF_BASE="HEAD~1"
  if [ -s "$PROMPT_HEAD_FILE" ]; then
    PH=$(cat "$PROMPT_HEAD_FILE" 2>/dev/null)
    if [ -n "$PH" ] && git -C "$HOME/.claude" cat-file -e "${PH}^{commit}" 2>/dev/null; then
      DIFF_BASE="$PH"
    fi
  fi
  # Bound diff bytes: a huge diff (large refactor, generated files) blows
  # past Ollama's num_ctx and causes timeouts. Probe size first; if over
  # threshold, omit the diff body entirely — commit titles above are
  # enough context, and a mid-line truncation is misleading.
  DIFF_RAW=$(git -C "$HOME/.claude" diff "$DIFF_BASE..HEAD" 2>/dev/null)
  DIFF_BYTES=$(printf %s "$DIFF_RAW" | wc -c | awk '{print $1}')
  DIFF_LIMIT=4096
  if [ "$DIFF_BYTES" -gt "$DIFF_LIMIT" ]; then
    printf '(diff body omitted: %s bytes raw, exceeds %s-byte budget — see commit titles above)\n' \
      "$DIFF_BYTES" "$DIFF_LIMIT"
  else
    printf '%s' "$DIFF_RAW"
  fi
  echo
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
      num_ctx: 32768,
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
# Pass the body via --data-binary @file rather than -d "$REQ". With large
# prompts (post-anchor change can hit ~200KB), shoving the body through
# argv triggers fork-exec failures (E2BIG / exit 126) on some kernels
# even when ARG_MAX nominally allows it. Reading from $DUMP_PATH avoids
# the argv path entirely.
OUT=$(timeout 240 curl -s --max-time 240 -X POST "$OLLAMA_HOST/api/chat" \
  -H 'Content-Type: application/json' \
  --data-binary "@$DUMP_PATH" 2>/dev/null)
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
