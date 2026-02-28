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

## Self-review
- Critique your work → fix → repeat until nothing left to critique.
- "Why might this not be what was requested?" If any reason found → fix it, don't stop.

## Testing (if code was touched this session)
- Relevant tests updated and passing?
- Reproducing test added before the fix (when feasible)?
- Broken unrelated tests fixed? (No such thing as "unrelated issue".)
