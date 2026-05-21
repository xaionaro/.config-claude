#!/bin/bash
# Stop hook: gates Claude from stopping until verification proof is written.
# Command hook — blocks first stop attempt, sends Claude back to verify,
# then allows on second attempt when proof file exists.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOME/.claude/hooks/lib/claude-proof-state.sh"
. "$HOME/.claude/hooks/lib/claude-tmp.sh"
claude_init_tmp || true
claude_install_fail_open_trap stop-gate
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$CWD" ] && CWD="$PWD"
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r 'if (.transcript_path? | type) == "string" then .transcript_path else "" end')

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  exit 0
fi

# Ephemeral / side-channel sessions have no transcript_path. They are
# read-only context-gathering threads; proof accumulation is the parent
# session's responsibility. Skip the gate entirely.
if [ -z "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Subagent exemption. Two real subagent shapes observed in live hook
# input (captured 2026-05-06):
#   1. Agent-tool inline spawn — input has .agent_id (UUID).
#   2. claude --agent-type top-level spawn — input has .agent_type
#      (e.g. "general-purpose") plus .permission_mode and
#      .last_assistant_message; NO .agent_id.
# Both are subagents whose work is verified by the orchestrator that
# spawned them; neither walks the proof checklist. Treat either signal
# as exemption. Mirrors hooks/eci-active-gate.sh:39.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
if [ -n "$AGENT_ID" ] || [ -n "$AGENT_TYPE" ]; then
  exit 0
fi

# Skip stop hook for ALL subordinate team roles — only the team lead
# (and main-thread sessions with no role) walk the proof checklist.
#
# Subordinates (coordinator, snitch, explorer, designer, reviewer,
# executor, verifier, QA, brainstormer, test-*, eci-implementer, etc.)
# report verdicts via messaging or commit their work directly; the
# lead's stop-gate is the single accountability point. Adding new role
# names to skill rosters does NOT require updating this gate — anything
# other than empty/lead is exempt.
case "${CLAUDE_ROLE:-}" in
  ""|lead|team-lead|teamlead) ;;  # gated: main thread + team lead
  *) exit 0 ;;                     # exempt: every other subordinate role
esac

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
PROOF="$PROOF_DIR/proof.md"

# Scope loop detection per session. (AGENT_ID exempted above, so
# this branch always uses the unsuffixed timestamps file.)
TIMESTAMPS="$PROOF_DIR/stop_timestamps"

# Track stop hook invocations for loop detection
mkdir -p "$PROOF_DIR"
echo "$(date +%s)" >> "$TIMESTAMPS"
# Count invocations in last 5 minutes
NOW=$(date +%s)
CUTOFF=$((NOW - 300))
RECENT_COUNT=0
if [ -f "$TIMESTAMPS" ]; then
  RECENT_COUNT=$(awk -v cutoff="$CUTOFF" '$1 >= cutoff' "$TIMESTAMPS" | wc -l)
  # Prune old entries
  awk -v cutoff="$CUTOFF" '$1 >= cutoff' "$TIMESTAMPS" > "$TIMESTAMPS.tmp" && mv "$TIMESTAMPS.tmp" "$TIMESTAMPS"
fi

LOOP_REMINDER=""
if [ "$RECENT_COUNT" -ge 5 ]; then
  LOOP_REMINDER=" LOOP DETECTED ($RECENT_COUNT hits in 5min). Flow: (1) hook blocks first stop, (2) read \$PROOF_DIR/instructions.md or ~/.claude/hooks/stop-checklist.md, (3) write proof to $PROOF, (4) stop again. Identify which step is failing; do not retry the same approach."
fi

block() {
  jq -n --arg reason "$1$LOOP_REMINDER" '{"decision": "block", "reason": $reason}'
  exit 0
}

# --- repo identity + secret-scan helpers (ported from codex) -----------
# Used by:
#   - per-repo history-key canonicalisation (freshness oracle)
#   - run_secret_scan (gitleaks worktree + commit-history scan)
# Hard-block policy: gitleaks missing → return 2 → block (parity with
# codex stop-gate.sh:144-147,720-728). This differs from soft-skip.

hash_string() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

canonical_existing_path() {
  local path="$1"
  local dir base canonical_dir

  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    return
  fi

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$dir" ]; then
    canonical_dir="$( (cd "$dir" 2>/dev/null && pwd -P) || printf '%s' "$dir" )"
    printf '%s/%s\n' "$canonical_dir" "$base"
  else
    printf '%s\n' "$path"
  fi
}

