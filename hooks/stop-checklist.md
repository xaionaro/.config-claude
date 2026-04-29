Before stopping, verify ALL of the following. If any check fails → continue working.

## Questions

- NEVER end your turn to ask a question. Use the AskUserQuestion tool instead — always.

## Git

- Commit all changes before stopping. Do not leave uncommitted work.
- NEVER git push unless the user explicitly asked. No exceptions.

## Completion

- DONE = objective evidence only. No inference, no assumptions. You cannot claim DONE if you have not tested that it works. Session boundaries are not completion criteria.
- Every statement in your completion summary is a claim. Apply the Claim Verification protocol: each must be [DOC] (backed by tool output from this session) or explicitly marked [UNVERIFIED].
  Example: "All tests pass" requires (1) found every test file/command in the project, (2) ran them all, (3) all returned pass. Without all three, the claim is [UNVERIFIED].
- NOT DONE if no objective evidence. State what's missing and why.
- NOT DONE if you noticed a bug in code you touched or read — fix it before stopping.
- NOT DONE if you chose a simple or convenient solution over the correct, clean one. Redo it.
- Stated "next step" or know remaining work exists? Continue working. Completing a subtask means starting the next one.
- All Active tasks resolved this turn. (In the reviewer prompt's `## TASKS`, only items under `### Active` count toward the no-open-tasks-at-stop violation.) Tasks the user accepted as out-of-scope → rename subject to `[DEFERRED <reason>] <original subject>` via TaskUpdate. Tasks waiting on user input or an external dependency → rename to `[BLOCKED on <thing>] <original subject>`. Stale tasks (idle > 24h with no prefix) → confirm and resolve, cancel, or relabel.
- BLOCKED on user input → report (what, exact questions, exact next commands) using the AskUserQuestion tool. Do not stop to ask. Keep working.

## Root cause

- Assume the bug is in our code. Blaming a library or tool requires reproducing the issue in isolation with evidence.
- Root cause identified? (Not just symptoms — why does the problem exist?)
- If blaming external code: did you read its source, reproduce in isolation, find the exact cause?
- Investigation complete? Don't ask permission to investigate — just do it.
- "Possible root cause" requires objective evidence. Cite it.
- 5 Whys: ask "why?" at least 3 times from the symptom. If you can still ask "why?" meaningfully, you haven't reached root cause.
- Generalized? Your fix addresses one instance — did you search for the same pattern elsewhere and fix or document those too?

## Adversarial self-critique

- Your work contains errors. Did you find them?
- Claim inventory complete? Every factual claim, assumption, and decision listed?
- Pre-mortem done? Imagined failure, identified the most likely flaw, investigated it?
- At least 3 concrete problems found? (Not vague — specific code/claim/decision cited.)
- Each problem fixed or refuted with evidence (not "I think it's fine")?
- After each fix, did you re-critique? (critique → fix → re-critique until clean pass)
- Verification questions generated for non-trivial claims and answered via tools (not memory)?
- Confidence ratings assigned? UNCERTAIN/UNKNOWN claims flagged explicitly?
- "Why might this not be what was requested?" If any reason found → fix it, don't stop.

## Assumed blockers

- If claiming something is impossible, missing, or unavailable — did you actually verify?
- "No emulator/server/tool/service available" → Did you try to install, start, or create it? You have a full Linux environment with sudo. Try before claiming blocked.
- "Can't test this" → List 3 ways you COULD test it. Pick the most feasible one and do it.
- "Would need X to verify" → Go get/build/start X. Only stop if you tried and it genuinely failed (with error output as evidence).
- Assumption without attempt = not blocked. Actually try it.
- A limitation is a problem to fix, not a reason to give up. Solve it.

## Rule-compliance self-audit

<!-- Keep in sync with stop-verification.md Step 5. -->
<!-- Full verification parses this grammar mechanically; the fast-exit path below is the short form. -->

The audit subject is the written rule (CLAUDE.md, skill rules, project instructions, memories), not user reactions. Prioritize violations the user did not flag.

Scope: the last turn only — conduct between the previous stop (or session start) and this stop attempt. Earlier turns belong to earlier stops' audits.

Write one of:

- **Form A** — no violations: `clean-scan: CLAUDE.md, <skill>, <memory>` (minimum three rule sources actually scanned).
- **Form B** — one or more `Violation:` blocks, each carrying a correction marker below it: `commit: <hash>`, an `` ```edit `` fence, an `` ```grep `` fence, an `` ```restate `` fence, or a `blocker:` with `input:` and `command:` lines. Listing without correction is not accepted. Fake commit hashes fail `git cat-file`.

Prefer the strongest feasible fix (Eliminate > Facilitate > Detect > Document). Iterate until a scan finds none.

The scan is performed this turn, not carried forward from a prior stop. When HEAD advanced or the working tree is dirty, the audit must reflect that motion. When the repo is unchanged, a repeat finding is acceptable but must include a `rescanned: <source1>, <source2>, ... — <UTC time>` line.

## Background processes

- No unneeded leftover background processes. Anything spawned this session that the user does not need running (one-shot servers, abandoned `&` jobs, build watchers, scratch tmux/screen sessions, dangling `claude` subprocesses) → kill before stopping. Long-lived intended services are fine; transient experiments are not.
- Reviewer sees a `## BACKGROUND_PROCESSES` snapshot. If anything there does not justify staying alive → kill it. Document any survivors with one-line rationale.

## Testing (if code was touched this session)

- All tests pass. Failing tests = keep working until they pass. Fix the root cause, not the test.
- Skipped tests = make the resource available (install, start, configure) and re-run. A skip is not a pass.
- Relevant tests updated and passing?
- Reproducing test added before the fix (when feasible)?
- Broken unrelated tests fixed? (No such thing as "unrelated issue".)
- Dual-sided? Each test confirms good behavior IS happening AND bad behavior is NOT happening.
- Test validated? For each new test, broke the code intentionally and confirmed the test fails.
