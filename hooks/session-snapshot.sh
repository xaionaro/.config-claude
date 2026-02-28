#!/bin/bash
# SessionStart hook: saves git HEAD as baseline for the stop hook.
# Only saves once per session (skips on compact/clear if baseline exists).

set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  exit 0
fi

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
BASELINE="$PROOF_DIR/baseline_head"

# Only save if baseline doesn't exist yet (preserve across compact/clear)
if [ ! -f "$BASELINE" ]; then
  mkdir -p "$PROOF_DIR"
  git rev-parse HEAD >"$BASELINE" 2>/dev/null || true
fi
