# Shellcheck-friendly library: no-credential reviewer call defaults/helpers.
# shellcheck shell=bash

: "${CLAUDE_STOP_REVIEWER_TIMEOUT:=240}"
: "${CLAUDE_EDIT_PRE_REVIEWER_TIMEOUT:=58}"

# Claude-only: the model/host/token defaults below have no Codex counterpart.
# hooks/tests/reviewer/run.sh and run-opencode.sh read them under set -u.
#
# Usage (sourced):
#   . "$HOME/.claude/hooks/lib/reviewer-call.sh"
#   echo "$REVIEWER_DEFAULT_MODEL"   # qwen3.5:9b-mxfp8
#   echo "$REVIEWER_DEFAULT_HOST"    # http://192.168.0.171:11434
#   reviewer_ollama_options 42       # JSON object with seed=42
#
# Notes:
#   - Production hook may still derive MODEL/HOST from the
#     CLAUDE_STOP_REVIEWER env (parsed by reviewer-backend.sh); these
#     values are the fallback / test-harness defaults.
#   - Options must stay in sync with system-prompt-reviewer.sh request
#     body. Drift = irreproducible test results.

REVIEWER_DEFAULT_MODEL="qwen3.5:9b-mxfp8"
REVIEWER_DEFAULT_HOST="http://192.168.0.171:11434"

# Output token budget. Ollama uses num_predict (set in reviewer_ollama_options)
# at 2048 historically. OpenAI-compat backends use this larger value because
# reasoning-heavy free models on opencode-zen (notably big-pickle and
# minimax-m2.5-free) spend 100-200 tokens on hidden chain-of-thought before
# any content emission. Verified empirically: at 4096 they emit empty content
# (finish_reason=length); at 8192 they emit valid json_schema-conformant
# verdicts. nemotron-3-super-free works at either budget; the larger value
# covers all three reasoning-capable free models without per-model dispatch.
REVIEWER_DEFAULT_MAX_TOKENS=8192

# reviewer_ollama_options <seed>
# Emit the Ollama options JSON for a single call. Seed is a parameter so
# the harness can vary it across runs while production keeps a fixed seed.
reviewer_ollama_options() {
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

reviewer_strip_fences() {
  sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d; /^[[:space:]]*```[[:space:]]*$/d'
}

reviewer_run_with_timeout() {
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

reviewer_tmp_root() {
  local root="${TMPDIR:-${HOME:?HOME must be set}/tmp}" canonical
  canonical="$(realpath -m -- "$root" 2>/dev/null || true)"
  if [ "$canonical" = /tmp ] || [[ "$canonical" == /tmp/* ]]; then
    root="${HOME:?HOME must be set}/tmp"
  fi
  mkdir -p -- "$root" 2>/dev/null || return 1
  printf '%s\n' "$root"
}

_reviewer_call_chat_impl() {
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
      send_path=$(mktemp "$(reviewer_tmp_root)/claude-reviewer-call.XXXXXX") || return 1
      jq -n \
        --arg model "$REVIEWER_OLLAMA_MODEL" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        --argjson schema "$(cat "$schema_file")" \
        --argjson options "$(reviewer_ollama_options 42)" \
        '{model:$model,stream:false,think:false,format:$schema,options:$options,
          messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' >"$send_path"
      response=$(reviewer_run_with_timeout "$curl_timeout_secs" \
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
      send_path=$(mktemp "$(reviewer_tmp_root)/claude-reviewer-call.XXXXXX") || return 1
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
      response=$(reviewer_run_with_timeout "$curl_timeout_secs" \
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
  printf '%s' "$raw" | reviewer_strip_fences
}

reviewer_call_chat() {
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
    reviewer_run_with_timeout "$outer_term_secs" \
      bash -c 'source "$1"; _reviewer_call_chat_impl "${@:2}"' \
      reviewer-call "$library" "$kind" "$sys_file" "$usr_file" \
      "$schema_file" "$timeout_secs" "$curl_timeout_secs"
}
