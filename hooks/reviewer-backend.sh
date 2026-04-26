#!/bin/bash
# Shared reviewer-backend selector. Sourced by both system-prompt-reviewer.sh
# and stop-gate.sh so the env-var parse lives in one place.
#
# Reads CLAUDE_STOP_REVIEWER and exports:
#   REVIEWER_BACKEND        — "ollama" or "claude"
#   REVIEWER_OLLAMA_HOST    — only for ollama backend
#   REVIEWER_OLLAMA_MODEL   — only for ollama backend
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
    return 0
  fi

  case "$raw" in
    claude)
      REVIEWER_BACKEND="claude"
      REVIEWER_OLLAMA_HOST=""
      REVIEWER_OLLAMA_MODEL=""
      return 0
      ;;
    ollama:*)
      # Parse URL pattern explicitly: scheme://host(:port)?, then model is
      # everything after the next ":". Cannot use last-colon split because
      # model names often contain colons (e.g. qwen3.5:9b-mxfp8).
      local rest="${raw#ollama:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?):(.+)$ ]]; then
        REVIEWER_OLLAMA_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OLLAMA_MODEL="${BASH_REMATCH[3]}"
        REVIEWER_BACKEND="ollama"
        return 0
      fi
      echo "reviewer-backend: malformed CLAUDE_STOP_REVIEWER='$raw' (expected 'ollama:scheme://host[:port]:MODEL')" >&2
      return 1
      ;;
    *)
      echo "reviewer-backend: unknown CLAUDE_STOP_REVIEWER='$raw' (expected 'claude' or 'ollama:URL:MODEL')" >&2
      return 1
      ;;
  esac
}
