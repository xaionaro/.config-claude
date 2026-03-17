Before stopping, verify ALL of the following. If any check fails → continue working.

## Questions

- NEVER end your turn to ask a question. Use the AskUserQuestion tool instead — always.

## Git

- Commit all changes before stopping. Do not leave uncommitted work.
- NEVER git push unless the user explicitly asked. No exceptions.

## Completion

- DONE = objective evidence only. No inference, no assumptions. You cannot claim DONE if you have not tested that it works. Session boundaries are not completion criteria.
- Every statement in your completion summary is a claim. Apply the Claim Verification protocol: each must be [DOC] (backed by tool output from this session) or explicitly marked [UNVERIFIED].
  Example: "All tests pass" requires: (1) searched the project for all test files and test commands, (2) ran every one, (3) all returned pass. Without all three steps, the claim is [UNVERIFIED].
- NOT DONE if no objective evidence. State what's missing and why.
- NOT DONE if you noticed a bug in code you touched or read — fix it before stopping.
- NOT DONE if you chose a simple or convenient solution over the correct, clean one. Redo it.
- Stated "next step" or know remaining work exists? Continue working. Completing a subtask means starting the next one.
- BLOCKED on user input → report (what, exact questions, exact next commands) using the AskUserQuestion tool. Do not stop to ask — use the AskUserQuestion tool and keep working.

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

## System instructions compliance

- Re-read ALL system instructions (CLAUDE.md, project instructions, skill constraints).
- Verify every instruction that applies to this session's work was followed.
- If any instruction was violated → fix it before stopping.

## Testing (if code was touched this session)

- All tests pass. Failing tests = keep working until they pass. Fix the root cause, not the test.
- Skipped tests = make the resource available (install, start, configure) and re-run. A skip is not a pass.
- Relevant tests updated and passing?
- Reproducing test added before the fix (when feasible)?
- Broken unrelated tests fixed? (No such thing as "unrelated issue".)
- Dual-sided? Each test confirms good behavior IS happening AND bad behavior is NOT happening.
- Test validated? For each new test, broke the code intentionally and confirmed the test fails.
