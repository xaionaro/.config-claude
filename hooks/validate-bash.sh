#!/bin/bash
# PreToolUse hook: validates Bash commands before execution.
#
# Order: (1) git push deny, (2) subagent `eci-active off` deny, (3) git reset
# gate, (4) ECI command plan from the Codex planner. Steps 1 and 3 are the
# CLAUDE.md git rules; step 2 is a Claude-only subagent guard. Step 4 is codex
# parity with one divergence: when an ECI marker is active and the planner
# cannot run or exits non-zero, the hook denies (fail closed). Without a marker
# it fails open with a stderr advisory, as the Codex shim does.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/claude-proof-state.sh"
. "$HOOK_DIR/lib/claude-tmp.sh"
. "$HOOK_DIR/lib/claude-python.sh"
claude_init_tmp || true
claude_install_fail_open_trap validate-bash

# Stage the hook input as exact bytes (no $(cat) newline stripping); the planner
# reads the same file. With no temp file, the input stays in memory and step 4
# applies eci_planner_unavailable.
INPUT=''
tmp="$(mktemp "${TMPDIR:-${HOME:-}/tmp}/validate-bash.XXXXXX" 2>/dev/null)" || tmp=''
if [ -n "$tmp" ]; then
  trap 'rm -f -- "$tmp" "$tmp.out"' EXIT
  cat >"$tmp"
else
  INPUT="$(cat)"
fi

# One field of the hook input, read from the staged file when present.
json_query() {
  if [ -n "$tmp" ]; then
    jq -r "$1" "$tmp" 2>/dev/null || true
  else
    printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true
  fi
}

SESSION_ID="$(json_query '.session_id // empty')"
CWD="$(json_query '.cwd // empty')"
COMMAND="$(json_query '.tool_input.command // empty')"

# The subagent test is claude_hook_is_subagent_context on the whole input
# (staged file or in-memory copy). </dev/null keeps an empty input from making
# the predicate read stdin, which is already consumed.
IS_SUBAGENT=false
if claude_hook_is_subagent_context "$INPUT${tmp:+$(cat -- "$tmp")}" </dev/null; then
  IS_SUBAGENT=true
fi

PROOF_ROOT="$(claude_configured_proof_root)"
ECI_MARKER="$PROOF_ROOT/$SESSION_ID/eci_active"

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# The ECI planner cannot run. Active ECI marker: deny (fail closed). No marker:
# advisory on stderr and exit 0 (fail open, codex parity).
eci_planner_unavailable() {
  if [ -e "$ECI_MARKER" ]; then
    deny "ECI planner unavailable while ECI is active ($ECI_MARKER): $1. Bash is denied until the Codex command planner is restored."
  fi
  printf 'ECI planner unavailable: %s\n' "$1" >&2
  exit 0
}

