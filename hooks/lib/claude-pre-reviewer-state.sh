# Pre-reviewer state and reviewer-call helpers for the Claude first-tool-call admission hook.
# Claude adaptation of the Codex lib functions the worker needs: codex-proof-state.sh
# (transcript admissibility, hashing), reviewer-backend.sh (backend parse) and
# reviewer-call.sh (ollama / opencode-zen chat call). Behaviour is copied; names use claude_.
# shellcheck shell=bash

: "${CLAUDE_EDIT_PRE_REVIEWER_TIMEOUT:=58}"

. "${BASH_SOURCE[0]%/*}/eci-diagnostic.sh"

claude_hash_string() {
  if command -v sha256sum >/dev/null 2>&1; then
    local digest
    digest="$(printf '%s' "${1:-}" | sha256sum)" || return 1
    printf '%s\n' "${digest%% *}"
  else
    printf '%s' "${1:-}" | /usr/bin/python3 -c \
      'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  fi
}

# Claude transcripts live under ~/.claude/projects; the root is lexical so a
# symlinked home does not silently change the admitted transcript scope.
claude_hook_projects_root() {
  local home="${HOME:-}" root

  [ -n "$home" ] || return 1
  root="$home/.claude/projects"
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$root" in
    *[![:print:]]*|*//*|*/./*|*/../*|*/..|*/.) return 1 ;;
  esac
  printf '%s\n' "$root"
}

claude_hook_transcript_first_record_is_admissible() {
  local input="${1:-}" projects_root
  projects_root="$(claude_hook_projects_root)" || return 1
  printf '%s' "$input" | \
    /usr/bin/python3 "${BASH_SOURCE[0]%/*}/bounded_hook_input.py" \
      hook-transcript-first-record "$projects_root" >/dev/null 2>&1
}

claude_pre_reviewer_reset_backend() {
  REVIEWER_BACKEND=""
  REVIEWER_OLLAMA_HOST=""
  REVIEWER_OLLAMA_MODEL=""
  REVIEWER_OPENCODE_HOST=""
  REVIEWER_OPENCODE_MODEL=""
}

claude_pre_reviewer_diagnostic() {
  local code="$1"
  local operation="$2"
  local subject="$3"
  local reason="$4"
  local remediation="$5"
  printf '%s\n' "$(eci_diagnostic_reason "$code" "Stop" "$operation" "$subject" "$reason" "$remediation")" >&2
}

# Parses the opt-in env value named by $1 into REVIEWER_* variables.
# Returns 0 for an empty value or a valid ollama/opencode-zen spec, 1 otherwise.
claude_parse_pre_reviewer_env() {
  local env_name="$1"
  local raw="${!env_name:-}"

  claude_pre_reviewer_reset_backend
  [ -z "$raw" ] && return 0

  case "$raw" in
    ollama:*)
      local rest="${raw#ollama:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_BACKEND="ollama"
        REVIEWER_OLLAMA_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OLLAMA_MODEL="${BASH_REMATCH[3]}"
        return 0
      fi
      local safe_raw
      safe_raw="$(eci_diagnostic_value "$raw")"
      claude_pre_reviewer_diagnostic \
        "ECI_REVIEWER_BACKEND_MALFORMED" \
        "external-review-config" \
        "env=$env_name,backend=ollama" \
        "reviewer-backend: malformed $env_name=$safe_raw (expected ollama:scheme://host[:port]:MODEL)" \
        "set $env_name to ollama:scheme://host[:port]:MODEL or leave it empty, then retry"
      return 1
      ;;
    opencode-zen:*)
      local rest="${raw#opencode-zen:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_BACKEND="opencode-zen"
        REVIEWER_OPENCODE_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OPENCODE_MODEL="${BASH_REMATCH[3]}"
        return 0
      fi
      local safe_raw
      safe_raw="$(eci_diagnostic_value "$raw")"
      claude_pre_reviewer_diagnostic \
        "ECI_REVIEWER_BACKEND_MALFORMED" \
        "external-review-config" \
        "env=$env_name,backend=opencode-zen" \
        "reviewer-backend: malformed $env_name=$safe_raw (expected opencode-zen:scheme://host[:port]:MODEL)" \
        "set $env_name to opencode-zen:scheme://host[:port]:MODEL or leave it empty, then retry"
      return 1
      ;;
    *)
      local safe_raw safe_backend
      safe_raw="$(eci_diagnostic_value "$raw")"
      safe_backend="$(eci_diagnostic_value "${raw%%:*}")"
      claude_pre_reviewer_diagnostic \
        "ECI_REVIEWER_BACKEND_UNSUPPORTED" \
        "external-review-config" \
        "env=$env_name,backend=$safe_backend" \
        "reviewer-backend: unknown $env_name=$safe_raw (review skipped; allowed: ollama:URL:MODEL, opencode-zen:URL:MODEL)" \
        "use ollama:URL:MODEL or opencode-zen:URL:MODEL, or leave reviewer configuration empty"
      return 1
      ;;
  esac
}

