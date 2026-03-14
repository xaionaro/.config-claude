STOP BLOCKED — Write verification proof before stopping.
NEVER end your turn to ask a question. Use the AskUserQuestion tool instead — always.

Proof file: {{PROOF}} (mkdir -p {{PROOF_DIR}} first).
Evidence bundle: BUNDLE=$HOME/.cache/claude-proof/$(date -u +%Y%m%dT%H%M%SZ) — mkdir -p $BUNDLE, save all commands and outputs there.

## FAST EXIT

Write a one-line explanation to the proof file and stop if any of these apply:
- Asking the user for input, confirmation, or a decision (use the question tool — do not stop to ask)
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

If ANY issue found → go fix the issues first, then restart verification from Step 1.
Do not proceed to Step 3 until code review passes clean.

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

### Step 4 — Adversarial self-critique

Your work contains errors — find them.

#### 4a — Claim inventory
List every factual claim, assumption, and decision in your work and summary.
Include implicit claims (e.g. "this file is the right place for this change"
is a claim). Anything you assert as true goes on this list.

#### 4b — Pre-mortem
Imagine it is tomorrow and your work was reviewed and found to have a critical
flaw. What is the single most likely flaw? Consider:
- What assumption did you make that might not hold?
- What requirement did you silently drop or misinterpret?
- What edge case would break this?
- What would a hostile reviewer attack first?

If you identified a plausible flaw → fix it before proceeding.

#### 4c — Adversarial critique (minimum 3 objections, then iterate)
Your work contains errors. Identify at least 3 of them.

Adopt the stance of a skeptical, adversarial reviewer whose job is to reject.
Find at least 3 specific, concrete problems. Not vague concerns — quote the
specific code, claim, or decision that is wrong or questionable.

If you cannot find 3 problems, you are not looking hard enough. Consider:
- Logic errors, off-by-ones, race conditions, missing error paths
- Misunderstanding the user's actual intent vs. what they literally said
- Changes that silently break something outside the diff
- Claims in your summary that are not backed by evidence you actually produced

For each problem found: fix it or explain with evidence why it is not actually
a problem. "I think it's fine" is not evidence.

**After fixing any problem, re-run the critique on the fixed version.** Your fix
may have introduced new issues. Repeat the cycle (critique → fix → re-critique)
until a full pass finds no actionable problems. Only then proceed.

#### 4d — Verification questions
For each non-trivial claim from step 4a, generate a specific verification
question that would confirm or refute it. Then answer that question using tools
(grep, read the code, run a command) — not from memory. If you cannot verify a
claim with a tool, mark it UNVERIFIED and state this in your proof.

#### 4e — Confidence calibration
For each claim that remains after the above steps, rate it:
- VERIFIED — confirmed via tool output or test result
- LIKELY — strong reasoning but no external confirmation
- UNCERTAIN — plausible but could be wrong
- UNKNOWN — guessing

Any UNCERTAIN or UNKNOWN claims must be flagged explicitly in your proof file.
Do not present them as facts.

#### 4f — Challenge your own blockers
- If you're stopping because something is "not available" or "can't be done" — did you actually TRY?
- You have a full Linux environment with sudo. Emulators, servers, tools, compilers — install and start them.
- "Can't test this" is almost never true. List 3 ways you could test it. Pick one. Do it.
- An assumption is not a blocker. An attempt that failed (with error output) is a blocker.

### Step 5 — System instructions compliance

Re-read ALL system instructions (CLAUDE.md, project instructions, skill constraints).
For each instruction that applies to this session's work, verify it was followed.
If any instruction was violated → fix it before proceeding.

Save the list of checked instructions and their compliance status to $BUNDLE.

### Step 6 — Testing

- Relevant tests updated and passing?
- Reproducing test added before the fix (when feasible)?
- Broken unrelated tests fixed? (No such thing as "unrelated issue".)
- Dual-sided? Each test confirms good behavior IS happening AND bad behavior is NOT happening.
- Test validated? For each new test, broke the code intentionally and confirmed the test fails. Save evidence to $BUNDLE.

## DECISION

DONE = objective evidence only. No inference, no assumptions.

Commit all changes with git before writing the proof file.
NEVER git push unless the user explicitly asked. No exceptions.

Write to the proof file:
- Files changed
- Code review result
- Root cause identified and whether the fix addresses it
- Claim inventory (all claims made, with confidence rating for each)
- Pre-mortem: what was the most likely flaw? Was it real?
- Adversarial critique: the 3+ objections found, and resolution for each
- Verification questions asked and tool-verified answers
- Any UNCERTAIN or UNKNOWN claims that remain
- Witness test name and results (with/without the production change)
- Overall verdict
