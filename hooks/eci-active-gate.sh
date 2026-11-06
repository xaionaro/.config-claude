#!/usr/bin/env bash
# PreToolUse hook: protect active ECI control and ledger targets during edits.
#
# Port of ~/.codex/hooks/eci-active-gate.sh. Denies Edit, Write, MultiEdit and
# NotebookEdit whose target is an ECI control or ledger file (or a reserved
# proof-dir descendant), raw or realpath-resolved, under a proof root.
#
# Deliberate divergences from the Codex gate:
#   - every string path in tool_input (file_path, notebook_path, path,
#     target_file) is checked, not only the first non-null key;
#   - an alias (hard link, or symlink to a control file) is denied even when
#     the link's own name is a working document;
#   - an edit tool whose tool_input is not an object is denied with exit 2
#     (Codex exits 5, which Claude Code treats as a non-blocking error).
# Otherwise: no subagent exemption, no marker-based main-thread denial, and
# other malformed or incomplete input is allowed.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/claude-eci-control.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"

input=$(cat)

if ! printf '%s' "$input" | jq -e '
  type == "object" and (.tool_name | type) == "string" and
  (.tool_name | length > 0) and
  (.session_id | type) == "string" and (.cwd | type) == "string"
' >/dev/null 2>&1; then
  # Without a typed payload no concrete edit target can be resolved, so leave
  # the call to normal validation.
  exit 0
fi
tool_name=$(printf '%s' "$input" | jq -r '.tool_name' 2>/dev/null || true)

session_id=$(printf '%s' "$input" | jq -r '.session_id' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd' 2>/dev/null || true)
case "$session_id" in
  ""|*[!A-Za-z0-9_-]*)
    exit 0
    ;;
esac
[ -n "$cwd" ] || {
  exit 0
}
case "$cwd" in
  *[![:print:]]*)
    exit 0
    ;;
esac

case "$tool_name" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# An edit whose tool_input is not an object has no checkable target. Deny it
# with exit 2, the blocking exit code, and state the reason on stderr too.
if ! printf '%s' "$input" | jq -e '(.tool_input | type) == "object"' >/dev/null 2>&1; then
  reason="ECI denies this $tool_name call: tool_input is not a JSON object, so the edit target cannot be checked. Resend the call with a structured tool_input."
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  printf '%s\n' "$reason" >&2
  exit 2
fi

# Every non-empty string path is a target. Deciding on the first non-null key
# alone let a benign file_path mask a control notebook_path.
tool_paths() {
  printf '%s' "$input" |
    jq -r '.tool_input | objects | [.file_path, .notebook_path, .path, .target_file][] | select(type == "string" and length > 0)' 2>/dev/null
}

# Working documents of the current session are coordination state, not
# lifecycle controls. The exception is limited to the callback's own proof
# session so a foreign session's record still reaches the control check below.
current_session_working_document() {
  local path="${1:-}" owner_session

  case "${path##*/}" in
    project-understanding.yaml|latest-status-report.md|latest-status-report.yaml|handoff.md|high_level_log.jsonl|high_level_log.anchor|proof.md) ;;
    *) return 1 ;;
  esac
  owner_session="$(claude_path_owner_session_id "$path" 2>/dev/null || true)"
  [ "$owner_session" = "$session_id" ]
}

tool_path_list="$(tool_paths)"

# Check raw and resolved targets (including lexical aliases and hard links)
# against the control boundary. Alias denial is decided first: a hard link to a
# control file, or a symlink whose target is one, is denied even when the
# link's own name is a working document.
while IFS= read -r control_path; do
  [ -n "$control_path" ] || continue
  lexical_control_path="$(claude_lexical_hook_path "$cwd" "$control_path" 2>/dev/null || true)"
  resolved_control_path="$(claude_resolve_hook_path "$cwd" "$control_path" 2>/dev/null || true)"
  control_alias=false
  if [ -n "$lexical_control_path" ] && claude_path_is_eci_control_alias "$lexical_control_path"; then
    control_alias=true
  elif [ -n "$resolved_control_path" ] && [ "$resolved_control_path" != "$lexical_control_path" ] &&
    claude_path_is_eci_control_alias "$resolved_control_path"; then
    control_alias=true
  fi
  if [ -n "$lexical_control_path" ] && [ -L "$lexical_control_path" ] &&
     [ -n "$resolved_control_path" ] && [ "$resolved_control_path" != "$lexical_control_path" ] &&
     claude_path_is_eci_control_file "$resolved_control_path"; then
    control_alias=true
  fi

  denied=false
  if [ "$control_alias" = true ]; then
    denied=true
  elif { claude_path_is_eci_control_file "$lexical_control_path" ||
         claude_path_is_eci_control_file "$resolved_control_path"; } &&
       ! current_session_working_document "${resolved_control_path:-$lexical_control_path}"; then
    denied=true
  fi
  if [ "$denied" = true ]; then
    target_value="$(eci_diagnostic_value "${resolved_control_path:-$control_path}")"
    reason="$(eci_diagnostic_reason "ECI_CONTROL_OWNER_REQUIRED" "PreToolUse" "edit-routing" "tool=$tool_name,target=$target_value" "ECI denies direct edits to active control state" "route this control-state change through its ECI lifecycle owner, not a direct edit")"
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
done <<< "$tool_path_list"

# Every remaining target (repository source, Markdown, unrelated proof files)
# is left to normal routing and validation.
exit 0
