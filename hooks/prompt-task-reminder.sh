#!/bin/bash
# UserPromptSubmit hook: enforces mandatory skill routing on every user message,
# AND records HEAD-at-this-prompt so the reviewer hook can show the cumulative
# diff for the whole turn (all commits since this prompt) instead of just
# HEAD~1..HEAD.

# Stdin is the hook event JSON; consume it once and reuse.
HOOK_INPUT=$(cat 2>/dev/null || true)

cat <<'EOF'
PRE-WORK: TaskCreate if new request. Size→skill: medium→ECI, large→ATE. Walk CLAUDE.md Mandatory Skills (0-10), invoke all applicable. Follow system prompt. Tag claims T1-T5 (T5→promote or discard). No implementation before skills invoked.
EOF

# Record HEAD of ~/.claude at the moment of this prompt. Sibling dir under
# ~/.cache/claude-proof/reviewer/ — that dir survives stop-gate's $PROOF_DIR
# wipe (see feedback_proof_dir_wiped memory).
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
case "$SESSION_ID" in
  ""|*[!A-Za-z0-9_-]*) ;; # missing or unsafe → skip recording
  *)
    REVIEWER_DIR="$HOME/.cache/claude-proof/reviewer/$SESSION_ID"
    mkdir -p "$REVIEWER_DIR"
    git -C "$HOME/.claude" rev-parse HEAD >"$REVIEWER_DIR/prompt_head" 2>/dev/null || true

    # Bypass markers (stop-reviewer and pre-reviewer) are ephemeral —
    # they only apply to the turn in which the user touches them. Clear
    # on every new user prompt so a stale bypass can't keep silencing
    # gates indefinitely.
    rm -f "$REVIEWER_DIR/bypass" 2>/dev/null
    rm -f "$HOME/.cache/claude-proof/pre-reviewer/$SESSION_ID/bypass" 2>/dev/null
    ;;
esac

# Remind coordinator/lead/snitch to re-read the skill after context compaction
if [ "${CLAUDE_ROLE:-}" = "coordinator" ] || [ "${CLAUDE_ROLE:-}" = "lead" ] || [ "${CLAUDE_ROLE:-}" = "snitch" ]; then
  cat <<'EOF'
SKILL RELOAD CHECK: If you cannot recall agent-teams-execution (roles, protocols, rules), re-invoke via Skill tool, skill "agent-teams-execution". Compaction may have evicted it.
EOF
fi
