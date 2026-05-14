#!/bin/bash
# PreToolUse hook on Agent|SendMessage|Monitor: when ECI is active for the
# session, touch $PROOF_DIR/eci_teammate_pending so stop-gate.sh releases
# stops while the orchestrator awaits the teammate reply. Cleared on the
# next user/teammate message by hooks/eci-pending-clear.sh.

set -uo pipefail
trap 'exit 0' ERR

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# Subagent calls do not run ECI; only the main thread's marker matters.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
{ [ -n "$AGENT_ID" ] || [ -n "$AGENT_TYPE" ]; } && exit 0

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
[ -f "$PROOF_DIR/eci_active" ] || exit 0

mkdir -p "$PROOF_DIR"
touch "$PROOF_DIR/eci_teammate_pending"
exit 0
