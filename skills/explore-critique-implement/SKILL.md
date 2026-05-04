---
name: explore-critique-implement
description: Use when solving any non-trivial problem where the solution space is uncertain — research options via a persistent explorer teammate, adversarially critique them via fresh agents, then loop (implement → critique) until the critic finds nothing. Skip only for single-line or trivial changes.
---

# Explore-Critique-Implement

Separate the hand that builds from the hand that tears down. The builder cannot credibly critique its own output.

## When to use

| Use | Skip |
|-----|------|
| Solution space uncertain | Single-line change |
| 2+ plausible approaches | Trivial typo or reformat |
| Correctness is load-bearing | Throwaway experiment |
| Research would reduce uncertainty | Mechanical rename |

## Prerequisites

Coding task? Every subagent prompt (explorer, critic, implementer) must include: "Before starting, load the `<language>-coding-style` skill and follow its rules."

## Engagement marker

The PreToolUse gate `~/.claude/hooks/eci-active-gate.sh` denies direct Edit/Write/MultiEdit on the main thread while engaged. Every code change must flow through a subagent or teammate. Subagents and teammates write from their own session — the marker is keyed to the orchestrator's session and is absent in theirs, so neither trips this gate. The Stop hook exemption for `eci-implementer` uses a different scope — see `hooks/stop-gate.sh`.

| Step | Command | When |
|------|---------|------|
| Engage | `~/.claude/bin/eci-active on "<task + scope>"` | Before Step 1 of the first iteration |
| Disengage | See Teardown sequence below | Clean pass landed, hard escalate, or user confirms scope closed |

Do not disengage mid-task to escape the gate — that is the regression this marker exists to catch. If a hand-edit feels necessary, SendMessage the persistent `implementer` teammate.

## Team setup

**Teammate** = persistent (TeamCreate + named Agent + SendMessage). **Subagent** = fresh (Agent tool, no `team_name`).

Persistent teammates handle Step 1 (explorer) and Step 3 (implementer) across iterations. Fresh-role work (Step 2 critic, Critic A, Critic B, E2E, brainstormer, loop-breaker) spawns fresh Agent-tool subagents — never SendMessage to a teammate.

CLAUDE_ROLE must be set in the teammate's *process env* — this only applies to teammates launched as independent claude CLI processes (e.g. ATE-style tmux panes). Use `claude-as-role <role>` (or `CLAUDE_ROLE=<role> claude ...`) when launching. Setting CLAUDE_ROLE inside the spawn-prompt body has no effect — that's text the agent reads, not env. Agent-tool sidechain teammates (`team_name`+`name` to the Agent tool) do NOT fire the Stop hook in current Claude Code, so the env mechanism does not apply to them; only fresh subagents (E2E/critics/brainstormer) which also never fire Stop. The TeamCreate-spawned `team-lead` pseudo-role is the orchestrator's own session — it has no separate Stop hook either; the orchestrator's stop serves as the lead's. The exemption is therefore only load-bearing when ECI teammates are launched as independent claude processes.

### Spawning

| Action | Command |
|--------|---------|
| Create team | `TeamCreate eci-<short-task-slug>` |
| Spawn explorer (persistent, sidechain) | Agent tool: `team_name=eci-<slug>`, `name=explorer` |
| Spawn explorer (persistent, independent process) | tmux pane: `claude-as-role explorer ...` |
| Spawn implementer (persistent, sidechain) | Agent tool: `team_name=eci-<slug>`, `name=implementer` |
| Spawn implementer (persistent, independent process) | tmux pane: `claude-as-role eci-implementer ...` |
| Spawn fresh-role agent | Agent tool with no `team_name` |

**Teammate `subagent_type` must include team tools** (SendMessage, TaskUpdate, etc.). Use `general-purpose` (or any full-capability type). Read-only types — `feature-dev:code-explorer`, `feature-dev:code-architect`, `feature-dev:code-reviewer`, `Explore`, `Plan` — lack SendMessage and cannot reply to the lead. The teammate will then say it has no SendMessage and the cycle stalls.

