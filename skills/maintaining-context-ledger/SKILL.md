---
name: maintaining-context-ledger
description: Use when writing or verifying project-understanding ledgers, context ledgers, ECI/ATE session ledgers, handoff context, or stop-hook ledger updates — keeps the ledger a current-state snapshot and the high-level log an append-only history, side by side
---

# Maintaining Context Ledgers

Two files, side by side, both required:

| File | Role | Edit mode |
|------|------|-----------|
| `project-understanding.md` (the **ledger**) | Current-state snapshot | Rewrite in place; stale entries deleted |
| `high_level_log.md` (the **log**) | Append-only history of every material change | Append only; never edit, never delete past entries |

The ledger answers *what is true now*. The log answers *what happened, in order, and why we believe what's now in the ledger*. They are not redundant — the ledger has no history; the log has no synthesis.

## Core Rule

A fresh agent reading only the ledger (no transcript, no memory) must reach the same current understanding you have. Record every project/task detail that could affect planning, implementation, risk handling, assignment, command choice, verification, or the final answer.

**Err on exhaustive useful detail for current state.** Do not omit a detail because it seems obvious from transcript, local state, prior agent memory, or project familiarity — the next agent has none of those. Equally: do not retain a detail because it was true earlier. Exhaustive on **current** state; zero on superseded state.

## Storage

For ECI/ATE, both files live at:

```text
~/.cache/claude-proof/$SESSION_ID/project-understanding.md   # the ledger
~/.cache/claude-proof/$SESSION_ID/high_level_log.md          # the log
```

Do not store either file in the project/repo.

## High-Level Log

Append-only history. Every material change recorded in the ledger gets a corresponding entry appended to the log at the same moment.

| Rule | Detail |
|------|--------|
| Append only | Never edit, reorder, or delete past entries — even if they later turn out wrong. Wrong entries are corrected by a *new* appended entry referencing the prior one. |
| Reflect all details | Capture the change itself, the prior state, the new state, the reason, the source/evidence, and the agent/turn that made it. The log is the place for the history the ledger drops. |
| Chronological | Newest entries at the bottom. Each entry leads with a UTC timestamp. |
| Same-turn pairing | Every ledger update has at least one log entry from that turn. A ledger diff with no log append is a defect. |
| No synthesis | The log records what changed; it does not duplicate the ledger's current-state synthesis. Cross-reference by section/heading instead. |

Suggested entry shape (adapt as needed, but keep timestamp + change + reason + evidence):

```text
## 2026-05-08T14:22Z — Decisions / library choice
- Was: undecided between X and Y.
- Now: chose Y.
- Why: <reason, in one sentence>.
- Evidence: <commit | report path | command output reference>.
- Agent: <runtime name / role>.
```

## Current State, Not History

| Case | Ledger Action |
|------|---------------|
| Mutable fact changes | Replace value in place; never append beside old |
| Hypothesis disproved, plan abandoned, decision reversed | Delete the obsolete entry; keep only the surviving conclusion |
| Old state explains a binding constraint or hazard | Keep only the needed history and why it still matters |
| Step finishes | Record verdict + resulting state + evidence link; drop the "in progress" entry |
| Detailed report exists elsewhere | Link it; don't copy body, substeps, transcripts, bullet lists |
| User corrects an agent mistake | Record corrected fact, affected state, recurrence guard, source link |
| Task/blocker resolved | Move to completed milestones with link, or delete |

Skip blow-by-blow history unless it prevents recurrence.

### Log vs Ledger

A given fact lives in one file, not both. Route by edit mode:

| Content | Ledger | Log |
|---|---|---|
| "14:22 — tried A, failed" | — | append |
| "Considered X, chose Y because…" | "Using Y. Why: <reason>." | append the consideration + decision event |
| "Thought bug was in M, found in N" | "Bug: N. Fix: <link>." | append the M→N correction event |
| "Step 1 done. Step 2 done. Step 3 WIP." | "Current: step 3 — <state>. Done: 1, 2 (links)." | append each step transition as it happens |
| Narrative of what each agent did | Current owner + last verdict + next action | append per-agent action when it produced a material change |