claude_pre_reviewer_strip_fences() {
  sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d; /^[[:space:]]*```[[:space:]]*$/d'
}

claude_pre_reviewer_run_with_timeout() {
  local timeout_secs="$1"
  shift
  if timeout --version 2>&1 | grep -Fq 'GNU coreutils'; then
    timeout --signal=TERM --kill-after=1s "${timeout_secs}s" "$@"
  elif command -v busybox >/dev/null 2>&1; then
    busybox timeout -s TERM -k 1 "$timeout_secs" "$@"
  else
    return 1
  fi
}

claude_pre_reviewer_tmp_root() {
  local root="${TMPDIR:-${HOME:?HOME must be set}/tmp}" canonical
  canonical="$(realpath -m -- "$root" 2>/dev/null || true)"
  if [ "$canonical" = /tmp ] || [[ "$canonical" == /tmp/* ]]; then
    root="${HOME:?HOME must be set}/tmp"
  fi
  mkdir -p -- "$root" 2>/dev/null || return 1
  printf '%s\n' "$root"
}

claude_pre_reviewer_ollama_options() {
  local seed="${1:-42}"
  jq -n --argjson seed "$seed" '{
    temperature: 0.3,
    top_k: 40,
    top_p: 0.9,
    seed: $seed,
    num_ctx: 32768,
    num_predict: 2048,
    repeat_penalty: 1.0
  }'
}

_claude_pre_reviewer_call_impl() {
  local kind="$1"
  local sys_file="$2"
  local usr_file="$3"
  local schema_file="$4"
  local timeout_secs="$5"
  local curl_timeout_secs="$6"
  local raw response http_code body send_path

  send_path=""
  trap '[ -z "$send_path" ] || rm -f -- "$send_path"' EXIT HUP INT TERM

  case "$REVIEWER_BACKEND" in
    ollama)
      send_path=$(mktemp "$(claude_pre_reviewer_tmp_root)/claude-reviewer-call.XXXXXX") || return 1
      jq -n \
        --arg model "$REVIEWER_OLLAMA_MODEL" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        --argjson schema "$(cat "$schema_file")" \
        --argjson options "$(claude_pre_reviewer_ollama_options 42)" \
        '{model:$model,stream:false,think:false,format:$schema,options:$options,
          messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' >"$send_path"
      response=$(claude_pre_reviewer_run_with_timeout "$curl_timeout_secs" \
        curl -s --max-time "$curl_timeout_secs" \
        -X POST "$REVIEWER_OLLAMA_HOST/api/chat" \
        -H 'Content-Type: application/json' \
        --data-binary "@$send_path" \
        -w '\n%{http_code}' 2>/dev/null)
      local exit_call=$?
      rm -f -- "$send_path"
      send_path=""
      [ "$exit_call" -eq 0 ] || return 1
      http_code=$(printf '%s' "$response" | tail -n1)
      body=$(printf '%s' "$response" | sed '$d')
      case "$http_code" in 2*) ;; *) return 1 ;; esac
      raw=$(printf '%s' "$body" | jq -r '.message.content // empty' 2>/dev/null)
      ;;
    opencode-zen)
      send_path=$(mktemp "$(claude_pre_reviewer_tmp_root)/claude-reviewer-call.XXXXXX") || return 1
      jq -n \
        --arg model "$REVIEWER_OPENCODE_MODEL" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        --argjson schema "$(cat "$schema_file")" \
        --arg name "${kind}_verdict" \
        '{model:$model,stream:false,max_tokens:8192,max_completion_tokens:8192,
          temperature:0.3,top_p:0.9,seed:42,
          response_format:{type:"json_schema",json_schema:{name:$name,schema:$schema,strict:false}},
          messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' >"$send_path"
      response=$(claude_pre_reviewer_run_with_timeout "$curl_timeout_secs" \
        curl -s --max-time "$curl_timeout_secs" \
        -X POST "$REVIEWER_OPENCODE_HOST/zen/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        --data-binary "@$send_path" \
        -w '\n%{http_code}' 2>/dev/null)
      local exit_call=$?
      rm -f -- "$send_path"
      send_path=""
      [ "$exit_call" -eq 0 ] || return 1
      http_code=$(printf '%s' "$response" | tail -n1)
      body=$(printf '%s' "$response" | sed '$d')
      case "$http_code" in 2*) ;; *) return 1 ;; esac
      raw=$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
      ;;
    *)
      return 1
      ;;
  esac

  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | claude_pre_reviewer_strip_fences
}

claude_pre_reviewer_call_chat() {
  local kind="$1"
  local sys_file="$2"
  local usr_file="$3"
  local schema_file="$4"
  local timeout_secs="$5"
  local curl_timeout_secs
  local outer_term_secs
  local library

  case "$timeout_secs" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$timeout_secs" -ge 3 ] || return 1
  curl_timeout_secs=$((timeout_secs - 2))
  outer_term_secs=$((timeout_secs - 1))
  library="${BASH_SOURCE[0]}"

  REVIEWER_BACKEND="${REVIEWER_BACKEND:-}" \
  REVIEWER_OLLAMA_MODEL="${REVIEWER_OLLAMA_MODEL:-}" \
  REVIEWER_OLLAMA_HOST="${REVIEWER_OLLAMA_HOST:-}" \
  REVIEWER_OPENCODE_MODEL="${REVIEWER_OPENCODE_MODEL:-}" \
  REVIEWER_OPENCODE_HOST="${REVIEWER_OPENCODE_HOST:-}" \
    claude_pre_reviewer_run_with_timeout "$outer_term_secs" \
      bash -c 'source "$1"; _claude_pre_reviewer_call_impl "${@:2}"' \
      pre-reviewer-call "$library" "$kind" "$sys_file" "$usr_file" \
      "$schema_file" "$timeout_secs" "$curl_timeout_secs"
}
