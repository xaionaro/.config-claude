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

# Skip stop hook for roles that don't write code
case "${CLAUDE_ROLE:-}" in
  lead|coordinator|snitch|explorer|brainstormer|designer|reviewer|test-designer|test-reviewer|verifier|qa)
    exit 0 ;;
esac

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
PROOF="$PROOF_DIR/proof.md"

# Skill-controlled bypass: any skill that knows the main thread never
# implements code can touch this marker on entry and remove it on exit.
# See ~/.claude/bin/skip-stop for the helper that manages it.
if [ -f "$PROOF_DIR/skip_stop" ]; then
  exit 0
fi

# Scope loop detection per agent (subagents share parent session_id)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
if [ -n "$AGENT_ID" ]; then
  TIMESTAMPS="$PROOF_DIR/stop_timestamps_${AGENT_ID}"
else
  TIMESTAMPS="$PROOF_DIR/stop_timestamps"
fi

# Track stop hook invocations for loop detection
mkdir -p "$PROOF_DIR"
echo "$(date +%s)" >> "$TIMESTAMPS"
# Count invocations in last 5 minutes
NOW=$(date +%s)
CUTOFF=$((NOW - 300))
RECENT_COUNT=0
if [ -f "$TIMESTAMPS" ]; then
  RECENT_COUNT=$(awk -v cutoff="$CUTOFF" '$1 >= cutoff' "$TIMESTAMPS" | wc -l)
  # Prune old entries
  awk -v cutoff="$CUTOFF" '$1 >= cutoff' "$TIMESTAMPS" > "$TIMESTAMPS.tmp" && mv "$TIMESTAMPS.tmp" "$TIMESTAMPS"
fi

LOOP_REMINDER=""
if [ "$RECENT_COUNT" -ge 5 ]; then
  LOOP_REMINDER=" LOOP DETECTED ($RECENT_COUNT hits in 5min): You are stuck in a stop-hook loop. This is YOUR problem to solve autonomously. How the stop hook works: (1) it blocks your first stop attempt, (2) you read ~/.cache/claude-proof/\$SESSION_ID/instructions.md or ~/.claude/hooks/stop-checklist.md, (3) you write proof to $PROOF, (4) you stop again and it lets you through. Figure out which step you are failing and fix it. Do NOT keep retrying the same approach."
fi

block() {
  jq -n --arg reason "$1$LOOP_REMINDER" '{"decision": "block", "reason": $reason}'
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

# 4. No code changes → require checklist review (not full verification)
if [ -z "$CODE_CHANGES" ]; then
  INSTRUCTIONS="$PROOF_DIR/instructions.md"
  mkdir -p "$PROOF_DIR"
  cat > "$INSTRUCTIONS" <<INSTEOF
STOP BLOCKED — Check against the acceptance criteria before stopping.
NEVER end your turn to ask a question. Use the AskUserQuestion tool instead — always.

Proof file: $PROOF

No code changes detected — full verification is NOT required.
However, you must still check your work against the acceptance criteria.

1. Read the checklist at ~/.claude/hooks/stop-checklist.md
2. For each item that applies to this session's work, verify it was followed.
3. If any item was violated → fix it before stopping.
4. Write to the proof file:
   - "fast-exit: checklist review (no code changes)" on the first line
   - Which checklist items applied and their pass/fail status
   - Any issues found and how they were resolved
INSTEOF
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
