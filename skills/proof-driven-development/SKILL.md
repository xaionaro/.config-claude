---
name: proof-driven-development
description: Use when implementing algorithms, data structures, or critical logic — proves correctness in Lean 4 first, then translates to the target language with differential testing
---

# Proof-Driven Development

Prove correctness in Lean 4 before implementing in the target language. Keep proofs alongside production code.

## Workflow

1. **Specify** — Write formal spec in Lean 4: types, function signatures, properties (preconditions, postconditions, invariants).
2. **Prove** — Prove key properties. Use `lake build` to verify. Iterate with Lean's error messages until all proofs pass.
3. **Implement** — Translate the verified Lean algorithm to the target language. The Lean implementation is the reference.
4. **Differential test** — Run both Lean executable and target implementation against the same inputs. Compare outputs. Divergence = bug in translation.
5. **Maintain** — Proofs live in `proofs/` directory. Update proofs when the algorithm changes.

## Project structure

```
project/
├── proofs/               # Lean 4 project
│   ├── lakefile.lean
│   ├── lean-toolchain
│   ├── Spec/             # Formal specifications (types, signatures)
│   ├── Proofs/           # Correctness proofs
│   └── DiffTest/         # Executable spec for differential testing
├── src/                  # Production code (any language)
└── tests/
    └── differential/     # Tests comparing Lean output vs production output
```

## Lean 4 setup

Toolchain: `elan` + `lake`. Verify: `source ~/.elan/env && lean --version`.

Initialize a new proofs directory:
```bash
cd project && lake init proofs && mv proofs/ proofs-tmp/ && mkdir proofs && mv proofs-tmp/* proofs/ && rm -rf proofs-tmp/
```

## What to prove

Focus proofs on properties that matter, not on trivial implementations:
- **Correctness**: output satisfies the specification for all valid inputs.
- **Invariants**: data structure invariants preserved across operations.
- **Edge cases**: boundary conditions, empty inputs, overflow, off-by-one.
- **Equivalence**: when refactoring, prove new implementation equivalent to old.

## Translation rules

When translating Lean → target language:
- Map Lean types to target language types preserving semantics (not just syntax).
- Preserve the algorithm structure. Optimizations must maintain the proven properties.
- Generate property-based tests from Lean theorems — each theorem becomes a test case generator.

## Differential testing

The Lean implementation is executable. Use it as an oracle:
1. Generate test inputs (random, edge cases, from Lean theorem parameters).
2. Run inputs through Lean executable (`lake env lean --run`).
3. Run same inputs through target implementation.
4. Compare outputs. Any difference = translation bug.

## When to use this skill

- Implementing algorithms with correctness requirements.
- Data structures with invariants.
- Protocol implementations (state machines, parsers, serializers).
- Refactoring critical code — prove equivalence.
- Any code where "I tested it" is insufficient and formal guarantees are needed.

## When NOT to use

- Glue code, configuration, UI, simple CRUD.
- When the specification itself is unclear (clarify first, then formalize).
