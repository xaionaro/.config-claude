#!/bin/bash
# Stop hook (asyncRewake): runs an EXTERNAL Ollama reviewer to score the
# just-finished turn against CLAUDE.md + the curated reviewer-rules.md.
# On detected violations, exits 2 with the violation list on stdout — the
# harness wakes the main agent with that text as a system reminder (per
# asyncRewake + rewakeMessage in settings.json).
#
# Coexists with the synchronous stop-gate.sh: that one validates the proof's
# structure; this one critiques the conduct. Both fire on Stop in parallel.
#
# Cost / latency gates:
#   - skip when stop_hook_active=true (second pass; nothing new)
#   - skip when no proof exists yet
#   - skip on user-touched bypass marker
#   - timeout 60s on the model call
#   - track consecutive-fail streak; after 3, switch to permanent block
#     until the user resolves or touches the bypass marker

set -uo pipefail

OLLAMA_HOST="http://192.168.0.171:11434"
MODEL="gemma4:31b-nvfp4"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // empty')

[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# Skip on second-pass stops; nothing new to review since first-pass.
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Reviewer reads the transcript directly (per the rule-source-not-narrative
# redesign), so it does not need proof.md / summary-to-print.md to exist.
# The transcript JSONL is always present for any session that ever ran.

# State outside $PROOF_DIR so it survives stop-cycle wipe.
STATE_DIR="$HOME/.cache/claude-proof/reviewer/$SESSION_ID"
mkdir -p "$STATE_DIR"
BYPASS_MARKER="$STATE_DIR/bypass"
STREAK_FILE="$STATE_DIR/streak"

# User-acknowledged bypass: skip review until removed.
[ -f "$BYPASS_MARKER" ] && exit 0

RULES="$HOME/.claude/hooks/reviewer-rules.md"
[ ! -f "$RULES" ] && exit 0

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

OUT=$(timeout 240 curl -s --max-time 240 -X POST "$OLLAMA_HOST/api/chat" \
  -H 'Content-Type: application/json' \
  -d "$REQ" 2>/dev/null)
EXIT_CALL=$?
rm -f "$USER_BODY"

# curl/timeout failure → fail-open with diagnostic.
if [ $EXIT_CALL -ne 0 ] || [ -z "$OUT" ]; then
  printf 'system-prompt-reviewer: ollama call failed (exit=%s, host=%s) — review skipped.\n' "$EXIT_CALL" "$OLLAMA_HOST"
  exit 0
fi

# Ollama errors come back as {"error":"..."} with HTTP 200. Detect.
OLLAMA_ERR=$(echo "$OUT" | jq -r '.error // empty' 2>/dev/null)
if [ -n "$OLLAMA_ERR" ]; then
  printf 'system-prompt-reviewer: ollama error: %s — review skipped.\n' "$OLLAMA_ERR"
  exit 0
fi

# Extract the model's structured JSON from message.content.
RAW=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
[ -z "$RAW" ] && exit 0

# Strip optional markdown code fences that some models (gemma4) emit even
# when Ollama's format-schema is supplied. Accept ``` or ```json fences.
RESULT=$(printf '%s' "$RAW" | sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d' | sed -E '/^[[:space:]]*```[[:space:]]*$/d')

VERDICT=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)

case "$VERDICT" in
  pass)
    rm -f "$STREAK_FILE"
    exit 0
    ;;
  fail)
    STREAK=$(( $(cat "$STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$STREAK" > "$STREAK_FILE"

    VIOLATIONS=$(printf '%s' "$RESULT" | jq -r '.violations[] | "- \(.rule)\n  evidence: \(.evidence)"' 2>/dev/null)
    if [ -z "$VIOLATIONS" ]; then
      VIOLATIONS="(reviewer returned fail without enumerating violations)"
    fi

    if [ "$STREAK" -ge 3 ]; then
      printf 'External reviewer fail-closed: %d consecutive flagged stops. Resolve the violations or "touch %s" to override.\n%s\n' "$STREAK" "$BYPASS_MARKER" "$VIOLATIONS"
    else
      printf 'External reviewer flagged compliance violations (gemma4 via ollama):\n%s\n' "$VIOLATIONS"
    fi
    exit 2
    ;;
  *)
    # Malformed verdict — fail-open with diagnostic.
    exit 0
    ;;
esac
