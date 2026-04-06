---
name: harness-tuning
description: Use when writing or editing skills, system prompts, CLAUDE.md
---

# Harness Tuning

Every token costs context window in every session. Waste is cumulative.

**Core rule:** Every word earns its place. Removing a word doesn't change behavior? Remove it.

## Principles

| # | Rule | Example |
|---|------|---------|
| 1 | One idea per sentence | Split compounds. Cut conjunctions. |
| 2 | Rule first, not reasoning | "Never push without approval" not "Because pushing can cause..." |
| 3 | Tables over prose | Rows scan; paragraphs don't. |
| 4 | No filler | Cut: "It is important to", "Make sure to", "In order to" |
| 5 | Define once, reference elsewhere | Rule in table AND prose AND red flags? Keep table. |
| 6 | Imperatives | "Tag all claims" not "All teammates should tag their claims" |
| 7 | Specific over abstract | "Reject bare `uint64`" not "Ensure strong typing" |
| 8 | Examples compress | One precise example replaces a paragraph. |

## Anti-Patterns

| Verbose | Concise |
|---------|---------|
| "must make sure to always verify that..." | "verifies..." |
| "It is important to note that this is non-negotiable" | (delete) |
| "In the event that a teammate fails to respond" | "Teammate unresponsive:" |
| "Each and every factual claim must be tagged" | "Tag all claims" |
| "Before marking any task as complete, they must verify against..." | "Before marking done:" |

## Targets

| Scope | Max words |
|-------|-----------|
| Session-loaded skills | 200 |
| Complex discipline skills | 1500 |
| CLAUDE.md / system prompts | Minimize ruthlessly |

20%+ word reduction with same rules = better version.

## Process

1. Write content.
2. Each sentence: "Does this change behavior?" No -> delete.
3. Deduplicate. Keep most scannable version (table > list > prose).
4. 3+ parallel items -> table.
5. `wc -w`. Target met?

## Red Flags

| Symptom | Fix |
|---------|-----|
| Same rule in 3+ places | Keep one |
| "It is" / "There are" opener | Imperative |
| Prose restating a table | Delete prose |
| "Must should always" stacking | One verb |
| +10% words, no new rules | Revert |