Per-ledger-line test: *true and load-bearing right now?* No → drop from ledger; if it captures something material that happened, append to log instead.

## Structure

The ledger is **always** structured. Free-form prose, wall-of-text, and chat-style narration are rejected. Every fact lives under a heading whose subject it belongs to; every section is scannable — table, bullet list, or short labeled lines (`Owner: …`, `Status: …`, `Evidence: …`). No multi-paragraph essays. **No long one-liners** — split multi-clause bullets, semicolon chains, and "and"-joined run-ons into sub-bullets, labeled lines, or table rows. One fact per line. Prefer tables for >2 parallel items.

Choose headings that fit the project. The agent decides the section set, names, and order. The example below is a starting template, not a fixed schema — adopt, drop, rename, or reorder as the work demands:

| Example section | Purpose |
|---------|---------|
| Sources | Authoritative inputs and what each governs |
| Goal | Desired outcome, reason, scope boundaries |
| Requirements | Binding conditions, acceptance criteria, source refs, current status |
| Context | Domain model, terminology, relevant locations, relationships |
| Decisions | Choices made, rationale, tradeoffs, consequences |
| Corrections | User-corrected agent mistakes and recurrence guards |
| Unknowns | Assumptions, risks, blockers, open questions, validation needed |
| Progress | Current work state, owners, completed milestones with report links, WIP, next action |
| Verification | How completion will be proven, evidence links, current verdicts, missing proof |

Use `### <subject>` subsections when a section grows large enough that a fresh agent would have to scan to find a fact. Keep the project's own vocabulary, names, identifiers, and source wording when they are binding. Do not flatten specifics into generic labels.

## Update Points

Update before work starts, after material state changes, after material findings/decisions/agreements, after milestones, after user corrections, before QA/verdicts, before user-waiting stops, and before shutdown.

Three-pass ledger edit, in order:

1. **Stale pass.** Re-read each section; for every line ask *still current?* No → delete or rewrite.
2. **Omission pass.** Add what's missing, checking authoritative sources, user instructions, current diffs/state, and this turn's agent reports.
3. **Fit pass.** Re-read the section list itself. Has the work outgrown the headings? Are facts being shoehorned into a section whose name no longer covers them? Has a subsection grown into a topic of its own? Is a section now empty because its concern is gone? Rename, split, merge, add, or drop sections so the headings match the current shape of the work.

Structure must evolve with the project. A frozen schema that no longer fits is itself a defect. A purely additive diff to the **ledger** is a log-into-ledger defect — rewrite in place.

Then **append to `high_level_log.md`** one entry per material change made this turn. Every passed-around fact the stale pass deleted or rewrote becomes a log entry — that is where the history lives now.

## Invalid Ledger

Reject the ledger if any holds:

- A fresh agent needs the transcript or unstated local memory to recover useful current project/task facts.
- An authoritative source is named without extracting its relevant current-state details.
- Binding requirements, acceptance criteria, user corrections, assumptions, risks, decisions, current state, or evidence are missing.
- Claims cannot be traced to sources, reports, commands, logs, screenshots, or commits.
- Obsolete states are retained as if current (stale plans, abandoned hypotheses, finished WIP, resolved blockers, superseded values).
- Entries are timestamped narrative or chronological "what happened next" prose — i.e. log-style.
- Multiple values for the same fact coexist (old + new) instead of one current value.
- Activity logs or copied report bodies replace current-state summaries and links.
- The latest update is purely additive while sections that should have changed were left untouched.
- Facts are dumped as free-form prose instead of placed under a heading whose subject covers them.
- A section runs as multi-paragraph narrative where a table, bullet list, or labeled lines would scan.
- A line packs multiple facts into a long bullet or run-on sentence (semicolon chains, "and"-joined clauses, multi-clause stuffing) where sub-bullets, labeled lines, or one row/line per fact would scan.
- Headings no longer fit the content (facts shoehorned under a name that does not cover them, subsections that have grown into topics of their own, empty sections kept after their concern is gone).
- The high-level log is missing, was edited or truncated in place, lacks entries for ledger changes made this session, or duplicates the ledger's current-state synthesis instead of recording change history.
- Secrets, credentials, or unnecessary personal data are recorded.
