#!/bin/bash
# PreToolUse hook: blocks adding local path replace directives to go.mod.
# Remote fork replacements are fine — only local paths (=> ../ or => ./) are blocked.

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')

# Only care about go.mod files
[[ "$FILE_PATH" == */go.mod ]] || exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Get the text being added
if [[ "$TOOL_NAME" == "Write" ]]; then
  TEXT=$(echo "$INPUT" | jq -r '.tool_input.content')
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  TEXT=$(echo "$INPUT" | jq -r '.tool_input.new_string')
else
  exit 0
fi

# Check for local path replace: => ../ or => ./
if echo "$TEXT" | grep -qE '=>\s*\.\.?/'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "NEVER add local path replace directives (=> ../something or => ./something) to go.mod. Use go.work for local module resolution instead. Remote fork replacements in go.mod are fine."
    }
  }'
  exit 0
fi
