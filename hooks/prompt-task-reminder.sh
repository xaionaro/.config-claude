#!/bin/bash
# UserPromptSubmit hook: reminds agent to manage task queue.
# Output is injected as context the agent sees alongside the user's message.
cat <<'EOF'
Before responding: if this message contains a new actionable request (not a trivial question, not already tracked), create a task via TaskCreate. Check existing tasks first to avoid duplicates.
EOF

# Remind coordinator/lead/snitch to re-read the skill after context compaction
if [ "${CLAUDE_ROLE:-}" = "coordinator" ] || [ "${CLAUDE_ROLE:-}" = "lead" ] || [ "${CLAUDE_ROLE:-}" = "snitch" ]; then
  cat <<'EOF'
SKILL RELOAD CHECK: If you cannot recall the full agent-teams-execution skill content (roles, protocols, rules), re-invoke it now: use the Skill tool with skill "agent-teams-execution". Context compaction may have removed it.
EOF
fi
