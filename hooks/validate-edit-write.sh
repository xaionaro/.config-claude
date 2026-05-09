#!/bin/bash
# PreToolUse hook: validates Edit/Write/MultiEdit operations before execution.
#
# Default trap behaviour for this hook is fail-OPEN (`claude_install_fail_open_trap`):
# if the hook itself crashes, the tool call is allowed. This default is correct
# for the vendor/plans/submodule/go.mod path-policy blocks.
#
# THE SESSION-OWNERSHIP BLOCK IS DIFFERENT: it is a security gate and must
# fail-CLOSED on any internal error. It does this by locally swapping to a
# deny-emitting ERR trap for the duration of the block, then restoring the
# file-level fail-open trap. If you add another security-relevant policy to
# this script, repeat the trap swap; do NOT inherit the script-wide fail-open
# default.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/claude-proof-state.sh"
. "$HOOK_DIR/lib/claude-tmp.sh"
claude_init_tmp || true
claude_install_fail_open_trap validate-edit-write

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

case "$TOOL_NAME" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // .tool_input.target_file // empty' 2>/dev/null || true)

# Session-file ownership gate. Forbid editing session-scoped files owned by
# another session: ~/.cache/claude-proof/<SID>/, ~/.claude/projects/<DIR>/<SID>.jsonl,
# ~/.claude/projects/<DIR>/<SID>/{subagents,tool-results}/..., and
# ~/.claude/todos/<SID>-agent-<X>.json.
#
# Allowed owners:
#   - the current session id (hook input .session_id)
#   - the explicit parent session id ($CLAUDE_PARENT_SESSION_ID), set by
#     `claude-as-role` for tmux ATE teammates, so a spawned teammate can
#     write into its parent's ledger / log / todos.
#   - $CLAUDE_CODE_SESSION_ID — Claude Code exports this into every
#     subprocess env. For Agent-tool sidechain subagents that share the
#     orchestrator's process this matches the orchestrator's session,
#     covering the parent case automatically. For top-level spawns
#     (independent claude proc) it usually equals the new session id —
#     redundant with OWN_SID, harmless.
# If none resolves on a protected path, fail closed (deny).
#
# HOME_RE escapes every ERE metacharacter that may appear in $HOME. The class
# covers BRE/ERE specials []\\/.^$* plus ERE-only +?(){}| so paths like
# /Users/jane (work) or /home/x+y do not silently break the regex (which would
# bypass the gate, since extract_owner_sid would return empty). The sed
# s-command below uses '#' as the delimiter, so '|' inside the pattern is a
# literal ERE alternation operator with no escaping needed.
HOME_RE=$(printf '%s' "$HOME" | sed 's|[][\\/.^$*+?(){}|]|\\&|g')
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
extract_owner_sid() {
  local p="$1"
  printf '%s' "$p" | sed -nE \
    -e "s#^${HOME_RE}/\\.cache/claude-proof/(${UUID_RE})(/.*)?\$#\\1#p" \
    -e "s#^${HOME_RE}/\\.claude/projects/[^/]+/(${UUID_RE})\\.jsonl\$#\\1#p" \
    -e "s#^${HOME_RE}/\\.claude/projects/[^/]+/(${UUID_RE})/(subagents|tool-results)/.*\$#\\1#p" \
    -e "s#^${HOME_RE}/\\.claude/todos/(${UUID_RE})-agent-${UUID_RE}\\.json\$#\\1#p"
}

OWN_SID="${SESSION_ID:-}"
PARENT_SID="${CLAUDE_PARENT_SESSION_ID:-}"
CODE_SID="${CLAUDE_CODE_SESSION_ID:-}"
claude_valid_session_id "$OWN_SID" || OWN_SID=""
claude_valid_session_id "$PARENT_SID" || PARENT_SID=""
claude_valid_session_id "$CODE_SID" || CODE_SID=""

# Auto-detect parent SID from the spawning claude proc's argv. Claude
# Code passes `--parent-session-id <SID>` to subagent / team-member
# processes (TeamCreate spawns, --agent-id top-level spawns). The hook
# is exec'd as a direct child of that claude proc, so /proc/$PPID/cmdline
# carries the flag. NUL-separated argv → split on NUL, find the entry
# immediately after --parent-session-id. Linux-only; other OSes fall
# through to the file fallback below.
if [ -z "$PARENT_SID" ] && [ -r "/proc/$PPID/cmdline" ]; then
  ARGV_PARENT_SID=$(tr '\0' '\n' </proc/$PPID/cmdline 2>/dev/null \
    | awk 'prev=="--parent-session-id" { print; exit } { prev=$0 }')
  claude_valid_session_id "$ARGV_PARENT_SID" || ARGV_PARENT_SID=""
  [ -n "$ARGV_PARENT_SID" ] && PARENT_SID="$ARGV_PARENT_SID"
fi

# File fallback for already-running teammates whose spawning claude proc
# carries no --parent-session-id flag and whose env was not seeded with
# CLAUDE_PARENT_SESSION_ID. The orchestrator (or the user) can declare
# the parent SID by writing it into
# ~/.cache/claude-proof/<OWN_SID>/parent_session_id. First line of the
# file is treated as an additional allowed parent SID.
if [ -z "$PARENT_SID" ] && [ -n "$OWN_SID" ]; then
  PARENT_SID_FILE="$HOME/.cache/claude-proof/$OWN_SID/parent_session_id"
  if [ -f "$PARENT_SID_FILE" ]; then
    FILE_PARENT_SID=$(head -n1 "$PARENT_SID_FILE" 2>/dev/null | tr -d '[:space:]' || true)
    claude_valid_session_id "$FILE_PARENT_SID" || FILE_PARENT_SID=""
    [ -n "$FILE_PARENT_SID" ] && PARENT_SID="$FILE_PARENT_SID"
  fi
