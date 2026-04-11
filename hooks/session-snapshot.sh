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

# Clear any stale skip_stop marker left behind by a previous skill invocation
# in the same session id (e.g. on session resume after a crash).
rm -f "$PROOF_DIR/skip_stop"
