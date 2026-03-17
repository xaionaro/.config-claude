---
name: python-coding-style
description: Use when writing, reviewing, or modifying Python code (*.py, pyproject.toml, setup.cfg files) or reviewing diffs/PRs containing Python changes — ensures code quality and adherence to established Python conventions for naming, error handling, concurrency, typing, logging, and code organization
---

# Python Coding Style

## Idiomatic Python

- Write idiomatic Python (PEP 8, PEP 20 — The Zen of Python).
- Choose the correct, clean solution even when it's harder than the simple, practical, or convenient one.
- **Read before using.** Before first use of any package (stdlib or third-party), read its API surface — docs, source, or context7. Don't guess signatures, defaults, or behavior.

## Type Hints

- Type-annotate all function signatures and class attributes. Use `typing` / `collections.abc` for complex types.
- Named types for domain concepts: `UserID = NewType('UserID', int)`, not bare `int`. Use `Literal`, `TypeAlias`, `TypeVar` where they add clarity.
- Use `@dataclass` or `NamedTuple` for structured data — not plain dicts or tuples for domain objects.
- One source of truth per logic/constant — define once, reference everywhere. Duplicated values drift.

## File tree

- One class per module when the class is substantial. Small related classes can share a module.
- Never use abstract file/directory/function names (like "helpers", "utils", "misc"). Every name should specifically and unambiguously explain the content.
- Use `__init__.py` to define the public API of a package. Re-export only what external consumers need.

## Naming

- `snake_case` for functions, methods, variables, modules. `PascalCase` for classes. `UPPER_SNAKE` for module-level constants.
- Private by convention: single `_prefix` for internal. No double `__` mangling unless avoiding name collision in inheritance.
- Multi-parameter functions: each parameter on its own line when >3 params or line exceeds limit:
  ```python
  def remove_push_to(
      self,
      target: Abstract,
      *,
      force: bool = False,
  ) -> None:
  ```

## Error Handling

- Custom exceptions inherit from a project-specific base, not bare `Exception`.
- Use exception chaining: `raise NewError("...") from original_err`.
- Context managers (`with`) for all resource cleanup — files, connections, locks.
- Catch specific exceptions, never bare `except:` or `except Exception:` without re-raise.
- Cleanup-on-error pattern:
  ```python
  resource = acquire()
  try:
      use(resource)
  except SomeError:
      resource.rollback()
      raise
  ```

## Concurrency

- `asyncio` for I/O-bound concurrency. `concurrent.futures` for CPU-bound parallelism.
- Never mix blocking I/O into async code — use `asyncio.to_thread()` or `run_in_executor()`.
- Async context managers (`async with`) for async resource lifecycle.

## Other patterns

- Prefer `match`/`case` (3.10+) over `if`/`elif` chains when semantically there could be more than 2 options.
- Use `Enum` for finite sets of related constants, not string or int literals.
- Prefer composition over inheritance. Use protocols (`typing.Protocol`) for structural subtyping.

## Logging

- `logging` stdlib module. Get logger per module: `logger = logging.getLogger(__name__)`.
- Structured logging: pass extra data via `extra=` or structured formatters, not string interpolation in the message.
- Do not use `print()` for operational output outside of CLI entry points.
- **Level semantics** (use the right level for the situation):
  - `DEBUG` — detailed diagnostic, state changes, request handling.
  - `INFO` — rare, notable events only (startup, shutdown, config reload). Most messages should be `DEBUG`, not `INFO`.
  - `WARNING` — recoverable problems, degraded operation, unexpected-but-handled conditions.
  - `ERROR` — operation failed, needs attention but process continues.
  - `CRITICAL` — unrecoverable, process must exit.
- **Level consistency:** When adding log statements, scan how the same module uses levels for similar operations and match. If existing usage conflicts with the definitions above, raise the inconsistency to the user after finishing the task.

## Testing

- `pytest` as test runner. `assert` statements directly — no `self.assertEqual`.
- Use fixtures for setup/teardown. Parametrize for variant coverage.

## Code Organization

- Blank line between logical blocks within functions. Two blank lines between top-level definitions.
- Constants at module top, not magic values inline.
- Imports: stdlib → third-party → local, separated by blank lines. Absolute imports preferred.

