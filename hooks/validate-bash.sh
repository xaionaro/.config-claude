#!/bin/bash
# PreToolUse hook: validates Bash commands before execution.

set -euo pipefail

INPUT=$(cat)

# Quick prefilter: skip jq if irrelevant
case "$INPUT" in
  *"go test"*count*) ;;
  *) exit 0 ;;
esac

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# Check for go test with -count=1 (covers -count=1 and -count 1)
if echo "$COMMAND" | grep -qE 'go\s+test\b' && echo "$COMMAND" | grep -qE '\-count[= ]1\b'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Do not add -count=1 to go test commands. Allow Go test caching. Re-run the same command without -count=1."
    }
  }'
  exit 0
fi
