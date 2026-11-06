#!/usr/bin/env bash
# Claude Code statusLine. Item list and order mirror Codex [tui].status_line
# (~/.codex/config.toml): model-with-reasoning, git-branch, total-input-tokens,
# total-output-tokens, five-hour-limit, weekly-limit, context-used,
# context-window-size, thread-credits (no Claude source, omitted),
# estimated-thread-cost, thread-id, thread-name.
# Reads statusLine JSON on stdin. Omits any item whose source is absent. Always exits 0.

input=$(cat)

DIM=$'\033[2m'
RST=$'\033[0m'
SEP=" ${DIM}·${RST} "

# num PATH: print the value at PATH if it is a JSON number, else print nothing.
num() { printf '%s' "$input" | jq -r "$1 | if type == \"number\" then . else empty end" 2>/dev/null; }
# str PATH: print the value at PATH if it is a non-empty string, else print nothing.
str() { printf '%s' "$input" | jq -r "$1 | if type == \"string\" and . != \"\" then . else empty end" 2>/dev/null; }

items=()
add() { [ -n "$1" ] && items+=("$1"); }

# pct LABEL PATH: "LABEL N%" with N rounded, omitted when PATH is absent or null.
pct() {
  local v
  v=$(num "$2")
  [ -n "$v" ] && add "$1 $(printf '%.0f' "$v")%"
}

# model-with-reasoning
model=$(str '.model.display_name')
effort=$(str '.effort.level')
[ -n "$model" ] && add "${model}${effort:+ $effort}"

# git-branch (read from git; empty on non-repo or detached HEAD)
cwd=$(str '.workspace.current_dir')
[ -n "$cwd" ] && add "$(git -C "$cwd" branch --show-current 2>/dev/null)"

# total-input-tokens, total-output-tokens
add "$(num '.context_window.total_input_tokens')"
add "$(num '.context_window.total_output_tokens')"

# five-hour-limit, weekly-limit
pct 5h '.rate_limits.five_hour.used_percentage'
pct wk '.rate_limits.seven_day.used_percentage'

# context-used, context-window-size
pct ctx '.context_window.used_percentage'
add "$(num '.context_window.context_window_size')"

# estimated-thread-cost (thread-credits has no Claude equivalent)
cost=$(num '.cost.total_cost_usd')
[ -n "$cost" ] && add "$(printf '$%.2f' "$cost")"

# thread-id, thread-name
add "$(str '.session_id')"
add "$(str '.session_name')"

out=""
for item in "${items[@]}"; do
  if [ -z "$out" ]; then out=$item; else out="$out$SEP$item"; fi
done
printf '%s\n' "$out"
exit 0