### CLAUDE_ROLE per role (canonical)

Stop-hook role allowlist references this table. Keep `hooks/stop-gate.sh` case statement and `bin/claude-as-role` allowlist in sync.

| Role | CLAUDE_ROLE | Persistence |
|------|-------------|-------------|
| Explorer | `explorer` | Persistent teammate |
| Implementer | `eci-implementer` | Persistent teammate |
| Step 2 critic | `reviewer` | Fresh subagent |
| Critic A | `reviewer` | Fresh subagent |
| Critic B | `reviewer` | Fresh subagent |
| Loop-breaker | `reviewer` | Fresh subagent |
| E2E agent | `verifier` | Fresh subagent |
| Brainstormer | `brainstormer` | Fresh subagent |

### Explorer spawn-prompt baseline

Per-message body in Step 1.
- `name`/`team_name` per Spawning table. For independent-process teammates, launch via `claude-as-role explorer` (sets CLAUDE_ROLE in process env).
- "Treat each new task message as a fresh assignment per Step 1 of the ECI skill. Re-read every referenced file each turn — do not trust prior-turn reads."

### Implementer spawn-prompt baseline

Per-message body in Step 3.
- `name`/`team_name` per Spawning table. For independent-process teammates, launch via `claude-as-role eci-implementer`.
- "Treat each new task message as a fresh assignment per Step 3 of the ECI skill. Re-read every file you intend to modify each turn."
- One commit per logical change.

## Teardown sequence

Run in this exact order on disengage. Stopping mid-sequence keeps the gate armed.

1. Write disengage-report markdown (content per **Disengage report** below).
2. SendMessage `commit any uncommitted work and confirm clean tree` to `implementer`; await ack.
3. SendMessage `{"type": "shutdown_request"}` to `implementer`, then to `explorer`.
4. Read incoming turns until both `shutdown_response` received OR 60s elapsed.
   - If a teammate hasn't responded by 60s → `tmux kill-pane -t <pane>` (ATE harsh-fallback; see ATE Shutdown procedure for pane resolution).
5. `TeamDelete eci-<slug>`.
6. `~/.claude/bin/eci-active off <report.md>` (LAST — keeps gate armed if teardown fails partway).

If the orchestrator's next Stop blocks for proof, copy the disengage report to `$PROOF_DIR/proof.md`.

### Disengage report

`~/.claude/bin/eci-active off` requires a markdown report walking the stop checklist (`~/.claude/hooks/stop-checklist.md`) and critically analyzing items that could not be fully complied with during the ECI scope. Required sections:

```
## Stop checklist walkthrough
- Questions: pass/fail/N-A — <one-line evidence>
- Git: pass/fail/N-A — <one-line evidence>
- Completion: pass/fail/N-A — <one-line evidence>
- Root cause: ...
- Adversarial self-critique: ...
- Assumed blockers: ...
- Rule-compliance self-audit: ...
- Testing: ...

## Incomplete compliance
- <item> — could not fully comply because <reason>; impact: <what slipped>
- ...
fully-compliant: <reason rule-by-rule>   # only if no incomplete items
```

The bin rejects reports missing either header or with an empty walkthrough. Validation is a content gate, not a wordcount — write substance, not boilerplate.

## Loop structure

Each iteration tackles one change. All four steps run per iteration. Do not advance to next change until current one passes all steps.

| Step | Phase | Actor | Output |
|------|-------|-------|--------|
| 1 | Explore | Persistent `explorer` teammate (SendMessage) | Ranked options + cited sources |
| 2 | Critique explorations | Fresh Agent-tool subagent | Winner with CONCRETE TEXT |
| 3 | Implement | Persistent `implementer` teammate (SendMessage) | One diff |
| 4 | Review gate (parallel) | Critic A + Critic B + E2E agent — fresh Agent-tool subagents in parallel | All three run concurrently; wait for all |
| Exit | Main thread | Apply / commit / report |