## General discipline

- After every change: reduce code in related pieces. Remove logic, not lines. Keep readable.
- When a workaround feels ugly, treat it as a design smell — find the elegant approach.
- Validate inputs with strong expectations. When there's no error channel, use assert/invariant.
- Small functions, but keep semantically self-sufficient thoughts whole.
- Satisfy all linters — they catch real bugs before runtime.
- **Comments explain how or what's next**: Only write `how-it-works` explanations and TODOs. No "generated by AI" or similar attributions.
- **Eliminate tech debt on contact**: Fix generators rather than editing generated files.
- **Use authoritative sources over generation**: Download or reference canonical sources (LICENSE, .gitignore templates, config schemas) instead of generating from memory.
- **No hidden assumptions.** Handle exactly the cases you expect. Return errors for everything else. A condition like `x > y` silently accepts cases you didn't consider — use explicit checks for each supported case and error on the rest.

## Semantic integrity

A name is a contract — implementation fulfills exactly what the name promises.

- **Does only what it says.** `resolve_table` resolves a table — not decide *whether* to, retry, or log analytics. Extra behavior belongs in the caller or the name.
- **Does everything it says.** `validate_and_save` must validate and save. If either can happen without the other, split or rename.
- **No opposite behavior.** `disable` must not return an "enabled" state. `remove` must not archive.
- **Return type matches name.** `get_user` → User. `is_valid` → bool. `list_items` → collection.
- **No smuggled decisions.** `do_x()` assumes X should happen. "If not needed, return early" inside it is a violation — the caller decides.
- **No smuggled side effects.** Properties don't mutate state. Predicates (`is_`, `has_`, `can_`) don't change anything. If they must, the name must reveal it.

Review check: read the name, predict the body, read the body. Any surprise is a violation.

## Semantic consistency

Same concept → same name everywhere. Same name → same meaning everywhere. Related concepts → parallel structure.

- **One name per concept.** "stream" everywhere — not "channel"/"feed"/"pipe" in different modules for the same thing.
- **One concept per name.** `handle` can't mean "process a request" here and "resource reference" there.
- **Parallel pairs.** `start_capture`/`stop_capture` — not `begin_encoding`/`end_encoding`. Pick one verb set per domain.
- **Full rename propagation.** "job" → "task" means classes, functions, variables, logs, errors, comments all change. Partial rename is worse than none.
- **Consistent abstraction level.** Sibling calls: `initialize_cluster`, `configure_network`, `go` — the last one breaks the level.
- **Domain names, not implementation.** `StreamProcessor` over `DictWithLock`. Name must survive an implementation change.

## Locality and lifetime

Everything as local as possible, as short-lived as possible.

- **Narrowest scope.** Variables live in the innermost block that needs them. Don't declare at function top when only needed inside a branch.
- **Shortest span.** Minimize distance between assignment and last use. A variable assigned at line 1 and next used at line 20 means the code between should be restructured or the variable moved closer.
- **Release early.** Use `with` blocks scoped tightly — don't hold files/connections open longer than needed.
- **No module-level when local suffices.** Module-level mutable state is global state. Use only when multiple functions genuinely share it.
- **No stale references.** Don't store references that outlive the data's logical lifetime (closed connections, expired cache entries, finished request contexts).

## Be consistent

- If you are modifying a module/package, scan other files in the package and follow the same patterns. If some pattern is suboptimal, raise the question (if needs to be fixed) to the user after finishing the task.
- **Fix violations on sight.** When reading or modifying code, if you encounter an obvious violation of these rules in the surrounding code, fix it. Don't leave known violations behind.

## Dependencies

- Pin dependencies in `pyproject.toml` or `requirements.txt`. Never install packages without recording them.
- Prefer stdlib solutions over third-party when the stdlib option is adequate.

## Readability

- Keep code flat. Avoid deeply nested `if`/`for`/`try` blocks. Use early returns, `continue`, and guard clauses to reduce nesting. If a block is nested 3+ levels deep, refactor it.
- When replacing one approach with another (e.g., to fix a bug), add a comment explaining why the new approach was chosen.
