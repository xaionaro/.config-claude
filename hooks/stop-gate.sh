#!/bin/bash
# Stop hook: gates Claude from stopping until verification proof is written.
# Command hook — blocks first stop attempt, sends Claude back to verify,
# then allows on second attempt when proof file exists.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active')

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  exit 0
fi

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
PROOF="$PROOF_DIR/proof.md"

block() {
  jq -n --arg reason "$1" '{"decision": "block", "reason": $reason}'
  exit 0
}

# 1. Proof exists → block once more so Claude prints the summary, then cleanup
if [ -f "$PROOF" ]; then
  CONTENT=$(cat "$PROOF")
  rm -f "$PROOF" "$PROOF_DIR/baseline_head"
  rmdir "$PROOF_DIR" 2>/dev/null || true
  block "Print this verification summary to the user as-is, then stop:

$CONTENT"
fi

# 2. Already sent back (proof printed or no proof written) → allow
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# 3. Check for code changes
BASELINE_FILE="$PROOF_DIR/baseline_head"
BASELINE_HEAD=""
if [ -f "$BASELINE_FILE" ]; then
  BASELINE_HEAD=$(cat "$BASELINE_FILE")
fi

CODE_CHANGES=$(
  {
    git diff --name-only 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    [ -n "$BASELINE_HEAD" ] && git diff "$BASELINE_HEAD"..HEAD --name-only 2>/dev/null
  } |
    sort -u |
    grep -v -E '\.(json|yaml|yml|toml|md|txt|env|lock|ini|cfg|conf|csv|svg|png|jpg|gif|ico)$' |
    head -1
) || true

# 4. No code changes → block once with acceptance-criteria reminder
if [ -z "$CODE_CHANGES" ]; then
  block "Read and follow $HOOK_DIR/stop-checklist.md before stopping."
fi

# 5. Code changed, no proof → block and send verification protocol
block "Read and follow $HOOK_DIR/stop-verification.md — proof file: $PROOF (mkdir -p $PROOF_DIR first)."
