---
name: explore-critique-implement
description: Use when a non-trivial task needs ECI (medium coding task, investigation, single-feature implementation, "why does X not work?", uncertain solution space, two plausible approaches) or active ATE routes bounded work through ECI
---

# Explore-Critique-Implement

Separate exploration, authoritative critique, implementation, and independent review. The builder never critiques its own output.

## Port status

Ported from the Codex ECI skill (Supervisor / Job Orchestrator version). Text follows the Codex source; only the items below differ.

| Item | Status |
| --- | --- |
| Roles ported | Supervisor, Job (J/N counts), Job Orchestrator (J > 1), Orchestrator, Explorer, Step 2 Critic, Implementer Producer, Fast Owner Producer, Critic A/B/C, E2E, Helper, brainstormer, feasibility validator, loop-breaker |
| Modules ported | `references/`: coordinator, task-orchestrator, fast-path, fast-continuation-cases, explore, critique, implement, review, coverage-map |
| Deviation: engagement marker | Claude keeps `eci-active on/off` and the Stop-hook marker. Codex retires markers for native goals. See [Claude mechanics](#claude-mechanics) |
| Deviation: no TeamCreate | `TeamCreate` is unavailable in this environment. Every role is an Agent-tool subagent addressed with `SendMessage`; teammates and `TeamDelete` are not used |
| Deviation: tool names | Codex spawn/`write agent://`/`send_message`/`interrupt_agent`/`wait`/`proc://` map to Agent / `SendMessage` / `TaskStop` / completion notifications / `ListAgents`. `SendMessage` also resumes a finished named agent |
| Deviation: models | Codex `model-selection.yaml` becomes the Agent `model` parameter. The tool has no reasoning-effort parameter, so `max` and `higher` both map to `opus` |
| Deviation: Git | Codex `eci-worker-git` has no Claude counterpart; Worker Git steps are manual native Git on exact owned paths |
| Not ported | Native goal calls (replaced by the engagement lifecycle); the Codex-format alternative disengage report |
| Open dependency | `CODEX.md` anchors became `CLAUDE.md` anchors, as in the sibling ports: `#concurrent-tasks`, `#work-estimates`, `#engineering-priorities`, `#clean-system-and-repair`, `#decisions` (security follow-ups). `CLAUDE.md` has no such sections yet. Ledger links target `../context-ledger/`, while `CLAUDE.md` names `maintaining-context-ledger`. Claude `eci-active` lists only `on`, `off`, `status`, so the `requirement-assignment` subcommand that `context-ledger` names does not exist yet |
| Open conflict | `CLAUDE.md` Git rule (amend an unpushed bad commit) vs. ECI immutable checkpoint range (repair in a new commit after handoff). The ECI rule is kept as written |

## Activation and invariants

Start only when the session selects ECI (`CLAUDE.md` routes medium coding tasks, investigations, and "why does X not work?" questions here) or active ATE explicitly routes bounded work through it. Loading this router alone does not start ECI. Use ECI for non-mechanical work with uncertainty, future behavior/routing/protocol risk, or two plausible approaches; classify by decision complexity and risk, not diff size. A one-line/local change is still non-trivial when it changes instructions, prompts, routing, protocols, public contracts, security, persistence, concurrency, architecture, or reviewer/agent behavior. Skip only a mechanical answer whose consequences are obvious, directly verifiable, and carry no future behavior or routing risk.

On activation and closure, the Supervisor follows the [engagement lifecycle](references/coordinator.md#engagement-lifecycle-claude-mechanics) (`eci-active on/off`; see [Claude mechanics](#claude-mechanics)).

- Maintain requirement lineage and a project-understanding ledger. The active ECI/ATE lifecycle owns normal work; ATE may contain normal ECI. Keep forecast values in `forecasts.yaml`; project-understanding may link to it but must not duplicate them.
- Apply [concurrent task scheduling](../../CLAUDE.md#concurrent-tasks) to new Jobs, independent progress, outcome-local gates, and root closure. Each outcome keeps its scope and Producer identities; ownership follows the [Job Orchestrator contract](references/task-orchestrator.md).
- For material ECI work, keep `exact user source → faithful requested outcome →
  bounded scope`. A repair necessary to meet or prove that outcome stays current-lane work.
  For each already-discovered lower-priority code issue that remains unfixed, add the TODO defined by [Main ECI quality responsibility](references/fast-path.md#main-eci-quality-responsibility). It does not change an in-scope disposition or replace its required repair; for an unadmitted separate-outcome issue, its TODO is the only code edit and the issue remains post-ECI.
  Missing or stale lineage never blocks known in-scope work.
- Derive interface scope and lifetime from the requested capability, affected entities’ meaning and ownership, contracts, and representative consumers. An immediate example alone does not establish a narrower boundary. Preserve explicitly authorized narrow or staged scope; add no speculative capabilities.
- Apply [coding-policy enforcement](../references/workflow-runtime/coding-style-admission.md) to governed work. For workflow or review-failure repairs, apply [policy failure investigations](../references/review-investigation.md#policy-failure-investigations) before adopting scope, selecting a remedy, or accepting its proof.
- Every admitted outcome starts main-path ECI and one [Fast Owner](references/fast-path.md) concurrently within its home Job. That module owns launch, lifetime, shared-tree priority, evidence feedback, adoption, and closure rules.
- Apply [impact-first provisional delivery](references/fast-path.md#impact-first-provisional-delivery): deliver verified useful improvements over a broken baseline while the full quality and acceptance pipeline continues.
- Jobs may recursively admit bounded authorized child packages under the [recursive Job contract](references/task-orchestrator.md#recursive-child-admission-and-closure). Each child owns the full pipeline and reports through its parent owner; unadmitted separate-outcome restrictions do not prohibit authorized child work.
- Follow the normative [post-Fast completion sequence](references/fast-path.md#post-fast-completion).
- Intermediate iteration progress remains concurrent.
- Record `Stage: normal` for ECI; show main-path and Fast progress within each outcome, not as separate stages or automatic lanes.
- A lane is an independently advancing workstream, not an ECI step. Serial implement→review→repair→review→implement stays one lane with one critical path. Create distinct lanes only for independently advancing work with separate ownership or synchronization.
- Every normal ECI Worker reads this router plus the exact module(s) useful to its assignment. Report an unknown role, predicate, or link to the Supervisor and resolve it while safe bounded assigned work continues; it does not itself deny or stall normal work.
- Enforce ECI duties for your actual activity, including delegated work. When work changes, recheck role authority, model selection, and applicable ECI dependency skills and their required methods under their role/activity predicates. Report significant movements (activity/phase changes, Helper dispatch/completion, material findings or verification) and any unmet duty through the existing report route, with evidence and the next correction. A retained role label or a loaded skill does not establish compliance.
- Own your assigned outcome through successful completion, required evidence, and complete handoff. Resolve recoverable obstacles with safe, authorized in-scope actions; use and verify available recovery paths before asking for help (for example, use authorized ADB recovery to unlock the task device). If no authorized in-scope path is available, or attempted recovery leaves the outcome blocked, report why, what you tried (where possible), and the exact missing input, access, or approval. Keep scope bounded; the Supervisor retains ECI lifecycle and final acceptance.
- The Supervisor alone loads lifecycle, blocker, pause, stop, teardown, and pressure-policy modules. The current Job owner—an Orchestrator when J > 1, the Supervisor when J ≤ 1—loads shared [review policy](../references/workflow-runtime/review-policy.md) only for outcome-level review dispatch and evidence coordination under the [Job Orchestrator contract](references/task-orchestrator.md). It sends findings, evidence, and disposition recommendations to the Supervisor. The Supervisor retains final adjudication, commit-range verification, acceptance, and protected operations.
- Each normal iteration is Explore → Critique → Implement → parallel Review. A producer never acts as critic.
- Bugs with hard uncertainty or a material competing diagnosis/approach use `debugging-discipline` on either path; retain permitted basic investigation and Fast's deferred main-path sequence.

## Configuration E2E contract

Every configuration change, including configuration-only work, requires the final implementer-owned and fresh independent E2E pair on the stabilized final cumulative state described below. This requirement may not be waived.

## Runtime E2E policy

Code/debug work affecting runtime behavior reachable through a UI, API, device, or CLI requires the final E2E pair below. Docs, prompts, design-only changes, tests-only changes, and pure refactors do not require E2E under this policy.

## E2E cadence, scope, and timing

Each implementation iteration still gets focused tests/proof, a checked scoped Producer commit during handoff, independent Supervisor verification of its immutable range, and independent code review. Do not run routine E2E between iterations. An early E2E is allowed only to investigate a concrete failure or integration uncertainty; run the shortest faithful real-path scenario that can resolve it. Early evidence does not replace final E2E.

For active ECI, this router controls E2E applicability and cadence within ECI iterations. `testing-discipline` still governs focused-check and required-E2E quality, but its generic per-modification E2E default does not add routine E2E between ECI iterations. This ECI-local cadence does not replace separately applicable outer-workflow acceptance evidence, such as ATE root gates.

Once main-path implementation, post-Fast findings/dispositions, and any resulting repairs are complete, run one final pair before acceptance whenever a configuration or runtime trigger applies: the Implementer Producer’s E2E and a fresh independent Step 4 E2E on the same stabilized final cumulative revision. The independent run may repeat or extend the Producer’s run. A later material edit affecting exercised behavior, assertions, or configuration invalidates the affected E2E evidence; refresh it before acceptance.

Use the shortest faithful real path that proves the original criteria and checks relevant regressions. Run the full suite only when it supplies coverage required for that proof. Cite the command and actual output/state/screenshot; proxy evidence alone is insufficient.

Every early, Fast, Producer-final, and independent-final E2E report records `started_at_utc` and `finished_at_utc` (RFC 3339 UTC), `elapsed_monotonic_seconds`, command, scope/coverage, tested revision, and environment identity sufficient for comparison (runner/host class, OS/architecture, relevant tool/runtime versions, and test-service/data configuration). Redact secrets. Compare duration only for matching commands and scope/coverage in materially equivalent environments; do not rerun solely to collect timing. A comparable material regression beyond ordinary variance triggers the Fast Owner Producer or a bounded Helper to profile and optimize E2E duration in parallel while main-path ECI continues. Preserve assertions, coverage, real-path evidence, and the independent final E2E.

## Model selection

At each new spawn, pass the `model` the profile table maps to (Agent tool `model` parameter) on a fresh agent: any `subagent_type` other than `fork`, so it inherits no conversation. The Agent tool has no reasoning-effort parameter. Keep existing launch settings and reusable owners. If a new activity needs another profile, assign a correctly configured helper. Keep independent reviewer assignments self-contained and blind to producer findings. If a requested model is unavailable, record the limitation and continue with the available provider. Do not assume effective-model telemetry. Profile selection does not change role authority or reviewer independence.

Choose by assigned activity; mixed assignments use the highest applicable profile.

| Profile | Agent `model` | Activities |
| --- | --- | --- |
| `max` | `opus` | Solution design; unresolved RCA work; design review, including Step 2; long-term health review, including Critic C. |
| `higher` | `opus` | Other independent reviews, including Critics A/B, settled RCA review, and independent Step 4 E2E. |
| `default` | `sonnet` | Implementation; routine work; producer E2E. |

## Module routing

For bounded Linux host process families needing deadline/interruption cleanup or exact PID/birth cancellation, use [owned-command](../owned-command/SKILL.md); keep ordinary foreground inspection such as `rg --files` direct.

Supervisor routes begin with [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md). Use [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for governed writing/admission, [review policy](../references/workflow-runtime/review-policy.md) only for review/impact routing, [pause-all-work](../references/workflow-runtime/pause-all-work.md) only for its exact direct-user predicate, [stop recovery](../references/workflow-runtime/stop-recovery.md) only for recognized Stop diagnostics, and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only for workflow-policy changes.

| Role | Required module | Conditional module/predicate |
| --- | --- | --- |
| Supervisor | [coordinator](references/coordinator.md), [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md), [review policy](../references/workflow-runtime/review-policy.md) | [pause-all-work](../references/workflow-runtime/pause-all-work.md), [stop recovery](../references/workflow-runtime/stop-recovery.md), and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only by their predicates |
| `explorer` | [explore](references/explore.md) | [debugging-discipline](../debugging-discipline/SKILL.md) only for assigned bug investigation; [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for assigned governed source discovery |
| `critic-step2` | [critique](references/critique.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for independent admission |
| Producer (`implementer`) | [implement](references/implement.md) | [debugging-discipline](../debugging-discipline/SKILL.md) only for assigned code/debug work; [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for a governed scope |
| Orchestrator | [task-orchestrator](references/task-orchestrator.md) | Candidate, handoff, or relay by bounded assignment; Job dispatch only after its designated publisher publishes ownership under that contract; shared [review policy](../references/workflow-runtime/review-policy.md) only for outcome-level review/evidence |
| `fast-owner` (Fast Owner Producer) | [ECI fast path](references/fast-path.md) | Early E2E only under [E2E cadence, scope, and timing](#e2e-cadence-scope-and-timing) |
| Critic A/B/C, E2E | [review](references/review.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for reviewed governed scope; E2E follows [E2E cadence, scope, and timing](#e2e-cadence-scope-and-timing). |

## Step handoffs

1. Explorer ranks tagged, evidence-backed options and required PoC/style-source proposal.
2. The current Job owner dispatches a fresh Step 2 critic for the outcome. The critic independently baselines, admits scope, rejects bad options, and selects concrete winner text or returns bounded re-exploration.
3. The assigned Implementer Producer applies only the winner and `treatment: now` corrections with causal/proof evidence, then commits its checked scope during handoff.
Before Step 4 or dependent work on another implementation iteration, the Supervisor independently verifies the Producer’s immutable parent-to-commit range. Reviewers receive that range and explicit exclusions; excluded baseline and later ambient changes remain outside review scope.
4. The current Job owner dispatches fresh A/B/C critics in parallel for every outcome iteration and fresh independent E2E when required; E2E follows [E2E cadence, scope, and timing](#e2e-cadence-scope-and-timing). The Supervisor retains final impact/treatment/disposition adjudication and acceptance. Substantive findings return as one design batch; contained fixes return once to implementation. Clean pass needs every original criterion, required proof, and no remaining `now` issue.

## Claude mechanics

Claude-only deviations from the Codex source. Everything outside this section and the other labelled "Claude mechanics" blocks follows Codex.

### Engagement marker and hooks

| Piece | Behavior |
| --- | --- |
| Engage / disengage | The Supervisor runs `~/.claude/bin/eci-active on "<task + scope>"` before Step 1 of the first iteration and `~/.claude/bin/eci-active off <disengage-report.md>` as the last teardown step ([engagement lifecycle](references/coordinator.md#engagement-lifecycle-claude-mechanics), [teardown](references/coordinator.md#teardown-sequence-claude-mechanics)). Workers never run `eci-active`. Do not disengage mid-task to make a direct edit; route it to a Producer. |
| Marker | `eci-active on` writes `$PROOF_DIR/eci_active` (`$PROOF_DIR` = `~/.cache/claude-proof/$SESSION_ID`) with `scope`, `cwd`, `session_id`. |
| PreToolUse gate | `~/.claude/hooks/eci-active-gate.sh` denies Edit/Write/MultiEdit/NotebookEdit only when the target is an ECI control or ledger file, including the marker. It does not read the marker for source edits and exempts no subagent. Routing every tracked contribution through a Producer is a skill rule, not gate-enforced. |
| Stop hook | `~/.claude/hooks/stop-gate.sh` hard-blocks an idle stop while the marker exists. One auto-release: `eci-pending-set.sh` (PreToolUse on Agent, SendMessage, Monitor; main thread only) arms `$PROOF_DIR/eci_teammate_pending`, and stops release silently until `eci-pending-clear.sh` clears it on the next user prompt or reply. |
| Block while a Worker runs | A mid-flight user message can clear the marker. Confirm the Worker still runs (Agent status or `ListAgents`), then `touch $PROOF_DIR/eci_teammate_pending`. Verify first; never arm blindly. |
| Genuine stall | Surface the blocker to the user with AskUserQuestion; do not stop to ask. |
| Compaction | While the marker exists, every user prompt prints its contents and a reminder to re-invoke this skill via the Skill tool. `eci-post-compact-refresh.sh` is a no-op. |

### Subagent model (`TeamCreate` unavailable)

- Every role is an Agent-tool subagent. `TeamCreate`, `TeamDelete`, `team_name`, and teammate panes are not used. Disclose this substitution in the first ECI status report.
- Give each spawn a semantic `name`. Reusable roles (Explorer, Implementer Producer, Fast Owner Producer, Orchestrator) keep one name for their lifetime; continue them with `SendMessage` to that name, which resumes a finished agent from its transcript and queues for a running one. Never spawn a replacement to get "fresh context": the fresh-target rule already gives it.
- Blind identities (Step 2 critic, Critic A/B/C, E2E, brainstormer, feasibility validator, loop-breaker) are new spawns with unique names per invocation. Never `SendMessage` a finished one into a later round.
- Use `subagent_type: general-purpose` for every role. `feature-dev:*` agents lack `SendMessage` and `Bash`; `Explore` and `Plan` lack `Agent`, `Edit`, and `Write`.
- A subagent's final result returns to its spawner. Ownership transfers change the logical owner, so Workers also report explicitly with `SendMessage` to the current owner; `to: "main"` reaches the Supervisor.

### `CLAUDE_ROLE`

Agent-tool subagents carry an `agent_id`; the Stop hook exempts them, so no role env applies. `CLAUDE_ROLE` matters only for an independent `claude` process launched as `~/.claude/bin/claude-as-role <role>`. Setting it in a prompt has no effect. The Stop hook gates only an empty role, `lead`, `team-lead`, and `teamlead`; every other value is exempt. Keep this table, `hooks/stop-gate.sh`, and `bin/claude-as-role` in sync.

| Role | `CLAUDE_ROLE` |
| --- | --- |
| Supervisor | none (main session, gated) |
| Orchestrator | `coordinator` |
| Explorer | `explorer` |
| Implementer Producer, Fast Owner Producer | `eci-implementer` |
| Step 2 critic, Critic A/B/C, feasibility validator, loop-breaker | `reviewer` |
| E2E | `verifier` |
| Brainstormer | `brainstormer` |

Orchestrator, Fast Owner Producer, and feasibility validator are not in the allowlist; they map to the nearest listed role.

## Relationship to other skills

| Skill | Relationship |
| --- | --- |
| `brainstorming` | Explores user intent before design; ECI explores solutions after intent is clear. |
| `agent-teams-execution` | Starts only on explicit user request; once active, may route bounded work through ECI. Re-spawn an ECI critic that cites no issues beyond producer self-reports. |
| `blocker-resolution-protocol` | Supplies shared blocker records and escalation rules. ECI retains role separation, loop-breaker, and hard-escalation semantics. |
| `debugging-discipline` | Diagnoses known bugs; ECI explores open-ended improvement/design. |

Maintenance provenance: [coverage map](references/coverage-map.md).

## Red flags

- A worker loads coordinator/blocker/pause/stop/teardown/review-runtime/pressure policy without explicit assignment.
- A producer reviews itself, a blind critic reuses context, or review critics run sequentially.
- A substantive gate finding is patched directly instead of returning through Explore/Critique.
- A lifecycle is closed to bypass routing or acceptance.
- A Worker runs `eci-active`, or `eci-active off` runs before the other teardown steps (see [Claude mechanics](#claude-mechanics)).

## After compaction

After each ECI compaction, the Supervisor re-invokes this skill via the Skill tool and rereads its exact assigned modules before the next decision. Then refresh the latest status report and print a proper status report to the user using [writing-status-reports](../writing-status-reports/SKILL.md). Compaction alone does not trigger queue-item critique. Resume safe work after reporting.
