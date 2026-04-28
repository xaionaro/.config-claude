#!/bin/bash
# PreToolUse hook on Edit|Write|MultiEdit: denies direct file edits when
# the agent is running as an agent-teams-execution (ATE) orchestrator.
#
# Per ATE skill, lead and coordinator audit/spawn but never implement.
# Agents that drift into hand-editing hit this gate and must spawn an
# executor teammate instead.
#
# Subagents (agent_id non-empty) bypass — they are by definition the
# delegated implementers, not the orchestrator session itself.
#
# Failure mode: any infrastructure error traps to deny-with-evidence so
# the gate cannot be silently bypassed.

set -uo pipefail

trap 'jq -n --arg reason "ate-orchestrator-gate infra error at line $LINENO; investigate the gate script" "{
  hookSpecificOutput: {
    hookEventName: \"PreToolUse\",
    permissionDecision: \"deny\",
    permissionDecisionReason: \$reason
  }
}"; exit 0' ERR

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

# Subagent calls bypass — implementer subagents must be free to write.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
[ -n "$AGENT_ID" ] && exit 0

# Only restrict orchestrator roles. Other ATE roles (executor, test-executor)
# legitimately edit files. Designer/reviewer roles produce reports through
# messaging, not Edit/Write — but we leave them alone to avoid false positives.
case "${CLAUDE_ROLE:-}" in
  lead|coordinator) ;;
  *) exit 0 ;;
esac

REASON=$(printf 'ATE %s must never implement directly — spawn an executor teammate (or appropriate role) and assign the task. If your role is mis-set, unset CLAUDE_ROLE.' "${CLAUDE_ROLE}")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