Agent separation: see Red Flags. Main thread orchestrates; agents produce.

## Step 1: Explore

SendMessage to the persistent `explorer` teammate. Each per-message body must include:
- The problem/change for THIS iteration, in full context.
- What's already been tried or ruled out (iterations 2+: include results from prior iterations, current codebase state, and last blocking gate issues verbatim if a prior cycle's gate failed).
- Exact file paths of existing related code — explorer must re-read them this turn to avoid suggesting duplicates. "Re-read referenced files; do not trust prior turn reads."
- Required output: ranked options, each with {what, why, where it applies, cost, tradeoffs}.
- Required citations tagged T1-T5 per `claim verification` hierarchy. Primary sources only for T1.
- Word cap on the report (default: 1000 words).

## Step 2: Critique explorations

Spawn a DIFFERENT agent — not the explorer, not the main thread. Spawn as a fresh Agent-tool subagent. MUST NOT SendMessage to the persistent `explorer` or `implementer` teammate.

The critic's prompt must include:
- **Original user requirements verbatim.** The critic must verify options against what the user actually asked for, not just technical soundness.
- **"Step 0 — Independent baseline."** Read the source material (target file, existing code, prior art) and write your own 3-5 bullet assessment BEFORE opening the explorer's report. Include this baseline in the critique output.
- "Assume every suggestion is wrong until you prove otherwise."
- "Read the current state first" (the file/code/doc the explorer was working on) — verify duplication claims independently.
- **Cite-verify protocol:**
  - Fetch every T1/T2 URL via WebFetch; use Read for source-code citations.
  - Unfetchable URL (auth-gated, internal, tool unavailable) → flag "unverified — could not fetch" + state whether dependent claim is load-bearing.
  - Load-bearing = any citation justifying a KEEP/MODIFY verdict. Load-bearing + unfetchable = issue.
  - Quote the exact supporting passage. Flag hallucinated URLs, misquotes, and training-recall mislabeled as T1.
  - Non-load-bearing citations may be skipped if explicitly marked "non-load-bearing: no verdict depends on this source."
  - T3/T4: sample, not exhaustive.
- Per-option verdict: KEEP / MODIFY / REJECT / DUPLICATE, with evidence-tied justification.
- **Pick the winner** — one option with CONCRETE TEXT of the proposed change, not "add a section". If no option survives, the iteration ends with no implementation (report to main thread why).
- Rejected list with per-item reason.
- Single-option explorations get the same adversarial treatment — one option is not an automatic winner. REJECT is valid.
- "Be harsh. Most suggestions are noise. Zero survivors is a valid outcome."

## Step 3: Implement

SendMessage to the persistent `implementer` teammate. One change, one diff per message. Code tasks: implementer invokes `superpowers:test-driven-development`, `debugging-discipline`, and the applicable `<language>-coding-style` skill on each new task message; re-reads every file it intends to modify.

Each new task message to `implementer` includes:
- The current iteration's concrete-text from the Step 2 critic (verbatim).
- Iterations 2+: prior iteration's gate findings (verbatim) and files changed since the last message.

**E2E before submit (code/debugging tasks).** Implementer must, before reporting done: build, run full test suite, exercise the affected feature through real UI/API as a user. Cite direct evidence (output, screenshot, observed state). Proxy evidence (unit tests, lint) insufficient. No E2E evidence in submission = orchestrator bounces back without spawning the gate.

If submission lacks E2E evidence, SendMessage: "Submission lacks E2E evidence — re-run build, test suite, and user-path exercise; cite output. Do not re-submit until evidence is in the message body."

## Step 4: Review gate (parallel)

Spawn all three as fresh Agent-tool subagents in a single message (three parallel Agent tool calls). Each MUST NOT SendMessage to the persistent `explorer` or `implementer` teammate. Wait for all three to complete before evaluating results. Every reviewer prompt must include the **original user requirements verbatim** — reviewers catch requirement deviations, not just technical issues.

### Issue severity codes

Every issue from Critic A and Critic B must carry exactly one code:

