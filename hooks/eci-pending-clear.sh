#!/bin/bash
# UserPromptSubmit hook: clear the ECI teammate-pending marker on every new
# user or teammate-reply prompt. The orchestrator now has something fresh to
# act on; the next dispatch will re-arm the marker via eci-pending-set.sh.

set -uo pipefail
trap 'exit 0' ERR

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

rm -f "$HOME/.cache/claude-proof/$SESSION_ID/eci_teammate_pending"
exit 0
