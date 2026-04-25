#!/bin/bash
# PostToolUse hook on Skill tool: records skill invocations to per-session marker dir.
# Markers live OUTSIDE $PROOF_DIR (which stop-gate.sh wipes on successful stop) so
# they survive cross-stop within a session — parallel to the freshness-oracle log.

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# tool_input.skill is the verified key per the Skill tool schema in the system
# prompt. Fallbacks retained for robustness against future schema changes.
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // .tool_input.name // .tool_input.skill_name // empty')

DIR="$HOME/.cache/claude-proof/skills/$SESSION_ID"
mkdir -p "$DIR"

# Audit: dump the first PostToolUse-on-Skill payload so the schema can be
# verified offline. Subsequent invocations leave it untouched.
[ -f "$DIR/.last-input.json" ] || echo "$INPUT" > "$DIR/.last-input.json"

if [ -n "$SKILL" ]; then
  # Plugin-namespaced skills look like "superpowers:debugging-discipline".
  # Touch both the full name and the basename so gate lookups by either form.
  BASE="${SKILL##*:}"
  touch "$DIR/$SKILL" "$DIR/$BASE" 2>/dev/null || true
fi

exit 0
