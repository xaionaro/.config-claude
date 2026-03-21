#!/bin/bash
# UserPromptSubmit hook: reminds agent to manage task queue.
# Output is injected as context the agent sees alongside the user's message.
cat <<'EOF'
Before responding: if this message contains a new actionable request (not a trivial question, not already tracked), create a task via TaskCreate. Check existing tasks first to avoid duplicates.
EOF
