#!/usr/bin/env bash
# PostCompact hook: no-op. Claude Code gives PostCompact no decision control,
# so this hook validates the event shape, writes a mismatch to stderr, which Claude Code shows only in debug logs for exit 0, and
# always prints the empty JSON object on stdout.
set -euo pipefail

input=$(cat)
if ! printf '%s' "$input" | jq -e '
  type == "object" and
  (.session_id? | type) == "string" and
  (.cwd? | type) == "string" and
  (.hook_event_name? | type) == "string" and
  .hook_event_name == "PostCompact" and
  ((has("trigger") | not) or ((.trigger | type) == "string" and (.trigger == "manual" or .trigger == "auto")))
' >/dev/null 2>&1; then
  printf '%s\n' 'eci-post-compact-refresh: unexpected PostCompact input shape' >&2
fi
printf '%s\n' '{}'
exit 0
