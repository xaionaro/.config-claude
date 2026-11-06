#!/usr/bin/env bash
# UserPromptSubmit hook: capture this prompt for the pre-tool admission reviewer.
# Claude port of the Codex writer in ~/.codex/hooks/prompt-task-reminder.sh.
# Writes <proof root>/pre-reviewer/<session_id>/capture-turn-<key>.json, where
# <proof root> is claude_proof_root and <key> is claude_turn_state_key of the
# prompt_id. Contract: ~/.codex/hooks/pre-reviewer-causal-scope.md.
# Fail-open: every error exits 0 silently. Stdout from a UserPromptSubmit hook
# is injected into the model context, so this hook never writes to stdout.

set -uo pipefail
exec >/dev/null 2>&1

# Opt-in gate, as in the reviewer shim: unset means inert, one shell start only.
# The worker reads only CLAUDE_EDIT_PRE_REVIEWER, so that is the only gate.
[ -n "${CLAUDE_EDIT_PRE_REVIEWER:-}" ] || { cat >/dev/null 2>&1; exit 0; }

case "${BASH_SOURCE[0]}" in
  */*) source_dir="${BASH_SOURCE[0]%/*}" ;;
  *) source_dir=. ;;
esac
HOOK_DIR="$(cd -P -- "$source_dir" 2>/dev/null && pwd)" || exit 0
LIB_DIR="$HOOK_DIR/lib"

. "$LIB_DIR/claude-tmp.sh" || exit 0
. "$LIB_DIR/claude-proof-state.sh" || exit 0
. "$LIB_DIR/claude-pre-reviewer-state.sh" || exit 0
. "$LIB_DIR/pre-reviewer-turn-state.sh" || exit 0
. "$LIB_DIR/reviewer-redact.sh" || exit 0

# Same admission bound as the Codex writer: 64 KiB, no NUL, strict UTF-8,
# exactly one JSON object.
INPUT_BYTE_LIMIT=65536
input_file=""
redacted_tmp=""
capped_tmp=""
json_tmp=""

cleanup() {
  local path
  claude_unlock_pre_reviewer_turn
  for path in "$input_file" "$redacted_tmp" "$capped_tmp" "$json_tmp"; do
    [ -n "$path" ] && rm -f -- "$path"
  done
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

admit_input() {
  local file="$1" size

  head -c "$((INPUT_BYTE_LIMIT + 1))" >"$file" || return 1
  size=$(wc -c <"$file") || return 1
  [ "$size" -le "$INPUT_BYTE_LIMIT" ] || return 1
  [ "$(tr -d '\000' <"$file" | wc -c)" -eq "$size" ] || return 1
  iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1 || return 1
  jq -se 'length == 1 and (.[0] | type == "object")' "$file" >/dev/null 2>&1 || return 1
  # A JSON-escaped NUL passes the raw-byte check but the reader's validator
  # rejects it, so refuse it here before any state is created.
  jq -e 'if (.prompt? | type) == "string" then (.prompt | contains("\u0000") | not) else true end' \
    "$file" >/dev/null 2>&1
}

# Migrates a legacy directory mode the way the Codex writer does, so the
# worker's strict 0700 check passes afterwards.
ensure_state_dir() {
  local state_dir="$1"

  claude_ensure_private_pre_reviewer_state_dir "$state_dir" && return 0
  [ -e "$state_dir" ] || return 1
  /usr/bin/python3 "$LIB_DIR/migrate_pre_reviewer_state_dir.py" "$state_dir" \
    >/dev/null 2>&1 || return 1
  claude_ensure_private_pre_reviewer_state_dir "$state_dir"
}

# Sets redacted_tmp, capped_tmp, json_tmp. Runs before the turn lock is taken.
prepare_capture() {
  local state_dir="$1" key="$2" turn_id_json="$3" admitted="$4"

  umask 077
  redacted_tmp="$(mktemp "$state_dir/.capture-turn-$key.redacted.XXXXXX")" || return 1
  capped_tmp="$(mktemp "$state_dir/.capture-turn-$key.capped.XXXXXX")" || return 1
  json_tmp="$(mktemp "$state_dir/.capture-turn-$key.json.XXXXXX")" || return 1
  jq -jr '.prompt' <"$admitted" | redact_sensitive_text >"$redacted_tmp" || return 1
  /usr/bin/python3 "$LIB_DIR/utf8_prefix_cap.py" <"$redacted_tmp" >"$capped_tmp" || return 1
  jq -n --argjson turn_id "$turn_id_json" --rawfile prompt "$capped_tmp" \
    '{turn_id: $turn_id, prompt: $prompt}' >"$json_tmp" || return 1
  chmod 0600 -- "$json_tmp"
}

# Caller holds the turn lock. A claimed turn is already reviewed: leave it alone.
publish_capture() {
  local state_dir="$1" key="$2" prompt_ready="$3"
  local capture="$state_dir/capture-turn-$key.json"
  local claim="$state_dir/claim-turn-$key"

  if [ -e "$claim" ] || [ -L "$claim" ]; then
    return 0
  fi
  rm -f -- "$capture" || return 0
  if [ "$prompt_ready" = true ] && mv -f -- "$json_tmp" "$capture"; then
    json_tmp=""
  fi
  return 0
}

# Runs outside the turn lock, as in the Codex writer. Bounded by the
# prune script's own nonblocking maintenance lock and cursor.
prune_turn_state() {
  local state_dir="$1" prune_fd path_metadata descriptor_metadata owner expected
  local status=1

  owner="$(id -u)" || return 1
  exec {prune_fd}<"$state_dir" || return 1
  path_metadata="$(stat -c '%d:%i|%F|%u|%a' -- "$state_dir" 2>/dev/null)" || path_metadata=""
  descriptor_metadata="$(stat -Lc '%d:%i|%F|%u|%a' -- "/proc/self/fd/$prune_fd" 2>/dev/null)" ||
    descriptor_metadata=""
  expected="${descriptor_metadata%%|*}|directory|$owner|700"
  if [ -n "$descriptor_metadata" ] &&
      [ "$path_metadata" = "$descriptor_metadata" ] &&
      [ "$descriptor_metadata" = "$expected" ]; then
    /usr/bin/python3 "$LIB_DIR/prune_pre_reviewer_turn_state.py" "$prune_fd" "$(date +%s)" \
      >/dev/null 2>&1
    status=$?
  fi
  exec {prune_fd}>&-
  return "$status"
}

write_capture() {
  local admitted="$1" session_id prompt_id prompt_type turn_id_json key root state_dir
  local prompt_ready=false

  session_id=$(jq -r 'if (.session_id? | type) == "string" then .session_id else "" end' \
    <"$admitted") || return 1
  claude_valid_session_id "$session_id" || return 1
  prompt_id=$(jq -r '.prompt_id // empty' <"$admitted") || return 1
  [ -n "$prompt_id" ] || return 1
  turn_id_json="$(claude_hook_turn_id_json "$(jq -cn --arg id "$prompt_id" '{turn_id: $id}')")"
  [ -n "$turn_id_json" ] || return 1
  key="$(claude_turn_state_key "$turn_id_json")" || return 1

  root="$(claude_proof_root)"
  state_dir="$root/pre-reviewer/$session_id"
  ensure_state_dir "$state_dir" || return 1

  prompt_type=$(jq -r '.prompt? | type' <"$admitted") || return 1
  if [ "$prompt_type" = string ] &&
      prepare_capture "$state_dir" "$key" "$turn_id_json" "$admitted"; then
    prompt_ready=true
  fi
  if claude_lock_pre_reviewer_turn "$state_dir"; then
    publish_capture "$state_dir" "$key" "$prompt_ready"
    claude_unlock_pre_reviewer_turn
    prune_turn_state "$state_dir" || true
  fi
  return 0
}

main() {
  claude_init_tmp || true
  input_file="$(mktemp)" || return 0
  admit_input "$input_file" || return 0
  write_capture "$input_file" || return 0
}

main
exit 0
