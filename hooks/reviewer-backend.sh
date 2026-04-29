#!/bin/bash
# Shared reviewer-backend selector. Sourced by both system-prompt-reviewer.sh
# and stop-gate.sh so the env-var parse lives in one place.
#
# Reads CLAUDE_STOP_REVIEWER and exports:
#   REVIEWER_BACKEND        — "ollama", "opencode-zen", "github-copilot", or "claude"
#   REVIEWER_OLLAMA_HOST    — only for ollama backend
#   REVIEWER_OLLAMA_MODEL   — only for ollama backend
#   REVIEWER_OPENCODE_HOST  — only for opencode-zen backend
#   REVIEWER_OPENCODE_MODEL — only for opencode-zen backend
#   REVIEWER_COPILOT_MODEL  — only for github-copilot backend (URL is fixed)
#
# Format:
#   unset / empty → no LLM reviewer; stop-gate falls back to the proof.md
#                   self-check protocol. The LLM reviewer is opt-in.
#   "claude"      → bare claude with apiKeyHelper (configured in settings.json)
#   "ollama:<URL>:<MODEL>"
#                 → URL is matched against `scheme://host[:port]`; everything
#                   after that is the model (which may itself contain ":",
#                   e.g. qwen3.5:9b-mxfp8). The simpler "split on last colon"
#                   approach can't tell a port boundary from a model boundary.
#   "opencode-zen:<URL>:<MODEL>"
#                 → URL parsed same way as ollama; calls /zen/v1/chat/completions on URL
#   "github-copilot:<MODEL>"
#                 → URL is fixed at https://api.githubcopilot.com/chat/completions
#                   (the public Copilot proxy for individual accounts). Bearer
#                   is fetched via the lib/copilot-token.sh helper using the
#                   PAT in ~/.config/github-copilot/apps.json. Enterprise hosts
#                   (api.{biz}.githubcopilot.com) NOT supported — open an issue
#                   if needed; trivial to layer on top.
#
# Supported URL forms: scheme://host[:port]
# NOT supported (would need parser changes):
#   - userinfo:    scheme://user:pw@host
#   - paths:       scheme://host/v1
#   - IPv6 hosts:  scheme://[::1]:port
#
# Returns 0 on success (including the empty-env case — REVIEWER_BACKEND
# is "" then), 1 on parse failure (malformed non-empty env var).

# Regex matching the leading XML tag of synthetic user-shape transcript
# entries that look like real user prompts but are NOT (Claude Code injects
# them for slash-command echoes, subagent completion notifications, etc.).
# Used by the turn-slicing filters in system-prompt-reviewer.sh and
# edit-bash-pre-reviewer.sh — single source so a new synthetic tag class
# only needs adding here.
# Pass into jq as `--arg synth_re "$SYNTHETIC_USER_TAG_RE"` and apply via
# `test($synth_re; "i")`. Match() would raise on no-match; test() returns bool.
SYNTHETIC_USER_TAG_RE='^[[:space:]]*<(task-notification|command-name|command-message|command-args|local-command-stdout|local-command-caveat|system-reminder)>'

parse_reviewer_env() {
  local raw="${CLAUDE_STOP_REVIEWER:-}"

  if [ -z "$raw" ]; then
    REVIEWER_BACKEND=""
    REVIEWER_OLLAMA_HOST=""
    REVIEWER_OLLAMA_MODEL=""
    REVIEWER_OPENCODE_HOST=""
    REVIEWER_OPENCODE_MODEL=""
    REVIEWER_COPILOT_MODEL=""
    return 0
  fi

  case "$raw" in
    claude)
      REVIEWER_BACKEND="claude"
      REVIEWER_OLLAMA_HOST=""
      REVIEWER_OLLAMA_MODEL=""
      REVIEWER_OPENCODE_HOST=""
      REVIEWER_OPENCODE_MODEL=""
      REVIEWER_COPILOT_MODEL=""
      return 0
      ;;
    ollama:*)
      local rest="${raw#ollama:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_OLLAMA_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OLLAMA_MODEL="${BASH_REMATCH[3]}"
        REVIEWER_BACKEND="ollama"
        REVIEWER_OPENCODE_HOST=""
        REVIEWER_OPENCODE_MODEL=""
        REVIEWER_COPILOT_MODEL=""
        return 0
      fi
      echo "reviewer-backend: malformed CLAUDE_STOP_REVIEWER='$raw' (expected 'ollama:scheme://host[:port][/]:MODEL')" >&2
      return 1
      ;;
    opencode-zen:*)
      local rest="${raw#opencode-zen:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_OPENCODE_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OPENCODE_MODEL="${BASH_REMATCH[3]}"
        REVIEWER_BACKEND="opencode-zen"
        REVIEWER_OLLAMA_HOST=""
        REVIEWER_OLLAMA_MODEL=""
        REVIEWER_COPILOT_MODEL=""
        return 0
      fi
      echo "reviewer-backend: malformed CLAUDE_STOP_REVIEWER='$raw' (expected 'opencode-zen:scheme://host[:port][/]:MODEL')" >&2
      return 1
      ;;
    github-copilot:*)
      local model="${raw#github-copilot:}"
      if [ -n "$model" ]; then
        REVIEWER_COPILOT_MODEL="$model"
        REVIEWER_BACKEND="github-copilot"
        REVIEWER_OLLAMA_HOST=""
        REVIEWER_OLLAMA_MODEL=""
        REVIEWER_OPENCODE_HOST=""
        REVIEWER_OPENCODE_MODEL=""
        return 0
      fi
      echo "reviewer-backend: malformed CLAUDE_STOP_REVIEWER='$raw' (expected 'github-copilot:MODEL')" >&2
      return 1
      ;;
    *)
      echo "reviewer-backend: unknown CLAUDE_STOP_REVIEWER='$raw' (expected 'claude', 'ollama:URL:MODEL', 'opencode-zen:URL:MODEL', or 'github-copilot:MODEL')" >&2
      return 1
      ;;
  esac
}
