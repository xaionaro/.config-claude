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

# 1. Proof exists → validate content, save summary for Claude to print, then cleanup
if [ -f "$PROOF" ]; then
  # Skip validation for fast-exit proofs (trivial changes, mid-conversation, etc.)
  if ! grep -qi "fast.exit\|fast exit" "$PROOF"; then
    # Validate that proof contains required adversarial self-critique sections.
    # An empty or rubber-stamped proof ("LGTM") must not pass.
    MISSING=""
    grep -qi "claim.inventory\|claim inventory" "$PROOF" || MISSING="$MISSING Claim-inventory"
    grep -qi "pre.mortem\|pre mortem\|premortem" "$PROOF" || MISSING="$MISSING Pre-mortem"
    grep -qi "adversarial.critique\|adversarial critique\|objection" "$PROOF" || MISSING="$MISSING Adversarial-critique"
    grep -qi "verified\|likely\|uncertain\|confidence" "$PROOF" || MISSING="$MISSING Confidence-calibration"

    if [ -n "$MISSING" ]; then
      block "Proof file is missing required sections:$MISSING. Re-read instructions.md and write a complete proof."
    fi
  fi

  SUMMARY="$PROOF_DIR/summary-to-print.md"
  cp "$PROOF" "$SUMMARY"
  rm -f "$PROOF" "$PROOF_DIR/baseline_head"
  block "Checking stop criteria."
fi

# 2. Already sent back (proof printed or no proof written) → allow + cleanup
if [ "$STOP_ACTIVE" = "true" ]; then
  rm -rf "$PROOF_DIR" 2>/dev/null || true
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
  block "Checking stop criteria."
fi

# 5. Code changed, no proof → block and send verification protocol
#    Write a session-specific instructions file with the proof path baked in
INSTRUCTIONS="$PROOF_DIR/instructions.md"
mkdir -p "$PROOF_DIR"
sed \
  -e "s|{{PROOF}}|$PROOF|g" \
  -e "s|{{PROOF_DIR}}|$PROOF_DIR|g" \
  "$HOOK_DIR/stop-verification.md" > "$INSTRUCTIONS"
block "Checking stop criteria."
