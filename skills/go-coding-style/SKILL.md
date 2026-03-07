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

## Logging

- `github.com/facebookincubator/go-belt` via context: `logger.Debugf(ctx, "...")`.
- Structured fields: `belt.WithField(ctx, "key", value)`.
- Entry/exit tracing: `logger.Tracef(ctx, "MethodName")` / `logger.Tracef(ctx, "/MethodName")`.
- Do not reference stdin/stdout/stderr outside of the `main` package. For example, do not use `fmt.Print*` functions
  outside of the `main` package.

## Testing

- `github.com/stretchr/testify` — `assert` for soft, `require` for fatal.

## Code Organization Principles

- Blank line between logical blocks within functions. Never double blank lines.
- Constants as `const` block at file top, not magic values inline.

## Be consistent

- If you are modifying a package, scan other files in the package and follow the same patterns. If some pattern is
  suboptimal, then raise the question (if needs to be fixed) to the user after finishing the task.
