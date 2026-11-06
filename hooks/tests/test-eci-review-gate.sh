#!/usr/bin/env bash
# Standalone test for hooks/eci-review-gate.sh (Claude port of the Codex CLI).
#
# Each case runs the gate under `env -i` with a scratch HOME, a scratch proof
# root (CLAUDE_PROOF_ROOT) and a scratch git repository, then asserts the exit
# code plus the stream and text of the reason. Accept paths and deny paths are
# both asserted; a `!stream` expectation asserts that text is absent.
# Deterministic: no clock input, no shared state, no network.

set -u

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HOOKS_DIR/eci-review-gate.sh"
SID="11111111-2222-3333-4444-555555555555"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

pass=0
fail=0
RUN=""
CASE_N=0
CASE=""
root=""
home=""
repo=""
canon=""
RC=0
EXTRA_ENV=()

note_pass() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
note_fail() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

cleanup() { [ -n "$RUN" ] && rm -rf -- "$RUN"; }
trap cleanup EXIT

mkdir -p "$HOME/tmp" && RUN="$(mktemp -d "$HOME/tmp/eci-review-gate-test.XXXXXX")" || {
  echo "FAIL setup: cannot create scratch dir under $HOME/tmp" >&2
  exit 1
}

# new_case: fresh proof root, scratch HOME, git repo with one committed file
# and one unstaged change (so target.txt is in the current diff).
new_case() {
  CASE_N=$((CASE_N + 1))
  CASE="$RUN/case-$CASE_N"
  root="$CASE/proof"
  home="$CASE/home"
  repo="$CASE/repo"
  mkdir -p "$root/$SID" "$home" "$repo"
  git -C "$repo" init -q
  printf 'v1\n' >"$repo/target.txt"
  git -C "$repo" add -- target.txt
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -qm init
  printf 'v2\n' >"$repo/target.txt"
  canon="$(cd "$repo" && pwd -P)"
  EXTRA_ENV=()
}

# run_gate <cwd> [gate args...]: runs the gate with a fully controlled env.
run_gate() {
  local cwd="$1"
  shift
  (cd "$cwd" && env -i PATH="$PATH" HOME="$home" CLAUDE_PROOF_ROOT="$root" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$GATE" "$@") >"$CASE/stdout" 2>"$CASE/stderr"
  RC=$?
}

# check <label> <want-rc> [stream needle]...: stream is stdout|stderr, prefix
# `!` to assert the needle is absent.
check() {
  local label="$1" want="$2" detail="" stream needle neg found
  shift 2
  [ "$RC" = "$want" ] || detail="rc=$RC want=$want"
  while [ "$#" -ge 2 ]; do
    stream="$1"
    needle="$2"
    shift 2
    neg=0
    case "$stream" in
      !*) neg=1; stream="${stream#!}" ;;
    esac
    if grep -qF -- "$needle" "$CASE/$stream" 2>/dev/null; then found=1; else found=0; fi
    if [ "$neg" = 1 ] && [ "$found" = 1 ]; then
      detail="$detail; unexpected [$needle] in $stream"
    fi
    if [ "$neg" = 0 ] && [ "$found" = 0 ]; then
      detail="$detail; missing [$needle] in $stream"
    fi
  done
  if [ -z "$detail" ]; then
    note_pass "$label"
  else
    note_fail "$label" "${detail#; } | stdout: $(head -c 300 "$CASE/stdout" | tr '\n' ' ') | stderr: $(head -c 300 "$CASE/stderr" | tr '\n' ' ')"
  fi
}

write_manifest() {
  printf '{"current_target_path": "%s"}\n' "$1" >"$root/$SID/eci-required-critics.json"
}

write_marker() { # write_marker <canonical-cwd> [owner-sid]
  printf 'scope: test\ncwd: %s\nsession_id: %s\ncreated_utc: 2026-01-01T00:00:00Z\n' \
    "$1" "${2:-$SID}" >"$root/$SID/eci_active"
}

assert_cmd() { # assert_cmd <label> <cmd...>
  local label="$1"
  shift
  if "$@"; then note_pass "$label"; else note_fail "$label" "command failed: $*"; fi
}

