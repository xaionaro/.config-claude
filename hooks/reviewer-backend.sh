#!/bin/bash
# Shared reviewer-backend selector. Sourced by both system-prompt-reviewer.sh
# and stop-gate.sh so the env-var parse lives in one place.
#
# Reads CLAUDE_STOP_REVIEWER and exports:
#   REVIEWER_BACKEND        — "ollama", "opencode-zen", or "claude"
#   REVIEWER_OLLAMA_HOST    — only for ollama backend
#   REVIEWER_OLLAMA_MODEL   — only for ollama backend
#   REVIEWER_OPENCODE_HOST  — only for opencode-zen backend
#   REVIEWER_OPENCODE_MODEL — only for opencode-zen backend
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
#
# Supported URL forms: scheme://host[:port]
# NOT supported (would need parser changes):
#   - userinfo:    scheme://user:pw@host
#   - paths:       scheme://host/v1
#   - IPv6 hosts:  scheme://[::1]:port
#
# Returns 0 on success (including the empty-env case — REVIEWER_BACKEND
# is "" then), 1 on parse failure (malformed non-empty env var).

parse_reviewer_env() {
  local raw="${CLAUDE_STOP_REVIEWER:-}"

  if [ -z "$raw" ]; then
    REVIEWER_BACKEND=""
    REVIEWER_OLLAMA_HOST=""
    REVIEWER_OLLAMA_MODEL=""
    REVIEWER_OPENCODE_HOST=""
    REVIEWER_OPENCODE_MODEL=""
    return 0
  fi

  case "$raw" in
    claude)
      REVIEWER_BACKEND="claude"
      REVIEWER_OLLAMA_HOST=""
      REVIEWER_OLLAMA_MODEL=""
      REVIEWER_OPENCODE_HOST=""
      REVIEWER_OPENCODE_MODEL=""
      return 0
      ;;
    ollama:*)
      # Parse URL pattern explicitly: scheme://host(:port)?, then model is
      # everything after the next ":". Cannot use last-colon split because
      # model names often contain colons (e.g. qwen3.5:9b-mxfp8).
      local rest="${raw#ollama:}"
      # Allow an optional trailing "/" between the URL and the model
      # boundary ":" — a common copy-paste shape where the URL is given
      # as `http://host:port/`. The slash is consumed but NOT included
      # in the captured host (Ollama expects clean URL with no path).
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_OLLAMA_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OLLAMA_MODEL="${BASH_REMATCH[3]}"
        REVIEWER_BACKEND="ollama"
        REVIEWER_OPENCODE_HOST=""
        REVIEWER_OPENCODE_MODEL=""
        return 0
      fi
      echo "reviewer-backend: malformed CLAUDE_STOP_REVIEWER='$raw' (expected 'ollama:scheme://host[:port][/]:MODEL')" >&2
      return 1
      ;;
    opencode-zen:*)
      # Same URL-shape parser as ollama; model is everything after the
      # boundary ":" and may itself contain colons.
      local rest="${raw#opencode-zen:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_OPENCODE_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OPENCODE_MODEL="${BASH_REMATCH[3]}"
        REVIEWER_BACKEND="opencode-zen"
        REVIEWER_OLLAMA_HOST=""
        REVIEWER_OLLAMA_MODEL=""
        return 0
      fi
      echo "reviewer-backend: malformed CLAUDE_STOP_REVIEWER='$raw' (expected 'opencode-zen:scheme://host[:port][/]:MODEL')" >&2
      return 1
      ;;
    *)
      echo "reviewer-backend: unknown CLAUDE_STOP_REVIEWER='$raw' (expected 'claude', 'ollama:URL:MODEL', or 'opencode-zen:URL:MODEL')" >&2
      return 1
      ;;
  esac
}
