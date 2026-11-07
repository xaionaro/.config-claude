# Code Quality Reviewer Prompt Template

Use this template when dispatching a code quality reviewer subagent.

**Purpose:** Verify implementation is well-built (clean, tested, maintainable)

**Only dispatch after spec compliance review passes.**

Dispatch a read-only reviewer with the Agent tool: `subagent_type="general-purpose"`, `name` = the role label, the template body as `prompt`. The reviewer is read-only by instruction (`general-purpose` has no tool restriction), so keep the read-only line in the prompt.

```
Agent(
  description="Review code quality",
  subagent_type="general-purpose",
  name="code-quality-reviewer",
  prompt="""
Role label: code-quality-reviewer

Read-only: do not edit, write, or delete files.

<stop-hook-boundary>
Follow any Stop-hook prompt in this session, including required proof/checklist files.
Fix blockers within your assigned scope. Report to the orchestrator only when recovery needs out-of-scope changes, unrelated user work, credentials, or approval.
</stop-hook-boundary>

[Filled requesting-code-review/code-reviewer.md prompt]
"""
)
```

Fill the prompt with:
- `WHAT_WAS_IMPLEMENTED`: [from implementer's report]
- `PLAN_OR_REQUIREMENTS`: Task N from [plan-file]
- `BASE_SHA`: [commit before task]
- `HEAD_SHA`: [current commit]
- `DESCRIPTION`: [task summary]

After spawn, print the roster entry: `code-quality-reviewer: <runtime name> [general-purpose]`.

**In addition to standard code quality concerns, the reviewer should check:**
- Does each file have one clear responsibility with a well-defined interface?
- Are units decomposed so they can be understood and tested independently?
- Is the implementation following the file structure from the plan?
- Did this implementation create new files that are already large, or significantly grow existing files? (Don't flag pre-existing file sizes — focus on what this change contributed.)

**Code reviewer returns:** Strengths, Issues (Critical/Important/Minor), Assessment
