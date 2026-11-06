#!/usr/bin/env bash
# ECI review-gate helpers for hooks/eci-review-gate.sh (Claude port).
#
# Ported from ~/.codex/hooks/lib/codex-proof-state.sh: Codex functions that have
# no Claude equivalent, renamed codex_* -> claude_* with logic copied verbatim.
# Each block notes its Codex source lines. Existing Claude helpers are reused,
# not ported:
#   codex_proof_root_is_safe -> claude_proof_root_is_safe   (claude-eci-control.sh)
#   codex_proof_root         -> claude_resolved_proof_root  (claude-eci-control.sh)
#   codex_reserved_proof_dir -> claude_reserved_proof_dir   (claude-eci-control.sh)
#   codex_valid_session_id   -> claude_valid_session_id     (claude-proof-state.sh)
#   codex_canonical_cwd      -> claude_canonical_cwd        (claude-proof-state.sh)
# codex_proof_root (canonical) maps to claude_resolved_proof_root, not
# claude_proof_root (configured, unresolved). CODEX_STOP_GATE_ROOT has no
# Claude analog and is not ported.

. "${BASH_SOURCE[0]%/*}/claude-eci-control.sh"

# Codex: codex_eci_marker_max_bytes
claude_eci_marker_max_bytes=4096

# Codex: codex_eci_marker_file_is_bounded
claude_eci_marker_file_is_bounded() {
  local marker="$1" prefix="" old_lc="" had_lc=0 within=false
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  # Read one byte beyond the finite cap with a Bash builtin so the active
  # Stop path does not spawn wc for every callback.  The metadata validator
  # still performs the complete bounded line/schema check afterwards.
  if [ "${LC_ALL+x}" = x ]; then
    had_lc=1
    old_lc="$LC_ALL"
  fi
  export LC_ALL=C
  IFS= read -r -N "$((claude_eci_marker_max_bytes + 1))" prefix <"$marker" || true
  [ "${#prefix}" -le "$claude_eci_marker_max_bytes" ] && within=true
  if [ "$had_lc" -eq 1 ]; then
    export LC_ALL="$old_lc"
  else
    unset LC_ALL
  fi
  [ "$within" = true ]
}

# Codex: codex_session_dir_is_safe
claude_session_dir_is_safe() {
  local root="$1"
  local session_id="$2"
  local dir

  claude_valid_session_id "$session_id" || return 1
  [ "$root" = "$(claude_resolved_proof_root)" ] || return 1
  claude_proof_root_is_safe || return 1
  dir="$root/$session_id"
  [ ! -L "$dir" ] || return 1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] || return 1
  fi
  return 0
}

# Codex: codex_state_file_owner_is_valid
claude_state_file_owner_is_valid() {
  local file="$1" require_unique="${2:-true}" owner links expected
  case "$require_unique" in
    true|false) ;;
    *) return 1 ;;
  esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  expected="${EUID:-$(id -u 2>/dev/null || printf '%s' -1)}"
  read -r owner links < <(stat -Lc '%u %h' -- "$file" 2>/dev/null) || return 1
  [ "$owner" = "$expected" ] && { [ "$require_unique" = false ] || [ "$links" = 1 ]; }
}

# Codex: codex_eci_aggregate_repo_id_is_valid
# Aggregate repository IDs are path-component-safe selectors.  The plan, not
# a command-line path, maps one such ID to its canonical Git worktree.
claude_eci_aggregate_repo_id_is_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]
}

# Codex: codex_eci_marker_metadata_is_valid
# Parse the four-line active marker with shell builtins.  Stop callbacks use
# this bounded record check; avoid grep/awk/sed process fan-out on every active
# callback while retaining the same path, owner, cwd, and control-byte rules.
claude_eci_marker_metadata_is_valid() {
  local marker="$1" expected_cwd="${2:-}" root root_real marker_real dir name marker_cwd marker_owner marker_scope
  local -a lines=()

  claude_proof_root_is_safe || return 1
  root="$(claude_resolved_proof_root)"
  [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || return 1
  root_real="$(realpath -e -- "$root" 2>/dev/null || true)"
  [ -n "$root_real" ] && [ -d "$root_real" ] || return 1
  [ ! -L "$marker" ] || return 1
  marker_real="$(realpath -e -- "$marker" 2>/dev/null || true)"
  [ -n "$marker_real" ] || return 1
  root="$root_real"
  marker="$marker_real"
  case "$marker" in
    "$root"/*/eci_active) ;;
    *) return 1 ;;
  esac
  # Every reader must enforce the same finite record bound before mapfile or
  # any other line-oriented parser touches the marker.  This is deliberately
  # a cheap stat/read probe and is shared by Stop, lifecycle, discovery, and
  # refresh hooks.
  claude_eci_marker_file_is_bounded "$marker" || return 1
  claude_state_file_owner_is_valid "$marker" false || return 1
  [ "$(tail -c 1 -- "$marker" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  dir="${marker%/*}"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  name="${dir##*/}"
  if ! claude_reserved_proof_dir "$name"; then
    claude_valid_session_id "$name" || return 1
  fi
  mapfile -t lines <"$marker" || return 1
  case "${#lines[@]}" in 3|4) ;; *) return 1 ;; esac
  for line in "${lines[@]}"; do
    [[ "$line" != *[[:cntrl:]]* ]] || return 1
  done
  case "${lines[0]}" in "scope: "*) ;; *) return 1 ;; esac
  case "${lines[1]}" in "cwd: "*) ;; *) return 1 ;; esac
  case "${lines[2]}" in "session_id: "*) ;; *) return 1 ;; esac
  if [ "${#lines[@]}" -eq 4 ]; then
    case "${lines[3]}" in "created_utc: "*) ;; *) return 1 ;; esac
  fi
  marker_cwd="${lines[1]#cwd: }"
  marker_owner="${lines[2]#session_id: }"
  marker_scope="${lines[0]#scope: }"
  [ -n "$marker_scope" ] && [ -n "$marker_cwd" ] && [ "$marker_owner" = "$name" ] || return 1
  case "$marker_cwd" in /*) ;; *) return 1 ;; esac
  if [ -n "$expected_cwd" ]; then
    [ "$(claude_canonical_cwd "$marker_cwd")" = "$expected_cwd" ] || return 1
  fi
}

# Codex: codex_eci_marker_path_owner_is_valid
# Validate the ownership encoded by a marker path without applying cwd
# ownership.  Discovery uses this before deciding whether a marker belongs to
# the current callback; a path/record mismatch is unsafe control state, not an
# inactive marker.
claude_eci_marker_path_owner_is_valid() {
  claude_eci_marker_metadata_is_valid "$1"
}

# Codex: codex_eci_marker_is_valid_for_cwd
# Return only ECI markers whose path owner and embedded session_id agree.  The
# ordinary direct-session marker and the reserved legacy marker namespace are
# checked together so callers can detect duplicate active owners instead of
# returning on the first glob match.  This helper is intentionally bounded to
# one proof-root directory scan and marker metadata; it is not used for
# transcript or ledger recovery.
claude_eci_marker_is_valid_for_cwd() {
  claude_eci_marker_metadata_is_valid "$1" "$2"
}
