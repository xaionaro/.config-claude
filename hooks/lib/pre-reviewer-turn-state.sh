# Shared per-turn claim primitives for the Claude first-tool-call admission reviewer.
# Claude port of the Codex turn-state helpers. The capture-file helpers are not
# ported: the worker derives the admitted prompt from the transcript instead.
# shellcheck shell=bash

claude_hook_turn_id_json() {
  local input="${1:-}"

  # Input is a valid UTF-8 JSON object. A malformed raw-byte alias is outside
  # this shell helper's contract; valid U+FFFD remains an ordinary character.
  printf '%s' "$input" | jq -c \
    'if type != "object" then empty else (.turn_id? // null) as $turn_id
    | if (($turn_id | type) == "string"
        and ($turn_id | utf8bytelength) > 0
        and ($turn_id | utf8bytelength) <= 4096)
      then $turn_id
      else empty
      end end' \
    2>/dev/null || true
}

claude_turn_state_key() {
  local turn_id_json="$1"
  local key

  key="$(claude_hash_string "$turn_id_json" 2>/dev/null || true)"
  case "$key" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s\n' "$key"
}

claude_turn_claim_path() {
  printf '%s/claim-turn-%s\n' "$1" "$2"
}

claude_ensure_private_pre_reviewer_state_dir() {
  local state_dir="$1"
  local metadata owner

  if [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]; then
    (umask 077; mkdir -p -m 0700 -- "$state_dir") || return 1
  fi
  metadata="$(stat -c '%F|%u|%a' -- "$state_dir" 2>/dev/null)" || return 1
  owner="$(id -u)" || return 1
  [ "$metadata" = "directory|$owner|700" ]
}

claude_lock_pre_reviewer_turn() {
  local state_dir="$1"
  local timeout="${CLAUDE_PRE_REVIEWER_LOCK_TIMEOUT:-1}"
  local path_metadata descriptor_metadata owner expected_metadata

  [[ "$timeout" =~ ^(0+([.][0123456789]+)?|0*1([.]0+)?)$ ]] || timeout=1
  claude_ensure_private_pre_reviewer_state_dir "$state_dir" || return 1
  owner="$(id -u)" || return 1
  path_metadata="$(stat -c '%d:%i|%F|%u|%a' -- "$state_dir" 2>/dev/null)" || return 1
  expected_metadata="${path_metadata%%|*}|directory|$owner|700"
  [ "$path_metadata" = "$expected_metadata" ] || return 1
  exec {CLAUDE_TURN_LOCK_FD}<"$state_dir" || return 1
  descriptor_metadata="$(stat -Lc '%d:%i|%F|%u|%a' \
    -- "/proc/self/fd/$CLAUDE_TURN_LOCK_FD" 2>/dev/null)" || {
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
    return 1
  }
  if [ "$descriptor_metadata" != "$path_metadata" ]; then
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
    return 1
  fi
  if ! flock -x -w "$timeout" "$CLAUDE_TURN_LOCK_FD"; then
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
    return 1
  fi

  path_metadata="$(stat -c '%d:%i|%F|%u|%a' -- "$state_dir" 2>/dev/null)" || {
    flock -u "$CLAUDE_TURN_LOCK_FD" 2>/dev/null || true
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
    return 1
  }
  descriptor_metadata="$(stat -Lc '%d:%i|%F|%u|%a' \
    -- "/proc/self/fd/$CLAUDE_TURN_LOCK_FD" 2>/dev/null)" || {
    flock -u "$CLAUDE_TURN_LOCK_FD" 2>/dev/null || true
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
    return 1
  }
  owner="$(id -u)" || {
    flock -u "$CLAUDE_TURN_LOCK_FD" 2>/dev/null || true
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
    return 1
  }
  expected_metadata="${descriptor_metadata%%|*}|directory|$owner|700"
  if [ "$path_metadata" != "$descriptor_metadata" ] ||
      [ "$descriptor_metadata" != "$expected_metadata" ]; then
    flock -u "$CLAUDE_TURN_LOCK_FD" 2>/dev/null || true
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
    return 1
  fi
}

claude_unlock_pre_reviewer_turn() {
  if [ -n "${CLAUDE_TURN_LOCK_FD:-}" ]; then
    flock -u "$CLAUDE_TURN_LOCK_FD" 2>/dev/null || true
    exec {CLAUDE_TURN_LOCK_FD}>&-
    CLAUDE_TURN_LOCK_FD=""
  fi
}