| Code | Meaning | Effect |
|------|---------|--------|
| **REJECT** | Would make the change wrong, unsafe, or contradictory | Triggers gate re-run after fix |
| **CONDITIONAL** | Fix needed, but obvious/trivial enough to trust without re-review | Must be fixed; no re-run needed |
| **NIT** | Soft recommendation | May be ignored |

Both critics tag every issue per the severity codes table above.

### Critic A — correctness

Emit only issues affecting correctness, safety, or fidelity to the concrete text. Interface contract fulfillment — does every interface implementation actually work, not just compile? Polish and taste items are NITs at most.

### Critic B — long-term health

Different agent from Critic A.

Focus — adversarial, long-term lens:
- **Tech debt**: Coupling, hidden dependencies, or shortcuts costing more to fix later than now?
- **Coding style**: Load the applicable `<language>-coding-style` skill. Does the diff follow naming, error handling, structure, and idiom conventions?
- **Code smells**: God methods, feature envy, primitive obsession, duplicated logic, unclear names, missing/premature abstractions. Flag only smells that materially hurt readability or maintainability.
- **Architectural fit**: Right layer? Respects module boundaries? Code in correct binary/package per its stated purpose?

Emit only issues that matter for long-term health. "Would refactor eventually" is not an issue — "will cause bugs or confusion within 3 months" is.

### E2E agent — end-to-end verification

**Code/debugging tasks only.** Skip for non-code tasks (docs, config, design).

1. Build the project. Compilation failure = issue.
2. Run full test suite. Failures = issue.
3. Exercise the affected feature through real UI or API as a user would. Verify observable outcomes (output, screenshots, state). Proxy evidence (unit tests pass, linter clean) alone insufficient — direct evidence required.
4. Confirm no regressions in related features.

### Evaluating results

Collect results from all three agents. Apply severity logic:

- At least one REJECT from Critic A or Critic B, OR any E2E failure → fix all REJECTs, CONDITIONALs, and E2E failures → re-run gate.
- Zero REJECTs but CONDITIONALs exist → fix them → gate passes (no re-run).
- Only NITs → gate passes.

Gate retry and cycle limits defined in Escalation table.

**Clean pass** = zero REJECTs + zero CONDITIONALs + E2E pass, all from the same gate run.

## Brainstormer (unblocker)

Fresh idea generator — fires on-demand when the cycle stalls. Output is raw ideas only; never decisions, verdicts, or filtering. Bigger list = better.

| Trigger | Action |
|---------|--------|
| Explorer returned zero viable options | Spawn brainstormer → feed ideas into a new explorer |
| Step 2 critic rejected every option | Spawn brainstormer → feed ideas into a new explorer |
| Implementer dead-end inside Step 3 | Spawn brainstormer → feed ideas into a new implementer prompt |

### Prompt requirements

- Original problem + everything tried so far, verbatim.
- Current code/file paths — brainstormer reads them independently.
- "Generate as many distinct ideas as possible. No filtering, no feasibility judgment, no negatives. Bigger list = better."
- "You are NOT one of the cycle agents. Do not trust prior agent summaries."

### Constraints

- Spawned as fresh Agent-tool subagent; never SendMessage to a persistent teammate.
- Must NOT be any cycle agent (explorer, Step 2 critic, implementer, Critic A, Critic B, E2E, loop-breaker).
- Each invocation = distinct fresh agent.
- Ideas only — the next cycle agent does the filtering.

## Loop-breaker

A FRESH agent — not any of the cycle agents — gets one chance to break the loop before escalating to the user.

**One loop-breaker invocation per change**, regardless of trigger. If the granted retry fails → hard escalate to user.

### Prompt must include

- Original problem statement.
- All cycle attempts: what was tried, what failed, remaining issues verbatim.
- Current code state (file paths — loop-breaker reads them independently).
- "You are a fresh reviewer. Read the code and issues yourself. Do not trust prior agents' assessments."

### Decision — exactly one of

