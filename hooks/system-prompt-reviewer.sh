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
MODEL="gemma4:31b"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // empty')

[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# Skip on second-pass stops; nothing new to review since first-pass.
[ "$STOP_ACTIVE" = "true" ] && exit 0

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
PROOF="$PROOF_DIR/proof.md"
SUMMARY="$PROOF_DIR/summary-to-print.md"

# Skip if no proof exists. stop-gate.sh hasn't run validation yet, or there
# was no work to validate (read-only turn).
if [ ! -f "$PROOF" ] && [ ! -f "$SUMMARY" ]; then
  exit 0
fi

# State outside $PROOF_DIR so it survives stop-cycle wipe.
STATE_DIR="$HOME/.cache/claude-proof/reviewer/$SESSION_ID"
mkdir -p "$STATE_DIR"
BYPASS_MARKER="$STATE_DIR/bypass"
STREAK_FILE="$STATE_DIR/streak"

# User-acknowledged bypass: skip review until removed.
[ -f "$BYPASS_MARKER" ] && exit 0

RULES="$HOME/.claude/hooks/reviewer-rules.md"
[ ! -f "$RULES" ] && exit 0

# Build user-message body: PROOF + DIFF + last user/assistant exchange.
USER_BODY=$(mktemp)
{
  echo "## PROOF"
  if [ -f "$PROOF" ]; then
    cat "$PROOF"
  else
    cat "$SUMMARY"
  fi
  echo
  echo "## DIFF"
  git -C "$HOME/.claude" log --pretty=format:"%H %s" -5 2>/dev/null
  echo
  git -C "$HOME/.claude" diff HEAD~1..HEAD 2>/dev/null | head -c 4096
  echo
  echo "## LAST_USER"
  TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    jq -rs '
      map(select(.type == "user"))
      | last
      | .message.content
      | if type == "array" then
          map(select(.type == "text") | .text) | join("")
        elif type == "string" then .
        else "" end
    ' "$TRANSCRIPT" 2>/dev/null | head -c 2048
    echo
    echo "## LAST_ASSISTANT_TEXT"
    jq -rs '
      map(select(.type == "assistant"))
      | last
      | .message.content
      | if type == "array" then map(select(.type == "text") | .text) | join("") else "" end
    ' "$TRANSCRIPT" 2>/dev/null | head -c 4096
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

OUT=$(timeout 60 curl -s --max-time 60 -X POST "$OLLAMA_HOST/api/chat" \
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
RESULT=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
[ -z "$RESULT" ] && exit 0

VERDICT=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)

case "$VERDICT" in
  pass)
    rm -f "$STREAK_FILE"
    exit 0
    ;;
  fail)
    STREAK=$(( $(cat "$STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$STREAK" > "$STREAK_FILE"

    VIOLATIONS=$(echo "$RESULT" | jq -r '.violations[] | "- \(.rule)\n  evidence: \(.evidence)"' 2>/dev/null)
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
