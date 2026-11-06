# Shellcheck-friendly library - sourced, never executed.
# shellcheck shell=bash
#
# Pins the Python interpreter for Claude hooks. On this machine bare `python3`
# resolves to /usr/local/bin/python3, a shim that prints a message and exits 1,
# so hook Python steps must not rely on PATH lookup.
#
# API:
#   PYTHON3   interpreter path (or name) used for hook Python steps.
#             Override via CLAUDE_PYTHON3.
#             Callers must check `command -v "$PYTHON3"` and fail closed when
#             it is missing or the run exits non-zero.

PYTHON3="${CLAUDE_PYTHON3:-/usr/bin/python3}"