| Decision | Meaning | Effect |
|----------|---------|--------|
| **ACCEPT** | Remaining issues are cosmetic, speculative, or not worth another iteration | Accept current state with reasoning. Gate passes. |
| **RETRY** | Remaining issues are real and fixable | Grant exactly one more attempt (gate retry or full cycle, matching the trigger). Provide specific guidance. |

### Constraints

- Spawned as fresh Agent-tool subagent; never an existing teammate.
- Must NOT be any of the 6 cycle agents (explorer, Step 2 critic, implementer, Critic A, Critic B, E2E agent).
- Reads code and issues independently — no reliance on prior agent summaries.
- One invocation per change. Granted retry fails → escalate to user.

## Escalation

Single decision table for all limit hits. One loop-breaker per change total.

| Trigger | Condition | Action | If retry fails |
|---------|-----------|--------|----------------|
| Gate retry cap | 3 gate retries failed within one cycle | Invoke loop-breaker (if not yet used for this change) | Hard escalate to user |
| Cycle limit | 3 full cycles failed for one change | Invoke loop-breaker (if not yet used for this change) | Hard escalate to user |
| Loop-breaker already used | Either limit hit but loop-breaker was consumed by prior trigger | Skip loop-breaker → hard escalate to user immediately | — |

**Hard escalate** = report to user with: (a) original problem, (b) what each cycle tried, (c) loop-breaker's assessment (if invoked), (d) last blocking issue, (e) next-best alternative from explorer's ranking. Silent punts forbidden.

## Iteration limit

Cycle limit defined in Escalation table (3 full cycles per change).

## Exit conditions

- All changes landed with clean pass, OR
- Loop-breaker ACCEPT → current state accepted with reasoning, OR
- Hard escalate triggered → report to user per Escalation table.

## Red flags

| Symptom | Fix |
|---------|-----|
| Implementing 2+ changes before re-critiquing | Stop. One at a time |
| "Good enough" at cycle 3 | Invoke loop-breaker, don't settle or force |
| Any two of {explorer, Step 2 critic, implementer, Critic A, Critic B, E2E agent, loop-breaker} are the same agent | Banned. Up to seven distinct agents (six per normal cycle + loop-breaker at limits) |
| Review-gate Critic A returned before Critic B was spawned | Sequential gate. Spawn Critic A + Critic B (+ E2E when in scope) in one message with parallel Agent tool calls; do not serialize even if one critic's view seems sufficient. |
| Skipping E2E inside loop | E2E is part of the review gate — runs every iteration, not at the end |
| Skipping exploration or critique for later iterations | Every iteration runs all four steps — none are optional |
| Winner lacks concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list in Step 2 | Critic is not adversarial. Re-spawn |
| Brainstormer output filters/judges/picks a winner | Brainstormer is idea-only. Re-spawn with "no filtering, no negatives" |
| Persistent teammate addressed for any fresh-role work (Step 2 critic, Critic A, Critic B, E2E, brainstormer, loop-breaker) | STOP. Spawn fresh Agent-tool subagent instead. |
| Disengage without teardown sequence | STOP. Shutdown teammates → TeamDelete → eci-active off, in that order. |
| Independent-process teammate launched without `claude-as-role`/`CLAUDE_ROLE=` env prefix | STOP. Stop hook will gate every iteration. Re-launch via `claude-as-role <role>`. |
| User-facing report uses task/iteration numbers ("task 3 done", "cycle 2 failed") | Numbers mean nothing to user. Name the change instead ("severity codes table done", "auth middleware swap failed"). |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `superpowers:brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | Full multi-role pipeline for large builds. This skill is the medium-task pattern (explore → critique → implement → parallel review gate). ECI shares the team mechanism (TeamCreate / SendMessage / TeamDelete + harsh-fallback `tmux kill-pane` per ATE Shutdown procedure) for the persistent explorer + implementer. Borrow its Snitch rubber-stamp check: critic citing zero issues beyond producer's self-reports = re-spawn with harsher prompt. |
| `superpowers:systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
