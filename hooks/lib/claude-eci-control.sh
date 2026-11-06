#!/usr/bin/env bash
# ECI control-path predicates for the Claude PreToolUse gate (eci-active-gate.sh).
#
# Port of the path closure used by ~/.codex/hooks/eci-active-gate.sh, with
# codex_* renamed to claude_*. Codex-only pieces are dropped: CODEX_* env,
# .codex-proof-alias directories, ~/.codex/sessions owner lookup, eci
# accidental-override records, and the stop-gate root cache.
#
# Marker trust: Claude eci_active markers carry no session_id/cwd fields
# (they hold "task:"/"engaged:" lines), so a marker is trusted by location
# alone: a regular, non-symlink <root>/<session>/eci_active in a safe root.

. "${BASH_SOURCE[0]%/*}/claude-proof-state.sh"

# Canonical proof root (ancestor symlinks resolved). claude_proof_root gives
# the configured value (CLAUDE_PROOF_ROOT or $HOME/.cache/claude-proof).
claude_resolved_proof_root() {
  local configured canonical

  configured="$(claude_proof_root)"
  if [ -d "$configured" ] && [ ! -L "$configured" ]; then
    canonical="$(cd -- "$configured" 2>/dev/null && pwd -P || true)"
    printf '%s\n' "${canonical:-$configured}"
  elif command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$configured" 2>/dev/null || printf '%s\n' "$configured"
  else
    printf '%s\n' "$configured"
  fi
}

claude_proof_root_is_safe() {
  local configured root parent

  configured="$(claude_proof_root)"
  while [ "$configured" != "/" ] && [ "${configured%/}" != "$configured" ]; do
    configured="${configured%/}"
  done
  case "$configured" in
    /*) ;;
    *) return 1 ;;
  esac
  root="$(claude_resolved_proof_root)"
  case "$root" in
    ""|*[![:print:]]*) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$configured" ] || return 1
  case "$root" in
    */*) parent="${root%/*}"; [ -n "$parent" ] || parent="/" ;;
    *) parent="." ;;
  esac
  [ ! -L "$root" ] || return 1
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] || return 1
  fi
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] || return 1
  fi
  return 0
}

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

claude_reserved_proof_dir() {
  case "${1:-}" in
    activity|audit|eci|history|pre-reviewer|reviewer|reviewer-dumps|security-warnings-*|side-stop|skip-stop|skills)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Reserved ECI control and ledger basenames. Must match the Codex list in
# ~/.codex/hooks/lib/codex-proof-state.sh codex_eci_control_basename exactly.
claude_eci_control_basename() {
  case "${1:-}" in
    eci-wait-repair-authorize|eci-wait-repair-authorize.*|eci_active|eci_active.*|goal_state|goal_state.*|eci_wait|eci_wait.*|eci_user_owned_wait.md|eci_user_owned_wait.md.*|eci-coordinator-edit|eci-coordinator-edit.*|eci-additional-repository|eci-additional-repository.*|eci-permissive-mode|eci-permissive-mode.*|eci-permissive-authorize|eci-permissive-authorize.*|.eci-permissive-mode|.eci-permissive-mode.*|.eci-permissive-authorize|.eci-permissive-authorize.*|eci-required-critics.json|eci-required-critics.json.*|eci-required-critics.*|eci-critic-identities.ledger|eci-critic-identities.ledger.*|eci-acceptance-anchor|eci-acceptance-anchor.*|eci-acceptance-transaction|eci-acceptance-transaction.*|eci-teardown-complete|eci-teardown-complete.*|eci-prewrite-admitted.*|eci-baseline-binding|eci-baseline-binding.*|baseline_head|baseline_head.*|eci-commit-admitted|eci-commit-admitted.*|eci-user-closed.ledger|eci-user-closed.ledger.*|eci-aggregate-plan.json|eci-aggregate-plan.json.*|eci-aggregate-teardown-complete|eci-aggregate-teardown-complete.*|eci-aggregate.*|eci-accidental-mistake-override|eci-accidental-mistake-override.*|.eci-accidental-mistake-override|.eci-accidental-mistake-override.*|.eci-accidental-mistake-override.claim|ate_nested_eci_active|ate_nested_eci_active.*|ate_nested_eci_completion|ate_nested_eci_completion.*|eci-blocker-report.md|stop_timestamps|stop_loop_state|stop_loop_state.*|disengage.md|user-closed.md|proof.md|instructions.md|project-understanding.yaml|project-understanding.yaml.*|high_level_log.jsonl|high_level_log.jsonl.*|high_level_log.anchor|high_level_log.anchor.*|high_level_log.jsonl.tmp.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Marker check by location only (see header). Returns 0 when the path is the
# active marker of a valid session directory in the safe canonical root.
claude_eci_marker_is_active() {
  local marker="$1" session_id="$2" root

  claude_valid_session_id "$session_id" || return 1
  claude_proof_root_is_safe || return 1
  root="$(claude_resolved_proof_root)"
  claude_session_dir_is_safe "$root" "$session_id" || return 1
  [ "$marker" = "$root/$session_id/eci_active" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(realpath -e -- "$marker" 2>/dev/null || true)" = "$marker" ] || return 1
}

# A shared edit target can alias a live coordinator control. Single-link
# files cannot, so ordinary edits do not scan the proof root. Compare shared
# targets only against control files in active session directories.
claude_path_is_eci_control_alias() {
  local path="${1:-}" root marker candidate session links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  links="$(stat -Lc '%h' -- "$path" 2>/dev/null || true)"
  [[ "$links" =~ ^[0-9]+$ ]] && [ "$links" -gt 1 ] || return 1
  root="$(claude_resolved_proof_root)"
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  for marker in "$root"/*/eci_active; do
    session="${marker%/*}"
    session="${session##*/}"
    claude_eci_marker_is_active "$marker" "$session" || continue
    for candidate in "${marker%/*}"/* "${marker%/*}"/.eci-*; do
      claude_eci_control_basename "${candidate##*/}" || continue
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      [ "$candidate" -ef "$path" ] && return 0
    done
  done
  return 1
}

# True when path names a control or ledger file (or a reserved proof dir
# descendant) under a proof root. Name- and location-based; does not require
# the target or any marker to exist.
claude_path_is_eci_control_file() {
  local path="${1:-}"
  local actual_root default_root root rest sid filename

  [ -n "$path" ] || return 1
  filename="${path##*/}"

  actual_root="$(claude_resolve_hook_path "$PWD" "$(claude_resolved_proof_root)" 2>/dev/null || claude_resolved_proof_root)"
  default_root="$(claude_resolve_hook_path "$PWD" "${HOME:-}/.cache/claude-proof" 2>/dev/null || printf '%s\n' "${HOME:-}/.cache/claude-proof")"
  for root in "$actual_root" "$default_root"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rest="${path#"$root"/}"
        sid="${rest%%/*}"
        [ "$rest" != "$sid" ] || continue
        # Claim directories are coordinator-owned recursively, including their
        # descendants (Codex parity: codex_path_is_eci_control_file).
        case "$rest" in
          */.eci-accidental-mistake-override.claim|*/.eci-accidental-mistake-override.claim/*|*/eci-wait-repair-authorize.claim|*/eci-wait-repair-authorize.claim/*)
            claude_valid_session_id "$sid" && return 0
            continue
            ;;
        esac
        # Reserved namespaces are coordinator-owned recursively; check before
        # the one-level session-control check so descendants are covered too.
        claude_reserved_proof_dir "$sid" && return 0
        [ "${rest#*/}" = "$filename" ] || continue
        claude_eci_control_basename "$filename" || continue
        claude_valid_session_id "$sid" || continue
        return 0
        ;;
    esac
  done
  return 1
}

claude_lexical_hook_path() {
  local cwd="${1:-$PWD}"
  local path="${2:-}"

  [ -n "$path" ] || return 1
  [ -n "$cwd" ] || cwd="$PWD"
  case "$path" in
    "~") path="${HOME:-}" ;;
    "~/"*) path="${HOME:-}/${path#~/}" ;;
  esac
  local lexical_path
  if command -v realpath >/dev/null 2>&1 &&
     lexical_path="$(realpath -ms -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$lexical_path"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$cwd" "$path" <<'PY'
import os
import sys
cwd, path = sys.argv[1:3]
if not os.path.isabs(path):
    path = os.path.join(cwd, path)
print(os.path.normpath(os.path.abspath(path)))
PY
  else
    case "$path" in
      /*) printf '%s\n' "$path" ;;
      *) printf '%s\n' "$cwd/$path" ;;
    esac
  fi
}

claude_resolve_hook_path() {
  local cwd="${1:-$PWD}"
  local path="${2:-}"

  [ -n "$path" ] || return 1
  [ -n "$cwd" ] || cwd="$PWD"
  case "$path" in
    "~") path="${HOME:-}" ;;
    "~/"*) path="${HOME:-}/${path#~/}" ;;
  esac
  case "$path" in
    /*) ;;
    *) path="$cwd/$path" ;;
  esac

  realpath -m -- "$path" 2>/dev/null || printf '%s\n' "$path"
}

# Session id owning a path under a proof root (the first component below the
# root). Fails for reserved namespaces and for non-session components.
claude_path_owner_session_id() {
  local path="$1"
  local root default_root rest sid

  [ -n "$path" ] || return 1

  root="$(claude_resolved_proof_root)"
  default_root="${HOME:-}/.cache/claude-proof"
  for root in "$root" "$default_root"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rest="${path#"$root"/}"
        sid="${rest%%/*}"
        claude_reserved_proof_dir "$sid" && return 1
        claude_valid_session_id "$sid" || return 1
        printf '%s\n' "$sid"
        return 0
        ;;
    esac
  done

  return 1
}
