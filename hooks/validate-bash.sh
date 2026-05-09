#!/bin/bash
# PreToolUse hook: validates Bash commands before execution.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/claude-proof-state.sh"
. "$HOOK_DIR/lib/claude-tmp.sh"
claude_init_tmp || true
claude_install_fail_open_trap validate-bash

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# Detect `eci-active off` invocation (any form: full path, bare, separators).
command_invokes_eci_off() {
  printf '%s' "$1" |
    tr "\"';&|()" '       ' |
    awk '
      {
        for (i = 1; i < NF; i++) {
          token = $i
          sub(/^.*\//, "", token)
          if (token == "eci-active" && $(i + 1) == "off") {
            found = 1
          }
        }
      }
      END { exit found ? 0 : 1 }
    '
}

# Determine whether a command is purely read-only (no writes, no side effects).
# Returns 0 (read-only) when every segment of the command is on the allow-list.
command_is_read_only() {
  local scrubbed

  [ -n "${1:-}" ] || return 1
  scrubbed="$(printf '%s' "$1" | sed -E 's/[[:space:]][0-9]*>>?[[:space:]]*\/dev\/null([[:space:]]|$)/ /g')"

  case "$scrubbed" in
    *'`'*|*'$('*|*'>'*|*'<'*) return 1 ;;
  esac

  printf '%s\n' "$scrubbed" |
    awk '
      function emit() {
        print segment
        segment = ""
      }
      BEGIN {
        single_quote_char = sprintf("%c", 39)
      }
      {
        for (pos = 1; pos <= length($0); pos++) {
          char = substr($0, pos, 1)
          next_char = substr($0, pos + 1, 1)
          if (escaped) {
            segment = segment char
            escaped = 0
            continue
          }
          if (char == "\\" && double_quote) {
            segment = segment char
            escaped = 1
            continue
          }
          if (!double_quote && char == single_quote_char) {
            single_quote = !single_quote
            segment = segment char
            continue
          }
          if (!single_quote && char == "\"") {
            double_quote = !double_quote
            segment = segment char
            continue
          }
          if (!single_quote && !double_quote) {
            if (char == ";") {
              emit()
              continue
            }
            if (char == "&" && next_char == "&") {
              emit()
              pos++
              continue
            }
            if (char == "|" && next_char == "|") {
              emit()
              pos++
              continue
            }
            if (char == "|") {
              emit()
              continue
            }
          }
          segment = segment char
        }
        emit()
      }
    ' |
    awk '
      function base_name(token) {
        sub(/^.*\//, "", token)
        return token
      }
      function allowed_simple(cmd) {
        return cmd ~ /^(cat|cut|date|dirname|du|egrep|fgrep|file|grep|head|jq|ls|nl|printf|pwd|readlink|realpath|rg|sed|sort|stat|tail|test|tr|uniq|wc|which|\[)$/
      }
      {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 == "") {
          next
        }
        part_count = split($0, parts, /[[:space:]]+/)
        idx = 1
        while (idx <= part_count && parts[idx] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          idx++
        }
        cmd = base_name(parts[idx])
        if (cmd == "") {
          next
        }
        if (cmd == "command") {
          if (parts[idx + 1] != "-v") {
            bad = 1
          }
          next
        }
        if (cmd == "git") {
          subcmd = parts[idx + 1]
          if (subcmd !~ /^(branch|describe|diff|grep|log|ls-files|remote|rev-parse|show|status)$/) {
            bad = 1
          }
          next
        }
        if (cmd == "find") {
          for (i = idx + 1; i <= part_count; i++) {
            if (parts[i] ~ /^-(delete|exec|execdir|ok|okdir)$/) {
              bad = 1
            }
          }
          next
        }
        if (cmd == "sed") {
          for (i = idx + 1; i <= part_count; i++) {
            if (parts[i] ~ /^-.*i/) {
              bad = 1
            }
          }
          next
        }
        if (!allowed_simple(cmd)) {
          bad = 1
        }
      }
      END { exit bad ? 1 : 0 }
    '
}

# Block subagents from disengaging ECI via `eci-active off`.
if claude_hook_is_subagent_context "$INPUT" && command_invokes_eci_off "$COMMAND"; then
  deny 'Only the main thread/orchestrator may disengage ECI with eci-active off. Subagents must report completion or blockers to the orchestrator while ECI remains active.'
fi

read_only=false
if command_is_read_only "$COMMAND"; then
  read_only=true
fi

# Mark shell activity for non-subagent, non-read-only commands.
if ! claude_hook_is_subagent_context "$INPUT" && [ "$read_only" != true ]; then
  claude_mark_activity "$SESSION_ID" "$CWD" shell || true
fi

# go test specific checks (preserved from prior validation).
case "$INPUT" in
  *"go test"*) ;;
  *) exit 0 ;;
esac

# Match `go test` as a word (avoids false-positive on `goconfig test`,
# `cd go-test-dir`, etc.).
if ! echo "$COMMAND" | grep -qE '(^|[^A-Za-z0-9_-])go[[:space:]]+test\b'; then
  exit 0
fi

# Check for go test with -count=1 (covers -count=1 and -count 1)
if echo "$COMMAND" | grep -qE '\-count[= ]1\b'; then
  deny 'Do not pass -count=1 to go test (defeats the test cache). Re-run without -count=1.'
fi

# Require output redirection so large test output goes to a file the
# agent can tail/head/grep without blowing the context window. Accept
# `> file`, `>> file`, `&> file`, `&>> file`, or `tee[ -a] file` (any
# capture-to-file shape). Reject bare `go test ...` with no capture.
if ! echo "$COMMAND" | grep -qE '([12&]?>>?|\|[[:space:]]*tee\b)'; then
  deny "go test output must be captured to a file (large output overruns the context window). Re-run with redirection, e.g.:
  go test ./... > /tmp/go-test.log 2>&1
Then tail/head/grep the log:
  tail -n 100 /tmp/go-test.log
  grep -E '^(--- FAIL|FAIL|PASS|ok|---)' /tmp/go-test.log"
fi
