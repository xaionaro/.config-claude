#!/bin/bash
# UserPromptSubmit hook: enforces mandatory skill routing on every user message.
# Output is injected as context the agent sees alongside the user's message.

cat <<'EOF'
═══ MANDATORY PRE-WORK GATE ═══

1. TASK TRACKING: New actionable request? → TaskCreate (check existing tasks first).

2. TASK SIZE → SKILL:
   - Trivial/Small → proceed directly
   - Medium (investigation, single-feature, "why does X not work?") → invoke explore-critique-implement
   - Large (multi-module, productionize, system-wide refactor) → invoke agent-teams-execution

3. Walk through EVERY entry in CLAUDE.md "Mandatory Skills" section (items 0-10). Invoke each applicable skill via Skill tool.

4. HARD RULE: Do NOT start implementation until task size classified AND all applicable skills invoked. No exemptions.

═══ END GATE ═══
EOF

# Remind coordinator/lead/snitch to re-read the skill after context compaction
if [ "${CLAUDE_ROLE:-}" = "coordinator" ] || [ "${CLAUDE_ROLE:-}" = "lead" ] || [ "${CLAUDE_ROLE:-}" = "snitch" ]; then
  cat <<'EOF'
SKILL RELOAD CHECK: If you cannot recall the full agent-teams-execution skill content (roles, protocols, rules), re-invoke it now: use the Skill tool with skill "agent-teams-execution". Context compaction may have removed it.
EOF
fi
