#!/bin/bash
# PreToolUse admission controller for Edit|Write|MultiEdit|Bash.
# Opt-in via CLAUDE_EDIT_PRE_REVIEWER (same format as CLAUDE_STOP_REVIEWER).
# Fires only on the FIRST tool call of the current user turn. Asks an LLM
# whether the task is non-trivial enough that the agent should delegate or
# load skills first (per CLAUDE.md Mandatory Skills). On deny, blocks the
# call with a PreToolUse-shaped permission decision.
#
# Fail-open on every error path: missing transcript, malformed env, LLM
# timeout, schema miss — exit 0 (allow). Admission control must never
# brick the agent; the stop reviewer is the catch-net.
#
# Subagent skip: any documented CLAUDE_ROLE bypasses entirely so subagent
# invocations are not gated (matches stop-gate.sh:19).
#
# TOCTOU: when the assistant emits 2-3 parallel tool_use blocks in one
# message, all hook instances may see "first call of turn" simultaneously
# before any tool_use is recorded. We use a noclobber-locked claim file
# (set -C >file) so only the first racer fires the LLM; the others exit 0.

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
# KEEP IN SYNC with --argjson gated below (FIRST_OF_TURN jq filter).
case "$TOOL" in Edit|Write|MultiEdit|Bash) ;; *) exit 0 ;; esac

