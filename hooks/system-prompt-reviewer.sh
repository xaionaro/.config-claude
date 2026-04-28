#!/bin/bash
# Stop hook (synchronous block): runs an EXTERNAL Ollama reviewer to score
# the just-finished turn against CLAUDE.md + the curated reviewer-rules.md.
# On detected violations, prints {"decision":"block","reason":<violations>}
# to stdout and exits 0 — Claude Code holds the stop and feeds the reason
# back to the agent so it must actually correct the violations before the
# turn can end. (Earlier asyncRewake design proved too easy to ignore.)
#
# Coexists with stop-gate.sh: that one validates the proof's structure;
# this one critiques the conduct. Both fire on Stop in parallel.
#
# Cost / latency gates:
#   - skip on user-touched bypass marker
#   - timeout 240s on the model call
#   - track consecutive-fail streak (informational; bypass marker is the
#     escape hatch when the reviewer is wrong)
# Note: fires on every Stop pass (including stop_hook_active=true) so
# post-correction state is also verified.

set -uo pipefail

# Invocation log set up FIRST so even early-exit failures (malformed env,
# missing config) get a record. Lives outside $PROOF_DIR so it survives
# the stop-cycle wipe.
LOG_DIR="$HOME/.cache/claude-proof/reviewer"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/invocations.log"
log() { printf '%s pid=%d %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*" >> "$LOG"; }

# Backend selection via CLAUDE_STOP_REVIEWER (parsed by shared helper).
# After parse: $REVIEWER_BACKEND in {ollama, claude}, plus the ollama
# host/model when applicable. See reviewer-backend.sh for format.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=reviewer-backend.sh
. "$HOOK_DIR/reviewer-backend.sh"
# shellcheck source=lib/compose-reviewer-prompt.sh
. "$HOOK_DIR/lib/compose-reviewer-prompt.sh"
# shellcheck source=lib/reviewer-filter.sh
. "$HOOK_DIR/lib/reviewer-filter.sh"
if ! parse_reviewer_env; then
  log "exit reason=malformed-env CLAUDE_STOP_REVIEWER='${CLAUDE_STOP_REVIEWER:-}'"
  printf 'system-prompt-reviewer: invalid CLAUDE_STOP_REVIEWER — review skipped.\n'
  exit 0
fi
# CLAUDE_STOP_REVIEWER unset → no LLM reviewer; just exit so stop-gate
# falls back to the proof.md self-check protocol.
if [ -z "$REVIEWER_BACKEND" ]; then
  log "exit reason=no-backend (CLAUDE_STOP_REVIEWER unset)"
  exit 0
fi
OLLAMA_HOST="$REVIEWER_OLLAMA_HOST"
MODEL="${REVIEWER_OLLAMA_MODEL:-claude-bare}"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // empty')

log "enter session=${SESSION_ID:-EMPTY} stop_active=${STOP_ACTIVE:-EMPTY}"

[ -z "$SESSION_ID" ] && { log "exit reason=empty-session"; exit 0; }
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) log "exit reason=unsafe-session-id"; exit 0 ;;
esac

# NOTE: previously skipped when stop_hook_active=true to save cost on
# second-pass stops. Under sync-block design that's wrong: the reviewer
# must verify the agent's *correction* work too, not only the pre-block
# state. Re-fire on every pass — cost is bounded by 240s timeout and
# warm-call latency (5-22s observed).

# Reviewer reads the transcript directly (per the rule-source-not-narrative
# redesign), so it does not need proof.md / summary-to-print.md to exist.
# The transcript JSONL is always present for any session that ever ran.

# State outside $PROOF_DIR so it survives stop-cycle wipe.
STATE_DIR="$HOME/.cache/claude-proof/reviewer/$SESSION_ID"
mkdir -p "$STATE_DIR"
BYPASS_MARKER="$STATE_DIR/bypass"
STREAK_FILE="$STATE_DIR/streak"

# User-acknowledged bypass: skip review until removed.
[ -f "$BYPASS_MARKER" ] && { log "exit reason=bypass-marker"; exit 0; }

