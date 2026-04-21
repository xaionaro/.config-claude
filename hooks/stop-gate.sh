#!/bin/bash
# Stop hook: gates Claude from stopping until verification proof is written.
# Command hook — blocks first stop attempt, sends Claude back to verify,
# then allows on second attempt when proof file exists.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active')

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  exit 0
fi

# Skip stop hook for roles that don't write code
case "${CLAUDE_ROLE:-}" in
  lead|coordinator|snitch|explorer|brainstormer|designer|reviewer|test-designer|test-reviewer|verifier|qa)
    exit 0 ;;
esac

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
PROOF="$PROOF_DIR/proof.md"

# Skill-controlled bypass: any skill that knows the main thread never
# implements code can touch this marker on entry and remove it on exit.
# See ~/.claude/bin/skip-stop for the helper that manages it.
if [ -f "$PROOF_DIR/skip_stop" ]; then
  exit 0
fi


# Scope loop detection per agent (subagents share parent session_id)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
if [ -n "$AGENT_ID" ]; then
  TIMESTAMPS="$PROOF_DIR/stop_timestamps_${AGENT_ID}"
else
  TIMESTAMPS="$PROOF_DIR/stop_timestamps"
fi

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
  LOOP_REMINDER=" LOOP DETECTED ($RECENT_COUNT hits in 5min): You are stuck in a stop-hook loop. This is YOUR problem to solve autonomously. How the stop hook works: (1) it blocks your first stop attempt, (2) you read ~/.cache/claude-proof/\$SESSION_ID/instructions.md or ~/.claude/hooks/stop-checklist.md, (3) you write proof to $PROOF, (4) you stop again and it lets you through. Figure out which step you are failing and fix it. Do NOT keep retrying the same approach."
fi

block() {
  jq -n --arg reason "$1$LOOP_REMINDER" '{"decision": "block", "reason": $reason}'
  exit 0
}

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
    HISTORY_DIR="$HOME/.cache/claude-proof/history"
    mkdir -p "$HISTORY_DIR"
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
        RESCAN_LINE=$(printf %s "$AUDIT_SECTION" | grep -iE '^[[:space:]]*rescanned:[[:space:]]+' | head -n1)
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
          block "Rule-compliance self-audit is byte-identical to the prior stop. Repo unchanged, so a repeat finding is acceptable, but include a line inside the audit section: 'rescanned: CLAUDE.md, <source2>, <source3>, ... — <UTC timestamp>' naming at least three sources actually re-read."
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
  rm -f "$PROOF" "$PROOF_DIR/baseline_head"
  block "Checking stop criteria."
fi

# 2. Already sent back (proof printed or no proof written) → allow + cleanup
if [ "$STOP_ACTIVE" = "true" ]; then
  rm -rf "$PROOF_DIR" 2>/dev/null || true
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

No code changes detected — full verification is NOT required.
However, you must still check your work against the acceptance criteria.

1. Read the checklist at ~/.claude/hooks/stop-checklist.md
2. For each item that applies to this session's work, verify it was followed.
3. If any item was violated → fix it before stopping.
4. Write to the proof file:
   - "fast-exit: checklist review (no code changes)" on the first line
   - Which checklist items applied and their pass/fail status
   - Any issues found and how they were resolved
INSTEOF
  block "Checking stop criteria."
fi

# 5. Code changed, no proof → block and send verification protocol
#    Write a session-specific instructions file with the proof path baked in
INSTRUCTIONS="$PROOF_DIR/instructions.md"
mkdir -p "$PROOF_DIR"
sed \
  -e "s|{{PROOF}}|$PROOF|g" \
  -e "s|{{PROOF_DIR}}|$PROOF_DIR|g" \
  "$HOOK_DIR/stop-verification.md" > "$INSTRUCTIONS"
block "Checking stop criteria."
