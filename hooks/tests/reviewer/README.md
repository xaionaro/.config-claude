# Reviewer harness

Replay USER fixtures through the stop-hook reviewer (Ollama backend) to
score a candidate `wrapper` prompt without burning a real Claude turn.
Composes the system prompt via the same library the production hook uses
(`hooks/lib/compose-reviewer-prompt.sh`) so test results track production.

## Usage

```
hooks/tests/reviewer/run.sh <wrapper-path> [N=runs] [usr-fixture]
```

Examples:

```
# 10 runs of the V2 candidate wrapper on the failing fixture (expects fail+cite)
hooks/tests/reviewer/run.sh wrappers/v2-wrapper.md 10 fixtures/usr-failing.md

# 10 runs of the V2 candidate wrapper on the truly-clean fixture (expects pass)
hooks/tests/reviewer/run.sh wrappers/v2-wrapper.md 10 fixtures/usr-truly-clean.md

# Override host/model
OLLAMA_HOST=http://other:11434 REVIEWER_MODEL=qwen3.5:9b-mxfp8 \
  hooks/tests/reviewer/run.sh wrappers/v2-wrapper.md 5
```

Per-run dumps land in `runs/<wrapper-stem>__<fixture-stem>/run-N.json`
(gitignored). Summary line: `pass=N fail=N hit=N/total parse_ok=N/total p50=s p95=s`.

## Files

| Path | Purpose |
|------|---------|
| `run.sh` | Harness; sources `lib/compose-reviewer-prompt.sh`, `lib/reviewer-call.sh`, reads `lib/reviewer-schema.json`. |
| `fixtures/usr-failing.md` | Assistant ends turn with `Proceed?` — must trip the question/AskUserQuestion rule. |
| `fixtures/usr-truly-clean.md` | Short, properly tagged claims, no question — must verdict=pass. |
| `fixtures/<name>.expect.json` | Pass criteria per fixture: `expected_verdict` plus optional `tail_contains`, `cite_regex`. |
| `wrappers/v2-wrapper.md` | Candidate wrapper under iteration. NOT live — production still uses `hooks/reviewer-rules.md`. |

## Pass criterion

- Clean fixture (`expected_verdict=pass`): a run "hits" when `verdict=="pass"`.
- Failing fixture (`expected_verdict=fail`): a run "hits" when `verdict=="fail"` AND
  `tail_contains` (when set) matches the model's `assistant_tail_quote` AND
  `cite_regex` (when set) matches at least one violation rule/evidence string.

## Current results (V2 wrapper baseline, 10 runs each, qwen3.5:9b-mxfp8)

Calibrated on `/tmp/reviewer-iter` under the V2 schema. The lib refactor
swaps to the production schema (`verdict`+`violations` only) — V2 numbers
should remain within sampling variance because the wrapper's prose still
asks for the diagnostic fields.

| Fixture | hit / runs | Notes |
|---------|------------|-------|
| `usr-failing.md`     | 10/10 | wrapper reliably catches text-question. |
| `usr-truly-clean.md` |  4/10 | ~60% false-positive rate — wrapper still being iterated. |

Re-run after any wrapper or lib change to confirm equivalence.