RULES_WRAPPER="$HOME/.claude/hooks/reviewer-rules.md"
INSTRUCTIONS="$HOME/.claude/CLAUDE.md"
[ ! -f "$RULES_WRAPPER" ] && { log "exit reason=missing-wrapper"; exit 0; }
[ ! -f "$INSTRUCTIONS" ] && { log "exit reason=missing-claude-md"; exit 0; }

# Build the system message via the shared composer. Composes:
#   wrapper + CLAUDE.md + stop-checklist.md + MEMORY.md
# See lib/compose-reviewer-prompt.sh — sole source of truth, also used
# by tests/reviewer/run.sh so harness and production stay in lockstep.
RULES=$(mktemp)
compose_reviewer_prompt "$RULES_WRAPPER" > "$RULES"
trap 'rm -f "$RULES"' EXIT

# Build user-message body. Order is RECENT_TURNS first, DIFF last — DIFF
# changes per commit (every turn or two) and would invalidate the KV
# cache for everything after it if it sat at the front; placing it last
# keeps the long, slow-changing RECENT_TURNS prefix cacheable across
# consecutive reviewer calls. Reviewer reads raw transcript turns, NOT
# the agent's proof.md (the unreliable narrative we're externalizing).
USER_BODY=$(mktemp)

# --- Anchor (hysteresis) for KV-cache stability ------------------------
# Slice start is anchored at a chosen turn-start entry-index, persisted
# per session. The slice grows from that anchor as new turns arrive.
# When the slice exceeds 150 turn-starts, we rebase the anchor forward
# to the last 100 — so the prefix is stable for ~50 calls between rebases
# and Ollama can reuse the KV cache.
TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
ANCHOR_FILE="$STATE_DIR/anchor"
ANCHOR_IDX=""
if [ -f "$ANCHOR_FILE" ]; then
  ANCHOR_IDX=$(cat "$ANCHOR_FILE" 2>/dev/null || echo "")
  case "$ANCHOR_IDX" in *[!0-9]*) ANCHOR_IDX="" ;; esac
