#!/bin/bash
# Library: compose the full reviewer system prompt from a wrapper file plus
# the appended rule sources (CLAUDE.md, stop-checklist.md, MEMORY.md).
#
# Single source of truth used by both the production stop hook
# (system-prompt-reviewer.sh) and the test harness
# (tests/reviewer/run.sh). Behavior must stay byte-identical to the
# original inline composition that lived at lines 96-126 of
# system-prompt-reviewer.sh.
#
# Usage (sourced):
#   . "$HOME/.claude/hooks/lib/compose-reviewer-prompt.sh"
#   compose_reviewer_prompt "$WRAPPER_PATH" > "$OUT"
#
# Inputs:
#   $1 — wrapper path (e.g. ~/.claude/hooks/reviewer-rules.md)
# Output:
#   stdout — composed system prompt
# Exit:
#   0 on success; 1 on missing wrapper or CLAUDE.md.

compose_reviewer_prompt() {
  local wrapper=$1
  local instructions="$HOME/.claude/CLAUDE.md"
  local stop_checklist="$HOME/.claude/hooks/stop-checklist.md"
  local memory_index="$HOME/.claude/projects/-home-streaming--claude/memory/MEMORY.md"

  [ -f "$wrapper" ] || { printf 'compose_reviewer_prompt: wrapper not found: %s\n' "$wrapper" >&2; return 1; }
  [ -f "$instructions" ] || { printf 'compose_reviewer_prompt: CLAUDE.md not found: %s\n' "$instructions" >&2; return 1; }

  cat "$wrapper"
  echo
  echo
  echo "============================================================"
  echo "# CLAUDE.md (user's global instructions)"
  echo "============================================================"
  echo
  cat "$instructions"
  echo
  if [ -f "$stop_checklist" ]; then
    echo
    echo "============================================================"
    echo "# stop-checklist.md (acceptance criteria for ending a turn)"
    echo "============================================================"
    echo
    cat "$stop_checklist"
    echo
  fi
  if [ -f "$memory_index" ]; then
    echo
    echo "============================================================"
    echo "# MEMORY.md (cross-session lessons-learned, one-line summaries)"
    echo "============================================================"
    echo
    cat "$memory_index"
    echo
  fi
}
