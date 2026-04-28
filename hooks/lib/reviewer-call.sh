#!/bin/bash
# Library: reviewer LLM call defaults (Ollama backend).
# Single source of truth for model identity, host, and sampling options
# shared between the production stop hook and the test harness.
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

# reviewer_ollama_options <seed>
# Emit the Ollama options JSON for a single call. Seed is a parameter so
# the harness can vary it across runs while production keeps a fixed seed.
reviewer_ollama_options() {
  local seed=${1:-42}
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