# Detect any `git push` invocation across pipes/subshells/bash -c. Prints `1`
# when a push is found. Falls back to a substring check if "$PYTHON3" is absent
# or exits non-zero (fails closed for push).
detect_git_push() {
  if command -v "$PYTHON3" >/dev/null 2>&1; then
    if "$PYTHON3" - "$COMMAND" <<'PY'
import os, shlex, sys

cmd = sys.argv[1]
OPS = {';', '&', '&&', '|', '||', '(', ')'}
GIT_KV = {'-c', '--config-env', '--exec-path', '--git-dir',
          '--namespace', '--super-prefix', '--work-tree'}
GIT_KV_EQ = tuple(a + '=' for a in GIT_KV if a.startswith('--'))

def tokenize(s):
    try:
        lex = shlex.shlex(s, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex), True
    except ValueError:
        return [], False

def segments(toks):
    out, start = [], 0
    for i, t in enumerate(toks + [';']):
        if t in OPS:
            if start < i:
                out.append(toks[start:i])
            start = i + 1
    return out

def is_assign(t):
    n, s, _ = t.partition('=')
    return bool(s) and bool(n) and n.replace('_', 'A').isalnum() and not n[0].isdigit()

def cmd_start(seg):
    i = 0
    while i < len(seg) and is_assign(seg[i]):
        i += 1
    while i < len(seg):
        n = os.path.basename(seg[i])
        if n in ('command', 'builtin', 'exec'):
            i += 1
            continue
        if n == 'env':
            i += 1
            while i < len(seg):
                t = seg[i]
                if is_assign(t):
                    i += 1; continue
                if t in ('-i', '-0') or t.startswith('-u'):
                    i += 1; continue
                if t in ('-C', '-S') and i + 1 < len(seg):
                    i += 2; continue
                if t.startswith('-'):
                    i += 1; continue
                break
            continue
        if n in ('sudo', 'doas'):
            i += 1
            while i < len(seg) and seg[i].startswith('-'):
                i += 1
            continue
        return i
    return i

def check_seg(seg, depth=0):
    i = cmd_start(seg)
    if i >= len(seg):
        return False
    n = os.path.basename(seg[i])
    if n in ('bash', 'sh', 'zsh', 'dash'):
        j = i + 1
        while j < len(seg):
            if seg[j] == '-c' and j + 1 < len(seg):
                return check_command(seg[j + 1], depth + 1)
            j += 1
        return False
    if n != 'git':
        return False
    j = i + 1
    while j < len(seg):
        t = seg[j]
        if t == '-C' and j + 1 < len(seg):
            j += 2; continue
        if t.startswith('-C') and len(t) > 2:
            j += 1; continue
        if t in GIT_KV and j + 1 < len(seg):
            j += 2; continue
        if any(t.startswith(p) for p in GIT_KV_EQ):
            j += 1; continue
        if t.startswith('-'):
            j += 1; continue
        return t == 'push'
    return False

def check_command(s, depth=0):
    if depth > 3:
        return 'git push' in s
    toks, ok = tokenize(s)
    if not ok:
        return 'git push' in s
    for seg in segments(toks):
        if check_seg(seg, depth):
            return True
    return False

if check_command(cmd):
    print('1')
PY
    then
      return 0
    fi
  fi
  case "$COMMAND" in
  *"git push"*) printf '1\n' ;;
  esac
}

