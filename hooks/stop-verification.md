STOP BLOCKED — Write verification proof before stopping.
NEVER end your turn to ask a question. Use the AskUserQuestion tool instead — always.

Proof file: {{PROOF}} (mkdir -p {{PROOF_DIR}} first).
Evidence bundle: BUNDLE=$HOME/.cache/claude-proof/$(date -u +%Y%m%dT%H%M%SZ) — mkdir -p $BUNDLE, save all commands and outputs there.

## FAST EXIT

Write a one-line explanation to the proof file and stop if any of these apply:
- Asking the user for input, confirmation, or a decision (use the AskUserQuestion tool — do not stop to ask)
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

### Step 2.6 — Generalize the fix

Your fix addresses one instance. Is it part of a broader class?

- What pattern or assumption caused this bug? Where else does that pattern appear?
- Search the codebase for similar instances (grep, glob). List what you found.
- If other instances exist: fix them now, or document why they're not affected (with evidence, not "I think it's fine").
- If the pattern is structural (e.g., missing validation, wrong default, unsafe assumption): is there a way to make the class of bugs impossible (type system, lint rule, abstraction)?

Skip this step only if the fix is purely configuration or environment-specific with no code pattern to generalize.

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

**After fixing any problem, re-run the critique on the fixed version.** Repeat
(critique → fix → re-critique) until a full pass finds no actionable problems.

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

### Step 5 — Rule-compliance self-audit

<!-- Keep in sync with stop-checklist.md "Rule-compliance self-audit". -->
<!-- Grammar below is machine-parsed by stop-gate.sh — deviations block the gate. -->

The audit subject is the written rule (CLAUDE.md, skill rules, project
instructions, memories), not any user reaction to your output. An
uncodified session-objection is not itself a rule; once codified into
CLAUDE.md, a skill, a project instruction, or memory, it is. Prioritize
violations the user did not flag — those carry the signal of incomplete
self-correction.

The scope of this audit is the last turn only — conduct between the
previous stop (or session start) and this stop attempt. Earlier turns
belong to earlier stops' audits; this stop audits only its own turn.

The gate parses this section. It accepts exactly one of two forms:

**Form A — no violations found.** One line, naming at least three rule
sources you actually scanned:

    clean-scan: CLAUDE.md, <skill name>, <memory or project instruction>

**Form B — one or more violation blocks.** Each block starts with
`Violation:` and carries a correction marker below it:

    Violation: <short label>
    Quote: <exact tool call, claim, or decision>
    Rule: <path>:<line or section>
    Correction:
      commit: <40-hex-hash>             ← git cat-file verifies it exists
      ```edit <path>                    ← new content that now exists there
      <content>
      ```
      ```grep <path>                    ← grep output proving amended state
      <output>
      ```
      ```restate                        ← current-turn restatement that
      <restated claim/decision>           supersedes the violating conduct
      ```
      blocker:                          ← correction needs user/future input
      input: <named required input>
      command: <exact command or edit that would apply the correction>

Every `Violation:` needs at least one correction marker. Listing
without a correction fails the gate. A blocker missing either `input:`
or `command:` fails the gate. Fake commit hashes fail `git cat-file`.

Prefer the strongest feasible fix (Eliminate > Facilitate > Detect >
Document). After corrections, re-scan and iterate until a scan finds
none, then record the final state as Form A or Form B.

The scan is an act performed this turn, not a recorded result carried
forward. When HEAD has advanced or the working tree has uncommitted
changes since the previous stop, the audit text must reflect that
motion — cite evidence from the new range, or record a fresh
clean-scan. When the repo is unchanged, a repeat finding is acceptable
but must include a line naming the sources re-read this turn, e.g.
`rescanned: CLAUDE.md, <skill>, <memory> — <UTC time>`.

Save the audit to $BUNDLE under a "Rule-compliance self-audit" heading.

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
- Rule-compliance self-audit: violations found, rule violated per violation, correction applied per violation
- Overall verdict
