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
# After parse: $REVIEWER_BACKEND in {ollama, opencode-zen, claude}, plus
# backend-specific host/model when applicable. See reviewer-backend.sh.
# MODEL/OLLAMA_HOST are NOT set here — each case branch derives them
# from its backend-specific REVIEWER_* var to avoid cross-backend bleed.
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
  TS_LIST=$(jq -s --arg synth_re "$SYNTHETIC_USER_TAG_RE" '
    [ to_entries[]
      | select(.value.type == "user"
               and ((.value.message.content | type) == "string")
               and ((.value.isMeta // false) | not)
               and ((.value.origin.kind // "") == "")
               and ((.value.message.content | tostring | test($synth_re; "i")) | not))
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
      --arg synth_re "$SYNTHETIC_USER_TAG_RE" \
      '
      . as $all
      | (
          [ $all | to_entries[]
              | select(.value.type == "user"
                       and ((.value.message.content | type) == "string")
                       and ((.value.isMeta // false) | not)
                       and ((.value.origin.kind // "") == "")
                       and ((.value.message.content | tostring | test($synth_re; "i")) | not))
              | .key
          ] | last // 0
        ) as $lts
      | def is_real_user($e):
          $e.type == "user"
          and ($e.message.content | type) == "string"
          and (($e.isMeta // false) | not)
          and (($e.origin.kind // "") == "")
          and (($e.message.content | tostring | test($synth_re; "i")) | not);
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
  # Skip GIT_STATUS / DIFF when the session is an ATE orchestrator (CLAUDE_ROLE
  # set — stop-gate.sh exempts non-orchestrator ATE roles before reviewer runs,
  # so any non-empty role here is lead/coordinator with active teammates) or
  # when ECI is active (subagent-driven implementation in flight). In both
  # cases the working tree is expected to be transiently dirty from peer/
  # subagent edits not yet landed, and flagging it as a Git rule violation
  # blocked every stop while teammates worked.
  ECI_MARKER="$HOME/.cache/claude-proof/$SESSION_ID/eci_active"
  if [ -n "${CLAUDE_ROLE:-}" ] || [ -e "$ECI_MARKER" ]; then
    SKIP_REASON=""
    [ -n "${CLAUDE_ROLE:-}" ] && SKIP_REASON="CLAUDE_ROLE=${CLAUDE_ROLE} (orchestrator session — teammates may be mid-edit)"
    [ -e "$ECI_MARKER" ] && SKIP_REASON="${SKIP_REASON:+$SKIP_REASON; }ECI active (subagent-driven implementation in flight)"
    echo "## GIT_STATUS"
    echo "(skipped: $SKIP_REASON. Working-tree state is transient until teammates/subagents commit.)"
    echo
    echo "## DIFF"
    echo "(skipped: same reason as GIT_STATUS.)"
    echo
  else
    echo "## GIT_STATUS"
    echo "Working-tree state at this stop. Per stop-checklist Git rule, uncommitted code = violation."
    echo
    seen_dirs=""
    # Iterate only the project the agent is working in. Including $HOME/.claude
    # unconditionally would surface ~/.claude's own uncommitted state (the user's
    # separate hooks-config repo) when the agent is working in any other project,
    # spuriously blocking stops on dirty state in an unrelated tree.
    for repo_dir in "$PWD"; do
      # $PWD unset → skip GIT_STATUS entirely (better than re-leaking ~/.claude
      # state which is exactly what this scoping fix avoids).
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

    # Same scoping rationale as the GIT_STATUS loop above: pull commits
    # and diff from the project the agent is working in, not unconditionally
    # from ~/.claude.
    # Skip DIFF entirely when $PWD unset; do NOT fall back to ~/.claude.
    REVIEW_REPO="$PWD"
    if [ -n "$REVIEW_REPO" ]; then
      echo "## DIFF"
      git -C "$REVIEW_REPO" log --pretty=format:"%H %s" -5 2>/dev/null
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
        if [ -n "$PH" ] && git -C "$REVIEW_REPO" cat-file -e "${PH}^{commit}" 2>/dev/null; then
          DIFF_BASE="$PH"
        fi
      fi
      # Bound diff bytes: a huge diff (large refactor, generated files) blows
      # past Ollama's num_ctx and causes timeouts. Probe size first; if over
      # threshold, omit the diff body entirely — commit titles above are
      # enough context, and a mid-line truncation is misleading.
      DIFF_RAW=$(git -C "$REVIEW_REPO" diff "$DIFF_BASE..HEAD" 2>/dev/null)
      DIFF_BYTES=$(printf %s "$DIFF_RAW" | wc -c | awk '{print $1}')
      DIFF_LIMIT=4096
      if [ "$DIFF_BYTES" -gt "$DIFF_LIMIT" ]; then
        printf '(diff body omitted: %s bytes raw, exceeds %s-byte budget — see commit titles above)\n' \
          "$DIFF_BYTES" "$DIFF_LIMIT"
      else
        printf '%s' "$DIFF_RAW"
      fi
      echo
    fi
  fi

  # BACKGROUND_PROCESSES — always shown (orthogonal to GIT_STATUS skip cases).
  # Per stop-checklist, agent must clean up unneeded stragglers from this
  # session. Filter to user-owned processes started in the last hour so the
  # snapshot stays focused on this-session candidates instead of long-lived
  # intended services. Cap rows to keep prompt size bounded.
  echo "## BACKGROUND_PROCESSES"
  echo "User-owned processes started within the last hour (etimes <= 3600). Per stop-checklist Background-processes rule: kill anything spawned this session that the user does not need running. Long-lived intended services are out of scope."
  echo
  # Exclude administrative process trees that are NEVER leftover work:
  #   ~/.claude/hooks/*    — the hook scripts running right now
  #   ~/.claude/bin/*      — skill-flow helpers (eci-active, skip-stop)
  #   bin/claude           — the claude CLI itself + subagent claude procs
  #   share/claude         — claude install path
  #   npm exec / node …mcp — MCP servers spawned by claude (administrative)
  #   ps/awk/jq/grep/cat   — short-lived utilities of this pipeline itself
  # Plus the hook's own pid + ppid (defense in depth).
  ps -eo pid,ppid,etimes,stat,cmd -u "$USER" --no-headers 2>/dev/null \
    | awk -v me="$$" -v me_pp="$PPID" '
        $3 <= 3600 \
        && $0 !~ /\.claude\/hooks\// \
        && $0 !~ /\.claude\/bin\// \
        && $0 !~ /bin\/claude(\s|$)/ \
        && $0 !~ /share\/claude\// \
        && $0 !~ /(npm exec|context7-mcp|node .*\/mcp)/ \
        && $5 !~ /^(ps|awk|jq|grep|cat|head|tail|sed|cut|sort|tr)$/ \
        && $1 != me && $2 != me \
        && $1 != me_pp && $2 != me_pp' \
    | head -30
  echo

  # TASKS — per tasks_visible_complete (MEMORY.md): the agent must not stop
  # with open tasks unless explicitly handed off. Reviewer needs to see the
  # current list to enforce this. Numeric sort (lex order would put 10
  # before 2). Always shown — unlike GIT_STATUS, the open-tasks list is not
  # made transient by teammate/subagent work.
  #
  # Four-bucket categorization (subject-prefix convention + file mtime):
  #   Active    — no prefix, mtime ≤ 24h. Must resolve this turn.
  #   Stale     — no prefix, mtime > 24h. Hygiene flag (confirm or cancel).
  #   Deferred  — subject starts with "[DEFERRED ...". User-accepted carry-over.
  #   Blocked   — subject starts with "[BLOCKED on ...". Waiting on input/external.
  #
  # Per-bucket caps prevent a runaway list blowing the body budget. Active
  # gets the largest cap (it is the load-bearing bucket); the omitted-count
  # is always printed loudly so a hidden Active overflow cannot pass review.
  #
  # KNOWN LIMITATION: file mtime is updated on every TaskUpdate, so a stale
  # task that receives a no-op TaskUpdate appears fresh and falls out of the
  # Stale bucket. Fixing this would require an audit log we do not have.
  # The tasks_visible_complete rule still applies via the Active bucket —
  # an untouched stale Active task remains an Active violation.
  echo "## TASKS"
  echo "Open tasks for this session, grouped into four buckets. Per the reviewer rule, ONLY tasks under '### Active' count toward the tasks_visible_complete violation. Stale is a hygiene reminder; Deferred and Blocked are legitimate carry-over."
  echo
  TASK_DIR="$HOME/.claude/tasks/$SESSION_ID"
  if [ -d "$TASK_DIR" ]; then
    TASK_FILES=$(ls -1 "$TASK_DIR"/*.json 2>/dev/null \
      | awk -F/ '{n=$NF; sub(/\.json$/,"",n); print n"\t"$0}' \
      | sort -n -k1,1 \
      | cut -f2-)
    NOW_EPOCH=$(date +%s)
    STALE_SECS=86400  # 24h
    ACTIVE_LINES=""
    STALE_LINES=""
    DEFERRED_LINES=""
    BLOCKED_LINES=""
    if [ -n "$TASK_FILES" ]; then
      while IFS= read -r tf; do
        [ -z "$tf" ] && continue
        # Emit "<id>\t<status>\t<subject>" only for non-completed/canceled.
        REC=$(jq -r 'select((.status // "") != "completed" and (.status // "") != "canceled")
                     | "\(.id)\t\(.status)\t\(.subject)"' "$tf" 2>/dev/null)
        [ -z "$REC" ] && continue
        TID=$(printf '%s' "$REC" | cut -f1)
        TST=$(printf '%s' "$REC" | cut -f2)
        TSUB=$(printf '%s' "$REC" | cut -f3-)
        LINE="- #${TID} [${TST}] ${TSUB}"
        case "$TSUB" in
          "[DEFERRED"*"]"*|"[DEFERRED "*)
            DEFERRED_LINES="${DEFERRED_LINES}${LINE}"$'\n' ;;
          "[BLOCKED on "*"]"*|"[BLOCKED "*)
            BLOCKED_LINES="${BLOCKED_LINES}${LINE}"$'\n' ;;
          *)
            MT=$(stat -c '%Y' "$tf" 2>/dev/null || echo 0)
            AGE=$(( NOW_EPOCH - MT ))
            if [ "$AGE" -gt "$STALE_SECS" ]; then
              # Format idle interval as Nd Nh (rounded down).
              IDLE_D=$(( AGE / 86400 ))
              IDLE_H=$(( (AGE % 86400) / 3600 ))
              STALE_LINES="${STALE_LINES}${LINE} (idle ${IDLE_D}d ${IDLE_H}h)"$'\n'
            else
              ACTIVE_LINES="${ACTIVE_LINES}${LINE}"$'\n'
            fi
            ;;
        esac
      done <<<"$TASK_FILES"
    fi
    # render_bucket <name> <header-suffix> <cap> <lines>
    # Prints the "### <name> ..." subsection with at most <cap> lines and
    # an "(N more omitted)" tail when the bucket overflows. Empty bucket
    # prints nothing — caller decides the all-empty fallback.
    render_bucket() {
      local name=$1 suffix=$2 cap=$3 lines=$4
      [ -z "$lines" ] && return 0
      local total
      total=$(printf '%s' "$lines" | grep -c '^- ' || true)
      printf '### %s %s\n' "$name" "$suffix"
      printf '%s' "$lines" | head -n "$cap"
      if [ "${total:-0}" -gt "$cap" ]; then
        printf '… (%d more %s tasks omitted)\n' "$(( total - cap ))" "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
      fi
      printf '\n'
    }
    if [ -z "$ACTIVE_LINES" ] && [ -z "$STALE_LINES" ] \
       && [ -z "$DEFERRED_LINES" ] && [ -z "$BLOCKED_LINES" ]; then
      echo "(no open tasks recorded)"
    else
      # Active gets cap=30 (load-bearing — reviewer must see overflow loudly).
      # Other buckets get cap=15.
      render_bucket "Active"   "(must resolve this turn or relabel as Deferred/Blocked)" 30 "$ACTIVE_LINES"
      render_bucket "Stale"    "(idle > 24h with no prefix — confirm or cancel)"          15 "$STALE_LINES"
      render_bucket "Deferred" "(user-accepted carry-over — not a violation)"             15 "$DEFERRED_LINES"
      render_bucket "Blocked"  "(waiting on input/external — not a violation)"            15 "$BLOCKED_LINES"
    fi
  else
    echo "(task store not present for this session)"
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

# archive_dump <content>
# Writes <content> to $DUMP_PATH (global) and rotates $DUMP_DIR (global)
# to keep at most 20 files. Both globals must be set before calling.
archive_dump() {
  printf '%s' "$1" > "$DUMP_PATH"
  ls -1t "$DUMP_DIR"/*.json 2>/dev/null | tail -n +21 | xargs -r rm -f --
}

case "$REVIEWER_BACKEND" in
  ollama)
    MODEL="$REVIEWER_OLLAMA_MODEL"
    OLLAMA_HOST="$REVIEWER_OLLAMA_HOST"
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
    archive_dump "$REQ"
    log "calling-ollama model=$MODEL host=$OLLAMA_HOST dump=$DUMP_PATH"
    START_CALL=$(date +%s)
    RESPONSE=$(timeout 240 curl -s --max-time 240 -X POST "$OLLAMA_HOST/api/chat" \
      -H 'Content-Type: application/json' \
      --data-binary "@$DUMP_PATH" \
      -w '\n%{http_code}' 2>/dev/null)
    EXIT_CALL=$?
    ELAPSED_CALL=$(( $(date +%s) - START_CALL ))
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    OUT=$(echo "$RESPONSE" | sed '$d')
    rm -f "$USER_BODY"
    if [ $EXIT_CALL -ne 0 ] || [ -z "$OUT" ]; then
      log "exit reason=call-failed backend=ollama exit=$EXIT_CALL elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: ollama call failed (exit=%s, host=%s) — review skipped.\n' "$EXIT_CALL" "$OLLAMA_HOST"
      exit 0
    fi
    case "$HTTP_CODE" in
      2*) ;;
      *)
        log "exit reason=ollama-http-error backend=ollama http=$HTTP_CODE elapsed=${ELAPSED_CALL}s"
        printf 'system-prompt-reviewer: ollama HTTP %s — review skipped.\n' "$HTTP_CODE"
        exit 0
        ;;
    esac
    OLLAMA_ERR=$(echo "$OUT" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$OLLAMA_ERR" ]; then
      log "exit reason=backend-error backend=ollama err=\"$OLLAMA_ERR\" elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: ollama error: %s — review skipped.\n' "$OLLAMA_ERR"
      exit 0
    fi
    RAW=$(echo "$OUT" | jq -r '.message.content // empty' 2>/dev/null)
    [ -z "$RAW" ] && { log "exit reason=empty-message-content backend=ollama elapsed=${ELAPSED_CALL}s"; exit 0; }
    ;;

  opencode-zen)
    MODEL="$REVIEWER_OPENCODE_MODEL"
    # OpenAI-compatible /zen/v1/chat/completions. Anonymous today; honors
    # OPENCODE_ZEN_API_KEY when set so a future cutover to authenticated
    # access is zero-config. The _backend field is archived in the dump
    # but stripped before POST — strict OpenAI-compat servers reject
    # unknown top-level keys.
    # max_tokens=8192: matches REVIEWER_DEFAULT_MAX_TOKENS in lib/reviewer-call.sh.
    # The lib is not sourced by the production hook (avoids extra I/O at every Stop);
    # change both literally if you tune this value.
    REQ=$(jq -n \
      --arg model "$MODEL" \
      --rawfile sys "$RULES" \
      --rawfile usr "$USER_BODY" \
      --argjson schema "$SCHEMA" \
      '{
        _backend: "opencode-zen",
        model: $model,
        stream: false,
        max_tokens: 8192,
        max_completion_tokens: 8192,
        temperature: 0.3,
        top_p: 0.9,
        seed: 42,
        response_format: {
          type: "json_schema",
          json_schema: { name: "reviewer_verdict", schema: $schema, strict: false }
        },
        messages: [
          { role: "system", content: $sys },
          { role: "user",   content: $usr }
        ]
      }')
    archive_dump "$REQ"
    log "calling-opencode-zen model=$MODEL host=$REVIEWER_OPENCODE_HOST dump=$DUMP_PATH"
    # Wire body strips $._backend (forensic-only field). Written to a
    # separate temp file so curl can stream it via @file (symmetry with
    # the ollama branch — safer with large bodies than inline shell var).
    SEND_PATH=$(mktemp)
    echo "$REQ" | jq 'del(._backend)' > "$SEND_PATH"
    # ${arr[@]+...} guard makes empty-array expansion safe on bash ≤ 4.3 under set -u; modern bash doesn't need it but the defensive form is cheap.
    OPENCODE_AUTH_HEADER=()
    if [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
      OPENCODE_AUTH_HEADER=(-H "Authorization: Bearer $OPENCODE_ZEN_API_KEY")
    fi
    START_CALL=$(date +%s)
    RESPONSE=$(timeout 240 curl -s --max-time 240 -X POST "$REVIEWER_OPENCODE_HOST/zen/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      ${OPENCODE_AUTH_HEADER[@]+"${OPENCODE_AUTH_HEADER[@]}"} \
      --data-binary "@$SEND_PATH" \
      -w '\n%{http_code}' 2>/dev/null)
    EXIT_CALL=$?
    ELAPSED_CALL=$(( $(date +%s) - START_CALL ))
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    OUT=$(echo "$RESPONSE" | sed '$d')
    rm -f "$USER_BODY" "$SEND_PATH"
    if [ $EXIT_CALL -ne 0 ] || [ -z "$OUT" ]; then
      log "exit reason=call-failed backend=opencode-zen exit=$EXIT_CALL elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: opencode call failed (exit=%s, host=%s) — review skipped.\n' "$EXIT_CALL" "$REVIEWER_OPENCODE_HOST"
      exit 0
    fi
    case "$HTTP_CODE" in
      2*) ;;
      *)
        log "exit reason=opencode-http-error backend=opencode-zen http=$HTTP_CODE elapsed=${ELAPSED_CALL}s"
        printf 'system-prompt-reviewer: opencode HTTP %s — review skipped.\n' "$HTTP_CODE"
        exit 0
        ;;
    esac
    OPENCODE_ERR=$(echo "$OUT" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$OPENCODE_ERR" ]; then
      log "exit reason=backend-error backend=opencode-zen err=\"$OPENCODE_ERR\" elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: opencode error: %s — review skipped.\n' "$OPENCODE_ERR"
      exit 0
    fi
    RAW=$(echo "$OUT" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    [ -z "$RAW" ] && { log "exit reason=empty-opencode-content backend=opencode-zen elapsed=${ELAPSED_CALL}s"; exit 0; }
    ;;

  github-copilot)
    MODEL="$REVIEWER_COPILOT_MODEL"
    # shellcheck source=lib/copilot-token.sh
    . "$HOOK_DIR/lib/copilot-token.sh"
    if ! copilot_get_bearer || [ -z "${COPILOT_BEARER:-}" ]; then
      log "exit reason=copilot-token-fetch-failed backend=github-copilot"
      printf 'system-prompt-reviewer: github-copilot token fetch failed — review skipped.\n'
      rm -f "$USER_BODY"
      exit 0
    fi
    REQ=$(jq -n \
      --arg model "$MODEL" \
      --rawfile sys "$RULES" \
      --rawfile usr "$USER_BODY" \
      --argjson schema "$SCHEMA" \
      '{
        _backend: "github-copilot",
        model: $model,
        stream: false,
        max_tokens: 8192,
        temperature: 0.3,
        top_p: 0.9,
        seed: 42,
        tool_choice: {type:"function",function:{name:"emit_verdict"}},
        tools: [{
          type: "function",
          function: {
            name: "emit_verdict",
            description: "Emit the reviewer verdict.",
            parameters: $schema
          }
        }],
        messages: [
          { role: "system", content: $sys },
          { role: "user",   content: $usr }
        ]
      }')
    archive_dump "$REQ"
    log "calling-github-copilot model=$MODEL dump=$DUMP_PATH"
    SEND_PATH=$(mktemp)
    echo "$REQ" | jq 'del(._backend)' > "$SEND_PATH"
    START_CALL=$(date +%s)
    RESPONSE=$(timeout 240 curl -s --max-time 240 \
      -X POST 'https://api.githubcopilot.com/chat/completions' \
      -H "Authorization: Bearer $COPILOT_BEARER" \
      -H 'content-type: application/json' \
      -H "copilot-integration-id: $COPILOT_INTEGRATION_ID" \
      -H "editor-version: $COPILOT_EDITOR_VERSION" \
      -H "editor-plugin-version: $COPILOT_PLUGIN_VERSION" \
      -H "user-agent: $COPILOT_USER_AGENT" \
      -H 'openai-intent: conversation-panel' \
      -H "x-github-api-version: $COPILOT_API_VERSION" \
      -H "x-request-id: $(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)" \
      -H "x-vscode-user-agent-library-version: $COPILOT_USER_AGENT_LIB" \
      --data-binary "@$SEND_PATH" \
      -w '\n%{http_code}' 2>/dev/null)
    EXIT_CALL=$?
    ELAPSED_CALL=$(( $(date +%s) - START_CALL ))
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    OUT=$(echo "$RESPONSE" | sed '$d')
    rm -f "$USER_BODY" "$SEND_PATH"
    if [ $EXIT_CALL -ne 0 ] || [ -z "$OUT" ]; then
      log "exit reason=call-failed backend=github-copilot exit=$EXIT_CALL elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: github-copilot call failed (exit=%s) — review skipped.\n' "$EXIT_CALL"
      exit 0
    fi
    case "$HTTP_CODE" in
      2*) ;;
      *)
        log "exit reason=copilot-http-error backend=github-copilot http=$HTTP_CODE elapsed=${ELAPSED_CALL}s"
        printf 'system-prompt-reviewer: github-copilot HTTP %s — review skipped.\n' "$HTTP_CODE"
        exit 0
        ;;
    esac
    COPILOT_ERR=$(echo "$OUT" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$COPILOT_ERR" ]; then
      log "exit reason=backend-error backend=github-copilot err=\"$COPILOT_ERR\" elapsed=${ELAPSED_CALL}s"
      printf 'system-prompt-reviewer: github-copilot error: %s — review skipped.\n' "$COPILOT_ERR"
      exit 0
    fi
    RAW=$(echo "$OUT" | jq -r '
      (.choices[0].message.tool_calls[0].function.arguments // empty) as $args
      | if ($args | length) > 0 then $args
        else (.choices[0].message.content // empty) end
    ' 2>/dev/null)
    [ -z "$RAW" ] && { log "exit reason=empty-copilot-content backend=github-copilot elapsed=${ELAPSED_CALL}s"; exit 0; }
    ;;

  claude)
    MODEL="claude-bare"
    # claude --bare reads system prompt + user body via dedicated flags,
    # not as JSON-API messages. Archive a representation of the inputs in
    # the same shape so the dump remains comparable across backends.
    REQ=$(jq -n \
      --arg model "$MODEL" \
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
    archive_dump "$REQ"
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

# Dedupe violations by normalized rule text. Defense in depth: the prompt
# already asks for one-per-rule, but local models occasionally still emit
# duplicates when several CURRENT_TURN entries trip the same rule.
# First-seen preservation (NOT unique_by — that re-sorts) keeps the most
# representative evidence the model placed first. Fail-safe: jq error
# returns empty → keep $RESULT unchanged.
if [ -n "$RESULT" ]; then
  DEDUPED=$(printf '%s' "$RESULT" | jq '
    # Normalize key: strip punctuation FIRST (otherwise punct between
    # words leaves doubled spaces that break the collapse), then collapse
    # whitespace, then trim leading/trailing.
    def _norm: ascii_downcase
      | gsub("[[:punct:]]"; "")
      | gsub("\\s+"; " ")
      | sub("^ "; "")
      | sub(" $"; "");
    .violations |= ((. // []) | (
      reduce .[] as $v ([];
        ($v.rule | _norm) as $k
        | if any(.[]; (.rule | _norm) == $k)
          then . else . + [$v] end)))
  ' 2>/dev/null)
  if [ -n "$DEDUPED" ]; then RESULT="$DEDUPED"; fi
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
# NOTE: this stays anchored to $HOME/.claude (NOT $REVIEW_REPO) because
# stop-gate.sh's reciprocal comparison reads HEAD from $HOME/.claude as well.
# Both sides must reference the same repo for the SHA equality check to be
# meaningful. The GIT_STATUS / DIFF sections above were rescoped to $PWD to
# stop ~/.claude's dirty state from leaking into other projects' reviews;
# this snapshot semantic is unrelated to that bug.
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
    rm -f "$STREAK_FILE" "$STATE_DIR/recent_violations.jsonl"
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

    # Task-tracking correction recipe: when a violation mentions tasks,
    # surface the live Active task list + the exact TaskUpdate calls that
    # would resolve a desync (work actually done, accepted out-of-scope,
    # waiting on input). The reviewer can only see the task store; if
    # tracking is wrong, the agent corrects it via TaskUpdate and re-stops.
    TASK_CORRECTIONS=""
    if printf '%s' "$VIOLATIONS" | grep -qiE '\btasks?\b|tasks_visible_complete'; then
      TASK_DIR_C="$HOME/.claude/tasks/$SESSION_ID"
      if [ -d "$TASK_DIR_C" ]; then
        ACTIVE_NOW=$(ls -1 "$TASK_DIR_C"/*.json 2>/dev/null \
          | awk -F/ '{n=$NF; sub(/\.json$/,"",n); print n"\t"$0}' \
          | sort -n -k1,1 \
          | cut -f2- \
          | while IFS= read -r tf; do
              [ -z "$tf" ] && continue
              jq -r '
                select((.status // "") != "completed" and (.status // "") != "canceled")
                | .subject as $s
                | select(($s | test("^\\[(DEFERRED|BLOCKED)"; "i")) | not)
                | "  - #\(.id) [\(.status)] \(.subject)"
              ' "$tf" 2>/dev/null
            done)
        if [ -n "$ACTIVE_NOW" ]; then
          TASK_CORRECTIONS=$(printf '\n=== Task-tracking corrections ===\nIf any flagged task is actually done/deferred/blocked, fix the tracking and re-stop:\n  Completed: TaskUpdate(taskId=N, status="completed")\n  Deferred:  TaskUpdate(taskId=N, subject="[DEFERRED <reason>] <subject>")\n  Blocked:   TaskUpdate(taskId=N, subject="[BLOCKED on <thing>] <subject>")\nCurrently Active (resolve, defer, block, or continue working):\n%s\n' "$ACTIVE_NOW")
        fi
      fi
    fi
    write_last_result "fail (streak=$STREAK)" "$VIOLATIONS$TASK_CORRECTIONS"

    # Synchronous block: hold the stop until verdict=pass. The agent must
    # actually fix the violations (or the user must touch $BYPASS_MARKER) —
    # an asyncRewake-style nudge is too easy to ignore with acknowledgement
    # prose that doesn't fix anything.
    #
    # Bypass-hint policy: surface the escape hatch ONLY when the reviewer
    # is consistently obstructing the SAME rule, not when it's just stacking
    # different fix-able issues across consecutive fails. Concretely:
    #   - Append normalized rule set to recent_violations.jsonl per fail.
    #   - At streak >= 3, intersect the last 3 fail entries.
    #   - If the intersection is non-empty → reviewer genuinely stuck on
    #     those rules → show bypass hint citing them.
    #   - If empty → agent is making progress (different rules each fail) →
    #     no bypass hint, keep working.
    RECENT_FILE="$STATE_DIR/recent_violations.jsonl"
    NORMALIZED_RULES=$(printf '%s' "$RESULT" | jq -c '
      def _norm: ascii_downcase
        | gsub("[[:punct:]]"; "")
        | gsub("\\s+"; " ")
        | sub("^ "; "")
        | sub(" $"; "");
      [.violations[].rule | _norm] | unique
    ' 2>/dev/null)
    if [ -n "$NORMALIZED_RULES" ] && [ "$NORMALIZED_RULES" != "null" ]; then
      printf '%s\n' "$NORMALIZED_RULES" >> "$RECENT_FILE"
      tail -n 5 "$RECENT_FILE" > "$RECENT_FILE.tmp" 2>/dev/null && mv "$RECENT_FILE.tmp" "$RECENT_FILE"
    fi
    PERSISTENT_RULES=""
    if [ "$STREAK" -ge 3 ] && [ -s "$RECENT_FILE" ]; then
      PERSISTENT_RULES=$(tail -n 3 "$RECENT_FILE" | jq -s -r '
        if length < 3 then []
        else (.[0]) as $first
          | reduce .[1:][] as $next ($first;
              map(select(. as $r | $next | index($r))))
        end
        | .[]
      ' 2>/dev/null)
    fi
    if [ -n "$PERSISTENT_RULES" ]; then
      PERSIST_LIST=$(printf '%s\n' "$PERSISTENT_RULES" | sed 's/^/  - /')
      OVERRIDE_HINT=$(printf '\n\nBypass available — reviewer has been re-blocking on the SAME rule(s) across all 3 last fails (genuinely stuck, not flagging fix-able mistakes):\n%s\n\nIf you have verified these are reviewer errors (not real violations the agent could correct): touch %s' "$PERSIST_LIST" "$BYPASS_MARKER")
    else
      OVERRIDE_HINT=""
    fi
    REASON=$(printf 'External compliance reviewer (%s via %s) flagged violations in your last turn.\n\nViolations:\n%s%s\n\nPRIMARY ACTION: fix the violations this turn. Streak=%d.%s\n' "$MODEL" "$REVIEWER_BACKEND" "$VIOLATIONS" "$TASK_CORRECTIONS" "$STREAK" "$OVERRIDE_HINT")
    jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'
    exit 0
    ;;
  *)
    # Malformed verdict — fail-open with diagnostic.
    log "exit reason=malformed-verdict raw=\"$(printf '%s' "$RAW" | head -c 200)\""
    exit 0
    ;;
esac
