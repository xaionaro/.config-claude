# Claude Code Tool Mapping

Skills use Claude Code tool names. When a skill names a generic action, use the Claude Code tool below:

| Skill references | Claude Code equivalent |
|-----------------|------------------------|
| Subagent dispatch | `Agent` tool (see [Prompt template dispatch](#prompt-template-dispatch)) |
| Parallel dispatches | Multiple `Agent` calls in one message |
| Subagent result | Arrives as a completion notification; there is no wait call. Never predict or fabricate a pending result |
| Continue a subagent | `SendMessage` to its id or name |
| Task tracking | `TaskCreate` / `TaskUpdate` |
| Invoke a skill | `Skill` tool |
| `Read`, `Write`, `Edit` (files) | Same tools |
| `Bash` (run commands) | Same tool |

## Subagent dispatch

The `Agent` tool is built in. One-shot subagents need no feature flag.

## Prompt template dispatch

Skill prompt templates (`code-quality-reviewer-prompt.md`, `requesting-code-review/code-reviewer.md`) are not agent types. To dispatch one:

1. Read the template file.
2. Fill the placeholders (`{BASE_SHA}`, `{WHAT_WAS_IMPLEMENTED}`, etc.).
3. Call `Agent` with `subagent_type="general-purpose"` and the filled text as `prompt`.

Named agent types listed in the `Agent` tool description (for example `feature-dev:code-reviewer`) dispatch directly with `subagent_type`.

### Prompt framing

Structure `prompt` for maximum instruction adherence:

```
Your task is to perform the following. Follow the instructions below exactly.

<agent-instructions>
[filled prompt content from the template's .md file]
</agent-instructions>

Execute this now. Output ONLY the structured response following the format
specified in the instructions above.
```

- Use task-delegation framing ("Your task is...") rather than persona framing ("You are...")
- Wrap instructions in XML tags — the model treats tagged blocks as authoritative
- End with an explicit execution directive to prevent summarization of the instructions

## Environment Detection

Branch and PR workflows should detect their environment with read-only git
commands before proceeding:

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
BRANCH=$(git branch --show-current)
```

- `GIT_DIR != GIT_COMMON` → already in a linked worktree
- `BRANCH` empty → detached HEAD (cannot branch/push/PR from sandbox)

See `finishing-a-development-branch` Step 1 for how that skill uses these
signals.