echo "== static"
assert_cmd "gate is executable" test -x "$GATE"
assert_cmd "gate mode is 755" test "$(stat -c %a "$GATE")" = 755
for f in "$GATE" "$HOOKS_DIR/lib/claude-proof-state.sh" "$HOOKS_DIR/lib/claude-eci-control.sh" \
  "$HOOKS_DIR/lib/claude-eci-review.sh"; do
  assert_cmd "bash -n $(basename "$f")" bash -n "$f"
done

echo "== usage and phase"
new_case
run_gate "$repo"
check "no args denied with usage" 2 stderr "Usage: eci-review-gate.sh <commit|final|off|prewrite> <session-id>" !stdout "ECI"
new_case
run_gate "$repo" bogus "$SID"
check "unknown phase denied" 2 stderr "Usage: eci-review-gate.sh"

echo "== session id"
new_case
run_gate "$repo" commit "bad/id"
check "invalid session id denied" 1 stderr "needs a valid session id"
new_case
EXTRA_ENV=(CODEX_SESSION_ID="$SID")
run_gate "$repo" commit
check "CODEX_SESSION_ID ignored, no arg denied" 1 stderr "needs a valid session id"
new_case
EXTRA_ENV=(CLAUDE_SESSION_ID="$SID")
run_gate "$repo" commit
check "CLAUDE_SESSION_ID env accepted, no manifest passes" 0 stdout "refresh needed: phase=commit"

echo "== proof root and session dir"
new_case
rm -rf -- "$root"
printf 'x\n' >"$root"
run_gate "$repo" commit "$SID"
check "proof root that is a file denied" 1 stderr "unsafe proof root"
new_case
rm -rf -- "$root/$SID"
run_gate "$repo" commit "$SID"
check "missing session dir denied" 1 stderr "needs the canonical session directory"
new_case
rm -rf -- "$root/$SID"
mkdir -p "$CASE/real-session"
ln -s "$CASE/real-session" "$root/$SID"
run_gate "$repo" commit "$SID"
check "session dir that is a symlink denied" 1 stderr "unsafe session directory"
new_case
mkdir -p "$CASE/codex-root/$SID"
EXTRA_ENV=(CODEX_PROOF_ROOT="$CASE/codex-root")
rm -rf -- "$root/$SID"
run_gate "$repo" commit "$SID"
check "CODEX_PROOF_ROOT ignored, missing CLAUDE session denied" 1 stderr "needs the canonical session directory"

echo "== commit, final, prewrite"
for p in commit final prewrite; do
  new_case
  run_gate "$repo" "$p" "$SID"
  check "$p: no manifest passes with refresh" 0 stdout "refresh needed: phase=$p" stdout "reason=no current review metadata exists"

  new_case
  write_manifest "$canon/target.txt"
  run_gate "$repo" "$p" "$SID"
  check "$p: current modified target passes" 0 stdout "review gate passed: phase=$p target=$canon/target.txt" !stderr "rejected"

  new_case
  git -C "$repo" checkout -q -- target.txt
  write_manifest "$canon/target.txt"
  run_gate "$repo" "$p" "$SID"
  check "$p: target not in diff passes with refresh" 0 stdout "no longer part of the current diff"

  new_case
  printf 'outside\n' >"$CASE/outside.txt"
  write_manifest "$CASE/outside.txt"
  run_gate "$repo" "$p" "$SID"
  check "$p: target outside repo denied" 1 stderr "outside the current repository" !stdout "gate passed"

  new_case
  printf '{ not json' >"$root/$SID/eci-required-critics.json"
  run_gate "$repo" "$p" "$SID"
  check "$p: unparseable manifest passes with refresh" 0 stdout "not parseable"

  new_case
  EXTRA_ENV=(ECI_REVIEW_CWD="$CASE/missing")
  run_gate "$repo" "$p" "$SID"
  check "$p: nonexistent review cwd denied" 1 stderr "unsafe review cwd"

  new_case
  mkdir -p "$CASE/nogit"
  EXTRA_ENV=(ECI_REVIEW_CWD="$CASE/nogit")
  run_gate "$repo" "$p" "$SID"
  check "$p: cwd outside git passes with refresh" 0 stdout "no current repository is available"

  new_case
  printf '{}\n' >"$root/$SID/eci-aggregate-plan.json"
  run_gate "$repo" "$p" "$SID"
  check "$p: singleton call on aggregate session denied" 1 stderr "singleton lifecycle invocation for an aggregate session"
