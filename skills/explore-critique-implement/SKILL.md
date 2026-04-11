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

## Phases

| # | Phase | Actor | Output |
|---|-------|-------|--------|
| 1 | Explore | Separate research agent | Ranked options + cited sources |
| 2 | Critique explorations | Different critic agent | Per-option verdict + shortlist |
| 3 | Loop: Implement | Implementer (subagent or main) | One shortlist item applied |
| 3 | Loop: Critique implementation | Different critic agent OR self-critique | Issues list or "clean" |
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
- "Assume every suggestion is wrong until you prove otherwise."
- "Read the current state first" (the file/code/doc the explorer was working on) — verify duplication claims independently.
- "Independently verify a sample of the explorer's citations" — fetch URLs, read primary sources. Flag hallucinated or misquoted citations.
- Per-option verdict: KEEP / MODIFY / REJECT / DUPLICATE, with evidence-tied justification.
- Shortlist of survivors with CONCRETE TEXT of the proposed change, not "add a section".
- Rejected list with per-item reason.
- "Be harsh. Most suggestions are noise. Fewer survivors is fine."

## Phase 3: Loop (Implement → Critique)

1. **Implement one item at a time.** No batching — one shortlist item, one diff.
2. **Critique the diff.** Either spawn a different critic agent OR self-critique by re-reading the diff against the critic's Phase-2 checks. Prefer a separate agent when the change is load-bearing.
3. **Issues found → fix → re-critique.** Repeat until clean pass.
4. **Loop limit: 3 implement→critique cycles per item.** At round 4, escalate to user with what was tried.

## Exit conditions

- All shortlist items landed with clean critique, OR
- Loop limit hit on any item → escalate, do not force, OR
- Critic finds no further actionable issues.

## Red flags

| Symptom | Fix |
|---------|-----|
| Same session explores and critiques | Spawn separate agent for critique |
| Critic rubber-stamps (0 rejections, 0 citations verified) | Re-spawn with harsher adversarial prompt |
| Critic paraphrases explorer's rationale | Not independent. Reject. Re-spawn |
| Citations not fetched by critic | Critic uses tools, not training recall |
| Implementing 2+ items before re-critiquing | Stop. One at a time |
| Main thread researching or critiquing | Delegate. Main thread orchestrates only |
| "Good enough" at round 3 | Escalate, don't settle |
| Critic sees explorer's output before writing its own assessment of the source material | Order: read source → form view → then read explorer |
| Shortlist items lack concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list | Critic is not adversarial. Re-spawn |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `superpowers:brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | Full multi-role pipeline for large builds. This skill is the lightweight 2-agent pattern for smaller, research-heavy tasks. |
| `superpowers:systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
