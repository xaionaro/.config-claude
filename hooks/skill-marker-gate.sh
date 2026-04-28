#!/bin/bash
# PreToolUse hook on Edit|Write|MultiEdit: denies if a required Mandatory Skill
# marker is missing. Per CLAUDE.md Mandatory Skills, certain file patterns
# require an explicit Skill-tool invocation before the file is edited.
#
# Bash matcher intentionally NOT covered in v1: bash command patterns are
# unbounded and false-positive-prone (python -m pytest, npm test, cargo test,
# make test, custom scripts...). The Edit/Write gate on test-file paths covers
# the write axis; running tests is the agent's CLAUDE.md obligation.
#
# Failure mode: any infrastructure error (jq crash, mkdir failure, schema
# mismatch) traps to deny-with-evidence. The gate's purpose is enforcement;
# silent-allow on infra errors is never the right default.

set -uo pipefail

# Fail-closed trap: if anything below errors out, emit a deny with the trace
# location so the user/agent can repair the gate rather than silently bypass.
trap 'jq -n --arg reason "skill-marker-gate infra error at line $LINENO; investigate $HOME/.cache/claude-proof and the gate script" "{
  hookSpecificOutput: {
    hookEventName: \"PreToolUse\",
    permissionDecision: \"deny\",
    permissionDecisionReason: \$reason
  }
}"; exit 0' ERR

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

# Try multiple plausible keys for file_path (Edit/Write use file_path; MultiEdit
# documented schema also uses file_path but defensively probe alternates).
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.target_file // empty')
if [ -z "$FILE_PATH" ]; then
  # Fail-closed on schema mismatch for protected tools — never silently allow.
  # Audit lives outside $PROOF_DIR so it survives the stop-cycle wipe.
  AUDIT_DIR="$HOME/.cache/claude-proof/audit/$SESSION_ID"
  mkdir -p "$AUDIT_DIR"
  AUDIT="$AUDIT_DIR/gate-schema-miss-${TOOL}-$(date +%s).json"
  echo "$INPUT" > "$AUDIT"
  jq -n --arg reason "skill-marker-gate: $TOOL invocation has no resolvable file_path (audit: $AUDIT). Update gate to handle this schema." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

DIR="$HOME/.cache/claude-proof/skills/$SESSION_ID"
BASENAME="$(basename "$FILE_PATH")"

REQUIRED=()

# Test files: testing-discipline.
case "$FILE_PATH" in
  *_test.go|*/test_*.py|*.test.ts|*.test.tsx|*.test.js|*/tests/*|*/test/*)
    REQUIRED+=("testing-discipline") ;;
esac

# Language coding style.
case "$FILE_PATH" in
  *.go|*/go.mod|*/go.sum)
    REQUIRED+=("go-coding-style") ;;
  *.py|*/pyproject.toml|*/setup.cfg)
    REQUIRED+=("python-coding-style") ;;
esac

# Harness: anything under ~/.claude/{skills,hooks,CLAUDE.md} or any CLAUDE.md.
case "$FILE_PATH" in
  "$HOME/.claude/skills/"*|"$HOME/.claude/hooks/"*) REQUIRED+=("harness-tuning") ;;
esac
case "$BASENAME" in
  CLAUDE.md) REQUIRED+=("harness-tuning") ;;
esac

# No requirements → allow.
[ "${#REQUIRED[@]}" -eq 0 ] && exit 0

# Find first missing marker.
MISSING=""
for SKILL in "${REQUIRED[@]}"; do
  if [ ! -e "$DIR/$SKILL" ]; then
    MISSING="$SKILL"
    break
  fi
done

[ -z "$MISSING" ] && exit 0

REASON="Required skill not yet invoked: '$MISSING'. Mandatory Skills require it before editing $FILE_PATH. Invoke via Skill tool (skill: \"$MISSING\"), then retry."

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
