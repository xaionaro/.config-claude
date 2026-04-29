#!/bin/bash
# PreToolUse hook: validates Bash commands before execution.

set -euo pipefail

INPUT=$(cat)

# Quick prefilter: skip jq if irrelevant
case "$INPUT" in
  *"go test"*) ;;
  *) exit 0 ;;
esac

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# Match `go test` as a word (avoids false-positive on `goconfig test`,
# `cd go-test-dir`, etc.). Used by both checks below.
if ! echo "$COMMAND" | grep -qE '(^|[^A-Za-z0-9_-])go[[:space:]]+test\b'; then
  exit 0
fi

# Check for go test with -count=1 (covers -count=1 and -count 1)
if echo "$COMMAND" | grep -qE '\-count[= ]1\b'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Do not pass -count=1 to go test (defeats the test cache). Re-run without -count=1."
    }
  }'
  exit 0
fi

# Require output redirection so large test output goes to a file the
# agent can tail/head/grep without blowing the context window. Accept
# `> file`, `>> file`, `&> file`, `&>> file`, or `tee[ -a] file` (any
# capture-to-file shape). Reject bare `go test ...` with no capture.
if ! echo "$COMMAND" | grep -qE '([12&]?>>?|\|[[:space:]]*tee\b)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "go test output must be captured to a file (large output overruns the context window). Re-run with redirection, e.g.:\n  go test ./... > /tmp/go-test.log 2>&1\nThen tail/head/grep the log:\n  tail -n 100 /tmp/go-test.log\n  grep -E '\''^(--- FAIL|FAIL|PASS|ok|---)'\'' /tmp/go-test.log"
    }
  }'
  exit 0
fi
