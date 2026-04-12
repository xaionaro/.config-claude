---
name: explore-critique-implement
description: Use when solving any non-trivial problem where the solution space is uncertain — research options via a separate agent, adversarially critique them via a different agent, then loop (implement → critique) until the critic finds nothing. Skip only for single-line or trivial changes.
---

# Explore-Critique-Implement

Separate the hand that builds from the hand that tears down. The builder cannot credibly critique its own output. Every producer gets a different critic.

## When to use

| Use | Skip |
|-----|------|
| Solution space uncertain | Single-line change |
| 2+ plausible approaches | Trivial typo or reformat |
| Correctness is load-bearing | Throwaway experiment |
| Research would reduce uncertainty | Mechanical rename |

## Prerequisites

Coding task? Every subagent prompt (explorer, critic, implementer) must include: "Before starting, load the `<language>-coding-style` skill (e.g., `go-coding-style`, `python-coding-style`) and follow its rules."

## Phases

| # | Phase | Actor | Output |
|---|-------|-------|--------|
| 1 | Explore | Separate research agent | Ranked options + cited sources |
| 2 | Critique explorations | Different critic agent | Per-option verdict + shortlist |
| 3 | Loop: Implement | Implementer (subagent or main) | One shortlist item applied |
| 3a | Loop: General critique | Critic agent A | Issues list or "clean" |
| 3b | Loop: Tech debt / style critique | Critic agent B (not A) | Debt/smell issues or "clean" |
| 3c | Loop: E2E verification | Main thread or subagent | Pass/fail with evidence |
| Exit | Main thread | Apply / commit / report |

**Never run any phase in the same session as the previous phase's producer.** Main thread orchestrates; agents produce.

## Phase 1: Explore

Spawn a separate agent. Prompt must include:
- The problem, in full context.
- What's already been tried or ruled out.
- Exact file paths of existing related code — explorer must read them first to avoid suggesting duplicates.
- Required output: ranked options, each with {what, why, where it applies, cost, tradeoffs}.
- Required citations tagged T1-T5 per `claim verification` hierarchy. Primary sources only for T1.
- Word cap on the report.

## Phase 2: Critique explorations

Spawn a DIFFERENT agent — not the explorer, not the main thread.

The critic's prompt must include:
- **"Step 0 — Independent baseline."** Read the source material (target file, existing code, prior art) and write your own 3-5 bullet assessment BEFORE opening the explorer's report. Include this baseline in the critique output so independence is auditable.
- "Assume every suggestion is wrong until you prove otherwise."
- "Read the current state first" (the file/code/doc the explorer was working on) — verify duplication claims independently.
- **Cite-verify protocol.** Default: fetch every T1/T2 URL the explorer cites. Use WebFetch. Quote the exact passage that supports the claim. Flag hallucinated URLs, misquoted findings, training-recall masquerading as T1. A citation may be skipped only if the critic explicitly writes "non-load-bearing: no verdict depends on this source" next to it — load-bearing means any citation the explorer uses to justify a KEEP/MODIFY verdict. T3/T4 references may be sampled.
- Per-option verdict: KEEP / MODIFY / REJECT / DUPLICATE, with evidence-tied justification.
- Shortlist of survivors with CONCRETE TEXT of the proposed change, not "add a section".
- Rejected list with per-item reason.
- "Be harsh. Most suggestions are noise. Fewer survivors is fine."

## Phase 3: Loop (Implement → Critique → Critique → E2E)

For each shortlist item, run the full loop: implement, two independent critiques, E2E verification. Do not advance to the next item until the current one passes all steps.

### 3.1 Implement

One shortlist item, one diff. No batching. Code tasks: implementer invokes `superpowers:test-driven-development`, `debugging-discipline`, and the applicable `<language>-coding-style` skill.

### 3.2 General critique (Critic A)

Spawn a critic agent — never the implementer, never the main thread. Self-critique is banned.

Focus: correctness, safety, contract violations, contradictions with the shortlist item's concrete text. Emits only issues that, if unresolved, would make the item wrong, unsafe, or contradict its concrete text. Polish and taste items do not belong — they waste cycles and invite aesthetic churn.

### 3.3 Tech debt / style / smell critique (Critic B)

Spawn a DIFFERENT critic agent — not Critic A, not the implementer, not the main thread. Two independent perspectives catch what one misses.

Focus — adversarial, long-term lens:
- **Tech debt**: Does this change introduce coupling, hidden dependencies, or shortcuts that will cost more to fix later than to fix now?
- **Coding style**: Load the applicable `<language>-coding-style` skill. Does the diff follow naming, error handling, structure, and idiom conventions?
- **Code smells**: God methods, feature envy, primitive obsession, duplicated logic, unclear names, missing abstractions (or premature ones). Flag only smells that materially hurt readability or maintainability — not nitpicks.
- **Architectural fit**: Does the change sit in the right layer? Does it respect existing module boundaries?

Critic B emits only issues that matter for long-term health. "Would refactor eventually" is not an issue — "will cause bugs or confusion within 3 months" is.

### 3.4 Fix → re-critique

Issues from either critic → fix → re-critique (both critics review again). Repeat until both return zero issues. "Clean pass" = both Critic A and Critic B return zero issues.

### 3.5 E2E verification

**Code/debugging tasks only.** Skip for non-code tasks (docs, config, design).

After clean pass from both critics:
1. Build the project. Compilation failure = back to 3.1.
2. Run full test suite. Failures = back to 3.1.
3. Exercise the affected feature through real UI or API as a user would. Verify observable outcomes (output, screenshots, state). Proxy evidence (unit tests pass, linter clean) alone insufficient — direct evidence required.
4. Confirm no regressions in related features.

Fail at any step → return to 3.1 with specific failure as new issue.

### Loop limit

**3 full cycles (implement → critiques → E2E) per item.** If cycle 3 still fails, do not attempt a 4th — escalate to user with: (a) the original shortlist item, (b) diff of each cycle's changes, (c) the last blocking issue that could not be resolved, (d) the next-best alternative from the explorer's ranking. Silent punts forbidden.

## Exit conditions

- All shortlist items landed with clean pass from both critics + E2E passed (code/debug tasks), OR
- Loop limit hit on any item → escalate, do not force, OR
- Both critics find no further actionable issues + E2E passed (code/debug tasks).

## Red flags

| Symptom | Fix |
|---------|-----|
| Implementing 2+ items before re-critiquing | Stop. One at a time |
| "Good enough" at cycle 3 | Escalate per loop-limit rule, don't settle |
| Same agent for both critiques | Banned. Critic A ≠ Critic B ≠ implementer. Three distinct agents minimum |
| Skipping E2E inside loop | E2E runs every cycle, not just at the end |
| Shortlist items lack concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list in Phase 2 | Critic is not adversarial. Re-spawn |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `superpowers:brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | Full multi-role pipeline for large builds. This skill is the lightweight 2-agent pattern for smaller, research-heavy tasks. Borrow its Snitch rubber-stamp check: critic citing zero issues beyond producer's self-reports = re-spawn with harsher prompt. |
| `superpowers:systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
| `<lang>-coding-style` | Language conventions. Each subagent loads it directly for coding tasks. |