git_common_dir() {
  local repo="$1"
  local common top

  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    canonical_existing_path "$common"
    return
  fi

  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
  case "$common" in
    /*) canonical_existing_path "$common" ;;
    *) canonical_existing_path "${top:-$repo}/$common" ;;
  esac
}

repo_identity() {
  local repo="$1"
  local top common

  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$repo")"
    top="$(canonical_existing_path "$top")"
    common="$(git_common_dir "$repo")"
    printf 'git:%s:%s\n' "$top" "$common"
  else
    printf 'nogit:%s\n' "$(claude_canonical_cwd "$repo")"
  fi
}

format_gitleaks_findings() {
  local report="$1"

  jq -r '
    .[] |
    "\(.File // "<unknown>"):\((.StartLine // "?") | tostring) \(.RuleID // "unknown") \(.Description // "possible secret")"
  ' "$report" 2>/dev/null
}

run_gitleaks_command() {
  local report="$1"
  shift
  local out rc

  out=$("$@" 2>&1)
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      printf '%s\n' "$out" >"${report}.err"
      return 2
      ;;
  esac
}

run_secret_scan() {
  local repo="$1"
  local baseline="$2"
  local proof_dir="$3"
  local report="$proof_dir/gitleaks-report.json"
  local findings="$proof_dir/gitleaks-findings.txt"
  local worktree_report="$proof_dir/gitleaks-worktree-report.json"
  local commit_report="$proof_dir/gitleaks-commit-report.json"
  local tmp_index base findings_count worktree_dirty commit_changed scan_rc errors=""
  local -a reports

  rm -f "$report" "$findings" "$worktree_report" "$commit_report" \
    "${worktree_report}.err" "${commit_report}.err"

  if ! command -v gitleaks >/dev/null 2>&1; then
    printf '%s\n' "gitleaks not found on PATH" >"$findings"
    return 2
  fi

  worktree_dirty=false
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]; then
    worktree_dirty=true
  fi

  commit_changed=false
  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null &&
      ! git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null; then
      commit_changed=true
    fi
  fi

  if [ "$worktree_dirty" = "true" ]; then
    tmp_index=$(mktemp "$proof_dir/gitleaks-index.XXXXXX")
    rm -f "$tmp_index"
    if GIT_INDEX_FILE="$tmp_index" git -C "$repo" read-tree HEAD >/dev/null 2>&1; then
      GIT_INDEX_FILE="$tmp_index" git -C "$repo" add -N -- . >/dev/null 2>&1 || true
      scan_rc=0
      GIT_INDEX_FILE="$tmp_index" run_gitleaks_command "$worktree_report" \
        gitleaks protect --source "$repo" --redact --no-banner --log-level error \
          --report-format json --report-path "$worktree_report" || scan_rc=$?
      case "$scan_rc" in
        0|1)
          [ -f "$worktree_report" ] || errors="$errors worktree"
          ;;
        *) errors="$errors worktree" ;;
      esac
    else
      printf '%s\n' "could not prepare temporary git index for worktree scan" >"${worktree_report}.err"
      errors="$errors worktree"
    fi
    rm -f "$tmp_index"
  fi

  if [ "$commit_changed" = "true" ]; then
    scan_rc=0
    run_gitleaks_command "$commit_report" \
      gitleaks detect --source "$repo" --log-opts "$base..HEAD" --redact --no-banner \
        --log-level error --report-format json --report-path "$commit_report" || scan_rc=$?
    case "$scan_rc" in
      0|1)
        [ -f "$commit_report" ] || errors="$errors commits"
        ;;
      *) errors="$errors commits" ;;
    esac
  fi

  reports=()
  [ -f "$worktree_report" ] && reports+=("$worktree_report")
  [ -f "$commit_report" ] && reports+=("$commit_report")
  if [ "${#reports[@]}" -gt 0 ]; then
    jq -s 'add' "${reports[@]}" >"$report" 2>/dev/null || cp "${reports[0]}" "$report"
  else
    printf '[]\n' >"$report"
  fi

  if [ -n "$errors" ]; then
    {
      printf '%s\n' "gitleaks failed for:$errors"
      [ -s "${worktree_report}.err" ] && cat "${worktree_report}.err"
      [ -s "${commit_report}.err" ] && cat "${commit_report}.err"
    } >"$findings"
    return 2
  fi

  findings_count=$(jq 'length' "$report" 2>/dev/null || printf '0')
  if [ "${findings_count:-0}" -gt 0 ]; then
    format_gitleaks_findings "$report" >"$findings"
    return 1
  fi

  rm -f "$findings" "$worktree_report" "$commit_report"
  return 0
}
# -----------------------------------------------------------------------

# --- ECI / skip / ATE / activity-empty ordering ------------------------
# Mirror of codex stop-gate.sh:396-426. Order matters: ECI is the strongest
# claim on the session, skip-stop is a deliberate bypass (only honored
# after the ECI check), ATE blocks unless awaiting_user/closed, and the
# activity-empty fast-continue lets stops through when there is genuinely
# nothing in flight.

# 1. ECI active → hard block, unless teammate-pending marker is set.
#    Marker touched by hooks/eci-pending-set.sh on Agent/SendMessage/Monitor;
#    cleared by hooks/eci-pending-clear.sh on next user/teammate message.
#    Lets the orchestrator idle-wait without spinning the stop loop.
ECI_ACTIVE=$(claude_existing_state_file eci eci_active "$SESSION_ID" "$CWD" 2>/dev/null || true)
if [ -n "$ECI_ACTIVE" ] && [ -f "$ECI_ACTIVE" ]; then
  if [ -f "$PROOF_DIR/eci_teammate_pending" ]; then
    exit 0
  fi
  claude_note_state_session_id "$ECI_ACTIVE" "$SESSION_ID" || true
  block "Stop blocked: ECI active and no teammate awaited (marker \$PROOF_DIR/eci_teammate_pending absent). If a teammate IS still working (marker may have been cleared by a recent user prompt or message), verify via TaskList/TaskGet or Agent status, then arm it with \`touch \$PROOF_DIR/eci_teammate_pending\` so idle stops release until the reply. Otherwise continue the ECI task — Agent/SendMessage/Monitor dispatch auto-arms the marker. If genuinely stuck, surface the blocker via AskUserQuestion (do not stop to ask). Disengage only on clean-pass or user-closed via ~/.claude/bin/eci-active off <disengage-report.md>."
fi

# 2. Skip-stop bypass (relocated): only honored after the ECI check.
# Skill-controlled bypass: any skill that knows the main thread never
# implements code can touch this marker on entry and remove it on exit.
# See ~/.claude/bin/skip-stop for the helper that manages it.
#
# Freshness gate: marker must have been touched within the last 60 minutes.
# Stops the leak class where a prior session's marker (e.g. ATE skill that
# crashed before `skip-stop off`) silently bypasses verification in a
# later, unrelated session reusing the same session-id directory.
if [ -f "$PROOF_DIR/skip_stop" ] && [ -n "$(find "$PROOF_DIR/skip_stop" -mmin -60 -print 2>/dev/null)" ]; then
  exit 0
fi

# 3. ATE active → block unless phase is awaiting_user or closed.
ATE_ACTIVE=$(claude_existing_state_file ate ate_active "$SESSION_ID" "$CWD" 2>/dev/null || true)
if [ -n "$ATE_ACTIVE" ] && [ -f "$ATE_ACTIVE" ]; then
  ATE_PHASE=$(claude_state_value "$ATE_ACTIVE" phase || true)
  case "$ATE_PHASE" in
    awaiting_user|closed) ;;
    *)
      claude_note_state_session_id "$ATE_ACTIVE" "$SESSION_ID" || true
      block "ATE coordinator is active. Continue the workstream, hand off, or close it via the lifecycle. Phase: ${ATE_PHASE:-<unset>}."
      ;;
  esac
fi

# 4. Activity-empty fast-continue. If there is no proof, no git change, no
# task_active marker, no activity markers, and no Claude-tool activity in
# the transcript since the last real user message → allow stop.
#
# Read-only tools (Read, Glob, Grep, WebSearch, ToolSearch, Skill, WebFetch)
# are intentionally excluded from the activity regex below — they don't
# count as work. The regex only references Claude tool names; foreign
# harness tool names are intentionally absent.
transcript_has_activity_since_last_user() {
  local transcript="$1"

  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  jq -e -s '
    def response_item_type($e):
      $e.payload.type // $e.payload.item.type // "";
    def content_of($e):
      $e.message.content // $e.payload.message.content // $e.payload.item.content // $e.payload.content // "";
    def event_role($e):
      if $e.type == "user" then "user"
      elif $e.type == "assistant" then "assistant"
      elif $e.type == "response_item" then
        if response_item_type($e) == "function_call" then "assistant"
        elif response_item_type($e) == "function_call_output" then "tool_result"
        else ($e.payload.role // $e.payload.item.role // "") end
      elif $e.type == "message" then ($e.role // "")
      else "" end;
    def is_real_user($e):
      event_role($e) == "user"
      and ((content_of($e) | type) == "string")
      and ((content_of($e) | test("^[[:space:]]*<(hook_prompt|subagent_notification|turn_aborted)"; "i")) | not)
      and (($e.isMeta // $e.message.isMeta // false) | not);
    def call_records($e):
      if $e.type == "response_item" and response_item_type($e) == "function_call" then
        [{
          name: ($e.payload.name // $e.payload.item.name // ""),
          arguments: (($e.payload.arguments // $e.payload.item.arguments // "") | tostring)
        }]
      else
        (content_of($e) as $c
        | if ($c | type) == "array" then
          [$c[] | select(.type == "tool_use" or .type == "function_call")
            | {name: (.name // ""), arguments: ((.input // .arguments // "") | tostring)}]
        else [] end)
      end;
    def active_call($c):
      (($c.name // "") | test("(^|\\.)(Bash|Edit|Write|MultiEdit|Agent|SendMessage|Monitor|TaskCreate|TaskUpdate|TaskStop|TaskGet|TaskList|TaskOutput|EnterWorktree|ExitWorktree|EnterPlanMode|ExitPlanMode|RemoteTrigger|PushNotification|TeamCreate|TeamDelete|CronCreate|CronDelete)$"))
      or
      (($c.name // "") == "multi_tool_use.parallel"
        and (($c.arguments // "") | test("functions\\.(Bash|Edit|Write|MultiEdit|Agent|SendMessage)")));
    . as $all
    | ([ $all | to_entries[] | select(is_real_user(.value)) | .key ] | last // -1) as $last_user
    | $last_user >= 0 and
      ([ $all | to_entries[]
        | select(.key > $last_user and event_role(.value) == "assistant")
        | call_records(.value)[]
        | select(active_call(.)) ] | length) > 0
  ' "$transcript" >/dev/null 2>&1
}

ACTIVITY_FOUND=""
for _act_marker in shell edit subagent; do
  _f=$(claude_existing_state_file activity "$_act_marker" "$SESSION_ID" "$CWD" 2>/dev/null || true)
  if [ -n "$_f" ]; then
    ACTIVITY_FOUND="$ACTIVITY_FOUND $_act_marker"
  fi
done

TASK_ACTIVE=$(claude_existing_state_file active-task task_active "$SESSION_ID" "$CWD" 2>/dev/null || true)

GIT_CHANGE_FOUND=""
if [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]; then
  GIT_CHANGE_FOUND=1
fi

if [ ! -f "$PROOF" ] && \
   [ -z "$GIT_CHANGE_FOUND" ] && \
   [ -z "$TASK_ACTIVE" ] && \
   [ -z "$ACTIVITY_FOUND" ] && \
   ! transcript_has_activity_since_last_user "$TRANSCRIPT_PATH"; then
  exit 0
fi
# -----------------------------------------------------------------------

# --- Reviewer-backed gate ----------------------------------------------
# When the reviewer backend is reachable, it is THE gate. On verdict=fail
# the reviewer's own block JSON is forwarded so the agent must correct.
# On verdict=pass the result is shown to the user and the stop is allowed.
# When the backend is unreachable (Ollama down, or claude unconfigured),
# we fall through to the proof.md verification protocol below.
#
# Backend selection is via CLAUDE_STOP_REVIEWER (parsed by shared helper).
. "$HOOK_DIR/reviewer-backend.sh"
parse_reviewer_env || REVIEWER_BACKEND=""

REVIEWER_BYPASS="$HOME/.cache/claude-proof/reviewer/$SESSION_ID/bypass"

# Reachability probe: ollama needs an HTTP probe to /api/tags; opencode-zen
# probes /zen/v1/models; claude is always considered "reachable" — the
# reviewer hook itself reports auth/connectivity failures and falls open
# with a diagnostic.
REVIEWER_REACHABLE=0
case "$REVIEWER_BACKEND" in
  ollama)
    if timeout 3 curl -sf "$REVIEWER_OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
      REVIEWER_REACHABLE=1
    fi
    ;;
  opencode-zen)
    if timeout 3 curl -sf "$REVIEWER_OPENCODE_HOST/zen/v1/models" >/dev/null 2>&1; then
      REVIEWER_REACHABLE=1
    fi
    ;;
  claude)
    REVIEWER_REACHABLE=1
    ;;
esac

if [ ! -f "$REVIEWER_BYPASS" ] && [ "$REVIEWER_REACHABLE" = "1" ]; then
  # Second-pass stop: by default, agent already printed the result, allow the
  # stop. Reset and re-run the reviewer when substantial work has landed since
  # the last reviewer call — closes the post-block silent-allow hole.
  # Reset triggers: HEAD advanced in ~/.claude, OR ≥N new assistant tool_use
  # blocks in the transcript (N defaults to 5; CLAUDE_REVIEWER_RESET_TOOL_CALLS
  # overrides).
  if [ "$STOP_ACTIVE" = "true" ]; then
    RESET=0
    REVIEWER_STATE="$HOME/.cache/claude-proof/reviewer/$SESSION_ID"
    if [ -f "$REVIEWER_STATE/last_reviewer_head" ]; then
      LAST_HEAD=$(cat "$REVIEWER_STATE/last_reviewer_head" 2>/dev/null)
      CUR_HEAD=$(git -C "$HOME/.claude" rev-parse HEAD 2>/dev/null)
      if [ -n "$CUR_HEAD" ] && [ -n "$LAST_HEAD" ] && [ "$CUR_HEAD" != "$LAST_HEAD" ]; then
        RESET=1
      fi
    fi
    if [ "$RESET" = "0" ] && [ -f "$REVIEWER_STATE/last_reviewer_tool_count" ]; then
      LAST_COUNT=$(cat "$REVIEWER_STATE/last_reviewer_tool_count" 2>/dev/null || echo 0)
      TRANSCRIPT=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" -type f 2>/dev/null | head -1)
      if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
        CUR_COUNT=$(jq -s '[.[]
                            | select(.type == "assistant")
                            | .message.content
                            | if type == "array" then [.[] | select(.type == "tool_use")] else [] end
                           ] | flatten | length' "$TRANSCRIPT" 2>/dev/null || echo 0)
        THRESHOLD="${CLAUDE_REVIEWER_RESET_TOOL_CALLS:-5}"
        case "$LAST_COUNT$CUR_COUNT$THRESHOLD" in
          *[!0-9]*) ;;
          *)
            DELTA=$(( CUR_COUNT - LAST_COUNT ))
            if [ "$DELTA" -ge "$THRESHOLD" ]; then
              RESET=1
            fi
            ;;
        esac
      fi
    fi
    if [ "$RESET" = "0" ]; then
      # Ledger-preserving cleanup: keep project-understanding*.md and
      # high_level_log*.md across stop cycles (both mandated by the
      # maintaining-context-ledger skill), clear everything else
      # (proof.md, baseline_head, etc.).
      [ -d "$PROOF_DIR" ] && find "$PROOF_DIR" -mindepth 1 -maxdepth 1 ! \( -name 'project-understanding*.md' -o -name 'high_level_log*.md' \) -exec rm -rf {} + 2>/dev/null || true
      exit 0
    fi
    # Fall through to reviewer call below.
  fi

  # Run reviewer synchronously, feeding it the exact stdin we received.
  REVIEWER_OUT=$(printf '%s' "$INPUT" | "$HOOK_DIR/system-prompt-reviewer.sh" 2>/dev/null || true)

  # verdict=fail → reviewer emits its own decision:block JSON. Forward it
  # so Claude Code blocks and the agent must correct the violations.
  if echo "$REVIEWER_OUT" | jq -e '.decision == "block"' > /dev/null 2>&1; then
    echo "$REVIEWER_OUT"
    exit 0
  fi

  # verdict=pass → show the reviewer's result to the user (with timestamp,
  # elapsed, model) and block once so the agent prints it. The second
  # stop attempt (handled above) then releases.
  REVIEWER_LAST="$HOME/.cache/claude-proof/reviewer/$SESSION_ID/last-result.md"
  if [ -f "$REVIEWER_LAST" ]; then
    mkdir -p "$PROOF_DIR"
    cp "$REVIEWER_LAST" "$PROOF_DIR/summary-to-print.md"
    block "Checking stop criteria."
  fi

  # Reviewer fell open without writing last-result.md (rare: ollama errored
  # mid-call). Allow the stop rather than wedge the agent.
  exit 0
fi
# -----------------------------------------------------------------------

# 1. Proof exists → validate content, save summary for Claude to print, then cleanup
if [ -f "$PROOF" ]; then
  # Skip validation for fast-exit proofs (trivial changes, mid-conversation, etc.)
  if ! grep -qi "fast.exit\|fast exit" "$PROOF"; then
    # Validate that proof contains required adversarial self-critique sections.
    # An empty or rubber-stamped proof ("LGTM") must not pass.
    MISSING=""
    grep -qi "claim.inventory\|claim inventory" "$PROOF" || MISSING="$MISSING Claim-inventory"
    grep -qi "pre.mortem\|pre mortem\|premortem" "$PROOF" || MISSING="$MISSING Pre-mortem"
    grep -qi "adversarial.critique\|adversarial critique\|objection" "$PROOF" || MISSING="$MISSING Adversarial-critique"
    grep -qi "verified\|likely\|uncertain\|confidence" "$PROOF" || MISSING="$MISSING Confidence-calibration"
    grep -qi "rule.compliance\|rule compliance\|self.audit\|self audit" "$PROOF" || MISSING="$MISSING Rule-compliance-self-audit"

    if [ -n "$MISSING" ]; then
      block "Proof file is missing required sections:$MISSING. Re-read instructions.md and write a complete proof."
    fi

    # Evidence-grammar check for the Rule-compliance self-audit section.
    # awk parses the section into per-violation blocks, enforces:
    #   - extraction terminates only on same-or-higher heading level (closes sub-heading bypass);
    #   - each Violation: must have at least one correction marker within its own block;
    #   - blocker: must carry non-empty input: AND command: sub-fields; placeholder command values rejected;
    #   - mutual exclusion between clean-scan (Form A) and Violation blocks (Form B);
    #   - clean-scan must include "CLAUDE.md" and at least three comma-separated sources.
    # Shell then verifies emitted commit hashes via git cat-file.
    AUDIT_HASHES=$(mktemp)
    AUDIT_ERRS=$(awk -v hashfile="$AUDIT_HASHES" '
      BEGIN { in_audit=0; opener=0; vn=0; has_corr=0; blk_open=0; blk_inp=0; blk_cmd=0; scan="" }

      /^#+[[:space:]]*Rule-compliance/ && !in_audit {
        in_audit=1
        match($0, /^#+/); opener=RLENGTH
        next
      }

      in_audit && /^#+[[:space:]]/ {
        match($0, /^#+/)
        if (RLENGTH <= opener) { in_audit=0 }
      }

      !in_audit { next }

      /^[[:space:]]*clean-scan:[[:space:]]+/ { scan = $0 }

      /^[[:space:]]*[*_-]*[[:space:]]*Violation:/ {
        if (vn > 0) {
          if (!has_corr) print "  - violation #" vn ": no correction marker"
          if (blk_open && (!blk_inp || !blk_cmd)) print "  - violation #" vn ": blocker missing non-empty input: or command:"
        }
        vn++; has_corr=0; blk_open=0; blk_inp=0; blk_cmd=0
      }

      vn > 0 && /^[[:space:]]*commit:[[:space:]]+[0-9a-f]{7,40}/ {
        has_corr=1
        match($0, /[0-9a-f]{7,40}/)
        print substr($0, RSTART, RLENGTH) > hashfile
      }

      vn > 0 && /^[[:space:]]*```(edit|grep|restate)/ { has_corr=1 }

      vn > 0 && /^[[:space:]]*blocker:/ { has_corr=1; blk_open=1 }
      vn > 0 && blk_open && /^[[:space:]]*input:[[:space:]]+[^[:space:]]+/ { blk_inp=1 }
      vn > 0 && blk_open && /^[[:space:]]*command:[[:space:]]+[^[:space:]]+/ {
        if ($0 ~ /command:[[:space:]]+(TBD|tbd|later|TODO|todo|fix[[:space:]]+later|figure[[:space:]]+out)[[:space:]]*$/) {
          print "  - violation #" vn ": blocker command: is a placeholder"
        } else {
          blk_cmd=1
        }
      }

      END {
        if (vn > 0) {
          if (!has_corr) print "  - violation #" vn ": no correction marker"
          if (blk_open && (!blk_inp || !blk_cmd)) print "  - violation #" vn ": blocker missing non-empty input: or command:"
        }
        if (vn == 0 && scan == "") print "  - empty audit: provide clean-scan: <3+ sources> or one or more Violation: blocks"
        if (vn > 0 && scan != "")  print "  - mutual-exclusion: both clean-scan and Violation blocks present; use one form"
        if (vn == 0 && scan != "") {
          if (scan !~ /CLAUDE\.md/) print "  - clean-scan: must include CLAUDE.md among the sources"
          sl = scan; sub(/^[[:space:]]*clean-scan:[[:space:]]+/, "", sl)
          n = split(sl, p, ","); ne = 0
          for (i=1; i<=n; i++) { g=p[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", g); if (length(g) > 0) ne++ }
          if (ne < 3) print "  - clean-scan: need at least three non-empty sources"
        }
      }
    ' "$PROOF")

    # Verify any claimed commit hashes exist (in either $PWD or ~/.claude).
    BAD_COMMITS=""
    if [ -s "$AUDIT_HASHES" ]; then
      while read -r H; do
        git cat-file -e "${H}^{commit}" 2>/dev/null || \
          git -C "$HOME/.claude" cat-file -e "${H}^{commit}" 2>/dev/null || \
          BAD_COMMITS="$BAD_COMMITS $H"
      done < "$AUDIT_HASHES"
    fi
    rm -f "$AUDIT_HASHES"

    if [ -n "$AUDIT_ERRS" ]; then
      block "Rule-compliance self-audit grammar failures:"$'\n'"$AUDIT_ERRS"
    fi
    if [ -n "$BAD_COMMITS" ]; then
      block "Rule-compliance self-audit cites commits unreachable in the current repo or ~/.claude:$BAD_COMMITS"
    fi

    # --- freshness oracle --------------------------------------------------
    # Prevents carrying an audit verbatim across stop cycles. Persists outside
    # $PROOF_DIR so state survives the STOP_ACTIVE=true cleanup at line 179.
    # Reject session ids containing path-traversal characters before using as filename.
    case "$SESSION_ID" in
      *[!A-Za-z0-9_-]*|"") SESSION_ID_SAFE="" ;;
      *) SESSION_ID_SAFE="$SESSION_ID" ;;
    esac
    if [ -z "$SESSION_ID_SAFE" ]; then
      : # skip freshness oracle when session id is unsafe
    else
    # Per-repo history-key canonicalisation: scope freshness state to the
    # actual git work tree (or canonical cwd for non-git roots) so two
    # sessions in different repos cannot collide. Layout:
    #   ~/.cache/claude-proof/history/<sha-of-repo-id>/<session>.log
    HISTORY_IDENTITY="$(repo_identity "$CWD")"
    HISTORY_KEY="$(hash_string "$HISTORY_IDENTITY")"
    HISTORY_DIR="$HOME/.cache/claude-proof/history/$HISTORY_KEY"
    mkdir -p "$HISTORY_DIR"
    printf '%s\n' "$HISTORY_IDENTITY" >"$HISTORY_DIR/repo_identity"
    HISTORY_FILE="$HISTORY_DIR/${SESSION_ID_SAFE}.log"

    # Fingerprint the audit section bytes.
    AUDIT_SECTION=$(awk '
      /^#+[[:space:]]*Rule-compliance/ && !in_a { in_a=1; match($0,/^#+/); lvl=RLENGTH; print; next }
      in_a && /^#+[[:space:]]/ { match($0,/^#+/); if (RLENGTH<=lvl) in_a=0 }
      in_a { print }
    ' "$PROOF")
    AUDIT_SHA=$(printf %s "$AUDIT_SECTION" | sha256sum | cut -d' ' -f1)
    CUR_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    WORKDIR_DIRTY=0
    [ -n "$(git status --porcelain 2>/dev/null)" ] && WORKDIR_DIRTY=1

    if [ -f "$HISTORY_FILE" ]; then
      LAST_LINE=$(tail -n1 "$HISTORY_FILE")
      PREV_SHA=$(printf %s "$LAST_LINE" | cut -d'|' -f1)
      PREV_HEAD=$(printf %s "$LAST_LINE" | cut -d'|' -f2)

      if [ "$AUDIT_SHA" = "$PREV_SHA" ]; then
        if [ -n "$CUR_HEAD" ] && [ -n "$PREV_HEAD" ] && [ "$CUR_HEAD" != "$PREV_HEAD" ]; then
          block "Rule-compliance self-audit is byte-identical to the prior stop, but HEAD advanced ($PREV_HEAD → $CUR_HEAD). Re-scan against the current state and write an audit that reflects it."
        fi
        if [ "$WORKDIR_DIRTY" = "1" ]; then
          block "Rule-compliance self-audit is byte-identical to the prior stop, but the working tree has uncommitted changes. Re-scan against the current state."
        fi
        # Unchanged repo + identical audit: require a re-scan gesture naming
        # ≥3 sources (same bar as clean-scan), with CLAUDE.md among them.
        # Check only within the audit section (avoid rescan: lines elsewhere bypassing the gate).
        # `|| true`: under `set -euo pipefail`, a no-match grep returns 1
        # and pipefail propagates that to the assignment, exiting the script
        # silently before the byte-identical-audit block can fire. The empty
        # fallback is the intended behavior — no rescanned line means
        # RESCAN_LINE stays empty and the block at the next check fires.
        RESCAN_LINE=$(printf %s "$AUDIT_SECTION" | grep -iE '^[[:space:]]*rescanned:[[:space:]]+' | head -n1 || true)
        RESCAN_OK=0
        if [ -n "$RESCAN_LINE" ]; then
          RESCAN_OK=$(printf %s "$RESCAN_LINE" | awk '
            {
              sub(/^[[:space:]]*[rR]escanned:[[:space:]]+/, "")
              n=split($0, p, ","); ne=0; has_claude=0
              for (i=1; i<=n; i++) { g=p[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", g); if (length(g) > 0) ne++; if (g ~ /CLAUDE\.md/) has_claude=1 }
              print (ne >= 3 && has_claude) ? 1 : 0
            }')
        fi
        if [ "$RESCAN_OK" != "1" ]; then
          block "Rule-compliance self-audit is byte-identical to the prior stop. Repo unchanged — a repeat finding is acceptable, but the audit section must include 'rescanned: CLAUDE.md, <source2>, <source3>, ... — <UTC timestamp>' naming at least three sources re-read."
        fi
      fi

      # When HEAD advanced, cited commits must include one reachable from the
      # PREV_HEAD → HEAD range. Check only within the audit section.
      if [ -n "$CUR_HEAD" ] && [ -n "$PREV_HEAD" ] && [ "$CUR_HEAD" != "$PREV_HEAD" ]; then
        if printf %s "$AUDIT_SECTION" | grep -qE '^[[:space:]]*commit:[[:space:]]+[0-9a-f]{7,40}'; then
          RANGE_OK=0
          for H in $(printf %s "$AUDIT_SECTION" | grep -oE '^[[:space:]]*commit:[[:space:]]+[0-9a-f]{7,40}' | awk '{print $NF}'); do
            if [ "$H" != "$PREV_HEAD" ] && git merge-base --is-ancestor "$PREV_HEAD" "$H" 2>/dev/null; then
              RANGE_OK=1; break
            fi
          done
          if [ "$RANGE_OK" = "0" ]; then
            block "Rule-compliance self-audit cites only pre-existing commits. HEAD advanced since the previous stop — cite at least one commit from the new range inside the audit section, or explain why new work produced no violations."
          fi
        fi
      fi
    fi

    # Record audit fingerprint + HEAD for the next stop cycle.
    # Overwrite (not append) so the log never grows beyond one line — only the
    # last entry is ever read (tail -n1). Bounded by SESSION_ID cardinality.
    printf '%s|%s|%s\n' "$AUDIT_SHA" "$CUR_HEAD" "$(date -u +%s)" > "$HISTORY_FILE"
    fi
    # -----------------------------------------------------------------------
  fi

  SUMMARY="$PROOF_DIR/summary-to-print.md"
  cp "$PROOF" "$SUMMARY"
  # Only append the reviewer result when an LLM backend is configured
  # (REVIEWER_BACKEND non-empty). When CLAUDE_STOP_REVIEWER is unset,
  # the reviewer hook never ran this turn, so last-result.md is from a
  # prior turn and would display a misleading stale timestamp.
  REVIEWER_LAST="$HOME/.cache/claude-proof/reviewer/$SESSION_ID/last-result.md"
  if [ -n "${REVIEWER_BACKEND:-}" ] && [ -f "$REVIEWER_LAST" ]; then
    cat "$REVIEWER_LAST" >> "$SUMMARY"
  fi
  rm -f "$PROOF" "$PROOF_DIR/baseline_head"

  # Activity-marker cleanup at proof acceptance: clear session-scoped
  # activity markers and task_active so the next stop sees a clean slate.
  # Mirrors codex stop-gate.sh:662-665. Cwd-scoped markers are also cleared
  # so the activity-empty fast-continue at the top of the next invocation
  # is not falsely tripped by stale markers.
  _act_session_dir=$(claude_session_state_dir activity "$SESSION_ID" 2>/dev/null || true)
  [ -n "$_act_session_dir" ] && rm -rf "$_act_session_dir" 2>/dev/null || true
  _act_cwd_dir=$(claude_cwd_state_dir activity "$CWD" 2>/dev/null || true)
  [ -n "$_act_cwd_dir" ] && rm -rf "$_act_cwd_dir" 2>/dev/null || true
  _task_session_dir=$(claude_session_state_dir active-task "$SESSION_ID" 2>/dev/null || true)
  [ -n "$_task_session_dir" ] && rm -f "$_task_session_dir/task_active" 2>/dev/null || true
  _task_cwd_dir=$(claude_cwd_state_dir active-task "$CWD" 2>/dev/null || true)
  [ -n "$_task_cwd_dir" ] && rm -f "$_task_cwd_dir/task_active" 2>/dev/null || true

  # After proof accepted: capture git status. If dirty, block stop and write
  # summary so the agent must commit owned changes or state unrelated blockers
  # before stopping. Mirrors codex stop-gate.sh:667-674.
  if [ -d "$PWD/.git" ] || git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty="$(git -C "$PWD" status --porcelain 2>/dev/null)"
    if [ -n "$dirty" ]; then
      {
        printf 'git status at proof acceptance — %s\n' "$(date -u +%FT%TZ)"
        printf 'cwd: %s\n\n' "$PWD"
        git -C "$PWD" status --porcelain
      } > "$PROOF_DIR/git-status-at-accept.txt"
      block "Verification proof accepted, but git state is still dirty. Read $PROOF_DIR/git-status-at-accept.txt; relay relevant results, commit owned completed changes or state unrelated blockers, then stop."
    fi
  fi

  block "Checking stop criteria."
fi

# 2. Already sent back (proof printed or no proof written) → allow + cleanup
if [ "$STOP_ACTIVE" = "true" ]; then
  # Ledger-preserving cleanup: keep project-understanding*.md and
  # high_level_log*.md across stop cycles (both mandated by the
  # maintaining-context-ledger skill), clear everything else.
  [ -d "$PROOF_DIR" ] && find "$PROOF_DIR" -mindepth 1 -maxdepth 1 ! \( -name 'project-understanding*.md' -o -name 'high_level_log*.md' \) -exec rm -rf {} + 2>/dev/null || true

  # Activity-marker cleanup mirrors the proof-acceptance path so the next
  # stop sees a clean slate when the agent is genuinely idle.
  _act_session_dir=$(claude_session_state_dir activity "$SESSION_ID" 2>/dev/null || true)
  [ -n "$_act_session_dir" ] && rm -rf "$_act_session_dir" 2>/dev/null || true
  _act_cwd_dir=$(claude_cwd_state_dir activity "$CWD" 2>/dev/null || true)
  [ -n "$_act_cwd_dir" ] && rm -rf "$_act_cwd_dir" 2>/dev/null || true
  _task_session_dir=$(claude_session_state_dir active-task "$SESSION_ID" 2>/dev/null || true)
  [ -n "$_task_session_dir" ] && rm -f "$_task_session_dir/task_active" 2>/dev/null || true
  _task_cwd_dir=$(claude_cwd_state_dir active-task "$CWD" 2>/dev/null || true)
  [ -n "$_task_cwd_dir" ] && rm -f "$_task_cwd_dir/task_active" 2>/dev/null || true

  exit 0
fi

# 3. Check for code changes
BASELINE_FILE="$PROOF_DIR/baseline_head"
BASELINE_HEAD=""
if [ -f "$BASELINE_FILE" ]; then
  BASELINE_HEAD=$(cat "$BASELINE_FILE")
fi

CODE_CHANGES=$(
  {
    git diff --name-only 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    [ -n "$BASELINE_HEAD" ] && git diff "$BASELINE_HEAD"..HEAD --name-only 2>/dev/null
  } |
    sort -u |
    grep -v -E '\.(json|yaml|yml|toml|md|txt|env|lock|ini|cfg|conf|csv|svg|png|jpg|gif|ico)$' |
    head -1
) || true

# 4. No code changes → require checklist review (not full verification)
if [ -z "$CODE_CHANGES" ]; then
  INSTRUCTIONS="$PROOF_DIR/instructions.md"
  mkdir -p "$PROOF_DIR"
  cat > "$INSTRUCTIONS" <<INSTEOF
STOP BLOCKED — Check against the acceptance criteria before stopping.
NEVER end your turn to ask a question. Use the AskUserQuestion tool instead — always.

Proof file: $PROOF

No code changes — full verification not required. Still check the acceptance criteria.

1. Read the checklist at ~/.claude/hooks/stop-checklist.md
2. For each applicable item, verify it was followed.
3. If any item was violated → fix it before stopping.
4. Write to the proof file:
   - "fast-exit: checklist review (no code changes)" on the first line
   - Which checklist items applied and their pass/fail status
   - Any issues found and how they were resolved
INSTEOF
  block "Checking stop criteria."
fi

# 5. Code changed, no proof → run secret scan, then block and send verification protocol.
#
# Secret scan placement mirrors codex stop-gate.sh:715-728: we are in the
# "changes exist, no proof yet" branch, so we run gitleaks on both the
# dirty worktree (via gitleaks protect on a temp index) and the new
# commit range (baseline..HEAD via gitleaks detect).
#
# Hard-block policy (parity with codex :144-147,720-728): if gitleaks is
# missing from PATH, we block with a "install gitleaks" message rather
# than soft-skip. Required dependency, advertised in CLAUDE.md.
SECRET_SCAN_RC=0
run_secret_scan "$CWD" "$BASELINE_FILE" "$PROOF_DIR" || SECRET_SCAN_RC=$?
case "$SECRET_SCAN_RC" in
  0) ;;
  1)
    block "Automated secret scan found possible secrets. Read $PROOF_DIR/gitleaks-findings.txt, remove or explicitly remediate them, then stop again."
    ;;
  *)
    if [ -s "$PROOF_DIR/gitleaks-findings.txt" ] && \
       grep -q "gitleaks not found on PATH" "$PROOF_DIR/gitleaks-findings.txt"; then
      block "Automated secret scan could not complete because gitleaks is not on PATH. Install gitleaks (apt install gitleaks or equivalent) or document divergence. See ~/.claude/CLAUDE.md # Environment for the dependency note."
    else
      block "Automated secret scan could not complete. Read $PROOF_DIR/gitleaks-findings.txt, fix the scanner failure, then stop again."
    fi
    ;;
esac

#    Write a session-specific instructions file with the proof path baked in
INSTRUCTIONS="$PROOF_DIR/instructions.md"
mkdir -p "$PROOF_DIR"
sed \
  -e "s|{{PROOF}}|$PROOF|g" \
  -e "s|{{PROOF_DIR}}|$PROOF_DIR|g" \
  "$HOOK_DIR/stop-verification.md" > "$INSTRUCTIONS"
block "Checking stop criteria."
