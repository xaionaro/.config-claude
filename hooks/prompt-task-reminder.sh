#!/bin/bash
# UserPromptSubmit hook: enforces mandatory skill routing on every user message.
# Output is injected as context the agent sees alongside the user's message.

cat <<'EOF'
PRE-WORK: TaskCreate if new request. Size→skill: medium→ECI, large→ATE. Walk CLAUDE.md Mandatory Skills (0-10), invoke all applicable. Follow system prompt. Tag claims T1-T5 (T5→promote or discard). No implementation before skills invoked.
EOF

# Remind coordinator/lead/snitch to re-read the skill after context compaction
if [ "${CLAUDE_ROLE:-}" = "coordinator" ] || [ "${CLAUDE_ROLE:-}" = "lead" ] || [ "${CLAUDE_ROLE:-}" = "snitch" ]; then
  cat <<'EOF'
SKILL RELOAD CHECK: If you cannot recall the full agent-teams-execution skill content (roles, protocols, rules), re-invoke it now: use the Skill tool with skill "agent-teams-execution". Context compaction may have removed it.
EOF
fi
