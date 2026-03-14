---
name: go-coding-style
description: Use when writing, reviewing, or modifying Go code — ensures adherence to the user's established Go conventions for naming, error handling, concurrency, types, logging, and code organization
---

# Go Coding Style

## File tree

- Each type is in itsown file.
- Never use abstract file/directory/function names (like "helper", "wrapper", "adapter"). Every name should specifically and unambiguously explain the content, and every used word in the name has high cost.

## Naming

Multi-parameter functions: each parameter on its own line, closing `) returnType {` on separate line:

```go
func (n *NodeWithCustomData[C, T]) RemovePushTo(
	ctx context.Context,
	to Abstract,
) (_err error) {
```

## Error Handling

- Custom error types implement `Unwrap() error`.
- Accumulate errors in `var errs []error`, return `errors.Join(errs...)`.
- Switch on error type:
  ```go
  switch {
  case err == nil:
  case errors.As(err, &ErrNotImplemented{}):
      logger.Warnf(ctx, "...")
  default:
      return fmt.Errorf("...: %w", err)
  }
  ```
- Deferred logging with named returns:
  ```go
  func (c *Codec) Close(ctx context.Context) (_err error) {
      logger.Tracef(ctx, "Close")
      defer func() { logger.Tracef(ctx, "/Close: %v", _err) }()
  ```
- Cleanup-on-error via defer:
  ```go
  defer func() {
      if _err != nil {
          _ = c.Close(ctx)
      }
  }()
  ```

## Concurrency

- `context.Context` is always the first parameter. Never stored in structs.
- Goroutines via `observability.Go(ctx, func(ctx context.Context) { ... })`, never raw `go`.

## Types & Generics

- Option pattern:
  ```go
  type Option interface { apply(*Config) }
  type Options []Option
  func (opts Options) config() Config { cfg := defaultConfig(); opts.apply(&cfg); return cfg }
  ```

## Other patterns

- Never use `else if`. Always use `switch` if semantically there could be more then 2 options. Even if in practice you currently have 1-2 options, but semantically there could be more, it still should be a `switch`.

## Logging

- `github.com/facebookincubator/go-belt` via context: `logger.Debugf(ctx, "...")`.
- Structured fields: `belt.WithField(ctx, "key", value)`.
- Entry/exit tracing: `logger.Tracef(ctx, "MethodName")` / `logger.Tracef(ctx, "/MethodName")`.
- Do not reference stdin/stdout/stderr outside of the `main` package. For example, do not use `fmt.Print*` functions
  outside of the `main` package.
- **Level semantics** (use the right level for the situation):
  - `Trace` — method entry/exit, low-level flow tracing.
  - `Debug` — normal operational messages, state changes, request handling.
  - `Info` — rare, notable events only (startup, shutdown, config reload). Most messages should be `Debug`, not `Info`.
  - `Warn` — recoverable problems, degraded operation, unexpected-but-handled conditions.
  - `Error` — operation failed, needs attention but process continues.
  - `Fatal` — unrecoverable, process must exit.
- **Level consistency:** When adding log statements, scan how the same package uses levels for similar operations and match. If existing usage conflicts with the level definitions above, raise the inconsistency to the user after finishing the task.

## Testing

- `github.com/stretchr/testify` — `assert` for soft, `require` for fatal.

## Code Organization Principles

- Blank line between logical blocks within functions. Never double blank lines.
- Constants as `const` block at file top, not magic values inline.

## Be consistent

- If you are modifying a package, scan other files in the package and follow the same patterns. If some pattern is
  suboptimal, then raise the question (if needs to be fixed) to the user after finishing the task.

## Modules

- NEVER add local path `replace` directives (e.g., `=> ../something`) to `go.mod`. Use `go.work` for local module resolution instead. Remote fork replacements in `go.mod` are fine.

## Readability

- Keep code flat. Avoid deeply nested `if`/`for`/`switch` blocks. Use early returns, `continue`, and guard clauses to reduce nesting. If a block is nested 3+ levels deep, refactor it.
- When replacing one approach with another (e.g., to fix a bug), add a comment explaining why the new approach was chosen.
