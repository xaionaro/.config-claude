#!/bin/bash
# Shared helpers sourced by multiple hooks. Source once at top of each hook:
#   . "$(dirname "$0")/lib/common.sh"     # from hooks/ root
#   . "$HOOK_DIR/lib/common.sh"           # when HOOK_DIR is already set
#
# This file provides ONLY:
#   (a) path constants (no side effects when SESSION_ID is set)
#   (b) lightweight validation helpers
#
# Stdin consumption (INPUT=$(cat)) is intentionally NOT here — each hook
# reads stdin at most once; a shared consumer would require careful
# ordering and is better kept local to each hook.

# Return silently if SESSION_ID is not yet set; callers must set it first.
[ -z "${SESSION_ID:-}" ] && return 0

# ---- Path constants -------------------------------------------------------
PROOF_DIR="${PROOF_DIR:-$HOME/.cache/claude-proof/$SESSION_ID}"
REVIEWER_STATE_DIR="${REVIEWER_STATE_DIR:-$HOME/.cache/claude-proof/reviewer/$SESSION_ID}"
REVIEWER_BYPASS="${REVIEWER_BYPASS:-$REVIEWER_STATE_DIR/bypass}"
REVIEWER_DUMPS_DIR="${REVIEWER_DUMPS_DIR:-$HOME/.cache/claude-proof/reviewer-dumps/$SESSION_ID}"

# ---- Session-ID safety check ----------------------------------------------
# Reject session IDs that could cause path traversal or log injection.
# Usage: validate_session_id || exit 0
validate_session_id() {
  case "${SESSION_ID:-}" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}