# Match the text `eci-active off` anywhere in a command (subagent guard). This
# is a text match, not a parse of an invocation: it deletes backslash-newline
# pairs first (bash joins them also inside a word: o\<newline>ff is off), drops
# the `$` of ANSI-C ($'..') and locale ($"..") quotes so that the quote strip
# leaves the word and not a variable name ($off), deletes quotes and
# backslashes, then looks for eci-active, whitespace, then the word off.
# Quoting forms, line continuations, wrappers (env, stdbuf, nice, sudo) and
# nested shells (bash -c, env -S) therefore all match. This replaces an
# argv-head parser that missed wrapper and continuation forms; ECI guards
# accidental deviation, not adversarial input, so a text match is enough.
# Accepted over-denial: the same text in echo, heredoc bodies, grep patterns
# and commit messages, and three shapes in which bash reads other words than
# the matcher does:
#   - Single quotes and $'..' keep a backslash-newline, so 'o\<newline>ff' is
#     the literal word o\<newline>ff, not off; the matcher deletes the pair.
#   - o\\<newline>ff is the word o\ followed by a second command, ff; the
#     matcher deletes the second backslash with the newline and reads off.
#   - A newline between eci-active and off makes two commands, eci-active
#     without an argument and then off; the matcher's whitespace class spans
#     the newline.
#
# Word formation is modelled only as quote removal (plus the $' and $" prefix)
# and backslash-newline joining. Everything else that builds a word is not
# detected, so this guard does not deny it, and the planner does not reliably
# deny it either: with an active marker it allowed
# ~/.claude/bin/eci-active {off,} and ~/.claude/bin/eci-active off$'\000y',
# for a subagent and for the main thread, and its verdict on other forms
# depends on the executable path and the caller. The forms are brace expansion
# (eci-active {off,}), parameter expansion
# including $IFS (o${X}ff, eci-active${IFS}off), command substitution
# (o"$(printf f)"f), pathname expansion (o?f beside a file named off),
# ANSI-C expansion (escapes inside $'..', such as $'o\x66f'), and arguments
# supplied at run time (E=...eci-active; "$E" off, or a script file that runs
# it). Only a planner pass that evaluates the words closes these.
#
# A NUL escape is one such miss. Bash cuts an ANSI-C string at the NUL, so
# eci-active off$'\0x' r.md runs eci-active off r.md. These spellings cut the
# word the same way (each was probed): \0, \00, \000, \x0, \x00, \u0000,
# \U00000000, \c@, \c` and \c<space>. The matcher sees off0x there (offx00,
# offu0000, offc@ for the other spellings): the $' normalization removed the $
# that used to follow off and end the match, and the match needs a non-word
# character after off.
command_mentions_eci_off() {
  local text="$1"
  text=${text//$'\\\n'/}
  text=${text//\$\'/\'}
  text=${text//\$\"/\"}
  text="$(printf '%s' "$text" | tr -d '\\"'"'")"
  [[ $text =~ eci-active[[:space:]]+off([^[:alnum:]_]|$) ]]
}

git_reset_dirs() {
  "$PYTHON3" - "$COMMAND" "${CWD:-$PWD}" <<'PY'
import os
import shlex
import sys

command = sys.argv[1]
cwd = sys.argv[2] or os.getcwd()

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(2)

operators = {";", "&", "&&", "|", "||", "(", ")"}


def basename(token):
    return os.path.basename(token)


def is_assignment(token):
    name, sep, _ = token.partition("=")
    return bool(sep) and bool(name) and name.replace("_", "A").isalnum() and not name[0].isdigit()


def resolve(path, base):
    path = os.path.expanduser(path)
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.join(base, path))


def skip_env(segment, index):
    index += 1
    while index < len(segment):
        token = segment[index]
        if is_assignment(token):
            index += 1
            continue
        if token in {"-i", "-0"} or token.startswith("-u"):
            index += 1
            continue
        if token in {"-C", "-S"} and index + 1 < len(segment):
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    return index


def command_index(segment):
    index = 0
    while index < len(segment) and is_assignment(segment[index]):
        index += 1
    while index < len(segment):
        name = basename(segment[index])
        if name in {"command", "builtin", "exec"}:
            index += 1
            continue
        if name == "env":
            index = skip_env(segment, index)
            continue
        if name in {"sudo", "doas"}:
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                index += 1
            continue
        return index
    return index


def git_reset_dir(segment, index, base_dir):
    git_dir = base_dir
    arg_takes_value = {
        "-c",
        "--config-env",
        "--exec-path",
        "--git-dir",
        "--namespace",
        "--super-prefix",
        "--work-tree",
    }
    arg_takes_value_eq = {arg + "=" for arg in arg_takes_value if arg.startswith("--")}
    index += 1
    while index < len(segment):
        token = segment[index]
        if token == "-C" and index + 1 < len(segment):
            git_dir = resolve(segment[index + 1], base_dir)
            index += 2
            continue
        if token.startswith("-C") and len(token) > 2:
            git_dir = resolve(token[2:], base_dir)
            index += 1
            continue
        if token in arg_takes_value and index + 1 < len(segment):
            index += 2
            continue
        if any(token.startswith(prefix) for prefix in arg_takes_value_eq):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        if token == "reset":
            return git_dir
        return None
    return None


segments = []
start = 0
for index, token in enumerate(tokens + [";"]):
    if token in operators:
        if start < index:
            segments.append(tokens[start:index])
        start = index + 1

current_dir = cwd
reset_dirs = []
for segment in segments:
    index = command_index(segment)
    if index >= len(segment):
        continue
    name = basename(segment[index])
    if name == "cd" and index + 1 < len(segment):
        current_dir = resolve(segment[index + 1], current_dir)
        continue
    if name in {"bash", "sh"} and "-c" in segment[index + 1 :]:
        script_index = segment.index("-c", index + 1) + 1
        if script_index < len(segment) and "git reset" in segment[script_index]:
            print("!shell-c")
        continue
    if name != "git":
        continue
    reset_dir = git_reset_dir(segment, index, current_dir)
    if reset_dir:
        reset_dirs.append(reset_dir)

for reset_dir in reset_dirs:
    print(reset_dir)
PY
}

enforce_git_reset_gate() {
  local reset_dirs=()
  local reset_dir repo_root marker marker_command reset_out

  case "$COMMAND" in
  *reset*) ;;
  *) return 0 ;;
  esac

  if ! command -v "$PYTHON3" >/dev/null 2>&1; then
    deny 'git reset denied: python3 is required to validate the one-time reset marker.'
  fi

  # Capture status explicitly: a failing git_reset_dirs must deny, not allow.
  if ! reset_out="$(git_reset_dirs)"; then
    deny 'git reset denied: reset validator failed or could not parse the shell command safely.'
  fi

  [ -n "$reset_out" ] || return 0
  mapfile -t reset_dirs <<<"$reset_out"

  [ "${#reset_dirs[@]}" -gt 0 ] || return 0

  if [ "${#reset_dirs[@]}" -gt 1 ]; then
    deny 'git reset denied: run only one git reset per Bash tool call.'
  fi

  reset_dir="${reset_dirs[0]}"
  if [ "$reset_dir" = "!shell-c" ]; then
    deny 'git reset denied: run git reset directly, not through bash -c or sh -c.'
  fi

  if ! repo_root="$(git -C "$reset_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    deny "git reset denied: could not identify the target repo for '$reset_dir'."
  fi

  marker="$repo_root/.git-reset-approved-once"
  if [ ! -f "$marker" ]; then
    deny "git reset denied: create $marker with date, reason, and command: $COMMAND after inspecting uncommitted changes."
  fi

  marker_command="$(awk '/^command: / { print substr($0, 10); found = 1; exit } END { if (!found) exit 1 }' "$marker" 2>/dev/null || true)"
  if [ -z "$marker_command" ]; then
    deny "git reset denied: $marker must contain a command: <exact Bash command> line."
  fi

  if [ "$marker_command" != "$COMMAND" ]; then
    deny "git reset denied: $marker command does not match this Bash command."
  fi

  if ! rm -f -- "$marker"; then
    deny "git reset denied: could not consume $marker."
  fi
}

