#!/bin/bash
# UserPromptSubmit hook: enforces mandatory skill routing on every user message,
# AND records HEAD-at-this-prompt so the reviewer hook can show the cumulative
# diff for the whole turn (all commits since this prompt) instead of just
# HEAD~1..HEAD.

# Stdin is the hook event JSON; consume it once and reuse.
HOOK_INPUT=$(cat 2>/dev/null || true)

# Proof root from its single definition in lib/claude-proof-state.sh. Without
# the lib, the proof-root steps below are skipped (fail open).
PROOF_ROOT=""
if . "$HOME/.claude/hooks/lib/claude-proof-state.sh" 2>/dev/null; then
  PROOF_ROOT="$(claude_configured_proof_root)"
fi

cat <<'EOF'
PRE-WORK: TaskCreate if new request. Size→skill: medium→ECI, large→ATE. Walk CLAUDE.md Mandatory Skills (0-10), invoke all applicable. Follow system prompt. Tag claims T1-T5 (T5→promote or discard). No implementation before skills invoked.
EOF

# Record HEAD of ~/.claude at the moment of this prompt. Sibling dir under
# $PROOF_ROOT/reviewer/ — that dir survives stop-gate's $PROOF_DIR
# wipe (see feedback_proof_dir_wiped memory).
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# A missing or unsafe session id, or no proof root, clears SESSION_ID, so every
# proof-root step below is skipped.
case "$SESSION_ID" in
  ""|*[!A-Za-z0-9_-]*) SESSION_ID="" ;;
esac
[ -n "$PROOF_ROOT" ] || SESSION_ID=""
case "$SESSION_ID" in
  "") ;; # skip recording
  *)
    REVIEWER_DIR="$PROOF_ROOT/reviewer/$SESSION_ID"
    mkdir -p "$REVIEWER_DIR"
    git -C "$HOME/.claude" rev-parse HEAD >"$REVIEWER_DIR/prompt_head" 2>/dev/null || true

    # Bypass markers (stop-reviewer and pre-reviewer) are ephemeral —
    # they only apply to the turn in which the user touches them. Clear
    # on every new user prompt so a stale bypass can't keep silencing
    # gates indefinitely.
    rm -f "$REVIEWER_DIR/bypass" 2>/dev/null
    rm -f "$PROOF_ROOT/pre-reviewer/$SESSION_ID/bypass" 2>/dev/null
    ;;
esac

# Remind coordinator/lead/snitch to re-read the skill after context compaction
if [ "${CLAUDE_ROLE:-}" = "coordinator" ] || [ "${CLAUDE_ROLE:-}" = "lead" ] || [ "${CLAUDE_ROLE:-}" = "snitch" ]; then
  cat <<'EOF'
SKILL RELOAD CHECK: If you cannot recall agent-teams-execution (roles, protocols, rules), re-invoke via Skill tool, skill "agent-teams-execution". Compaction may have evicted it.
EOF
fi

# ECI activation persists on disk but its skill content does not survive
# context compaction. When the eci_active marker exists, surface it on
# every user prompt so the agent re-engages even after compaction.
if [ -n "${SESSION_ID:-}" ]; then
  ECI_MARKER="$PROOF_ROOT/$SESSION_ID/eci_active"
  if [ -f "$ECI_MARKER" ]; then
    cat <<EOF
ECI ACTIVE for this session — code edits go through subagents per the explore-critique-implement skill (eci-active-gate denies direct edits only to ECI control and ledger files). Marker contents:
$(cat "$ECI_MARKER")
If you cannot recall the explore-critique-implement flow, re-invoke via Skill tool, skill "explore-critique-implement". Compaction may have evicted it. Disengage only when the scope is closed via: ~/.claude/bin/eci-active off <disengage-report.md>
EOF
  fi
fi

# /side stop marker (codex parity): a prompt starting with /side marks this
# session and its cwd so stop-gate.sh lets the side conversation stop.
# Same marker format as codex prompt-task-reminder.sh:63-89. Fail-open.
write_side_stop_marker() {
  local dir="$1" cwd="$2"
  mkdir -p "$dir" || return 1
  {
    printf 'command: /side\n'
    printf 'parent_session_id: %s\n' "$SESSION_ID"
    [ -n "$cwd" ] && printf 'cwd: %s\n' "$cwd"
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$dir/side_stop"
}

mark_side_stop() {
  local prompt cwd side_dir
  prompt=$(printf '%s' "$HOOK_INPUT" | jq -r 'if (.prompt? | type) == "string" then .prompt else "" end' 2>/dev/null) || return 0
  printf '%s\n' "$prompt" | grep -Eq '^[[:space:]]*/side([[:space:]]|$)' || return 0
  case "$SESSION_ID" in
    ""|*[!A-Za-z0-9_-]*) return 0 ;;
  esac
  cwd=$(printf '%s' "$HOOK_INPUT" | jq -r 'if (.cwd? | type) == "string" then .cwd else "" end' 2>/dev/null) || cwd=""
  write_side_stop_marker "$(claude_session_state_dir side-stop "$SESSION_ID")" "$cwd" || return 0
  if [ -n "$cwd" ]; then
    side_dir="$(claude_ensure_cwd_state_dir side-stop "$cwd" 2>/dev/null)" &&
      [ -n "$side_dir" ] && write_side_stop_marker "$side_dir" "$cwd"
  fi
  return 0
}
mark_side_stop || true
exit 0