fi
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # Turn-start = a real human-typed user message. The signal in Claude
  # Code transcripts: content is a string AND isMeta is not true. (Array
  # content + isMeta=true is a skill-load body; string content + isMeta
  # =true is synthetic stop-hook feedback. Neither counts as a turn.)
  TS_LIST=$(jq -s '
    [ to_entries[]
      | select(.value.type == "user"
               and ((.value.message.content | type) == "string")
               and ((.value.isMeta // false) | not))
      | .key
    ]
  ' "$TRANSCRIPT" 2>/dev/null || echo "[]")
  TS_COUNT=$(printf '%s' "$TS_LIST" | jq 'length')
  # Validate anchor still points to one of the current turn-starts.
  ANCHOR_VALID=0
  if [ -n "$ANCHOR_IDX" ]; then
    ANCHOR_VALID=$(printf '%s' "$TS_LIST" | jq --argjson a "$ANCHOR_IDX" 'index($a) != null | if . then 1 else 0 end')
  fi
  if [ "$ANCHOR_VALID" != "1" ]; then
    # Initialize: last 100 turn-starts (or all when fewer).
    if [ "$TS_COUNT" -le 100 ]; then
      ANCHOR_IDX=$(printf '%s' "$TS_LIST" | jq '.[0] // 0')
    else
      ANCHOR_IDX=$(printf '%s' "$TS_LIST" | jq '.[-100]')
    fi
  else
    ANCHOR_POS=$(printf '%s' "$TS_LIST" | jq --argjson a "$ANCHOR_IDX" 'index($a)')
    SLICE_TURNS=$(( TS_COUNT - ANCHOR_POS ))
    if [ "$SLICE_TURNS" -gt 150 ]; then
      # Rebase: drop oldest 50 turns, slice resumes at last-100.
      ANCHOR_IDX=$(printf '%s' "$TS_LIST" | jq '.[-100]')
    fi
  fi
  echo "$ANCHOR_IDX" > "$ANCHOR_FILE"
fi
ANCHOR_IDX=${ANCHOR_IDX:-0}

{
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Two explicit sections:
    #   ## USER_HISTORY   — every USER text entry from `$cutoff` up to
    #                       the start of the last turn. The agent's
    #                       actions in those past turns are intentionally
    #                       NOT shown — they were already audited in
    #                       their own stops; we keep only the human's
    #                       requests/corrections so the reviewer knows
    #                       the agreements that bind the current turn.
    #   ## CURRENT_TURN   — every entry from the last user-text message
    #                       onward (USER text, ASSISTANT text+tool_use,
    #                       TOOL_RESULT bodies). This is the only turn
    #                       whose conduct is up for review.
    # Per-tool input budgets (chosen from empirical p85-p89 of session
    # dumps so we cover the long tail of multi-line code blocks without
    # blowing the body cap):
    #   - Agent:                full prompt (subagent contracts critical)
    #   - Bash:                 full command (shell scripts auditable)
    #   - Edit/Write:           $edit_cap chars (covers ~p89 of new_string sizes)
    #   - MultiEdit:            $multiedit_cap chars (~3 stacked edits at p89)
    #   - other:                $other_cap chars
    # Tool outputs: first $tr_cap chars per block (covers ~p85; long tail trimmed).
    # Assistant text: first $asst_cap chars per block.
    # All caps hoisted to --argjson so the jq filter has a single source of
    # truth (no drift across the multiple sites where they're applied).
    # Final body capped via `tail -c 120000`.
    jq -rs \
      --argjson cutoff "$ANCHOR_IDX" \
      --argjson tr_cap 1000 \
      --argjson asst_cap 1500 \
      --argjson edit_cap 5000 \
      --argjson multiedit_cap 15000 \
      --argjson other_cap 1500 \
      '
      . as $all
      | (
          [ $all | to_entries[]
              | select(.value.type == "user"
                       and ((.value.message.content | type) == "string")
                       and ((.value.isMeta // false) | not))
              | .key
          ] | last // 0
        ) as $lts
      | def is_real_user($e):
          $e.type == "user"
          and ($e.message.content | type) == "string"
          and (($e.isMeta // false) | not);
        # ends_trim($cap): keep first $cap/2 + last $cap/2 chars of long
        # strings; mid-omission marker preserves both the OPENING (intent)
        # and the CLOSING (conclusions, questions, "Want me to..." phrases).
        # Tail-only or head-only truncation hides exactly the part most
        # likely to contain rule violations.
        def ends_trim($cap):
          if (. | length) <= $cap then .
          else (($cap / 2) | floor) as $half
               | .[:$half] + "…[truncated " + ((. | length) - $cap | tostring) + " chars]…" + .[-$half:]
          end;
        def render_user_text($e):
          ($e.message.content | tostring | ends_trim(1000)) as $text
          | if ($text | length) > 0 then "USER: " + $text else null end;
        def render_user_tr($e):
          ($e.message.content) as $c
          | (
              if ($c | type) == "array" then
                [$c[] | select(.type == "tool_result")
                  | (.content
                     | if type == "string" then ends_trim($tr_cap)
                       elif type == "array" then
                         ([.[] | if .type == "text" then (.text | ends_trim($tr_cap)) else "" end] | join(" ") | ends_trim($tr_cap))
                       else "" end)]
              else [] end
            ) as $tr
          | if ($tr | length) > 0 then
              "TOOL_RESULT: " + ($tr | map(if . == "" then "[empty]" else "[" + . + "]" end) | join(" "))
            else null end;
        def render_assistant($e):
          ($e.message.content
           | if type == "array" then
             [.[]
              | if .type == "text" then (.text | ends_trim($asst_cap))
                elif .type == "tool_use" then
                  ( .name as $n
                    | .input as $in
                    | if $n == "Agent" then
                        "[tool_use=Agent input=" + ($in | tostring) + "]"
                      elif $n == "Bash" then
                        "[tool_use=Bash input=" + ($in | tostring) + "]"
                      elif $n == "Edit" or $n == "Write" then
                        "[tool_use=" + $n + " input=" + ($in | tostring | ends_trim($edit_cap)) + "]"
                      elif $n == "MultiEdit" then
                        "[tool_use=" + $n + " input=" + ($in | tostring | ends_trim($multiedit_cap)) + "]"
                      else
                        "[tool_use=" + $n + " input=" + ($in | tostring | ends_trim($other_cap)) + "]"
                      end )
                else "" end]
             | join(" ")
           elif type == "string" then ends_trim($asst_cap)
           else "" end) as $body
          | if ($body | length) == 0 then null else "ASSISTANT: " + $body end;
        # Wrap each rendered entry in <entry>…</entry>. Escape both
        # </entry> AND <entry> in user content via split/join (literal
        # semantics, not regex — immune to future tag-rename mishaps).
        # The reviewer-controlled boundary stays unambiguous.
        def wrap_entries:
          map("<entry>"
              + (split("</entry>") | join("</_entry>")
                 | split("<entry>")  | join("<_entry>"))
              + "</entry>")
          | join("\n");
        ($all | to_entries
         | map(select(.key >= $cutoff and .key < $lts))
         | map(if is_real_user(.value) then render_user_text(.value) else null end)
         | map(select(. != null))
         | wrap_entries) as $history
      | ($all | to_entries
         | map(select(.key >= $lts))
         | map(
             if is_real_user(.value) then
               render_user_text(.value)
             elif .value.type == "user" then
               render_user_tr(.value)
             elif .value.type == "assistant" then
               render_assistant(.value)
             else null end)
         | map(select(. != null))
         | wrap_entries) as $current
      | "## USER_HISTORY (USER messages from earlier turns; the agent'"'"'s actions in those turns were already audited and are intentionally not shown)\n\n"
        + $history
        + "\n\n## CURRENT_TURN (the only turn under review now — all activity since the last USER message)\n\n"
        + $current
    ' "$TRANSCRIPT" 2>/dev/null \
    | tail -c 120000 \
    | awk -v hdr='## USER_HISTORY (USER messages from earlier turns; the agent'"'"'s actions in those turns were already audited and are intentionally not shown)' '
        # Trim at entry boundary: if tail-c cut mid-entry, lines before the
        # first complete <entry> tag are from a partial entry and must be
        # discarded. Track whether we saw the heading first; if not, it was
        # truncated away and must be re-injected before the entries.
        !found {
          if (/^## USER_HISTORY/) { saw_heading=1; print; next }
          if (/^<entry>/) {
            found=1
            if (!saw_heading) {
              print hdr; print ""
              print "(earlier USER_HISTORY entries omitted — body exceeded 120 KB limit)"
              print ""
            }
            print; next
          }
          if (saw_heading) print  # blank lines between heading and entries
          next
        }
        { print }
      '
  fi
  echo
  echo "## GIT_STATUS"
  echo "Working-tree state at this stop. Per stop-checklist Git rule, uncommitted code = violation."
  echo
  seen_dirs=""
  for repo_dir in "$HOME/.claude" "${PWD:-}"; do
    [ -z "$repo_dir" ] && continue
    case " $seen_dirs " in *" $repo_dir "*) continue ;; esac
    seen_dirs="$seen_dirs $repo_dir"
    git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || continue
    porcelain=$(git -C "$repo_dir" status --porcelain 2>/dev/null)
    if [ -z "$porcelain" ]; then
      printf '### %s\nclean — all changes committed\n\n' "$repo_dir"
    else
      modified=$(printf '%s\n' "$porcelain" | grep -c '^.M')
      staged=$(printf '%s\n' "$porcelain" | grep -cE '^[MADRC]')
      untracked=$(printf '%s\n' "$porcelain" | grep -c '^??')
      printf '### %s\nDIRTY — modified=%s staged=%s untracked=%s\n' "$repo_dir" "$modified" "$staged" "$untracked"
      printf '%s\n\n' "$porcelain" | head -c 2048
    fi
  done

  echo "## DIFF"
  git -C "$HOME/.claude" log --pretty=format:"%H %s" -5 2>/dev/null
  echo
  # Diff base = HEAD recorded by the UserPromptSubmit hook for this
  # session, so the reviewer sees ALL commits made in the current turn
  # (not just HEAD~1..HEAD). Falls back to HEAD~1 when the prompt-head
  # file is missing (first prompt of a session, or pre-hook session) or
  # when the recorded SHA is no longer reachable (force-push, rebase).
  PROMPT_HEAD_FILE="$STATE_DIR/prompt_head"
  DIFF_BASE="HEAD~1"
  if [ -s "$PROMPT_HEAD_FILE" ]; then
    PH=$(cat "$PROMPT_HEAD_FILE" 2>/dev/null)
    if [ -n "$PH" ] && git -C "$HOME/.claude" cat-file -e "${PH}^{commit}" 2>/dev/null; then
      DIFF_BASE="$PH"
    fi
  fi
  # Bound diff bytes: a huge diff (large refactor, generated files) blows
  # past Ollama's num_ctx and causes timeouts. Probe size first; if over
  # threshold, omit the diff body entirely — commit titles above are
  # enough context, and a mid-line truncation is misleading.
  DIFF_RAW=$(git -C "$HOME/.claude" diff "$DIFF_BASE..HEAD" 2>/dev/null)
  DIFF_BYTES=$(printf %s "$DIFF_RAW" | wc -c | awk '{print $1}')
  DIFF_LIMIT=4096
  if [ "$DIFF_BYTES" -gt "$DIFF_LIMIT" ]; then
    printf '(diff body omitted: %s bytes raw, exceeds %s-byte budget — see commit titles above)\n' \
      "$DIFF_BYTES" "$DIFF_LIMIT"
  else
    printf '%s' "$DIFF_RAW"
  fi
  echo
} > "$USER_BODY"

# JSON schema enforced on both backends: Ollama via /api/chat `format`,
# claude via --json-schema. Same shape so verdict parsing is uniform.
# Single source of truth at lib/reviewer-schema.json (also read by the
# test harness in tests/reviewer/run.sh).
SCHEMA=$(cat "$HOOK_DIR/lib/reviewer-schema.json")

# Archive what was sent so the user can inspect later. Same path for both
# backends; the dump file's `model` and `_backend` fields disambiguate.
DUMP_DIR="$HOME/.cache/claude-proof/reviewer-dumps/$SESSION_ID"
mkdir -p "$DUMP_DIR"
DUMP_PATH="$DUMP_DIR/$(date -u +%Y%m%dT%H%M%SZ).json"

case "$REVIEWER_BACKEND" in
  ollama)
    REQ=$(jq -n \
      --arg model "$MODEL" \
      --rawfile sys "$RULES" \
      --rawfile usr "$USER_BODY" \
      --argjson schema "$SCHEMA" \
      '{
        _backend: "ollama",
        model: $model,
        stream: false,
        think: false,
        format: $schema,
        options: {
          temperature: 0.3,
          top_k: 40,
          top_p: 0.9,
          seed: 42,
          num_ctx: 32768,
          num_predict: 2048,
          repeat_penalty: 1.0
        },
        messages: [
          { role: "system", content: $sys },
          { role: "user",   content: $usr }
        ]
      }')
    printf '%s' "$REQ" > "$DUMP_PATH"
    ls -1t "$DUMP_DIR"/*.json 2>/dev/null | tail -n +21 | xargs -r rm -f --
    log "calling-ollama model=$MODEL host=$OLLAMA_HOST dump=$DUMP_PATH"
    START_CALL=$(date +%s)
    OUT=$(timeout 240 curl -s --max-time 240 -X POST "$OLLAMA_HOST/api/chat" \
      -H 'Content-Type: application/json' \
      --data-binary "@$DUMP_PATH" 2>/dev/null)
    EXIT_CALL=$?
    ELAPSED_CALL=$(( $(date +%s) - START_CALL ))
    rm -f "$USER_BODY"
    if [ $EXIT_CALL -ne 0 ] || [ -z "$OUT" ]; then
      log "exit reason=ollama-call-failed exit=$EXIT_CALL elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: ollama call failed (exit=%s, host=%s) — review skipped.\n' "$EXIT_CALL" "$OLLAMA_HOST"
      exit 0
    fi
    OLLAMA_ERR=$(echo "$OUT" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$OLLAMA_ERR" ]; then
      log "exit reason=ollama-error err=\"$OLLAMA_ERR\" elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: ollama error: %s — review skipped.\n' "$OLLAMA_ERR"
      exit 0
    fi
    RAW=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
    [ -z "$RAW" ] && { log "exit reason=empty-message-content elapsed=${ELAPSED_CALL}s"; exit 0; }
    ;;

  claude)
    # claude --bare reads system prompt + user body via dedicated flags,
    # not as JSON-API messages. Archive a representation of the inputs in
    # the same shape so the dump remains comparable across backends.
    REQ=$(jq -n \
      --arg model "claude-bare" \
      --rawfile sys "$RULES" \
      --rawfile usr "$USER_BODY" \
      --argjson schema "$SCHEMA" \
      '{
        _backend: "claude",
        model: $model,
        format: $schema,
        messages: [
          { role: "system", content: $sys },
          { role: "user",   content: $usr }
        ]
      }')
    printf '%s' "$REQ" > "$DUMP_PATH"
    ls -1t "$DUMP_DIR"/*.json 2>/dev/null | tail -n +21 | xargs -r rm -f --
    log "calling-claude --bare dump=$DUMP_PATH"
    START_CALL=$(date +%s)
    # --bare: skip hooks/plugin sync/auto-memory; auth strictly via
    # --settings's apiKeyHelper (OAuth not read by --bare). We pass an
    # ISOLATED settings file (bin/bare-settings.json) containing only
    # apiKeyHelper — putting apiKeyHelper in the main settings.json
    # breaks normal sessions because OAuth-flow tries to use the
    # helper's output as a static API key.
    # --json-schema enforces the same {verdict, violations} shape Ollama uses.
    # User body is fed via stdin to avoid argv overflow on large transcripts.
    OUT=$(timeout 240 claude --bare --print \
      --output-format json --input-format text \
      --settings "$HOME/.claude/bin/bare-settings.json" \
      --append-system-prompt "$(cat "$RULES")" \
      --json-schema "$SCHEMA" \
      --allow-dangerously-skip-permissions \
      < "$USER_BODY" 2>/dev/null)
    EXIT_CALL=$?
    ELAPSED_CALL=$(( $(date +%s) - START_CALL ))
    rm -f "$USER_BODY"
    if [ $EXIT_CALL -ne 0 ] || [ -z "$OUT" ]; then
      log "exit reason=claude-call-failed exit=$EXIT_CALL elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: claude --bare failed (exit=%s) — review skipped.\n' "$EXIT_CALL"
      exit 0
    fi
    # claude --output-format=json wraps the response: {type, result, ...}
    # On error (no API key, etc.), is_error=true and result is a human msg.
    IS_ERROR=$(echo "$OUT" | jq -r '.is_error // false' 2>/dev/null)
    if [ "$IS_ERROR" = "true" ]; then
      ERR_MSG=$(echo "$OUT" | jq -r '.result // empty' 2>/dev/null)
      log "exit reason=claude-api-error err=\"$ERR_MSG\" elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: claude --bare error: %s — review skipped.\n' "$ERR_MSG"
      exit 0
    fi
    # When --json-schema is used, the schema-conformant payload lands in
    # .structured_output (a JSON object), NOT .result (which is the
    # plain-text response and is empty in that case). Re-encode it as a
    # JSON string so the downstream verdict parser (which expects a JSON
    # blob it can parse) treats both backends the same.
    RAW=$(echo "$OUT" | jq -r '
      if (.structured_output | type) == "object" then (.structured_output | tojson)
      else (.result // "") end
    ' 2>/dev/null)
    if [ -z "$RAW" ] || [ "$RAW" = "null" ]; then
      log "exit reason=empty-claude-result elapsed=${ELAPSED_CALL}s"
      exit 0
    fi
    ;;
esac

# Strip optional markdown code fences that some models (gemma4) emit even
# when Ollama's format-schema is supplied. Accept ``` or ```json fences.
RESULT=$(printf '%s' "$RAW" | sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d' | sed -E '/^[[:space:]]*```[[:space:]]*$/d')

VERDICT=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)

# Shingle filter: drop violations whose `rule` text shares < threshold
# 3-gram overlap with the rule corpus. Catches paraphrase-fabricated
# rules that don't quote real rule fragments. If all violations drop
# the filter flips verdict to "pass" automatically. See lib/reviewer-filter.sh.
if [ "$VERDICT" = "fail" ]; then
  FILTERED=$(filter_violations "$RESULT")
  if [ -n "$FILTERED" ] && [ "$FILTERED" != "$RESULT" ]; then
    RESULT="$FILTERED"
    VERDICT=$(printf '%s' "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)
  fi
fi

# Persist the last result so stop-gate.sh can append it to the next stop's
# summary-to-print.md. Markdown so it concatenates cleanly.
LAST_RESULT="$STATE_DIR/last-result.md"
NOW_HUMAN=$(date -u +'%Y-%m-%d %H:%M:%S UTC')
write_last_result() {
  local verdict=$1; local body=$2
  {
    echo
    echo "---"
    echo
    echo "## External-reviewer result"
    echo
    echo "- Reviewed at: $NOW_HUMAN"
    echo "- Elapsed: ${ELAPSED_CALL}s"
    echo "- Model: $MODEL"
    echo "- Verdict: $verdict"
    if [ -n "$body" ]; then
      echo
      echo "$body"
    fi
  } > "$LAST_RESULT"
}

# Append to per-session history file for false-positive monitoring.
# Fields: unix_epoch | elapsed | backend | model | verdict | violation_count
HISTORY_FILE="$STATE_DIR/history.jsonl"
VN=$(printf '%s' "$RESULT" | jq '.violations | length' 2>/dev/null || echo 0)
printf '{"ts":%s,"elapsed":%s,"backend":"%s","model":"%s","verdict":"%s","violations":%s}\n' \
  "$(date +%s)" "$ELAPSED_CALL" "$REVIEWER_BACKEND" "$MODEL" "${VERDICT:-malformed}" "$VN" \
  >> "$HISTORY_FILE" 2>/dev/null || true

# Snapshot HEAD and assistant tool_use count at this reviewer call. stop-gate.sh
# uses these on stop_hook_active=true to decide whether to silent-allow (no
# meaningful work since last review) or fall through and re-run the reviewer
# (substantial recovery work happened, must re-verify).
git -C "$HOME/.claude" rev-parse HEAD > "$STATE_DIR/last_reviewer_head" 2>/dev/null || true
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  jq -s '[.[]
          | select(.type == "assistant")
          | .message.content
          | if type == "array" then [.[] | select(.type == "tool_use")] else [] end
         ] | flatten | length' "$TRANSCRIPT" > "$STATE_DIR/last_reviewer_tool_count" 2>/dev/null || true
fi

case "$VERDICT" in
  pass)
    log "verdict=pass elapsed=${ELAPSED_CALL}s — streak reset"
    rm -f "$STREAK_FILE"
    write_last_result "pass" ""
    exit 0
    ;;
  fail)
    STREAK=$(( $(cat "$STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$STREAK" > "$STREAK_FILE"
    log "verdict=fail streak=$STREAK elapsed=${ELAPSED_CALL}s — blocking stop"

    VIOLATIONS=$(printf '%s' "$RESULT" | jq -r '.violations[] | "- \(.rule)\n  evidence: \(.evidence)"' 2>/dev/null)
    if [ -z "$VIOLATIONS" ]; then
      VIOLATIONS="(reviewer returned fail without enumerating violations)"
    fi
    write_last_result "fail (streak=$STREAK)" "$VIOLATIONS"

    # Synchronous block: hold the stop until verdict=pass. The agent must
    # actually fix the violations (or the user must touch $BYPASS_MARKER) —
    # an asyncRewake-style nudge is too easy to ignore with acknowledgement
    # prose that doesn't fix anything.
    REASON=$(printf 'External compliance reviewer (%s via %s) flagged violations in your last turn.\n\nViolations:\n%s\n\nFix in this turn (re-do the work correctly). Streak=%d. To override: touch %s\n' "$MODEL" "$REVIEWER_BACKEND" "$VIOLATIONS" "$STREAK" "$BYPASS_MARKER")
    jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'
    exit 0
    ;;
  *)
    # Malformed verdict — fail-open with diagnostic.
    log "exit reason=malformed-verdict raw=\"$(printf '%s' "$RAW" | head -c 200)\""
    exit 0
    ;;
esac
