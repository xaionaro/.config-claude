#!/bin/bash
# Stop hook (asyncRewake): runs an EXTERNAL Claude session to review the
# just-finished turn for system-prompt + CLAUDE.md compliance. On detected
# violations, exits 2 with the violation list on stdout — the harness wakes
# the main agent with that text as a system reminder (per asyncRewake +
# rewakeMessage in settings.json).
#
# Coexists with the synchronous stop-gate.sh: that one validates the proof's
# structure; this one critiques the conduct. Both fire on Stop in parallel.
#
# Cost gates:
#   - skip when stop_hook_active=true (second pass; nothing new to review)
#   - skip when no proof.md exists yet (stop-gate.sh hasn't validated yet)
#   - timeout 30s on the reviewer call
#   - --max-budget-usd 0.05 on the call
#   - --model haiku (cheap model for routine compliance review)
#   - track consecutive-fail streak; after 3, switch to permanent block
#     until the user touches a bypass marker

set -uo pipefail

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

# Build reviewer input.
INPUT_FILE=$(mktemp)
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
  git diff HEAD~1..HEAD 2>/dev/null | head -c 4096
  echo
  echo "## LAST_USER"
  TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    jq -rs '
      map(select(.type == "user" and (.message.content | type == "string")))
      | last
      | .message.content // ""
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
} > "$INPUT_FILE"

# Auth check. claude --bare requires ANTHROPIC_API_KEY (skips OAuth/keychain).
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  rm -f "$INPUT_FILE"
  printf 'system-prompt-reviewer: ANTHROPIC_API_KEY not set — review skipped. Set the key or "touch %s" to permanently bypass.\n' "$BYPASS_MARKER"
  # Fail-open: don't punish the user for missing creds. They must set the key
  # or accept the bypass; either way unblocked.
  exit 0
fi

SCHEMA='{"type":"object","required":["verdict","violations"],"properties":{"verdict":{"enum":["pass","fail"]},"violations":{"type":"array","items":{"type":"object","required":["rule","evidence"],"properties":{"rule":{"type":"string"},"evidence":{"type":"string"}}}}}}'

OUT=$(timeout 30 claude --bare -p \
  --output-format json \
  --json-schema "$SCHEMA" \
  --system-prompt-file "$RULES" \
  --max-budget-usd 0.05 \
  --model haiku \
  < "$INPUT_FILE" 2>/dev/null)
EXIT_CALL=$?
rm -f "$INPUT_FILE"

# Reviewer crashed/timed out → fail-open with diagnostic.
if [ $EXIT_CALL -ne 0 ]; then
  printf '%s\n' "system-prompt-reviewer: claude --bare exited $EXIT_CALL (timeout or infra error) — review skipped this turn."
  exit 0
fi

# Extract verdict from the result envelope.
RESULT=$(echo "$OUT" | jq -r '.result // empty' 2>/dev/null)
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
      printf 'External reviewer flagged compliance violations:\n%s\n' "$VIOLATIONS"
    fi
    exit 2
    ;;
  *)
    # Malformed verdict — fail-open with diagnostic.
    exit 0
    ;;
esac
