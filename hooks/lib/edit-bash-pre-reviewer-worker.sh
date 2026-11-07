#!/usr/bin/env bash
# Worker for the Claude first-tool-call admission reviewer. Runs inside the
# controller's unshare sandbox; its stdout is the only hook output path.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HOOK_DIR/lib/claude-proof-state.sh"
. "$HOOK_DIR/lib/claude-tmp.sh"
. "$HOOK_DIR/lib/claude-pre-reviewer-state.sh"
. "$HOOK_DIR/lib/pre-reviewer-turn-state.sh"
. "$HOOK_DIR/lib/reviewer-redact.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"
claude_init_tmp || true

input="$(/usr/bin/python3 "$HOOK_DIR/lib/bounded_hook_input.py" stdin)" || exit 0
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
prompt_id=$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null || true)
claude_valid_session_id "$session_id" || exit 0

case "$tool_name" in
  Bash|Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# Opt-in gate first: unset means nothing is read, created or touched.
[ -n "${CLAUDE_EDIT_PRE_REVIEWER:-}" ] || exit 0

# The turn key is the documented prompt_id of the hook input. The admitted
# prompt is the capture the writer stored for that turn. No capture means no
# review (codex parity: no transcript fallback).
[ -n "$prompt_id" ] || exit 0
turn_id_json="$(claude_hook_turn_id_json "$(jq -cn --arg id "$prompt_id" '{turn_id: $id}')")"
[ -n "$turn_id_json" ] || exit 0
if claude_hook_is_subagent_context "$input"; then
  exit 0
fi

root="$(claude_proof_root)"
state_dir="$root/pre-reviewer/$session_id"
stop_state_dir="$root/reviewer/$session_id"

is_touch_bypass_command() {
  local command_text="$1"
  local bypass_file="$2"

  case "$command_text" in
    "touch $bypass_file"|"touch '$bypass_file'"|"touch \"$bypass_file\""|\
    "touch -- $bypass_file"|"touch -- '$bypass_file'"|"touch -- \"$bypass_file\"") return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$tool_name" = "Bash" ]; then
  command_text=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  is_touch_bypass_command "$command_text" "$state_dir/bypass" && exit 0
  if is_touch_bypass_command "$command_text" "$stop_state_dir/bypass"; then
    mkdir -p "$stop_state_dir" 2>/dev/null || true
    exit 0
  fi
fi

[ -f "$state_dir/bypass" ] && exit 0

claude_parse_pre_reviewer_env CLAUDE_EDIT_PRE_REVIEWER || exit 0
[ -n "$REVIEWER_BACKEND" ] || exit 0
claude_ensure_private_pre_reviewer_state_dir "$state_dir" || exit 0

claim_key="$(claude_turn_state_key "$turn_id_json" 2>/dev/null || true)"
[ -n "$claim_key" ] || exit 0
claim="$(claude_turn_claim_path "$state_dir" "$claim_key")"
consumed_capture=""
cleanup_present_turn() {
  claude_unlock_pre_reviewer_turn
  [ -z "$consumed_capture" ] || rm -f -- "$consumed_capture"
}
trap cleanup_present_turn EXIT
trap 'cleanup_present_turn; exit 0' HUP INT TERM
claude_lock_pre_reviewer_turn "$state_dir" || exit 0
if [ -e "$claim" ] || [ -L "$claim" ]; then
  exit 0
fi

capture="$state_dir/capture-turn-$claim_key.json"
if [ ! -e "$capture" ] && [ ! -L "$capture" ]; then
  exit 0
fi
consumed_capture="$(mktemp "$state_dir/.capture-turn-$claim_key.consumed.XXXXXX")" || exit 0
mv -f -- "$capture" "$consumed_capture" || exit 0
last_user_message="$(/usr/bin/python3 "$HOOK_DIR/lib/turn_capture_validator.py" \
  "$turn_id_json" <"$consumed_capture")" || exit 0

