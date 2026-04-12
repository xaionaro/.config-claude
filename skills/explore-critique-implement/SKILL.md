---
name: explore-critique-implement
description: Use when solving any non-trivial problem where the solution space is uncertain — research options via a separate agent, adversarially critique them via a different agent, then loop (implement → critique) until the critic finds nothing. Skip only for single-line or trivial changes.
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

Coding task? Every subagent prompt (explorer, critic, implementer) must include: "Before starting, load the `<language>-coding-style` skill (e.g., `go-coding-style`, `python-coding-style`) and follow its rules."

## Loop structure

Each iteration tackles one change. All four steps run per iteration. Do not advance to next change until current one passes all steps.

| Step | Phase | Actor | Output |
|------|-------|-------|--------|
| 1 | Explore | Separate research agent | Ranked options + cited sources |
| 2 | Critique explorations | Different critic agent | Winner with CONCRETE TEXT |
| 3 | Implement | Implementer (subagent or main) | One diff |
| 4 | Review gate (parallel) | Critic A + Critic B + E2E agent | All three run concurrently; wait for all |
| Exit | Main thread | Apply / commit / report |

**Never run any step in the same session as the previous step's producer.** Main thread orchestrates; agents produce.

## Step 1: Explore

Spawn a separate agent. Prompt must include:
- The problem/change for THIS iteration, in full context.
- What's already been tried or ruled out (iterations 2+: include results from prior iterations, current codebase state, and last blocking gate issues verbatim if a prior cycle's gate failed).
- Exact file paths of existing related code — explorer must read them first to avoid suggesting duplicates.
- Required output: ranked options, each with {what, why, where it applies, cost, tradeoffs}.
- Required citations tagged T1-T5 per `claim verification` hierarchy. Primary sources only for T1.
- Word cap on the report (default: 1000 words).

## Step 2: Critique explorations

Spawn a DIFFERENT agent — not the explorer, not the main thread.

The critic's prompt must include:
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

One change, one diff. Code tasks: implementer invokes `superpowers:test-driven-development`, `debugging-discipline`, and the applicable `<language>-coding-style` skill.

## Step 4: Review gate (parallel)

Spawn all three agents in a single message (parallel Agent tool calls). Wait for all three to complete before evaluating results.

### Critic A — correctness

Emits only issues that, if unresolved, would make the change wrong, unsafe, or contradict its concrete text. Polish and taste items do not belong.

### Critic B — long-term health

Different agent from Critic A. Two independent perspectives catch what one misses.

Focus — adversarial, long-term lens:
- **Tech debt**: Does this change introduce coupling, hidden dependencies, or shortcuts that will cost more to fix later than to fix now?
- **Coding style**: Load the applicable `<language>-coding-style` skill. Does the diff follow naming, error handling, structure, and idiom conventions?
- **Code smells**: God methods, feature envy, primitive obsession, duplicated logic, unclear names, missing abstractions (or premature ones). Flag only smells that materially hurt readability or maintainability — not nitpicks.
- **Architectural fit**: Does the change sit in the right layer? Does it respect existing module boundaries?

Critic B emits only issues that matter for long-term health. "Would refactor eventually" is not an issue — "will cause bugs or confusion within 3 months" is.

### E2E agent — end-to-end verification

**Code/debugging tasks only.** Skip for non-code tasks (docs, config, design).

1. Build the project. Compilation failure = issue.
2. Run full test suite. Failures = issue.
3. Exercise the affected feature through real UI or API as a user would. Verify observable outcomes (output, screenshots, state). Proxy evidence (unit tests pass, linter clean) alone insufficient — direct evidence required.
4. Confirm no regressions in related features.

### Evaluating results

Collect results from all three agents. If ANY agent found issues → spawn a new implementer agent (not any gate agent) to apply the fix → re-run the entire gate. Repeat until all three return zero issues in the same run.

Cap gate retries at 3 per cycle. If the gate still fails after 3 retries, count the cycle as failed and proceed to the next full cycle (Steps 1-4 from scratch), or escalate if at cycle 3.

"Clean pass" = Critic A zero issues + Critic B zero issues + E2E pass, all from the same gate run.

## Iteration limit

**3 full cycles (explore → critique → implement → review gate) per change.** If cycle 3 still fails, do not attempt a 4th — escalate to user with: (a) the original problem, (b) what each cycle tried, (c) the last blocking issue that could not be resolved, (d) the next-best alternative from the explorer's ranking. Silent punts forbidden.

## Exit conditions

- All changes landed with clean pass from review gate, OR
- Iteration limit hit → escalate, do not force.

## Red flags

| Symptom | Fix |
|---------|-----|
| Implementing 2+ changes before re-critiquing | Stop. One at a time |
| "Good enough" at cycle 3 | Escalate per iteration-limit rule, don't settle |
| Any two of {explorer, Step 2 critic, implementer, Critic A, Critic B, E2E agent} are the same agent | Banned. Six distinct agents per cycle |
| Skipping E2E inside loop | E2E is part of the review gate — runs every iteration, not at the end |
| Skipping exploration or critique for later iterations | Every iteration runs all four steps — none are optional |
| Winner lacks concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list in Step 2 | Critic is not adversarial. Re-spawn |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `superpowers:brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | Full multi-role pipeline for large builds. This skill is the medium-task pattern (explore → critique → implement → parallel review gate). Borrow its Snitch rubber-stamp check: critic citing zero issues beyond producer's self-reports = re-spawn with harsher prompt. |
| `superpowers:systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
