#!/bin/bash
# Stop hook: gates Claude from stopping until verification proof is written.
# Command hook — blocks first stop attempt, sends Claude back to verify,
# then allows on second attempt when proof file exists.

set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active')

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  exit 0
fi

PROOF_DIR="$HOME/.cache/claude-proof/$SESSION_ID"
PROOF="$PROOF_DIR/proof.md"

# 1. Proof exists → block once more so Claude prints the summary, then cleanup
if [ -f "$PROOF" ]; then
  CONTENT=$(python3 -c 'import sys,json; print(json.dumps(open(sys.argv[1]).read()))' "$PROOF")
  rm -f "$PROOF" "$PROOF_DIR/baseline_head"
  rmdir "$PROOF_DIR" 2>/dev/null || true
  jq -n --argjson content "$CONTENT" \
    '{"decision": "block", "reason": ("Print this verification summary to the user as-is, then stop:\n\n" + $content)}'
  exit 0
fi

# 2. Already sent back (proof printed or no proof written) → allow
if [ "$STOP_ACTIVE" = "true" ]; then
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

# 4. No code changes → block once with acceptance-criteria reminder
if [ -z "$CODE_CHANGES" ]; then
  CHECKLIST=$(cat <<'CHECKLIST_EOF'
Before stopping, check:
- Root cause identified? (Not just symptoms — why does the problem exist?)
- If blaming external code: did you read its source, reproduce in isolation, find the exact cause?
- Investigation complete? (Don't ask permission to investigate — just do it.)
- If blocked: stated exactly what's missing and what you tried?

If any check fails → continue working. Stop only if all pass.
CHECKLIST_EOF
  )
  jq -n --arg reason "$CHECKLIST" \
    '{"decision": "block", "reason": $reason}'
  exit 0
fi

# 5. Code changed, no proof → block and send verification protocol
REASON=$(
  cat <<REASON_EOF
STOP BLOCKED — Write verification proof before stopping.

Proof file: $PROOF (mkdir -p $PROOF_DIR first).
Evidence bundle: BUNDLE=\$HOME/.cache/claude-proof/\$(date -u +%Y%m%dT%H%M%SZ) — mkdir -p \$BUNDLE, save all commands and outputs there.

## FAST EXIT

Write a one-line explanation to the proof file and stop if any of these apply:
- Asking the user for input, confirmation, or a decision
- No completion claim — still mid-thought or explaining
- Already verified during this session (summarize what you did)
- Change is trivially correct (rename, typo, dead code removal) where a mistake is implausible

## FULL VERIFICATION

### Step 1 — Evidence bundle
Run git diff. Save output to \$BUNDLE.

### Step 2 — Code review
Inspect all diffs as a strict senior engineer:
- Correctness: logic errors, off-by-ones, null/nil/undefined, edge cases
- Error handling: are errors checked and propagated?
- Security: injection, unsanitized input, hardcoded secrets
- Consistency: does the change follow patterns of the surrounding code?
- Completeness: TODOs, placeholder values, half-finished code?

If ANY issue found → write issues to proof file and STOP. Do not proceed to Step 3.

### Step 2.5 — Root-cause analysis

Answer these questions in the proof file:
- What is the root cause? (Not "what broke" — why did it break?)
- Is the fix addressing the root cause, or only the symptom?
- If symptom-only: why is root-cause fix infeasible? What follow-up is needed?

If the fix is symptom-only without justification → do not proceed. Go fix the root cause first.

### Step 3 — Objective proof

If there are production changes but no witness (test or repro script), create one that exercises the changed code.

Run the witness with the fix present — must PASS.
Remove ONLY the production change, run the witness again — must FAIL.
Restore the production change.

Save all commands, outputs, and exit codes to \$BUNDLE.

## DECISION

Commit all changes with git before writing the proof file.

Write to the proof file:
- Files changed
- Code review result
- Root cause identified and whether the fix addresses it
- Witness test name and results (with/without the production change)
- Overall verdict
REASON_EOF
)

jq -n \
  --arg reason "$REASON" \
  '{"decision": "block", "reason": $reason, "systemMessage": "Verification required — checking changes."}'
