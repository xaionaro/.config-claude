#!/usr/bin/env bash
# PreToolUse hook for the SendMessage tool: blocks calls addressed to
# recipients that do not exist in the team roster, returning the current
# roster so the caller can correct the recipient name.
#
# Roster source: ~/.claude/teams/<team>/config.json (members[].name, agentId).
# Resolution:
#   - If tool_input.team_name is supplied -> validate against that team only.
#   - Otherwise -> accept iff recipient appears in any known team's roster;
#     deny with a global roster dump when it appears in zero teams.
#
# Recipient field resolution: tool_input.to | tool_input.recipient | tool_input.name.
# If none are present, exit 0 (let the harness handle malformed input).
#
# Failure mode: trap-to-deny-with-evidence (matches eci-active-gate.sh and
# the rest of the gate suite — surfaces hook bugs immediately rather than
# silently failing open).

set -uo pipefail

trap 'jq -n --arg reason "sendmessage-roster-gate infra error at line $LINENO; investigate $HOME/.claude/teams and the gate script" "{
  hookSpecificOutput: {
    hookEventName: \"PreToolUse\",
    permissionDecision: \"deny\",
    permissionDecisionReason: \$reason
  }
}"; exit 0' ERR

# shellcheck source=lib/teams-roster.sh
. "$HOME/.claude/hooks/lib/teams-roster.sh"

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" = "SendMessage" ] || exit 0

RECIPIENT=$(echo "$INPUT" | jq -r '.tool_input.to // .tool_input.recipient // .tool_input.name // empty')
# Nothing to validate; let the harness raise the schema error.
[ -n "$RECIPIENT" ] || exit 0

TEAM=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty')

emit_deny() {
  local reason="$1"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

if [ -n "$TEAM" ]; then
  if teams_roster_team_has_recipient "$TEAM" "$RECIPIENT"; then
    exit 0
  fi
  CFG="$(teams_roster_team_config "$TEAM")"
  if [ ! -f "$CFG" ]; then
    REASON=$(printf 'SendMessage rejected: team "%s" has no config at %s. Verify team_name.' "$TEAM" "$CFG")
    emit_deny "$REASON"
  fi
  ROSTER="$(teams_roster_team_pretty "$TEAM")"
  REASON=$(printf 'SendMessage to "%s" rejected: not in roster of team "%s".\n\n%s\nUse the exact name or agentId from the roster above.' "$RECIPIENT" "$TEAM" "$ROSTER")
  emit_deny "$REASON"
fi

# No team_name supplied: accept when recipient matches anywhere.
if teams_roster_global_has_recipient "$RECIPIENT"; then
  exit 0
fi

ROSTER="$(teams_roster_global_pretty)"
REASON=$(printf 'SendMessage to "%s" rejected: not in any known team roster.\n\n%s\nUse the exact name or agentId. Pass team_name to disambiguate.' "$RECIPIENT" "$ROSTER")
emit_deny "$REASON"