if ! ( umask 077; set -C; : >"$claim" ) 2>/dev/null; then
  # Claim not created: restore the capture so the turn stays reviewable.
  if mv -f -- "$consumed_capture" "$capture"; then
    consumed_capture=""
  fi
  exit 0
fi
claude_unlock_pre_reviewer_turn
rm -f -- "$consumed_capture"
consumed_capture=""
trap - EXIT HUP INT TERM

if ! tool_input="$(
  printf '%s' "$input" |
    jq -c '.tool_input // {}' 2>/dev/null |
    redact_sensitive_text |
    /usr/bin/python3 "$HOOK_DIR/lib/utf8_prefix_cap.py"
)"; then
  exit 0
fi

sys_file=$(mktemp "$TMPDIR/claude-pre-reviewer-system.XXXXXX") || exit 0
usr_file=$(mktemp "$TMPDIR/claude-pre-reviewer-user.XXXXXX") || exit 0
schema_file=$(mktemp "$TMPDIR/claude-pre-reviewer-schema.XXXXXX") || exit 0
trap 'rm -f "$sys_file" "$usr_file" "$schema_file"' EXIT

cat >"$sys_file" <<'EOF'
Admission controller for a coding agent. The agent is about to invoke a tool on the first action of a new user turn. Decide whether the agent may proceed directly or should first load a matching skill / delegate.

Claude routing excerpt:
- Debugging, failures, unexpected behavior: use debugging skills.
- Go code: use coding-go.
- Python code: use coding-python.
- Tests: use testing-discipline.
- Prompt, skill, or CLAUDE.md edits: use harness-tuning.
- Medium uncertain coding task: use explore-critique-implement.
- Explicit subagent/delegation request: use standard subagent tools.

Rules:
- Trivial = file read, quick status, simple lookup, or typo-scale change.
- Non-trivial = logic, bugfix, tests, multi-file change, prompt/hook behavior, or uncertain implementation.
- Deny only when the next action should clearly be skill/delegation setup first.
- When in doubt, allow.

Output JSON only: {"verdict":"allow"|"deny","reason":"one sentence"}
EOF
printf 'LAST USER MESSAGE:\n%s\n\nTOOL ABOUT TO BE CALLED: %s\nTOOL INPUT: %s\n' "$last_user_message" "$tool_name" "$tool_input" >"$usr_file"
cat >"$schema_file" <<'JSON'
{
  "type": "object",
  "required": ["verdict", "reason"],
  "additionalProperties": false,
  "properties": {
    "verdict": {"type": "string", "enum": ["allow", "deny"]},
    "reason": {"type": "string"}
  }
}
JSON

result=$(claude_pre_reviewer_call_chat "pre_reviewer" "$sys_file" "$usr_file" "$schema_file" "$CLAUDE_EDIT_PRE_REVIEWER_TIMEOUT" 2>/dev/null) || exit 0

verdict=$(printf '%s' "$result" | jq -r '.verdict // empty' 2>/dev/null || true)
reason=$(printf '%s' "$result" | jq -r '.reason // empty' 2>/dev/null || true)

if [ "$verdict" = "deny" ]; then
  if [ "$tool_name" = Bash ]; then
    subject="tool=Bash,command=$(eci_command_identity_subject "${command_text:-}"),session=$(eci_diagnostic_value "$session_id"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}")"
  else
    edit_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' 2>/dev/null || true)
    subject="tool=$(eci_diagnostic_value "$tool_name"),path=$(eci_diagnostic_value "${edit_path:-<missing>}"),session=$(eci_diagnostic_value "$session_id"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}")"
  fi
  detail=$(printf 'Pre-tool admission reviewer denied the first tool call of this turn.\n\nReason: %s\n\nLoad the matching skill or delegate before invoking %s directly. The recovery route is unavailable; report the blocker.' "$reason" "$tool_name")
  message="$(eci_diagnostic_reason "$(eci_diagnostic_code_for_reason "$detail")" "PreToolUse" "pre-reviewer-admission" "$subject" "$detail" "load the matching skill or delegate before invoking the tool; report the blocker if recovery is unavailable")"
  jq -n --arg reason "$message" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi
