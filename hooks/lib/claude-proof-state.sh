#!/usr/bin/env bash
# Shared state helpers for Claude proof-adjacent hooks.
#
# Claude analog of ~/.codex/hooks/lib/codex-proof-state.sh: the two files share
# the same on-disk state-directory layout and helper API, but the Claude copy
# uses CLAUDE_* env vars and ~/.cache/claude-proof as the default root, and
# replaces the Codex transcript-shape subagent detection with a hook-input
# .agent_id check (see claude_hook_is_subagent_context below).

claude_proof_root() {
  printf '%s\n' "${CLAUDE_PROOF_ROOT:-$HOME/.cache/claude-proof}"
}

claude_valid_session_id() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

claude_canonical_cwd() {
  local cwd="${1:-$PWD}"
  if [ -d "$cwd" ]; then
    (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s\n' "$cwd"
  else
    printf '%s\n' "$cwd"
  fi
}

claude_cwd_key() {
  local cwd
  cwd="$(claude_canonical_cwd "${1:-$PWD}")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$cwd" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$cwd" | cksum | awk '{print $1}'
  fi
}

claude_session_state_dir() {
  local kind="$1"
  local session_id="$2"
  claude_valid_session_id "$session_id" || return 1
  printf '%s/%s/sessions/%s\n' "$(claude_proof_root)" "$kind" "$session_id"
}

claude_cwd_state_dir() {
  local kind="$1"
  local cwd="${2:-$PWD}"
  printf '%s/%s/cwd/%s\n' "$(claude_proof_root)" "$kind" "$(claude_cwd_key "$cwd")"
}

claude_ensure_cwd_state_dir() {
  local kind="$1"
  local cwd="${2:-$PWD}"
  local dir
  dir="$(claude_cwd_state_dir "$kind" "$cwd")" || return 1
  mkdir -p "$dir" || return 1
  claude_canonical_cwd "$cwd" >"$dir/cwd"
  printf '%s\n' "$dir"
}

claude_cli_state_dir() {
  local kind="$1"
  local create="${2:-false}"
  local dir

  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    dir="$(claude_session_state_dir "$kind" "$CLAUDE_SESSION_ID")" || return 1
    [ "$create" = "true" ] && mkdir -p "$dir"
    printf '%s\n' "$dir"
    return 0
  fi

  if [ "$create" = "true" ]; then
    claude_ensure_cwd_state_dir "$kind" "$PWD"
  else
    claude_cwd_state_dir "$kind" "$PWD"
  fi
}

claude_cli_state_file() {
  local kind="$1"
  local filename="$2"
  local create="${3:-false}"
  local dir
  dir="$(claude_cli_state_dir "$kind" "$create")" || return 1
  printf '%s/%s\n' "$dir" "$filename"
}

claude_existing_state_file() {
  local kind="$1"
  local filename="$2"
  local session_id="${3:-}"
  local cwd="${4:-}"
  local dir path

  if claude_valid_session_id "$session_id"; then
    dir="$(claude_session_state_dir "$kind" "$session_id")" || return 1
    path="$dir/$filename"
    [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
  fi

  if [ -n "$cwd" ]; then
    dir="$(claude_cwd_state_dir "$kind" "$cwd")" || return 1
    path="$dir/$filename"
    [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
  fi

  if claude_valid_session_id "$session_id"; then
    path="$(claude_proof_root)/$session_id/$filename"
    [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
  fi

  return 1
}

claude_state_session_id() {
  local file="$1"
  awk -F':[[:space:]]*' '$1 == "session_id" { print $2; exit }' "$file" 2>/dev/null
}

claude_note_state_session_id() {
  local file="$1"
  local session_id="$2"
  local existing

  claude_valid_session_id "$session_id" || return 0
  [ -f "$file" ] || return 0
  existing="$(claude_state_session_id "$file" || true)"
  [ -n "$existing" ] && return 0
  printf 'session_id: %s\n' "$session_id" >>"$file"
}

claude_mark_activity() {
  local session_id="$1"
  local cwd="$2"
  local marker_name="$3"
  local dir marker

  claude_valid_session_id "$session_id" || return 0
  case "$marker_name" in
    shell|edit|subagent) ;;
    *) return 0 ;;
  esac

  dir="$(claude_session_state_dir activity "$session_id")" || return 0
  mkdir -p "$dir" || return 0
  marker="$dir/$marker_name"
  {
    printf 'kind: %s\n' "$marker_name"
    [ -n "$cwd" ] && printf 'cwd: %s\n' "$cwd"
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$marker"
}

claude_state_value() {
  local file="$1"
  local key="$2"
  awk -F':[[:space:]]*' -v key="$key" '$1 == key { print $2; exit }' "$file" 2>/dev/null
}

claude_side_stop_applies_to_session() {
  local file="$1"
  local session_id="$2"
  local command parent_session_id

  [ -f "$file" ] || return 1
  command="$(claude_state_value "$file" command || true)"
  [ "$command" = "/side" ] || return 1

  parent_session_id="$(claude_state_value "$file" parent_session_id || true)"
  if claude_valid_session_id "$parent_session_id"; then
    [ "$parent_session_id" != "$session_id" ]
    return
  fi

  return 0
}

claude_state_file_is_session_scoped() {
  local kind="$1"
  local filename="$2"
  local session_id="$3"
  local file="$4"
  local expected

  expected="$(claude_session_state_dir "$kind" "$session_id" 2>/dev/null || true)"
  [ -n "$expected" ] && [ "$file" = "$expected/$filename" ]
}

claude_side_stop_is_active_for_session() {
  local file="$1"
  local session_id="$2"

  [ -n "$file" ] && [ -f "$file" ] || return 1
  claude_side_stop_applies_to_session "$file" "$session_id" || return 1

  if claude_state_file_is_session_scoped side-stop side_stop "$session_id" "$file"; then
    return 0
  fi

  [ -n "$(find "$file" -mmin -60 -print 2>/dev/null)" ]
}

claude_bind_side_stop_to_session() {
  local file="$1"
  local session_id="$2"
  local dir

  [ -f "$file" ] || return 1
  dir="$(claude_session_state_dir side-stop "$session_id")" || return 1
  mkdir -p "$dir" || return 1
  cp "$file" "$dir/side_stop"
}

# Subagent detection in Claude. Two real subagent shapes observed in live
# hook input (captured 2026-05-06):
#   1. Agent-tool inline spawn — input has .agent_id (UUID).
#   2. claude --agent-type top-level spawn — input has .agent_type
#      (e.g. "general-purpose"); NO .agent_id.
# Either signal identifies a subagent; both must be exempted from
# main-thread-only gates (stop-gate, eci-active-gate, ate-orchestrator-gate).
# DO NOT introduce transcript-shape detection: Codex's
# codex_hook_is_subagent_context parses ~/.codex/sessions/*.jsonl
# session_meta.payload.source.subagent.thread_spawn — a structure
# unique to the Codex transcript schema. Claude exposes these fields directly.
claude_hook_is_subagent_context() {
  local input="${1:-$(cat)}"
  local agent_id agent_type
  agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
  agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)
  [ -n "$agent_id" ] || [ -n "$agent_type" ]
}

claude_remove_session_state_file() {
  local kind="$1"
  local filename="$2"
  local session_id="$3"
  local dir
  dir="$(claude_session_state_dir "$kind" "$session_id")" || return 0
  rm -f "$dir/$filename"
}

claude_remove_cwd_state_file() {
  local kind="$1"
  local filename="$2"
  local cwd="${3:-$PWD}"
  local dir
  dir="$(claude_cwd_state_dir "$kind" "$cwd")" || return 0
  rm -f "$dir/$filename"
}

claude_markdown_section_has_body() {
  local file="$1"
  local target="$2"

  awk -v target="$target" '
    BEGIN { target = tolower(target) }
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]*/ {
      heading = $0
      sub(/^##[[:space:]]*/, "", heading)
      heading = tolower(trim(heading))
      if (in_section) exit
      if (heading == target) {
        in_section = 1
        next
      }
    }
    in_section {
      line = trim($0)
      if (line != "") found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

claude_eci_terminal_verdict_error() {
  local subject="$1"
  local file="$2"
  local counts accepted retired

  counts="$(awk '
    {
      line = tolower($0)
      scan = line
      while (match(scan, /(^|[^[:alnum:]_-])(clean-pass|user-closed):/)) {
        accepted++
        scan = substr(scan, RSTART + RLENGTH)
      }
      scan = line
      while (match(scan, /(^|[^[:alnum:]_-])hard-escalation:/)) {
        retired++
        scan = substr(scan, RSTART + RLENGTH)
      }
    }
    END { print accepted + 0, retired + 0 }
  ' "$file")"
  read -r accepted retired <<EOF
$counts
EOF

  if [ "${retired:-0}" -ne 0 ]; then
    printf '%s must include exactly one terminal verdict marker: clean-pass: or user-closed:, and must not include retired marker hard-escalation:. Report a blocker requiring user input while ECI remains active.\n' "$subject"
  elif [ "${accepted:-0}" -ne 1 ]; then
    printf '%s must include exactly one terminal verdict marker: clean-pass: or user-closed:.\n' "$subject"
  fi
}
