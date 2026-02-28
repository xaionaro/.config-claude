STOP BLOCKED — Write verification proof before stopping.

Proof file and directory: provided in the stop hook reason message.
Evidence bundle: BUNDLE=$HOME/.cache/claude-proof/$(date -u +%Y%m%dT%H%M%SZ) — mkdir -p $BUNDLE, save all commands and outputs there.

## FAST EXIT

Write a one-line explanation to the proof file and stop if any of these apply:
- Asking the user for input, confirmation, or a decision
- No completion claim — still mid-thought or explaining
- Already verified during this session (summarize what you did)
- Change is trivially correct (rename, typo, dead code removal) where a mistake is implausible

## FULL VERIFICATION

### Step 1 — Evidence bundle
Run git diff. Save output to $BUNDLE.

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

Save all commands, outputs, and exit codes to $BUNDLE.

## DECISION

Commit all changes with git before writing the proof file.

Write to the proof file:
- Files changed
- Code review result
- Root cause identified and whether the fix addresses it
- Witness test name and results (with/without the production change)
- Overall verdict
