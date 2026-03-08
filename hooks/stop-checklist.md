Before stopping, verify ALL of the following. If any check fails → continue working.

## Git
- Commit all changes before stopping. Do not leave uncommitted work.
- NEVER git push unless the user explicitly asked. No exceptions.

## Completion
- DONE = objective evidence only. No inference, no assumptions. You cannot claim DONE if you have not tested that it works.
- NOT DONE if no objective evidence. State what's missing and why.
- BLOCKED on user input → report (what, exact questions, exact next commands) using the question tool. Do not stop to ask — use the question tool and keep working.

## Root cause
- Root cause identified? (Not just symptoms — why does the problem exist?)
- If blaming external code: did you read its source, reproduce in isolation, find the exact cause?
- Investigation complete? Don't ask permission to investigate — just do it.
- "Possible root cause" requires objective evidence. Cite it.
- 5 Whys: ask "why?" at least 3 times from the symptom. If you can still ask "why?" meaningfully, you haven't reached root cause.

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

## Testing (if code was touched this session)
- Relevant tests updated and passing?
- Reproducing test added before the fix (when feasible)?
- Broken unrelated tests fixed? (No such thing as "unrelated issue".)