done

echo "== off"
new_case
run_gate "$repo" off "$SID"
check "off: no active marker denied" 1 stderr "without the regular active marker"

new_case
write_marker "$canon"
mv "$root/$SID/eci_active" "$CASE/real-marker"
ln -s "$CASE/real-marker" "$root/$SID/eci_active"
run_gate "$repo" off "$SID"
check "off: marker symlink denied" 1 stderr "without the regular active marker"

new_case
write_marker "$canon"
run_gate "$repo" off "$SID"
check "off: valid marker in own cwd passes with refresh" 0 stdout "refresh needed: phase=off"

new_case
write_marker "$CASE/other-cwd"
run_gate "$repo" off "$SID"
check "off: marker for another cwd denied" 1 stderr "belongs to another cwd"

new_case
write_marker "$canon" "99999999-2222-3333-4444-555555555555"
run_gate "$repo" off "$SID"
check "off: marker session_id mismatch denied" 1 stderr "path/owner binding is malformed"

new_case
printf 'task: test\nengaged: 2026-01-01T00:00:00Z\n' >"$root/$SID/eci_active"
run_gate "$repo" off "$SID"
check "off: Claude eci-active format denied as malformed" 1 stderr "path/owner binding is malformed"

new_case
printf 'scope: test\ncwd: %s\nsession_id: %s\ncreated_utc: 2026-01-01T00:00:00Z' "$canon" "$SID" >"$root/$SID/eci_active"
run_gate "$repo" off "$SID"
check "off: marker without trailing newline denied" 1 stderr "path/owner binding is malformed"

# Bounded-record check: 4096 bytes is the limit, 4097 is denied.
bounded_marker() { # bounded_marker <total-bytes>
  local prefix pad
  prefix="$(LC_ALL=C printf 'scope: test\ncwd: %s\nsession_id: %s\ncreated_utc: ' "$canon" "$SID")"
  pad="$(LC_ALL=C printf '%*s' $(( $1 - ${#prefix} - 1 )) '' | tr ' ' a)"
  printf '%s%s\n' "$prefix" "$pad" >"$root/$SID/eci_active"
}
new_case
bounded_marker 4096
run_gate "$repo" off "$SID"
check "off: marker at 4096 bytes passes" 0 stdout "refresh needed: phase=off"
new_case
bounded_marker 4097
run_gate "$repo" off "$SID"
check "off: marker at 4097 bytes denied" 1 stderr "path/owner binding is malformed"

echo "== aggregate"
new_case
EXTRA_ENV=(ECI_AGGREGATE_REPO_ID="bad id")
run_gate "$repo" commit "$SID"
check "aggregate: invalid repo id denied" 1 stderr "bounded repository ID"
new_case
EXTRA_ENV=(ECI_AGGREGATE_REPO_ID="-leading")
run_gate "$repo" commit "$SID"
check "aggregate: leading-dash repo id denied" 1 stderr "bounded repository ID"
new_case
mkdir -p "$CASE/elsewhere"
EXTRA_ENV=(ECI_AGGREGATE_REPO_ID=repo_1 ECI_AGGREGATE_PARENT_CWD="$CASE/elsewhere")
run_gate "$repo" commit "$SID"
check "aggregate: parent cwd mismatch denied" 1 stderr "remain at the parent marker cwd"
new_case
EXTRA_ENV=(ECI_AGGREGATE_PARENT_CWD="$canon")
run_gate "$repo" commit "$SID"
check "aggregate: parent cwd without repo id denied" 1 stderr "without an aggregate repository ID"
new_case
EXTRA_ENV=(ECI_AGGREGATE_REPO_ID=repo_1 ECI_AGGREGATE_PARENT_CWD="$canon")
run_gate "$repo" commit "$SID"
check "aggregate: valid id and parent cwd passes with refresh" 0 stdout "no current aggregate repository metadata exists"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
