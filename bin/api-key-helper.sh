#!/bin/bash
# apiKeyHelper for `claude --bare`: parses ~/.claude/.credentials.json and
# emits the OAuth access token on stdout. Claude Code's --bare path uses
# whatever this prints as the bearer token for API calls.
#
# Failure modes (all silent): missing file, missing key, invalid JSON.
# In that case the caller (claude --bare) sees an empty key and reports
# its own auth error.
set -u
cred="$HOME/.claude/.credentials.json"
[ -f "$cred" ] || exit 0
jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null
