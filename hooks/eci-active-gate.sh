#!/bin/bash
# PreToolUse hook on Edit|Write|MultiEdit: denies main-thread writes when
# the explore-critique-implement (ECI) marker is engaged for this session.
#
# ECI requires the main thread to delegate implementation to subagents.
# Agents that ignore the rule and start editing files directly hit this
# gate. Disengage with `~/.claude/bin/eci-active off <report.md>` once scope closed.
#
# Subagents (agent_id non-empty) are allowed through — the marker targets
# main-thread regression, not legitimate implementer subagents.
#
# Failure mode: any infrastructure error traps to deny-with-evidence so
# the gate cannot be silently bypassed.

set -uo pipefail

trap 'jq -n --arg reason "eci-active-gate infra error at line $LINENO; investigate $HOME/.cache/claude-proof and the gate script" "{
  hookSpecificOutput: {
    hookEventName: \"PreToolUse\",
    permissionDecision: \"deny\",
    permissionDecisionReason: \$reason
  }
}"; exit 0' ERR

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

# Subagent calls bypass the marker — implementer subagents must be free to write.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
[ -n "$AGENT_ID" ] && exit 0

# Markdown files (docs, plans, ECI disengage reports) are part of orchestration —
# allow on the main thread without delegation. The gate exists to force code
# implementation through subagents, not to block doc/notes work.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.target_file // empty')
case "$FILE_PATH" in
  *.md|*.MD|*.markdown) exit 0 ;;
esac

MARKER="$HOME/.cache/claude-proof/$SESSION_ID/eci_active"
[ -f "$MARKER" ] || exit 0

MARKER_BODY=$(cat "$MARKER" 2>/dev/null || echo "<unreadable>")

REASON=$(printf 'ECI active for this session — main thread must delegate implementation to a subagent.\n\n%s\n\nDelegate via the Agent tool (one diff per implementer). Disengage with `~/.claude/bin/eci-active off <report.md>` only when the user confirms the task/scope is closed.' "$MARKER_BODY")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