# Determine whether a command is purely read-only (no writes, no side effects).
# Returns 0 (read-only) when every segment of the command is on the allow-list.
command_is_read_only() {
  local scrubbed

  [ -n "${1:-}" ] || return 1
  scrubbed="$(printf '%s' "$1" | sed -E 's/[[:space:]][0-9]*>>?[[:space:]]*\/dev\/null([[:space:]]|$)/ /g')"

  case "$scrubbed" in
  *'`'* | *'$('* | *'>'* | *'<'*) return 1 ;;
  esac

  printf '%s\n' "$scrubbed" |
    awk '
      function emit() {
        print segment
        segment = ""
      }
      BEGIN {
        single_quote_char = sprintf("%c", 39)
      }
      {
        for (pos = 1; pos <= length($0); pos++) {
          char = substr($0, pos, 1)
          next_char = substr($0, pos + 1, 1)
          if (escaped) {
            segment = segment char
            escaped = 0
            continue
          }
          if (char == "\\" && double_quote) {
            segment = segment char
            escaped = 1
            continue
          }
          if (!double_quote && char == single_quote_char) {
            single_quote = !single_quote
            segment = segment char
            continue
          }
          if (!single_quote && char == "\"") {
            double_quote = !double_quote
            segment = segment char
            continue
          }
          if (!single_quote && !double_quote) {
            if (char == ";") {
              emit()
              continue
            }
            if (char == "&" && next_char == "&") {
              emit()
              pos++
              continue
            }
            if (char == "|" && next_char == "|") {
              emit()
              pos++
              continue
            }
            if (char == "|") {
              emit()
              continue
            }
          }
          segment = segment char
        }
        emit()
      }
    ' |
    awk '
      function base_name(token) {
        sub(/^.*\//, "", token)
        return token
      }
      function allowed_simple(cmd) {
        return cmd ~ /^(cat|cut|date|dirname|du|egrep|fgrep|file|grep|head|jq|ls|nl|printf|pwd|readlink|realpath|rg|sed|sort|stat|tail|test|tr|uniq|wc|which|\[)$/
      }
      {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 == "") {
          next
        }
        part_count = split($0, parts, /[[:space:]]+/)
        idx = 1
        while (idx <= part_count && parts[idx] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          idx++
        }
        cmd = base_name(parts[idx])
        if (cmd == "") {
          next
        }
        if (cmd == "command") {
          if (parts[idx + 1] != "-v") {
            bad = 1
          }
          next
        }
        if (cmd == "git") {
          subcmd = parts[idx + 1]
          if (subcmd !~ /^(branch|describe|diff|grep|log|ls-files|remote|rev-parse|show|status)$/) {
            bad = 1
          }
          next
        }
        if (cmd == "find") {
          for (i = idx + 1; i <= part_count; i++) {
            if (parts[i] ~ /^-(delete|exec|execdir|ok|okdir)$/) {
              bad = 1
            }
          }
          next
        }
        if (cmd == "sed") {
          for (i = idx + 1; i <= part_count; i++) {
            if (parts[i] ~ /^-.*i/) {
              bad = 1
            }
          }
          next
        }
        if (!allowed_simple(cmd)) {
          bad = 1
        }
      }
      END { exit bad ? 1 : 0 }
    '
}

