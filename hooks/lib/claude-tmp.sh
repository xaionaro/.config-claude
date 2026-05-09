#!/usr/bin/env bash
# Hook scratch + error helpers. Two responsibilities:
#
# 1. claude_init_tmp — routes mktemp/scratch writes to $HOME/tmp/ so that
#    /tmp pressure (commonly tmpfs full) does not brick hooks. Per the
#    CLAUDE.md "Scratch storage" rule. Idempotent; safe to source-and-call
#    early in any hook.
#
# 2. claude_install_fail_open_trap — installs an ERR trap for hooks that
#    gate via `set -e` / `-o pipefail`. On any uncaught error (including
#    ENOSPC during mktemp/redirect, OOM tmpfs writes, jq stream failures),
#    the trap prints a stderr diagnostic and exits 0 (fail-open) so the
#    user's tool call is not silently denied by hook abort.
#
#    Caveat: the trap silences ALL errors, not only disk-pressure. The
#    tradeoff: an infrastructure failure must never wedge tool execution;
#    diagnostics surface on stderr instead of disappearing into a bare
#    non-zero exit.

claude_init_tmp() {
  local target="${CLAUDE_TMPDIR:-$HOME/tmp}"
  if mkdir -p "$target" 2>/dev/null && [ -w "$target" ]; then
    export TMPDIR="$target"
    return 0
  fi
  printf 'claude_init_tmp: %s unwritable; TMPDIR left as %s\n' \
    "$target" "${TMPDIR:-/tmp}" >&2
  return 1
}

# Internal: emit fail-open diagnostic. Called from the ERR trap installed
# by claude_install_fail_open_trap.
_claude_fail_open_emit() {
  local hook_name="$1" line="$2" exit_code="$3" cmd="$4"
  printf '%s: aborted line=%d exit=%d cmd=%q — failing open; check disk space (df -h /tmp $HOME/tmp)\n' \
    "$hook_name" "$line" "$exit_code" "$cmd" >&2
}

claude_install_fail_open_trap() {
  local name="${1:-${BASH_SOURCE[1]##*/}}"
  # Single-quoted trap body keeps $LINENO / $? / $BASH_COMMAND unexpanded
  # until trap-fire time. The hook name is interpolated at install time
  # via the embedded double-quoted segment.
  # shellcheck disable=SC2064
  trap '_claude_fail_open_emit "'"$name"'" "$LINENO" "$?" "$BASH_COMMAND"; exit 0' ERR
}