# Whitelist: `touch <path-under-~/.cache/claude-proof/.../bypass>` is the
# documented escape hatch for both this hook and the stop-hook reviewer.
# It MUST work even when no skill is loaded — that's the entire point of
# the bypass. Otherwise an ECI-active session would be impossible to
# release because the touch itself would be denied. Allowed paths:
#   $HOME/.cache/claude-proof/reviewer/<session>/bypass     (stop reviewer)
#   $HOME/.cache/claude-proof/pre-reviewer/<session>/bypass (this hook)
# Path components are restricted to safe chars (no `.`, no `/`) so a
# traversal payload like `..%2F..%2F../etc/bypass` cannot match.
# Quoting the path is also accepted (single or double quotes).
if [ "$TOOL" = "Bash" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if [[ "$CMD" =~ ^[[:space:]]*touch[[:space:]]+[\"\']?$HOME/\.cache/claude-proof/(reviewer|pre-reviewer)/[A-Za-z0-9_-]+/bypass[\"\']?[[:space:]]*$ ]]; then
    exit 0
  fi
fi

# Subagent skip — same role list as stop-gate.sh:19.
case "${CLAUDE_ROLE:-}" in
  lead|coordinator|snitch|explorer|brainstormer|designer|reviewer|test-designer|test-reviewer|verifier|qa)
    exit 0 ;;
esac

# Opt-in env. Reuse parse_reviewer_env by temporarily aliasing.
RAW_ENV="${CLAUDE_EDIT_PRE_REVIEWER:-}"
[ -z "$RAW_ENV" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=reviewer-backend.sh
. "$HOOK_DIR/reviewer-backend.sh"
_SAVED_STOP_REVIEWER="${CLAUDE_STOP_REVIEWER:-}"
CLAUDE_STOP_REVIEWER="$RAW_ENV"
if ! parse_reviewer_env; then
  CLAUDE_STOP_REVIEWER="$_SAVED_STOP_REVIEWER"
  exit 0
fi
CLAUDE_STOP_REVIEWER="$_SAVED_STOP_REVIEWER"
[ -z "${REVIEWER_BACKEND:-}" ] && exit 0

# Sibling state dir (not under $PROOF_DIR — survives stop-cycle wipe).
STATE_DIR="$HOME/.cache/claude-proof/pre-reviewer/$SESSION_ID"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Bypass marker.
[ -f "$STATE_DIR/bypass" ] && exit 0

# Locate transcript JSONL.
TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
[ -z "$TRANSCRIPT" ] && exit 0
[ ! -f "$TRANSCRIPT" ] && exit 0

# Determine: index of last real user-text message + whether any prior
# assistant tool_use exists at index > that. Also emit the index so we can
# scope the TOCTOU claim file per-turn.
read -r LTS FIRST_OF_TURN < <(jq -rs --argjson gated '["Edit","Write","MultiEdit","Bash"]' '
  . as $all
  | ([$all | to_entries[]
      | select(.value.type == "user"
               and ((.value.message.content | type) == "string")
               and ((.value.isMeta // false) | not))
      | .key] | last // -1) as $lts
  | if $lts < 0 then "\($lts) no" else
      ([$all | to_entries[]
        | select(.key > $lts
                 and .value.type == "assistant"
                 and ((.value.message.content | type) == "array")
                 and any(.value.message.content[]; .type == "tool_use" and (.name as $n | $gated | index($n))))
        | .key] | length) as $prior
      | if $prior == 0 then "\($lts) yes" else "\($lts) no" end
    end
' "$TRANSCRIPT" 2>/dev/null)

[ "${FIRST_OF_TURN:-no}" != "yes" ] && exit 0

# TOCTOU claim: noclobber-create a per-turn claim file. First racer wins;
# subsequent racers fail the redirect and exit 0. The file is keyed on
# $LTS so each new user turn gets a fresh claim slot.
CLAIM="$STATE_DIR/claim-$LTS"
( set -C; : > "$CLAIM" ) 2>/dev/null || exit 0

# Extract last user message text + tool input snippet (truncated).
USER_MSG=$(jq -rs '
  [.[] | select(.type == "user"
                and ((.message.content | type) == "string")
                and ((.isMeta // false) | not))
   | .message.content] | last // ""
' "$TRANSCRIPT" 2>/dev/null | head -c 4000)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null | head -c 4000)

# System prompt = framing + Mandatory Skills excerpt. Deliberately small;
# admission control must be cheap.
SYS=$(mktemp); USR=$(mktemp)
trap 'rm -f "$SYS" "$USR"' EXIT
cat > "$SYS" <<'EOF'
Admission controller for a coding agent. The agent is about to invoke a tool on the first action of a new user turn. Decide: proceed directly, or task is non-trivial and the agent should first delegate to a subagent / load a Mandatory Skill (per CLAUDE.md).

CLAUDE.md Mandatory Skills (excerpt):
- Debugging? -> systematic-debugging + debugging-discipline
- Go code? -> go-coding-style
- Python code? -> python-coding-style
- Tests? -> testing-discipline
- Logic? -> proof-driven-development
- Medium task? -> explore-critique-implement
- Large task? -> agent-teams-execution
- Skills/CLAUDE.md edits? -> harness-tuning

Rules:
- Trivial = single-line edit, lookup, ls, cat, git status, typo fix, file read, quick check.
- Non-trivial = implementing logic, multi-file refactor, new feature, productionization, debugging unknown failure, writing tests, editing skills.
- Should delegate/load-skill but doing it inline -> deny.
- Genuinely trivial OR prep already done -> allow.
- When in doubt, allow (stop reviewer is the catch-net).

Output JSON ONLY: {"verdict": "allow"|"deny", "reason": "<one sentence>"}
EOF
{
  printf 'LAST USER MESSAGE:\n%s\n\n---\nTOOL ABOUT TO BE CALLED: %s\nTOOL INPUT: %s\n' \
    "$USER_MSG" "$TOOL" "$TOOL_INPUT"
} > "$USR"

SCHEMA='{"type":"object","required":["verdict","reason"],"properties":{"verdict":{"type":"string","enum":["allow","deny"]},"reason":{"type":"string"}}}'
TIMEOUT=60
RAW=""

case "$REVIEWER_BACKEND" in
  ollama)
    MODEL="$REVIEWER_OLLAMA_MODEL"
    OLLAMA_HOST="$REVIEWER_OLLAMA_HOST"
    REQ=$(jq -n --arg model "$MODEL" --rawfile sys "$SYS" --rawfile usr "$USR" --argjson schema "$SCHEMA" \
      '{model:$model,stream:false,think:false,format:$schema,
        options:{temperature:0.1,seed:42,num_ctx:8192,num_predict:256},
        messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}')
    REQ_FILE=$(mktemp); printf '%s' "$REQ" > "$REQ_FILE"
    OUT=$(timeout "$TIMEOUT" curl -s --max-time "$TIMEOUT" -X POST "$OLLAMA_HOST/api/chat" \
      -H 'Content-Type: application/json' --data-binary "@$REQ_FILE" 2>/dev/null)
    EC=$?
    rm -f "$REQ_FILE"
    [ "$EC" -ne 0 ] || [ -z "$OUT" ] && exit 0
    RAW=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
    ;;
  opencode-zen)
    MODEL="$REVIEWER_OPENCODE_MODEL"
    # OpenAI-compat /zen/v1/chat/completions. Anonymous today; honors
    # OPENCODE_ZEN_API_KEY for forward-compat.
    # 4096 not 256: reasoning-heavy free models burn 100-200 tokens on hidden
    # CoT before content emission. Verified live against system-prompt-reviewer.sh.
    REQ=$(jq -n --arg model "$MODEL" --rawfile sys "$SYS" --rawfile usr "$USR" --argjson schema "$SCHEMA" \
      '{model:$model,stream:false,
        max_tokens:4096,max_completion_tokens:4096,
        temperature:0.1,seed:42,
        response_format:{type:"json_schema",
          json_schema:{name:"pre_reviewer_verdict",schema:$schema,strict:false}},
        messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}')
    REQ_FILE=$(mktemp); printf '%s' "$REQ" > "$REQ_FILE"
    OPENCODE_AUTH_HEADER=()
    if [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
      OPENCODE_AUTH_HEADER=(-H "Authorization: Bearer $OPENCODE_ZEN_API_KEY")
    fi
    OUT=$(timeout "$TIMEOUT" curl -s --max-time "$TIMEOUT" -X POST "$REVIEWER_OPENCODE_HOST/zen/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      ${OPENCODE_AUTH_HEADER[@]+"${OPENCODE_AUTH_HEADER[@]}"} \
      --data-binary "@$REQ_FILE" 2>/dev/null)
    EC=$?
    rm -f "$REQ_FILE"
    [ "$EC" -ne 0 ] || [ -z "$OUT" ] && exit 0
    RAW=$(echo "$OUT" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    ;;
  github-copilot)
    MODEL="$REVIEWER_COPILOT_MODEL"
    # shellcheck source=lib/copilot-token.sh
    . "$HOOK_DIR/lib/copilot-token.sh"
    if ! copilot_get_bearer || [ -z "${COPILOT_BEARER:-}" ]; then
      exit 0
    fi
    REQ=$(jq -n --arg model "$MODEL" --rawfile sys "$SYS" --rawfile usr "$USR" --argjson schema "$SCHEMA" \
      '{model:$model,stream:false,
        max_tokens:4096,
        temperature:0.1,seed:42,
        tool_choice:{type:"function",function:{name:"emit_verdict"}},
        tools:[{type:"function",function:{name:"emit_verdict",description:"Emit the admission-control verdict.",parameters:$schema}}],
        messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}')
    REQ_FILE=$(mktemp); printf '%s' "$REQ" > "$REQ_FILE"
    OUT=$(timeout "$TIMEOUT" curl -s --max-time "$TIMEOUT" \
      -X POST 'https://api.githubcopilot.com/chat/completions' \
      -H "Authorization: Bearer $COPILOT_BEARER" \
      -H 'content-type: application/json' \
      -H 'copilot-integration-id: vscode-chat' \
      -H 'editor-version: vscode/1.95.0' \
      -H 'editor-plugin-version: copilot-chat/0.26.7' \
      -H 'user-agent: GitHubCopilotChat/0.26.7' \
      -H 'openai-intent: conversation-panel' \
      -H 'x-github-api-version: 2025-04-01' \
      -H "x-request-id: $(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)" \
      -H 'x-vscode-user-agent-library-version: electron-fetch' \
      --data-binary "@$REQ_FILE" 2>/dev/null)
    EC=$?
    rm -f "$REQ_FILE"
    [ "$EC" -ne 0 ] || [ -z "$OUT" ] && exit 0
    RAW=$(echo "$OUT" | jq -r '
      (.choices[0].message.tool_calls[0].function.arguments // empty) as $args
      | if ($args | length) > 0 then $args
        else (.choices[0].message.content // empty) end
    ' 2>/dev/null)
    ;;
  claude)
    MODEL="claude-bare"
    OUT=$(timeout "$TIMEOUT" claude --bare --print \
      --output-format json --input-format text \
      --settings "$HOME/.claude/bin/bare-settings.json" \
      --append-system-prompt "$(cat "$SYS")" \
      --json-schema "$SCHEMA" \
      --allow-dangerously-skip-permissions \
      < "$USR" 2>/dev/null)
    EC=$?
    [ "$EC" -ne 0 ] || [ -z "$OUT" ] && exit 0
    RAW=$(echo "$OUT" | jq -r 'if (.structured_output|type)=="object" then (.structured_output|tojson) else (.result // "") end' 2>/dev/null)
    ;;
esac

[ -z "$RAW" ] && exit 0
RESULT=$(printf '%s' "$RAW" | sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d; /^[[:space:]]*```[[:space:]]*$/d')
VERDICT=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)
REASON=$(echo "$RESULT" | jq -r '.reason // empty' 2>/dev/null)

case "$VERDICT" in
  deny)
    MSG=$(printf 'Pre-tool admission controller (CLAUDE_EDIT_PRE_REVIEWER) denied the first tool call of this turn.\n\nReason: %s\n\nLoad the appropriate Mandatory Skill or delegate to a subagent before invoking %s directly.\n\nTo override: touch %s/bypass\n' \
      "$REASON" "$TOOL" "$STATE_DIR")
    jq -n --arg reason "$MSG" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
