# Capture and prepare a changed assignment

Applicability follows [Update Points](SKILL.md#update-points). Work in the session's existing `project-understanding.yaml` under `~/.agent/context/sessions/$CLAUDE_CODE_SESSION_ID/`. Capture and preparation send no message and do not update the status report.

Classify the input under [Project requirements](../../CLAUDE.md#project-requirements); reuse saved requirements when only corrective or operational work changes.

1. Apply the existing [affected-record and native-edit rules](SKILL.md#update-points). Make the resulting changes as exact native text replacements; no replacements selects no-write reuse. Each replaced text must occur exactly once when its edit is applied, in listed order; include adequate surrounding text to distinguish the intended record. Edit through the same-directory temporary copy in [Authoring and native edits](SKILL.md#authoring-and-native-edits), confirm each affected ID links to the assigned outcome, publish, then read the canonical snapshot back.
2. Collect the inputs: requirement IDs (`requirement:job:source:facet`), assigned outcome ID (`outcome:job:result`), target agent name, operational instructions, actor `{id, role}`, and reason (for example, "Material user correction changes this assignment"). Operational instructions cover job, parent chain, role, scope, expected work, checks and reporting route; keep them separate from canonical requirements. There is no separately authored requirement-message field.
3. Project from the saved snapshot every requirement and scope linked to the assigned outcome, including unchanged source, acceptance, evidence and unknown domain fields; follow other named record links too. Missing or unsupported chain content is an explicit failure: repair the ledger first; never drop it silently.
4. Compose the message with this exact shape, the projected records copied verbatim from the ledger:

````text
Canonical assignment requirements from <ledger path>
Assigned outcome: <outcome ID>
All linked requirements, scopes and supporting records (saved values):

```yaml
<projected records>
```

Operational instructions (separate from canonical requirements):
<instructions>
````

5. Append the paired log entry under [High-Level Log](SKILL.md#high-level-log) before forwarding: event `requirement_change` when the snapshot changed, otherwise `decision`; summary "Requirement capture and assignment preparation; native delivery remains pending."; the actor, reason and requirement IDs from step 2; `details` with the outcome, target, whether the snapshot changed, and the edits.
6. Forward the exact composed message with `SendMessage` to the target agent. Do not rewrite its requirement portion. Maintain the current status report in the same turn under [Update Points](SKILL.md#update-points); record actual delivery separately when material. Preparation is not delivery.

The ledger's unrelated bytes, comments, order, multiline text and mode remain intact. Faithful reuse does not rewrite the snapshot. Before publication, a failed edit leaves the snapshot unchanged. If the snapshot is saved but the log append failed, inspect current records, append the missing entry, then forward; make no further edit when the saved records are faithful. Do not replay a stale edit automatically. A failed delivery does not roll back capture.

This operation couples capture and assignment preparation on this adopted path. It does not inspect arbitrary direct messages or discover omitted user meaning. The direct paths for urgent controls and independent progress remain governed by [Update Points](SKILL.md#update-points).
