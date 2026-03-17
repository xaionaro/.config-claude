# Response Discipline

Decompose claims into verifiable units. Verify each against sources (docs, code, tool output). Iterate autonomously until critique yields nothing actionable. Keep the response complete, but concise.

Self-critique without external verification degrades correctness. Every suspect claim must trigger tool-based verification, not "I know."

# Claim Verification

Every factual claim requires tool-based verification in this session. Training data recall is not verification — confidence is not correctness.

**Protocol**: For all claims, search docs/web, provide primary-source citations, and tag key statements:

- **[DOC]** — confirmed by primary source (docs, source code, tool output) fetched this session. Cite the source.
- **[INFERRED]** — logically derived from verified facts, but not directly confirmed. State the reasoning chain.
- **[UNVERIFIED]** — not backed by a source fetched this session. Must be explicitly marked. Immediately verify via tools — do not present [UNVERIFIED] claims to the user without first attempting verification.

Tag key statements explicitly. Untagged factual claims are violations — mark before continuing.

**The common trap**: You "know" something from training. It feels like knowledge. You state it fluently. But you did not look it up in this session — that is [UNVERIFIED], not [DOC].

**How**: Find the specific text/code that supports your claim. Cite the source: "[DOC] Per [source], ..."

**Example (real failure)**:
BAD: "The JNI spec says the args parameter is 'an array of arguments.' It never says NULL is valid for zero-argument methods."
← Stated WITHOUT fetching the JNI spec. The spec actually said something different.

GOOD: [fetches JNI spec via WebFetch] "[DOC] I checked the JNI specification at [URL]. Section X says: '[exact quote]'. Based on this, ..."

# Decision-Making Rules

- **Security first**: Minimal, targeted solution. Disabling security features is not a solution.
- **Simplest safe path**: Propose the simplest solution that preserves security.
- **Skip dead ends fast**: When a solution requires unavailable resources, move to the next approach immediately.
- **Config values are intentional**: Modify configuration only when explicitly asked.
- **Verify UI manipulations**: After every UI manipulation via CDP, verify the result — screenshot or DOM check.
- **Assume the bug is in our code.** Blaming a library, external service, or tool requires reproducing the issue in isolation with evidence. Trace the code path first.
- **No hidden assumptions.** Handle exactly the cases you expect. Return errors for everything else. When investigating, verify each assumption by reading code or running tests — not by reasoning from what "should" happen.

# Git

- **Review diff for secrets**: Before every commit, inspect `git diff` for secrets or credentials.
- **Run static checks**: Before every commit, run all available static checks.
- **Push only on request**: Commit locally freely, but `git push` requires explicit user approval.
- **Clean commit messages**: Keep commit messages focused on the change — no "Co-Authored-By: Claude" or AI co-author lines.

# Mandatory Skills

Walk through every entry below before starting work. For each, decide: does it apply? If yes, invoke it via the Skill tool.

1. Debugging? (test failures, bugs, unexpected behavior, performance, build failures) → `superpowers:systematic-debugging` + `debugging-discipline`
2. Go code? (writing, reviewing, modifying *.go) → `go-coding-style`
3. Python code? (writing, reviewing, modifying *.py) → `python-coding-style`
4. Writing or reviewing tests? → `testing-discipline`
5. Implementing software with logic? (skip only for pure config/glue) → `proof-driven-development`

# Environment

- **Qt**: Qt is installed in ~/Qt
- **Android**: Android SDK/NDK is installed in ~/Android

# Infrastructure

- **Your IP-address**: The IP-address of this environment is 192.168.141.16.
- **Accessing this environment by other devices**: Other devices in LAN may connect to this environment using IP-address 192.168.0.131 and ports 7000-7019 (that are DNAT-ed to this environment).
- **OLLAMA**: There is a MacBook M4 Max 128GB Ollama available by address 192.168.0.171:11434.
- **Bluetooth**: Bluetooth is available as hci1/hci2 thanks to `DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/bluez-proxy/system_bus_socket`

# Execution

- **Stop hook**: When blocked by the stop hook, check `~/.cache/claude-proof/$SESSION_ID/` — read `summary-to-print.md` (print it to user then stop), `instructions.md` (verification protocol), or `~/.claude/hooks/stop-checklist.md` (acceptance criteria). Whichever file exists tells you what to do.
- **Questions via tool**: Always use the AskUserQuestion tool for questions and confirmations — this keeps the conversation flowing instead of blocking on your turn.
- **Delegate to subagents**: Delegate work to subagents to preserve the main context window, enable parallelism, and isolate noisy search results from the main thread.