# Block all git push invocations. CLAUDE.md: push only on request.
if [ -n "$COMMAND" ] && [ "$(detect_git_push 2>/dev/null)" = "1" ]; then
  deny 'git push is blocked. No task in this environment requires git push, and no task is blocked by its absence. If you believe push is needed, that judgment is wrong — commit locally and proceed.'
fi

# Block subagents from disengaging ECI via `eci-active off`.
if [ "$IS_SUBAGENT" = true ] && command_mentions_eci_off "$COMMAND"; then
  deny 'Only the main thread or orchestrator may disengage ECI with `eci-active off`. Subagents report completion or blockers to the orchestrator while ECI stays active. This check matches that phrase anywhere in command text, including quoted text, heredocs and commit messages. Do not retry the disengage in any form. When the phrase is only text, such as a commit message or search pattern, describe it in other words.'
fi

enforce_git_reset_gate

read_only=false
if command_is_read_only "$COMMAND"; then
  read_only=true
fi

# Mark shell activity for non-subagent, non-read-only commands.
if [ "$IS_SUBAGENT" != true ] && [ "$read_only" != true ]; then
  claude_mark_activity "$SESSION_ID" "$CWD" shell || true
fi

# ECI command plan: the Codex planner decides (codex parity). Its output and
# exit code pass through unchanged unless the fail-closed rules below apply.
# Kept Codex names: the planner is the shared runtime under ~/tmp/eci-runtime,
# built from the ~/.codex sources. It reads CODEX_HOOK_IS_SUBAGENT and
# CODEX_PROOF_ROOT, and it is located and rebuilt through ~/.codex.
unset CODEX_HOOK_IS_SUBAGENT
[ "$IS_SUBAGENT" = true ] && export CODEX_HOOK_IS_SUBAGENT=1
export CODEX_PROOF_ROOT="$PROOF_ROOT"
[ -n "$tmp" ] || eci_planner_unavailable "cannot stage hook input (mktemp under ${TMPDIR:-${HOME:-}/tmp} failed)"
case "${HOME:-}" in
  /*) ;;
  *) eci_planner_unavailable "HOME is empty or not absolute ('${HOME:-}')" ;;
esac
root="$HOME/.codex"
[ -d "$root" ] || eci_planner_unavailable "planner root missing: $root"
. "$root/hooks/lib/eci-runtime-sync.sh" || eci_planner_unavailable "cannot source $root/hooks/lib/eci-runtime-sync.sh"
bin="$(eci_runtime_artifact_path codex eci-command-plan)" || eci_planner_unavailable "no artifact path for eci-command-plan under $root"
eci_runtime_binary_is_native "$bin" || eci_runtime_build_missing "$root" eci-command-plan || eci_planner_unavailable "rebuild of $bin failed"
eci_runtime_binary_is_native "$bin" || eci_planner_unavailable "planner binary missing or not native: $bin"

# `|| rc=$?` and not `set +e`: the ERR trap from claude_install_fail_open_trap
# fires on any failed command outside a ||, && or if condition, even with
# errexit off, and would turn a planner exit code into a silent fail-open.
rc=0
"$bin" --hook <"$tmp" >"$tmp.out" || rc=$?
if [ "$rc" -ne 0 ] && [ -e "$ECI_MARKER" ]; then
  deny "ECI planner exited $rc while ECI is active ($ECI_MARKER). Bash is denied until the Codex command planner is restored."
fi
cat -- "$tmp.out"
exit "$rc"
