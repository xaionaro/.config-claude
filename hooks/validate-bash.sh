#!/usr/bin/env bash
# Recover the ignored executable on first use; command policy lives in Go.
set -euo pipefail

# ---- Claude-only guards: they run before the Codex planner below. ----
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/claude-proof-state.sh"
. "$HOOK_DIR/lib/claude-python.sh"

# The planner gets the same bytes on stdin (process substitution at the exec
# below); the trailing x keeps the trailing newlines that $(...) strips.
input="$(cat; printf x)"
input="${input%x}"
COMMAND="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"

# Claude subagent detection reads the hook input agent_id
# (claude_hook_is_subagent_context). </dev/null keeps an empty input from
# making the predicate read the consumed stdin.
IS_SUBAGENT=false
if claude_hook_is_subagent_context "$input" </dev/null; then
  IS_SUBAGENT=true
fi

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

# ---- Claude-only guard, kept by supervisor decision: subagent `eci-active off`. ----
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
# detected, so this guard does not deny it. The planner was probed on
# 2026-11-07 (codex eci-command-plan, sha256 23c29a46...): with an active marker
# it allowed ~/.claude/bin/eci-active {off,} and
# ~/.claude/bin/eci-active off$'\000y', for a subagent and for the main thread,
# and its verdict on other forms depended on the executable path and the
# caller. That is what that build did, not a property of the planner; a newer
# build can differ, so probe again before relying on it. The forms are brace expansion
# (eci-active {off,}), parameter expansion
# including $IFS (o${X}ff, eci-active${IFS}off), command substitution
# (o"$(printf f)"f), pathname expansion (o?f beside a file named off),
# ANSI-C expansion (escapes inside $'..', such as $'o\x66f'), and arguments
# supplied at run time (E=...eci-active; "$E" off, or a script file that runs
# it). Only a planner pass that evaluates the words closes these.
#
# A NUL escape is one such miss. Bash cuts an ANSI-C string at the NUL, so
# eci-active off$'\0x' r.md runs eci-active off r.md. These spellings cut the
# word the same way (each was probed in bash 5.3 on 2026-11-07): \0, \00, \000,
# \0000 (\000 then a 0), \400 (octal 400 wraps to NUL), \x0, \x00, \x000,
# \u0, \u00, \u000, \u0000, \U0, \U00000000, \U000000000, \c@, \c` and
# \c<space>. \1000, \c\x40, \c\100, \1, \x1 and \u1 do not. For
# eci-active off$'<spelling>x' r.md the matcher sees off followed by the spelling
# without its backslash and quotes, then x: off0x, off00x, off000x, off0000x,
# off400x, offx0x, offx00x, offx000x, offu0x, offu00x, offu000x, offu0000x,
# offU0x, offU00000000x, offU000000000x, offc@x, offc`x, and offc (the space
# ends the word). The $' normalization removed the $ that used to follow off and
# end the match, and the match needs a non-word character after off; each form
# has a letter or digit there, so none is denied.
command_mentions_eci_off() {
  local text="$1"
  text=${text//$'\\\n'/}
  text=${text//\$\'/\'}
  text=${text//\$\"/\"}
  text="$(printf '%s' "$text" | tr -d '\\"'"'")"
  [[ $text =~ eci-active[[:space:]]+off([^[:alnum:]_]|$) ]]
}

# Block subagents from disengaging ECI via `eci-active off`.
if [ "$IS_SUBAGENT" = true ] && command_mentions_eci_off "$COMMAND"; then
  deny 'Only the main thread or orchestrator may disengage ECI with `eci-active off`. Subagents report completion or blockers to the orchestrator while ECI stays active. This check matches that phrase anywhere in command text, including quoted text, heredocs and commit messages. Do not retry the disengage in any form. When the phrase is only text, such as a commit message or search pattern, describe it in other words.'
fi

# ---- Claude-only guards, kept by the CLAUDE.md Git rules: push only on ----
# ---- request, and the .git-reset-approved-once reset gate.             ----
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

# Block all git push invocations. CLAUDE.md: push only on request.
if [ -n "$COMMAND" ] && [ "$(detect_git_push 2>/dev/null)" = "1" ]; then
  deny 'git push is blocked. No task in this environment requires git push, and no task is blocked by its absence. If you believe push is needed, that judgment is wrong — commit locally and proceed.'
fi

enforce_git_reset_gate

# ---- Codex planner (copied from ~/.codex/hooks/validate-bash.sh). ----
case "${HOME:-}" in ''|!/*) exit 0 ;; esac
# Kept Codex root: the planner is the shared runtime under ~/tmp/eci-runtime,
# located and rebuilt through ~/.codex.
root="$HOME/.codex"
[ -d "$root" ] || exit 0
source "$root/hooks/lib/eci-runtime-sync.sh" || exit 0
binary="$(eci_runtime_artifact_path codex eci-command-plan)" || exit 0
if ! eci_runtime_binary_is_native "$binary"; then
  printf 'ECI runtime recovery: rebuilding missing or host-incompatible command hook: %s\n' "$binary" >&2
  eci_runtime_build_missing "$root" eci-command-plan || exit 0
fi
eci_runtime_binary_is_native "$binary" || exit 0
exec {planner_fd}<"$binary" || exit 0
# Kept Codex names: the planner binary reads CODEX_HOOK_IS_SUBAGENT and CODEX_PROOF_ROOT.
unset CODEX_HOOK_IS_SUBAGENT
if [ "$IS_SUBAGENT" = true ]; then
  export CODEX_HOOK_IS_SUBAGENT=1
fi
CODEX_PROOF_ROOT="$(claude_proof_root)"
export CODEX_PROOF_ROOT
exec "/proc/self/fd/$planner_fd" --hook < <(printf '%s' "$input")