fi

if [ -n "$FILE_PATH" ]; then
  trap '_claude_fail_open_emit "validate-edit-write" "$LINENO" "$?" "$BASH_COMMAND"; jq -n --arg reason "ownership check failed; failing closed for safety" "{hookSpecificOutput:{hookEventName:\"PreToolUse\",permissionDecision:\"deny\",permissionDecisionReason:\$reason}}"; exit 0' ERR
  # No `|| true`: real internal failure (e.g. printf/sed crash) must trip the
  # fail-closed ERR trap above, not silently produce an empty OWNER_SID.
  OWNER_SID=$(extract_owner_sid "$FILE_PATH")
  if [ -n "$OWNER_SID" ]; then
    if [ -z "$OWN_SID" ] && [ -z "$PARENT_SID" ] && [ -z "$CODE_SID" ]; then
      deny "Session-scoped file ${FILE_PATH##*/} requires a current session id; none resolved (no .session_id in hook input, no \$CLAUDE_PARENT_SESSION_ID, no \$CLAUDE_CODE_SESSION_ID). Refusing fail-open on a session-scoped path."
    elif [ "$OWNER_SID" != "$OWN_SID" ] && [ "$OWNER_SID" != "$PARENT_SID" ] && [ "$OWNER_SID" != "$CODE_SID" ]; then
      deny "Refusing to edit ${FILE_PATH##*/}: file belongs to session $OWNER_SID, allowed sessions are own ($OWN_SID)${PARENT_SID:+ and parent ($PARENT_SID)}${CODE_SID:+ and code-env ($CODE_SID)}. Each session may edit its own and its parent's proof / transcript / todos."
    fi
  fi
  trap - ERR
  claude_install_fail_open_trap validate-edit-write
fi

# Block edits to vendored code: source must be edited, then revendored.
# Covers all common vendored-dir conventions, case-insensitive:
#   import/ imports/ vendor/                        (Go + xaionaro-go)
#   3rdparty/ 3rd_party/ 3rd-party/ "3rd party/"    (numeric prefix)
#   thirdparty/ third_party/ third-party/ "third party/" (word prefix)
if [ -n "$FILE_PATH" ] && printf '%s\n' "$FILE_PATH" | grep -Eiq '(^|/)(import|imports|vendor|(3rd|third)[ _-]?party)(/|$)'; then
  deny 'Do not edit files under import/, imports/, vendor/, or any third-party/3rdparty variant directly. Edit the original source and revendor the files. Worst case: edit the originals and rsync them into the vendored dir.'
fi

# Block plan-file edits under docs/plans or docs/superpowers/plans. Plans go to /tmp/claude-plans.
if [ -n "$FILE_PATH" ] && printf '%s\n' "$FILE_PATH" | grep -Eq '(^|/)docs/(superpowers/)?plans/'; then
  BASENAME=$(basename "$FILE_PATH")
  deny "Plans must not be saved inside the repo. Save to /tmp/claude-plans/$BASENAME instead."
fi

# Block edits inside git submodules. A submodule is identified by a `.git`
# entry that is a FILE (gitlink, contents start with "gitdir: ...") rather
# than a directory. Walk up from FILE_PATH's directory looking for the
# closest `.git`; if it's a file, we're inside a submodule.
is_inside_submodule() {
  local p="$1"
  [ -n "$p" ] || return 1
  local d
  if [ -d "$p" ]; then
    d="$p"
  else
    d="$(dirname -- "$p")"
  fi
  case "$d" in
    /*) ;;
    *) d="$PWD/$d" ;;
  esac
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -e "$d/.git" ]; then
      [ -f "$d/.git" ] && return 0  # gitlink → inside a submodule
      return 1                       # regular repo
    fi
    d="$(dirname -- "$d")"
  done
  return 1
}
if [ -n "$FILE_PATH" ] && is_inside_submodule "$FILE_PATH"; then
  deny 'Do not edit files inside a git submodule. Update the submodule upstream and pull, or detach with git submodule deinit if intentional.'
fi

# Mark edit activity for non-subagent contexts (after deny checks so denied edits don't mark activity).
if ! claude_hook_is_subagent_context "$INPUT"; then
  claude_mark_activity "$SESSION_ID" "$CWD" edit || true
fi

# go.mod local-replace check (preserved from prior validation).
[[ "$FILE_PATH" == */go.mod ]] || exit 0

if [[ "$TOOL_NAME" == "Write" ]]; then
  TEXT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  TEXT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null || true)
elif [[ "$TOOL_NAME" == "MultiEdit" ]]; then
  TEXT=$(echo "$INPUT" | jq -r '[.tool_input.edits[]?.new_string] | join("\n") // empty' 2>/dev/null || true)
else
  exit 0
fi

# Check for local path replace: => ../ or => ./
if echo "$TEXT" | grep -qE '=>\s*\.\.?/'; then
  deny 'Do not add local-path replace directives (=> ../something or => ./something) to go.mod. Use go.work for local module resolution. Remote fork replaces are fine.'
fi
