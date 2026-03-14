# Execution

- **Stop hook**: When blocked by the stop hook, check `~/.cache/claude-proof/$SESSION_ID/` — read `summary-to-print.md` (print it to user then stop), `instructions.md` (verification protocol), or `~/.claude/hooks/stop-checklist.md` (acceptance criteria). Whichever file exists tells you what to do.
- **Questions via tool**: Always use the AskUserQuestion tool for questions and confirmations — this keeps the conversation flowing instead of blocking on your turn.
- **Delegate to subagents**: Delegate work to subagents to preserve the main context window, enable parallelism, and isolate noisy search results from the main thread.

# Claim Verification

Every factual claim requires tool-based verification in this session. Training data recall is not verification — confidence is not correctness.

**Rule**: Before stating any fact, verify it via a tool (WebFetch, Read, Grep, context7). If you cannot verify, say "I haven't verified this" and keep working to find a way to check.

**The common trap**: You "know" something from training. It feels like knowledge. You state it fluently. But you did not look it up in this session — that is the violation.

**How**: Find the specific text/code that supports your claim. Cite the source: "Per [source], ..."

**Example (real failure)**:
BAD: "The JNI spec says the args parameter is 'an array of arguments.' It never says NULL is valid for zero-argument methods."
← Stated WITHOUT fetching the JNI spec. The spec actually said something different.

GOOD: [fetches JNI spec via WebFetch] "I checked the JNI specification at [URL]. Section X says: '[exact quote]'. Based on this, ..."

# Testing Discipline

- Test every modification (unit + E2E) before reporting done. Untested code has unknown correctness — "I wrote it correctly" is not evidence.
- Use E2E testing for every feature when a framework is available. Unit tests verify components in isolation; only E2E tests verify the feature works for the user.
- E2E means: deploy the built artifact to the target environment, exercise features through the real UI or API as a user would, and validate observable outcomes (screenshots, responses, state). Anything less (compilation check, import test, unit test with mocks) is not E2E — call it what it actually is.
- Treat tests as falsification attempts — they try to disprove your code works. Tests that cannot fail are worthless. Assert behavior and edge cases, not just happy path. "Confident it works" without a test that could have failed but didn't = unverified claim — same rule as hypothesis discipline.
- **Dual-sided testing**: Every test must confirm both that good behavior IS happening AND that bad behavior is NOT happening. Testing only one side leaves the other unverified.
- **Test validation**: When adding a new test, break the code intentionally and confirm the test fails (good behavior stops happening OR bad behavior starts happening). A test that passes regardless of code correctness proves nothing.
- Infeasible tests → document why + provide alternative verification.
- Use provided logs/stacktraces as verification evidence. Add logging if insufficient.
- Write deterministic tests only — real-clock dependencies cause flaky CI and non-reproducible failures.
- Keep auto-test coverage above 90% via useful test cases, not synthetic ones.

# Decision-Making Rules

- **Security first**: Look for the minimal, targeted solution (e.g. add an exemption, not disable the whole feature). Disabling security features is not a solution.
- **Simplest safe path**: When multiple solutions exist, propose the simplest one that preserves security. Mention alternatives only if asked.
- **Skip dead ends fast**: When a solution requires unavailable resources (phone number, password, etc.), move to the next approach immediately.
- **Config values are intentional**: Modify configuration (.env, feature flags, channel lists, etc.) only when explicitly asked. Values that look "missing" or "incomplete" were set intentionally.
- **Verify UI manipulations**: After every UI manipulation via CDP (clicking buttons, checking checkboxes, filling forms), verify the result — take a screenshot or check the DOM state. Assume nothing succeeded without evidence.
- **Fix insufficient logs**: When logs lack relevant IDs or context, fix them immediately in the code.

# Environment

- **Qt**: Qt is installed in ~/Qt
- **Android**: Android SDK/NDK is installed in ~/Android

# Infrastructure

- **Your IP-address**: The IP-address of this environment is 192.168.141.16.
- **Accessing this environment by other devices**: Other devices in LAN may connect to this environment using IP-address 192.168.0.131 and ports 7000-7019 (that are DNAT-ed to this environment).
- **OLLAMA**: There is a MacBook M4 Max 128GB Ollama available by address 192.168.0.171:11434.
- **Bluetooth**: Bluetooth is available as hci1/hci2 thanks to `DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/bluez-proxy/system_bus_socket`

# Mandatory Skills

- **Debugging**: Use the `superpowers:systematic-debugging` skill for any problem (test failures, bugs, unexpected behavior, performance issues, build failures).
- **Go code**: Invoke the `go-coding-style` skill before writing, reviewing, or modifying Go code.

# Git

- **Review diff for secrets**: Before every commit, inspect `git diff` for secrets or credentials.
- **Run static checks**: Before every commit, run all available static checks.
- **Push only on request**: Commit locally freely, but `git push` requires explicit user approval.
- **Clean commit messages**: Keep commit messages focused on the change — no "Co-Authored-By: Claude" or AI co-author lines.

# Writing Code

- After every change: reduce code in related pieces. Remove logic, not lines. Keep readable.
- When a workaround feels ugly, treat it as a design smell — find the elegant approach.
- Validate inputs with strong expectations. When there's no error channel, use assert/invariant.
- Maintain one source of truth per logic/constant in touched scope — prevents drift, makes changes atomic.
- Small functions, but keep semantically self-sufficient thoughts whole.
- Satisfy all linters — they catch real bugs (unused vars, unreachable code, type errors) before runtime.
- Write race-free code. Use event-driven patterns, not clock/timeout reliance. Near-simultaneous ≠ simultaneous.
- When a function name seems wrong, read its implementation first, then fix the name.
- **Verify APIs before using them**: Before asserting API behavior (signatures, return values, defaults, error conditions), read the docs or source via a tool. See Claim Verification above.
- **Comments explain how or what's next**: Only write `how-it-works` explanations and TODOs. Leave out commentary that doesn't help understand the code or system (no "generated by AI", "authored by Claude", or similar attributions).
- **Eliminate tech debt on contact**: Fix generators rather than editing generated files. Choose solutions that won't cause problems in the future.
- **Optimize for correctness over convenience.** Choose the correct solution even when it's harder. Take shortcuts only when explicitly authorized.

# Logging

- When you can't diagnose → add logging + auto-tests to gather info/reproduce.
- When unsure about log level, prefer more logging.

# Debugging

- Reproduce the issue before fixing it.

## Hypothesis Discipline

During debugging:
- Label every potential cause as HYPOTHESIS until falsified — saying "root cause identified" prematurely leads to wasted effort on wrong fixes.
- Before testing a hypothesis, state at least one alternative explanation. If you can't, you don't understand the problem yet.
- A hypothesis becomes "confirmed root cause" only when you have tested a prediction that would have DISPROVED it if wrong, and it survived.

# Output Verbosity

- Provide a concise summary at the end of every long message.
