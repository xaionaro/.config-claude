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
| 3 | Loop: Critique implementation | Different critic agent | Issues list or "clean" |
| 4 | E2E confirmation | Main thread or subagent | Pass/fail with evidence |
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

## Phase 3: Loop (Implement → Critique)

1. **Implement one item at a time.** No batching — one shortlist item, one diff. Code tasks: implementer invokes `superpowers:test-driven-development`, `debugging-discipline`, and the applicable `<language>-coding-style` skill.
2. **Critique the diff.** Spawn a different critic agent — never the implementer, never the main thread. Self-critique is banned: producers systematically underweight their own errors.
3. **Issues found → fix → re-critique.** Repeat until clean pass. Critic emits only issues that, if unresolved, would make the item wrong, unsafe, or contradict its concrete text. Polish and taste items do not belong in the critique — they waste cycles and invite aesthetic churn. "Clean pass" = the critic returns zero issues.
4. **Loop limit: 3 implement→critique cycles per item.** If cycle 3 still ends in rejection, do not attempt a 4th — escalate to user with: (a) the original shortlist item, (b) diff of each cycle's changes, (c) the last blocking issue that could not be resolved, (d) the next-best alternative from the explorer's ranking. Silent punts forbidden.

## Phase 4: E2E Confirmation

**Implementation and debugging tasks only.** Skip for non-code tasks (docs, config, design).

After all shortlist items land with clean critique, run end-to-end verification:
1. Build the project. Compilation failure = back to Phase 3.
2. Run full test suite. Failures = back to Phase 3.
3. Exercise the affected feature through real UI or API as a user would. Verify observable outcomes (output, screenshots, state). Proxy evidence (unit tests pass, linter clean) alone insufficient — direct evidence required.
4. Confirm no regressions in related features.

Fail at any step → return to Phase 3 with specific failure as new issue.

## Exit conditions

- All shortlist items landed with clean critique + Phase 4 passed (code/debug tasks), OR
- Loop limit hit on any item → escalate, do not force, OR
- Critic finds no further actionable issues + Phase 4 passed (code/debug tasks).

## Red flags

| Symptom | Fix |
|---------|-----|
| Implementing 2+ items before re-critiquing | Stop. One at a time |
| "Good enough" at cycle 3 | Escalate per loop-limit rule, don't settle |
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
