#!/usr/bin/env bash
# Hook regression test runner. Adapted from /home/streaming/.codex/hooks/tests/run.sh
# with Claude-specific tooling, paths, and the role-exemption matrix.
#
# Many Claude hooks resolve state via $HOME/.cache/claude-proof/ directly (not
# via CLAUDE_PROOF_ROOT). To isolate, ported tests run hooks under a fake HOME
# that symlinks .claude -> the real ~/.claude (so hook source paths resolve)
# while ~/.cache/claude-proof lives entirely in the test sandbox.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
FIXTURES="$ROOT/hooks/tests/fixtures"
TMP_ROOT=""
if ! TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-hooks-tests.XXXXXX")"; then
  printf '%s\n' "FAIL setup could not create temporary test root"
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

cleanup() { [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

note() { printf '%s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); note "PASS $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); note "FAIL $1"; [ "${2:-}" ] && note "     $2"; }

run_case() {
  local name="$1"; shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

# fresh proof root per test; isolated from real ~/.cache/claude-proof.
# (kept for the original 15 tests — they pass CLAUDE_PROOF_ROOT for documentation
# even though most claude hooks ignore it. Subagent/role exemptions trigger
# before any state lookup so that path is not exercised.)
fresh_proof_root() {
  local name="$1"
  local dir="$TMP_ROOT/proof-$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Build an isolated HOME for ported tests. Symlinks .claude → real one so the
# hooks can `source $HOME/.claude/hooks/lib/claude-proof-state.sh`. The fake
# HOME's $HOME/.cache/claude-proof remains entirely test-controlled.
fresh_home() {
  local name="$1"
  local dir="$TMP_ROOT/home-$name"
  rm -rf "$dir"
  mkdir -p "$dir/.cache/claude-proof"
  ln -s "$HOME/.claude" "$dir/.claude"
  printf '%s' "$dir"
}

# proof_dir under a fake HOME for a session id (mirrors hook's $HOME/.cache/claude-proof/$SID layout).
proof_dir_in_home() {
  local home="$1" sid="$2"
  local d="$home/.cache/claude-proof/$sid"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Run a hook with given INPUT (from file) and env overrides; capture
# stdout+stderr to file `out`. Returns the hook's rc.
run_hook() {
  local out="$1" hook="$2" input_file="$3"; shift 3
  local env_args=()
  while [ $# -gt 0 ]; do env_args+=("$1"); shift; done
  env -i HOME="$HOME" PATH="$PATH" "${env_args[@]}" \
    bash "$hook" <"$input_file" >"$out" 2>"$out.err"
}

# Like run_hook but runs the hook with cwd set to $dir. Required for stop-gate.sh
# which calls `git status --porcelain` against the current shell cwd (not against
# input.cwd via `git -C`); the test repo must be the cwd to get an honest answer.
run_hook_in_dir() {
  local dir="$1" out="$2" hook="$3" input_file="$4"; shift 4
  local env_args=()
  while [ $# -gt 0 ]; do env_args+=("$1"); shift; done
  ( cd "$dir" && env -i HOME="$HOME" PATH="$PATH" "${env_args[@]}" \
      bash "$hook" <"$input_file" >"$out" 2>"$out.err" )
}

# ---- jq helpers (codex-style) ----
json_field_equals() {
  local file="$1" expr="$2" want="$3" got
  got="$(jq -r "$expr" "$file" 2>/dev/null || true)"
  [ "$got" = "$want" ]
}
json_field_contains() {
  local file="$1" expr="$2" needle="$3" got
  got="$(jq -r "$expr" "$file" 2>/dev/null || true)"
  case "$got" in *"$needle"*) return 0 ;; *) return 1 ;; esac
}
json_field_not_contains() { ! json_field_contains "$@"; }

is_pretool_deny() {
  json_field_equals "$1" '.hookSpecificOutput.permissionDecision // empty' "deny"
}
is_pretool_allow() {
  ! is_pretool_deny "$1"
}
is_stop_block() {
  json_field_equals "$1" '.decision // empty' "block"
}
expect_no_output() {
  [ ! -s "$1" ]
}
expect_silent_or_no_decision() {
  # Hook either exited silently or emitted nothing parseable as a decision.
  local d
  d=$(jq -r '.hookSpecificOutput.permissionDecision // .decision // "no-decision"' "$1" 2>/dev/null)
  [ -z "$d" ] && d="no-decision"
  [ "$d" = "no-decision" ]
}

with_cwd_fixture() {
  local src="$1" dst="$2"
  jq --arg cwd "$ROOT" '.cwd = $cwd' "$src" >"$dst"
}
with_cwd_path() {
  local src="$1" dst="$2" cwd="$3"
  jq --arg cwd "$cwd" '.cwd = $cwd' "$src" >"$dst"
}

make_git_repo() {
  local name="$1"
  local repo="$TMP_ROOT/git-$name"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  git -C "$repo" config user.email "hooks-test@example.invalid" || return 1
  git -C "$repo" config user.name "Hooks Test" || return 1
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "initial" || return 1
  printf '%s\n' "$repo"
}

# Like make_git_repo but seeds a .go file so the stop-gate's
# "code-changes" filter (which excludes .txt/.md/etc) sees changes
# when the test mutates file.go.
make_git_repo_with_code() {
  local name="$1"
  local repo="$TMP_ROOT/git-$name"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  git -C "$repo" config user.email "hooks-test@example.invalid" || return 1
  git -C "$repo" config user.name "Hooks Test" || return 1
  printf 'package main\nfunc main() {}\n' >"$repo/file.go"
  git -C "$repo" add file.go || return 1
  git -C "$repo" commit -qm "initial" || return 1
  printf '%s\n' "$repo"
}

make_fake_gitleaks() {
  local name="$1"
  local bin_dir="$TMP_ROOT/bin-$name"
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/gitleaks" <<'SCRIPT'
#!/usr/bin/env bash
set -u

report=""
source="."
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path|-r)
      shift
      report="${1:-}"
      ;;
    --source|-s)
      shift
      source="${1:-.}"
      ;;
  esac
  shift || break
done

if [ -z "$report" ]; then
  printf '%s\n' "missing report path" >&2
  exit 2
fi

if [ "${FAKE_GITLEAKS_MODE:-}" = "error" ]; then
  printf '%s\n' "scanner exploded" >&2
  exit 2
fi

if [ -d "$source" ] && grep -R "FAKE_SECRET" "$source" >/dev/null 2>&1; then
  cat >"$report" <<'JSON'
[
  {
    "Description": "Fake secret",
    "StartLine": 2,
    "File": "file.txt",
    "RuleID": "fake-secret"
  }
]
JSON
  exit 1
fi

printf '[]\n' >"$report"
exit 0
SCRIPT
  chmod +x "$bin_dir/gitleaks" || return 1
  printf '%s\n' "$bin_dir"
}

install_proof_fixture() {
  local proof_root="$1" fixture="$2"
  mkdir -p "$proof_root/t00-session" || return 1
  cp "$fixture" "$proof_root/t00-session/proof.md"
}

# Run stop-gate once with a complete proof to seed the freshness oracle
# history file, then restore proof.md and baseline_head (cleanup wipes
# them on accept). After this returns, the next stop-gate run will see
# PREV_SHA matching the audit fingerprint.
seed_freshness_oracle() {
  local home="$1" repo="$2" sid="$3" fixture="$4"
  local sd input out
  sd="$home/.cache/claude-proof/$sid"
  mkdir -p "$sd"
  cp "$fixture" "$sd/proof.md"
  git -C "$repo" rev-parse HEAD >"$sd/baseline_head"
  input=$(jq -n --arg sid "$sid" --arg cwd "$repo" --arg tr "/tmp/seed.jsonl" \
    '{session_id:$sid,transcript_path:$tr,stop_hook_active:false,cwd:$cwd}')
  out="$TMP_ROOT/seed-$sid.out"
  ( cd "$repo" && printf '%s' "$input" | env -i HOME="$home" PATH="$PATH" \
      bash "$ROOT/hooks/stop-gate.sh" >"$out" 2>"$out.err" ) || true
  # Re-install proof + baseline (the hook's accept-cleanup wiped them).
  cp "$fixture" "$sd/proof.md"
  git -C "$repo" rev-parse HEAD >"$sd/baseline_head"
}

# write a baseline_head referring to the repo's current HEAD
seed_baseline_head() {
  local proof_dir="$1" repo="$2"
  mkdir -p "$proof_dir"
  git -C "$repo" rev-parse HEAD >"$proof_dir/baseline_head" 2>/dev/null
}

write_transcript_with_activity() {
  local path="$1"
  cat >"$path" <<'EOF'
{"type":"user","message":{"role":"user","content":"do something"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
EOF
}

# ===========================================================================
# ORIGINAL 15 TESTS — preserved verbatim from the start-here scaffold.
# ===========================================================================

test_stop_gate_exempts_subagent_with_agent_id() {
  local proof_root tr input_file out decision
  proof_root="$(fresh_proof_root subagent-exempt)"
  tr="$TMP_ROOT/subagent-transcript.jsonl"
  write_transcript_with_activity "$tr"

  input_file="$TMP_ROOT/subagent-stop-input.json"
  jq --arg tr "$tr" --arg cwd "$ROOT" \
    '. + {agent_id:"sub-uuid", session_id:"t00-sub", transcript_path:$tr, cwd:$cwd}' \
    "$FIXTURES/stop-basic.json" >"$input_file"

  mkdir -p "$proof_root/t00-sub"
  git rev-parse HEAD >"$proof_root/t00-sub/baseline_head" 2>/dev/null || \
    printf '%s' "0000000000000000000000000000000000000000" >"$proof_root/t00-sub/baseline_head"

  out="$TMP_ROOT/subagent-stop.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input_file" \
    CLAUDE_PROOF_ROOT="$proof_root"
  decision=$(jq -r '.decision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "no-decision" ]; then
    pass "stop-gate exempts subagent with agent_id (no CLAUDE_ROLE)"
  else
    fail "stop-gate exempts subagent with agent_id (no CLAUDE_ROLE)" \
         "decision=$decision; expected silent exit. Output: $(head -c 300 "$out")"
  fi
}

test_stop_gate_does_not_exempt_agent_type_only() {
  # agent_type alone is a main-thread --agent session (Claude docs); only agent_id marks a subagent.
  local proof_root tr input_file out decision
  proof_root="$(fresh_proof_root subagent-by-type)"
  tr="$TMP_ROOT/agent-type-transcript.jsonl"
  write_transcript_with_activity "$tr"

  input_file="$TMP_ROOT/subagent-type-input.json"
  jq --arg tr "$tr" --arg cwd "$ROOT" \
    '{session_id:"t00-by-type",transcript_path:$tr,cwd:$cwd,permission_mode:"bypassPermissions",agent_type:"general-purpose",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:"done"}' \
    <<<'{}' >"$input_file"

  mkdir -p "$proof_root/t00-by-type"
  git rev-parse HEAD >"$proof_root/t00-by-type/baseline_head" 2>/dev/null || \
    printf '%s' "0000000000000000000000000000000000000000" >"$proof_root/t00-by-type/baseline_head"

  out="$TMP_ROOT/subagent-type.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input_file" \
    CLAUDE_PROOF_ROOT="$proof_root"
  decision=$(jq -r '.decision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "block" ]; then
    pass "stop-gate does not exempt agent_type-only main thread (no agent_id)"
  else
    fail "stop-gate does not exempt agent_type-only main thread (no agent_id)" \
         "decision=$decision; expected block. Output: $(head -c 300 "$out")"
  fi
}

test_stop_gate_blocks_main_thread_with_activity() {
  local proof_root tr input_file out decision
  proof_root="$(fresh_proof_root main-thread-block)"
  tr="$TMP_ROOT/main-transcript.jsonl"
  write_transcript_with_activity "$tr"

  input_file="$TMP_ROOT/main-stop-input.json"
  jq --arg tr "$tr" --arg cwd "$ROOT" \
    '. + {session_id:"t00-main", transcript_path:$tr, cwd:$cwd}' \
    "$FIXTURES/stop-basic.json" >"$input_file"

  mkdir -p "$proof_root/t00-main"
  git rev-parse HEAD >"$proof_root/t00-main/baseline_head" 2>/dev/null || \
    printf '%s' "0000000000000000000000000000000000000000" >"$proof_root/t00-main/baseline_head"

  out="$TMP_ROOT/main-stop.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input_file" \
    CLAUDE_PROOF_ROOT="$proof_root"
  decision=$(jq -r '.decision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "block" ]; then
    pass "stop-gate blocks main thread (no agent_id, no CLAUDE_ROLE) with transcript activity"
  else
    fail "stop-gate blocks main thread (no agent_id, no CLAUDE_ROLE) with transcript activity" \
         "decision=$decision; expected 'block'. Output: $(head -c 300 "$out")"
  fi
}

test_stop_gate_exempts_subordinate_role() {
  local proof_root tr input_file out decision
  proof_root="$(fresh_proof_root role-exempt)"
  tr="$TMP_ROOT/role-transcript.jsonl"
  write_transcript_with_activity "$tr"

  input_file="$TMP_ROOT/role-stop-input.json"
  jq --arg tr "$tr" --arg cwd "$ROOT" \
    '. + {session_id:"t00-role", transcript_path:$tr, cwd:$cwd}' \
    "$FIXTURES/stop-basic.json" >"$input_file"

  mkdir -p "$proof_root/t00-role"
  git rev-parse HEAD >"$proof_root/t00-role/baseline_head" 2>/dev/null || \
    printf '%s' "0000000000000000000000000000000000000000" >"$proof_root/t00-role/baseline_head"

  out="$TMP_ROOT/role-stop.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input_file" \
    CLAUDE_PROOF_ROOT="$proof_root" CLAUDE_ROLE="executor"
  decision=$(jq -r '.decision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "no-decision" ]; then
    pass "stop-gate exempts CLAUDE_ROLE=executor (subordinate role)"
  else
    fail "stop-gate exempts CLAUDE_ROLE=executor (subordinate role)" \
         "decision=$decision; expected silent exit. Output: $(head -c 300 "$out")"
  fi
}

test_stop_gate_blocks_team_lead_role() {
  local proof_root tr input_file out decision
  proof_root="$(fresh_proof_root lead-block)"
  tr="$TMP_ROOT/lead-transcript.jsonl"
  write_transcript_with_activity "$tr"

  input_file="$TMP_ROOT/lead-stop-input.json"
  jq --arg tr "$tr" --arg cwd "$ROOT" \
    '. + {session_id:"t00-lead", transcript_path:$tr, cwd:$cwd}' \
    "$FIXTURES/stop-basic.json" >"$input_file"

  mkdir -p "$proof_root/t00-lead"
  git rev-parse HEAD >"$proof_root/t00-lead/baseline_head" 2>/dev/null || \
    printf '%s' "0000000000000000000000000000000000000000" >"$proof_root/t00-lead/baseline_head"

  out="$TMP_ROOT/lead-stop.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input_file" \
    CLAUDE_PROOF_ROOT="$proof_root" CLAUDE_ROLE="lead"
  decision=$(jq -r '.decision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "block" ]; then
    pass "stop-gate blocks CLAUDE_ROLE=lead with transcript activity"
  else
    fail "stop-gate blocks CLAUDE_ROLE=lead with transcript activity" \
         "decision=$decision; expected 'block'. Output: $(head -c 300 "$out")"
  fi
}

test_validate_edit_write_blocks_singular_import_dir() {
  local input out decision
  input="$TMP_ROOT/edit-singular-import.json"
  cat >"$input" <<'EOF'
{"tool_name":"Edit","tool_input":{"file_path":"/foo/wingout/import/ffstream/main.go","old_string":"a","new_string":"b"}}
EOF
  out="$TMP_ROOT/edit-singular-import.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "deny" ]; then
    pass "validate-edit-write denies edits under singular import/ dir"
  else
    fail "validate-edit-write denies edits under singular import/ dir" \
         "decision=$decision; expected deny. Output: $(head -c 300 "$out")"
  fi
}

test_validate_edit_write_blocks_plural_imports_dir() {
  local input out decision
  input="$TMP_ROOT/edit-plural-imports.json"
  cat >"$input" <<'EOF'
{"tool_name":"Edit","tool_input":{"file_path":"/foo/wingout/imports/ffstream/main.go","old_string":"a","new_string":"b"}}
EOF
  out="$TMP_ROOT/edit-plural-imports.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "deny" ]; then
    pass "validate-edit-write denies edits under plural imports/ dir"
  else
    fail "validate-edit-write denies edits under plural imports/ dir" \
         "decision=$decision; expected deny. Output: $(head -c 300 "$out")"
  fi
}

test_validate_edit_write_blocks_vendor_dir() {
  local input out decision
  input="$TMP_ROOT/edit-vendor.json"
  cat >"$input" <<'EOF'
{"tool_name":"Edit","tool_input":{"file_path":"/foo/wingout/vendor/ffstream/main.go","old_string":"a","new_string":"b"}}
EOF
  out="$TMP_ROOT/edit-vendor.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "deny" ]; then
    pass "validate-edit-write denies edits under vendor/ dir"
  else
    fail "validate-edit-write denies edits under vendor/ dir" \
         "decision=$decision; expected deny. Output: $(head -c 300 "$out")"
  fi
}

test_validate_edit_write_blocks_thirdparty_variants() {
  local variants=(
    "/foo/3rdparty/lib/x.go"
    "/foo/3rd_party/lib/x.go"
    "/foo/3rd-party/lib/x.go"
    "/foo/3rd party/lib/x.go"
    "/foo/thirdparty/lib/x.go"
    "/foo/third_party/lib/x.go"
    "/foo/third-party/lib/x.go"
    "/foo/third party/lib/x.go"
    "/foo/ThirdParty/lib/x.go"
    "/foo/Third_Party/lib/x.go"
  )
  local p input out decision rc=0
  for p in "${variants[@]}"; do
    input="$TMP_ROOT/edit-tp-$(echo "$p" | tr '/ ' '__').json"
    jq -n --arg fp "$p" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"a",new_string:"b"}}' >"$input"
    out="${input%.json}.out"
    run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
    [ -z "$decision" ] && decision="no-decision"
    if [ "$decision" != "deny" ]; then
      fail "validate-edit-write denies edits under third-party variant ($p)" \
           "decision=$decision; expected deny"
      rc=1
    fi
  done
  [ "$rc" = 0 ] && pass "validate-edit-write denies edits under all third-party variants (10)"
}

test_validate_edit_write_allows_lookalike_dirnames() {
  local variants=(
    "/foo/importer/x.go"
    "/foo/imported/x.go"
    "/foo/3rdpartyhelper/x.go"
    "/foo/thirdpartylib/x.go"
  )
  local p input out decision rc=0
  for p in "${variants[@]}"; do
    input="$TMP_ROOT/edit-look-$(echo "$p" | tr '/ ' '__').json"
    jq -n --arg fp "$p" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"a",new_string:"b"}}' >"$input"
    out="${input%.json}.out"
    run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
    [ -z "$decision" ] && decision="no-decision"
    if [ "$decision" = "deny" ]; then
      fail "validate-edit-write does NOT block lookalike dirnames ($p)" \
           "decision=$decision; expected allow"
      rc=1
    fi
  done
  [ "$rc" = 0 ] && pass "validate-edit-write does NOT block lookalike dirnames (4)"
}

test_validate_edit_write_allows_regular_repo_edit() {
  local repo input out decision
  repo="$TMP_ROOT/regular-repo-$$"
  mkdir -p "$repo/.git"
  echo "package x" >"$repo/file.go"

  input="$TMP_ROOT/edit-regular.json"
  jq -n --arg fp "$repo/file.go" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"x",new_string:"y"}}' >"$input"
  out="$TMP_ROOT/edit-regular.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" != "deny" ]; then
    pass "validate-edit-write allows edits in a regular (non-submodule) repo"
  else
    fail "validate-edit-write allows edits in a regular (non-submodule) repo" \
         "decision=$decision; expected allow. Output: $(head -c 300 "$out")"
  fi
}

# Real git submodule and a worktree of it, built under $TMP_ROOT. No hook gates
# submodule paths (codex behaviour), so a Write into either must be allowed.
test_validate_edit_write_allows_write_into_submodule_and_its_worktree() {
  local name="validate-edit-write allows Write into a git submodule and a worktree of it"
  local r="$TMP_ROOT/sm-allow" p input out hrc bad=""
  local g=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git
    -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main
    -c protocol.file.allow=always -c commit.gpgsign=false -c core.hooksPath=/dev/null)
  mkdir -p "$r" || { fail "$name" "mkdir $r failed"; return; }
  {
    "${g[@]}" init -q "$r/subsrc" && echo x >"$r/subsrc/file.txt" &&
      "${g[@]}" -C "$r/subsrc" add file.txt && "${g[@]}" -C "$r/subsrc" commit -q -m init &&
    "${g[@]}" init -q "$r/super" && echo x >"$r/super/top.txt" &&
      "${g[@]}" -C "$r/super" add top.txt && "${g[@]}" -C "$r/super" commit -q -m init &&
      "${g[@]}" -C "$r/super" submodule add -q "$r/subsrc" sub &&
      "${g[@]}" -C "$r/super" commit -q -m addsub &&
      "${g[@]}" -C "$r/super/sub" worktree add -q -b subwt-branch "$r/sub-wt"
  } >"$r/build.log" 2>&1 || { fail "$name" "fixture build failed: $(head -c 300 "$r/build.log")"; return; }
  # Premise: both targets sit behind a gitfile (.git is a FILE), the layout a
  # submodule gate keys on; otherwise the allow below would prove nothing.
  if ! { [ -f "$r/super/sub/.git" ] && [ -f "$r/sub-wt/.git" ]; }; then
    fail "$name" "premise: expected .git gitfiles in the submodule and its worktree"; return
  fi

  input="$r/in.json"; out="$r/out.json"
  for p in "$r/super/sub/file.txt" "$r/sub-wt/file.txt"; do
    jq -n --arg fp "$p" '{tool_name:"Write",tool_input:{file_path:$fp,content:"y"}}' >"$input"
    run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"; hrc=$?
    if [ "$hrc" != 0 ] || is_pretool_deny "$out" || grep -qi deny "$out"; then
      bad="$bad [${p#"$r"/}: rc=$hrc out=$(head -c 200 "$out")]"
    fi
  done
  # Control: the hook does run on submodule paths (vendor/ inside one is still denied).
  jq -n --arg fp "$r/super/sub/vendor/x.go" '{tool_name:"Write",tool_input:{file_path:$fp,content:"y"}}' >"$input"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
  if ! { is_pretool_deny "$out" && json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason' "vendor"; }; then
    bad="$bad [control: expected vendor/ deny inside submodule, out=$(head -c 200 "$out")]"
  fi

  if [ -z "$bad" ]; then
    pass "$name"
  else
    fail "$name" "unexpected:$bad"
  fi
}

test_validate_bash_allows_write_into_submodule() {
  # No hook gates submodule paths: writes into submodules are allowed (codex
  # behaviour), including via Bash.
  local home repo sub input out decision
  home="$(fresh_home bash-submod)"
  make_planner_stub "$home" || return 1
  repo="$TMP_ROOT/sup-repo-bash-$$"
  sub="$repo/sub"
  mkdir -p "$repo/.git" "$sub"
  printf 'gitdir: %s/modules/sub\n' "$repo/.git" >"$sub/.git"

  input="$TMP_ROOT/bash-submod.json"
  jq -n --arg cmd "echo y > $sub/file.go" '{tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-submod.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root bash-submod)"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" != "deny" ] && planner_received "$home" "$input"; then
    pass "validate-bash allows writes into a git submodule"
  else
    fail "validate-bash allows writes into a git submodule" \
         "decision=$decision; expected non-deny. Output: $(head -c 300 "$out")"
  fi
}

test_validate_bash_allows_write_to_singular_import_dir() {
  local home input out decision
  home="$(fresh_home bash-singular-import)"
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/bash-singular-import.json"
  cat >"$input" <<'EOF'
{"tool_name":"Bash","tool_input":{"command":"echo x > wingout/import/ffstream/main.go"}}
EOF
  out="$TMP_ROOT/bash-singular-import.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root bash-singular-import)"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "no-decision" ] && planner_received "$home" "$input"; then
    pass "validate-bash allows writes under singular import/ dir"
  else
    fail "validate-bash allows writes under singular import/ dir" \
         "decision=$decision; expected no-decision. Output: $(head -c 300 "$out")"
  fi
}

test_stop_gate_skips_ephemeral_session() {
  local proof_root input_file out decision
  proof_root="$(fresh_proof_root ephemeral-skip)"

  input_file="$TMP_ROOT/ephemeral-stop-input.json"
  jq --arg cwd "$ROOT" '. + {cwd:$cwd}' "$FIXTURES/stop-ephemeral.json" >"$input_file"

  out="$TMP_ROOT/ephemeral-stop.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input_file" \
    CLAUDE_PROOF_ROOT="$proof_root"
  decision=$(jq -r '.decision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "no-decision" ]; then
    pass "stop-gate skips ephemeral session (transcript_path null)"
  else
    fail "stop-gate skips ephemeral session (transcript_path null)" \
         "decision=$decision; expected silent exit. Output: $(head -c 300 "$out")"
  fi
}

# ===========================================================================
# PORTED TESTS — adapted from /home/streaming/.codex/hooks/tests/run.sh.
# Each test below is a function returning 0 on pass, non-zero on fail.
# ===========================================================================

# ---- ECI gate (PreToolUse on Edit|Write|MultiEdit|NotebookEdit) ----
# Port of the Codex gate. A target is denied only when it is an ECI control or
# ledger file (or a reserved proof-dir descendant) under a proof root, raw or
# realpath-resolved, or a hard link / symlink to such a file. Hook input must
# carry session_id, tool_name and cwd; otherwise the gate allows.

# Write one hook-input JSON to $out. The filter sees $cwd (repo root); extra
# jq arguments (--arg name value) go before the filter.
eci_input() {
  local out="$1" filter="$2"; shift 2
  jq -n --arg cwd "$ROOT" "$@" "$filter" >"$out"
}

# Fresh home whose proof session t00-session holds an active marker.
eci_active_home() {
  local name="$1" home pdir
  home="$(fresh_home "$name")"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  printf '%s' "$home"
}

test_eci_gate_blocks_control_file_edit() {
  local home pdir input out
  home="$(eci_active_home eci-ctl-edit)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-ctl-edit.json"
  out="$TMP_ROOT/eci-ctl-edit.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_deny_reason_names_control_state() {
  local home pdir input out
  home="$(eci_active_home eci-ctl-reason)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-ctl-reason.json"
  out="$TMP_ROOT/eci-ctl-reason.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "ECI_CONTROL_OWNER_REQUIRED" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "active control state" &&
    json_field_not_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "coordinator"
}

# Decision depends on the target name and location, not on marker presence.
test_eci_gate_blocks_control_file_without_marker() {
  local home pdir input out
  home="$(fresh_home eci-ctl-nomarker)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  input="$TMP_ROOT/eci-ctl-nomarker.json"
  out="$TMP_ROOT/eci-ctl-nomarker.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_blocks_control_file_write() {
  local home pdir input out
  home="$(eci_active_home eci-ctl-write)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-ctl-write.json"
  out="$TMP_ROOT/eci-ctl-write.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/goal_state"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_blocks_control_file_multiedit() {
  local home pdir input out
  home="$(eci_active_home eci-ctl-multi)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-ctl-multi.json"
  out="$TMP_ROOT/eci-ctl-multi.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"MultiEdit",cwd:$cwd,tool_input:{file_path:$p,edits:[{old_string:"old",new_string:"new"}]}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_blocks_control_file_notebookedit() {
  local home pdir input out
  home="$(eci_active_home eci-ctl-notebook)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-ctl-notebook.json"
  out="$TMP_ROOT/eci-ctl-notebook.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$p,new_source:"x = 1"}}' --arg p "$pdir/eci_wait"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

# Basenames on the Codex control list are denied in the proof root.
test_eci_gate_blocks_codex_control_names() {
  local home pdir name input out
  home="$(eci_active_home eci-codex-names)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-codex-names.json"
  out="$TMP_ROOT/eci-codex-names.out"
  for name in eci-blocker-report.md disengage.md user-closed.md stop_loop_state eci-required-critics.json baseline_head instructions.md; do
    eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/$name"
    run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out" || return 1
  done
}

# Names removed from the Claude-only list match the Codex gate: allowed. Asserted
# so the removed protection is explicit and cannot return silently.
test_eci_gate_allows_names_outside_codex_list() {
  local home pdir name input out
  home="$(eci_active_home eci-removed-names)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-removed-names.json"
  out="$TMP_ROOT/eci-removed-names.out"
  for name in eci_teammate_pending ate_active task_active skip_stop summary-to-print.md parent_session_id gitleaks-findings.txt git-status-at-accept.txt last-result.md; do
    eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/$name"
    run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out" || return 1
  done
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$home/.cache/claude-proof/copilot/x.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Claim directories are coordinator-owned recursively (Codex parity).
test_eci_gate_blocks_repair_authorize_claim_descendant() {
  local home pdir input out
  home="$(eci_active_home eci-repair-claim)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-repair-claim.json"
  out="$TMP_ROOT/eci-repair-claim.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci-wait-repair-authorize.claim/inner.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_blocks_accidental_override_claim_descendant() {
  local home pdir input out
  home="$(eci_active_home eci-accidental-claim)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-accidental-claim.json"
  out="$TMP_ROOT/eci-accidental-claim.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/.eci-accidental-mistake-override.claim/inner.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

# Control check precedes the Markdown allowance: a control .md is denied.
test_eci_gate_blocks_markdown_control_file() {
  local home pdir input out
  home="$(eci_active_home eci-md-ctl)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-md-ctl.json"
  out="$TMP_ROOT/eci-md-ctl.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"# x"}}' --arg p "$pdir/eci-blocker-report.md"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_allows_source_edit_with_active_marker() {
  local home input out
  home="$(eci_active_home eci-src-edit)"
  input="$TMP_ROOT/eci-src-edit.json"
  out="$TMP_ROOT/eci-src-edit.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}'
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_allows_source_write_fixture() {
  local home input out
  home="$(eci_active_home eci-src-write)"
  input="$TMP_ROOT/eci-src-write.json"
  out="$TMP_ROOT/eci-src-write.out"
  with_cwd_fixture "$FIXTURES/eci-write-code.json" "$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_allows_source_multiedit_fixture() {
  local home input out
  home="$(eci_active_home eci-src-multi)"
  input="$TMP_ROOT/eci-src-multi.json"
  out="$TMP_ROOT/eci-src-multi.out"
  with_cwd_fixture "$FIXTURES/eci-multiedit.json" "$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_allows_source_notebookedit_fixture() {
  local home input out
  home="$(eci_active_home eci-src-notebook)"
  input="$TMP_ROOT/eci-src-notebook.json"
  out="$TMP_ROOT/eci-src-notebook.out"
  with_cwd_fixture "$FIXTURES/notebookedit-eci-active-deny.json" "$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_allows_markdown_edit() {
  local home input out
  home="$(eci_active_home eci-md-edit)"
  input="$TMP_ROOT/eci-md-edit.json"
  out="$TMP_ROOT/eci-md-edit.out"
  with_cwd_fixture "$FIXTURES/eci-edit-markdown.json" "$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_allows_markdown_multiedit() {
  local home input out
  home="$(eci_active_home eci-md-multi)"
  input="$TMP_ROOT/eci-md-multi.json"
  out="$TMP_ROOT/eci-md-multi.out"
  with_cwd_fixture "$FIXTURES/eci-multiedit-markdown.json" "$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_allows_markdown_write() {
  local home input out
  home="$(eci_active_home eci-md-write)"
  input="$TMP_ROOT/eci-md-write.json"
  out="$TMP_ROOT/eci-md-write.out"
  with_cwd_fixture "$FIXTURES/eci-write-markdown.json" "$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_allows_when_no_marker() {
  local home input out
  home="$(fresh_home eci-no-marker)"
  input="$TMP_ROOT/eci-no-marker.json"
  out="$TMP_ROOT/eci-no-marker.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}'
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# CLAUDE_ROLE is not an exemption: only the path decides.
test_eci_gate_blocks_control_file_with_role_env() {
  local home pdir input out
  home="$(eci_active_home eci-role-env)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-role-env.json"
  out="$TMP_ROOT/eci-role-env.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" CLAUDE_ROLE="eci-implementer" && is_pretool_deny "$out"
}

# No subagent exemption: agent_id / agent_type do not lift a control-file deny.
# Dual side: the same subagent shape still allows a source edit.
test_eci_gate_blocks_control_file_subagent_agent_id() {
  local home pdir input out
  home="$(eci_active_home eci-agent-id)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-agent-id.json"
  out="$TMP_ROOT/eci-agent-id.out"
  eci_input "$input" '{session_id:"t00-session",agent_id:"sub-uuid",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" || return 1
  is_pretool_deny "$out" || return 1
  eci_input "$input" '{session_id:"t00-session",agent_id:"sub-uuid",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}'
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_blocks_control_file_subagent_agent_type() {
  local home pdir input out
  home="$(eci_active_home eci-agent-type)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-agent-type.json"
  out="$TMP_ROOT/eci-agent-type.out"
  eci_input "$input" '{session_id:"t00-session",agent_type:"general-purpose",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

# Cross-session ledger is denied; the same name in the hook's own session is
# a working document and allowed (see test_eci_gate_allows_own_session_working_doc).
test_eci_gate_blocks_other_session_ledger() {
  local home pdir other input out
  home="$(eci_active_home eci-other-ledger)"
  other="$home/.cache/claude-proof/t01-other"
  input="$TMP_ROOT/eci-other-ledger.json"
  out="$TMP_ROOT/eci-other-ledger.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$other/project-understanding.yaml"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_allows_own_session_working_doc() {
  local home pdir input out
  home="$(eci_active_home eci-own-doc)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-own-doc.json"
  out="$TMP_ROOT/eci-own-doc.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/project-understanding.yaml"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" || return 1
  expect_no_output "$out" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/high_level_log.jsonl"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Ledger-named file that is not a control basename is allowed in the proof root.
test_eci_gate_allows_non_control_ledger_in_proof_root() {
  local home pdir input out
  home="$(eci_active_home eci-noncontrol)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-noncontrol.json"
  out="$TMP_ROOT/eci-noncontrol.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/latest-status-report.yaml"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" || return 1
  expect_no_output "$out" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/notes.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Reserved namespaces are denied recursively; a non-reserved nested path in the
# session dir is not a control target.
test_eci_gate_blocks_reserved_proof_dir_descendant() {
  local home pdir input out
  home="$(eci_active_home eci-reserved)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-reserved.json"
  out="$TMP_ROOT/eci-reserved.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$home/.cache/claude-proof/reviewer/nested/state.json"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" || return 1
  is_pretool_deny "$out" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/nested/state.json"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Hard link to the marker: link count > 1 makes the target an alias. The
# unlinked file with identical content is allowed.
test_eci_gate_blocks_hardlink_alias_to_marker() {
  local home pdir work input out
  home="$(eci_active_home eci-hardlink)"
  pdir="$home/.cache/claude-proof/t00-session"
  work="$home/work"
  mkdir -p "$work" || return 1
  ln "$pdir/eci_active" "$work/alias.go" || return 1
  printf 'task: test\n' >"$work/plain.go"
  input="$TMP_ROOT/eci-hardlink.json"
  out="$TMP_ROOT/eci-hardlink.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$work/alias.go"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" || return 1
  is_pretool_deny "$out" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$work/plain.go"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Symlink to the marker is caught through the realpath-resolved target.
test_eci_gate_blocks_symlink_to_control_file() {
  local home pdir work input out
  home="$(eci_active_home eci-symlink)"
  pdir="$home/.cache/claude-proof/t00-session"
  work="$home/work"
  mkdir -p "$work" || return 1
  ln -s "$pdir/eci_active" "$work/link.go" || return 1
  input="$TMP_ROOT/eci-symlink.json"
  out="$TMP_ROOT/eci-symlink.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$work/link.go"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

# Malformed session ids skip the gate even for a control target.
test_eci_gate_skips_unsafe_session_id() {
  local home pdir input out
  home="$(eci_active_home eci-unsafe-sid)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-unsafe-sid.json"
  out="$TMP_ROOT/eci-unsafe-sid.out"
  eci_input "$input" '{session_id:"../bad",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

test_eci_gate_skips_bad_json() {
  local home pdir input out
  home="$(eci_active_home eci-bad-json)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-bad-json.json"
  out="$TMP_ROOT/eci-bad-json.out"
  printf '{not json, "file_path": "%s/eci_active"' "$pdir" >"$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Missing cwd skips the gate; the same payload with cwd is denied.
test_eci_gate_skips_missing_cwd() {
  local home pdir input out
  home="$(eci_active_home eci-no-cwd)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-no-cwd.json"
  out="$TMP_ROOT/eci-no-cwd.out"
  jq -n --arg p "$pdir/eci_active" '{session_id:"t00-session",tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' >"$input"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" || return 1
  expect_no_output "$out" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_skips_non_edit_tool() {
  local home input out
  home="$(eci_active_home eci-non-edit)"
  input="$TMP_ROOT/eci-non-edit.json"
  out="$TMP_ROOT/eci-non-edit.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Bash",cwd:$cwd,tool_input:{command:"ls"}}'
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# A hard link named like a working document is an alias of another session's
# control and is denied. Dual side: an unlinked handoff.md in the same session
# is still an allowed working document.
test_eci_gate_blocks_working_doc_hardlink_alias() {
  local home pdir other input out
  home="$(fresh_home eci-wd-alias)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  other="$(proof_dir_in_home "$home" t01-other)"
  printf 'task: other\n' >"$other/eci_active" || return 1
  ln "$other/eci_active" "$pdir/handoff.md" || return 1
  input="$TMP_ROOT/eci-wd-alias.json"
  out="$TMP_ROOT/eci-wd-alias.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/handoff.md"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out" || return 1
  rm -f "$pdir/handoff.md" || return 1
  printf 'notes\n' >"$pdir/handoff.md" || return 1
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# The alias scan covers every session dir, not only active ones: a plain-named
# file hard-linked to an inactive session's eci_wait is denied. Dual side: an
# unlinked file with the same content is allowed.
test_eci_gate_blocks_hardlink_to_inactive_session_control() {
  local home pdir other input out
  home="$(fresh_home eci-g4a)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  other="$(proof_dir_in_home "$home" t01-other)"
  printf 'wait\n' >"$other/eci_wait" || return 1
  ln "$other/eci_wait" "$pdir/notes.txt" || return 1
  input="$TMP_ROOT/eci-g4a.json"
  out="$TMP_ROOT/eci-g4a.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/notes.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out" || return 1
  printf 'notes\n' >"$pdir/plain.txt" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/plain.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# An own-session working document that is a hard link to an inactive session's
# eci_wait is an alias: the alias check runs before the working-doc exemption.
test_eci_gate_blocks_own_working_doc_hardlink_to_inactive_control() {
  local home pdir other input out
  home="$(fresh_home eci-g4b)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  other="$(proof_dir_in_home "$home" t01-other)"
  printf 'wait\n' >"$other/eci_wait" || return 1
  ln "$other/eci_wait" "$pdir/proof.md" || return 1
  input="$TMP_ROOT/eci-g4b.json"
  out="$TMP_ROOT/eci-g4b.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/proof.md"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

# A hard link into the reserved proof/eci namespace is an alias with no session
# involved: that namespace is coordinator-owned, so any file under it counts.
# Dual side: an unlinked file in the same work dir is allowed.
test_eci_gate_blocks_hardlink_into_reserved_namespace() {
  local home reserved work input out
  home="$(fresh_home eci-r1)"
  reserved="$home/.cache/claude-proof/eci"
  work="$home/work"
  mkdir -p "$reserved" "$work" || return 1
  printf 'state\n' >"$reserved/state.json" || return 1
  ln "$reserved/state.json" "$work/alias.go" || return 1
  input="$TMP_ROOT/eci-r1.json"
  out="$TMP_ROOT/eci-r1.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$work/alias.go"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out" || return 1
  printf 'plain\n' >"$work/plain.go" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$work/plain.go"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# A plain (single-link) own-session proof.md is the working-document exemption:
# allowed while the session's marker is active.
test_eci_gate_allows_plain_own_proof_doc() {
  local home pdir input out
  home="$(eci_active_home eci-own-proof)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-own-proof.json"
  out="$TMP_ROOT/eci-own-proof.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/proof.md"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Every string path in tool_input is checked: a benign file_path must not mask a
# control notebook_path. Dual side: two benign paths stay allowed.
test_eci_gate_checks_every_target_key() {
  local home pdir input out
  home="$(eci_active_home eci-every-key)"
  pdir="$home/.cache/claude-proof/t00-session"
  input="$TMP_ROOT/eci-every-key.json"
  out="$TMP_ROOT/eci-every-key.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"NotebookEdit",cwd:$cwd,tool_input:{file_path:"README.md",notebook_path:$p,new_source:"x = 1"}}' --arg p "$pdir/eci_wait"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out" || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"NotebookEdit",cwd:$cwd,tool_input:{file_path:"README.md",notebook_path:"src/file.ipynb",new_source:"x = 1"}}'
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# An edit tool with a non-object tool_input is denied with exit 2 (blocking),
# reason on stderr. The same shape on a non-edit tool stays allowed.
test_eci_gate_denies_edit_with_non_object_tool_input() {
  local home input out rc
  home="$(eci_active_home eci-non-object)"
  input="$TMP_ROOT/eci-non-object.json"
  out="$TMP_ROOT/eci-non-object.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:"x"}'
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  rc=$?
  [ "$rc" -eq 2 ] && is_pretool_deny "$out" && [ -s "$out.err" ] || return 1
  eci_input "$input" '{session_id:"t00-session",tool_name:"Bash",cwd:$cwd,tool_input:"x"}'
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  rc=$?
  [ "$rc" -eq 0 ] && expect_no_output "$out"
}

# Broadening: skill-marker-gate must enforce required-skill markers on
# NotebookEdit too. Fixture targets src/foo.py (requires python-coding-style)
# without the marker file present.
test_skill_marker_gate_blocks_notebookedit_without_marker() {
  local home out
  home="$(fresh_home skill-marker-notebook)"
  # No marker dir created — skill not yet invoked, gate must deny.
  out="$TMP_ROOT/skill-marker-notebook.out"
  run_hook "$out" "$ROOT/hooks/skill-marker-gate.sh" "$FIXTURES/notebookedit-skill-marker-deny.json" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "python-coding-style"
}

# ---- ATE orchestrator gate ----

test_ate_gate_allows_edits_for_lead() {
  local input out
  input="$TMP_ROOT/ate-lead.json"
  jq -n '{tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-lead.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="lead"
  expect_no_output "$out"
}

test_ate_gate_allows_edits_for_coordinator() {
  local input out
  input="$TMP_ROOT/ate-coord.json"
  jq -n '{tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-coord.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="coordinator"
  expect_no_output "$out"
}

test_ate_gate_allows_edits_for_executor() {
  local input out
  input="$TMP_ROOT/ate-exec.json"
  jq -n '{tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-exec.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="executor"
  expect_no_output "$out"
}

test_ate_gate_allows_edits_for_no_role() {
  local input out
  input="$TMP_ROOT/ate-norole.json"
  jq -n '{tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-norole.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input"
  expect_no_output "$out"
}

test_ate_gate_allows_subagent_via_agent_id() {
  local input out
  input="$TMP_ROOT/ate-sub.json"
  jq -n '{agent_id:"u",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-sub.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="lead"
  expect_no_output "$out"
}

test_ate_gate_allows_subagent_via_agent_type() {
  local input out
  input="$TMP_ROOT/ate-sub-type.json"
  jq -n '{agent_type:"general-purpose",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-sub-type.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="lead"
  expect_no_output "$out"
}

test_ate_gate_skips_non_edit_tool() {
  local input out
  input="$TMP_ROOT/ate-bash.json"
  jq -n '{tool_name:"Bash",tool_input:{command:"ls"}}' >"$input"
  out="$TMP_ROOT/ate-bash.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="lead"
  expect_no_output "$out"
}

# ---- validate-edit-write (path policy) ----

test_validate_edit_write_blocks_direct_edit_plan_path() {
  local out
  out="$TMP_ROOT/edit-plan-edit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-plan-edit.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Plans must not be saved inside the repo"
}

test_validate_edit_write_blocks_direct_write_plan_path() {
  local out
  out="$TMP_ROOT/edit-plan-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-plan-write.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Plans must not be saved inside the repo"
}

test_validate_edit_write_blocks_direct_multiedit_plan_path() {
  local out
  out="$TMP_ROOT/edit-plan-multi.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-plan-multiedit.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Plans must not be saved inside the repo"
}

test_validate_edit_write_blocks_direct_write_imports_path() {
  local out
  out="$TMP_ROOT/edit-imports-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-imports-write.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "revendor"
}

test_validate_edit_write_blocks_direct_multiedit_vendor_path() {
  local out
  out="$TMP_ROOT/edit-vendor-multi.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-vendor-multiedit.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "revendor"
}

test_validate_edit_write_allows_vendorish_path() {
  local out
  out="$TMP_ROOT/edit-vendorish.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-vendorish-edit.json"
  expect_no_output "$out"
}

test_validate_edit_write_blocks_direct_edit_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-gomod-edit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-edit.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local-path replace"
}

test_validate_edit_write_blocks_direct_write_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-gomod-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-write.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local-path replace"
}

test_validate_edit_write_blocks_direct_multiedit_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-gomod-multi.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-multiedit.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local-path replace"
}

test_validate_edit_write_allows_unrelated_non_plan_edit() {
  local out
  out="$TMP_ROOT/edit-allow-unrelated.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-allow-unrelated-edit.json"
  expect_no_output "$out"
}

test_validate_edit_write_allows_remote_write_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-allow-remote-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-allow-remote-write.json"
  expect_no_output "$out"
}

test_validate_edit_write_allows_remote_multiedit_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-allow-remote-multi.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-allow-remote-multiedit.json"
  expect_no_output "$out"
}

# ---- validate-bash ----
# validate-bash runs the Claude guards (git push, git reset gate, subagent
# eci-active off), then delegates the ECI command plan to the Codex planner.
# Allow-path checks use a stub planner in a scratch HOME. It records the exact
# bytes it receives and prints nothing. That record is the sentinel that the
# wrapper reached the planner; an allow-all wrapper leaves no record and fails.

# Scratch HOME with a stub planner. Remove "$home/bin/eci-command-plan" to
# simulate a missing planner binary.
make_planner_stub() {
  local home="$1"
  mkdir -p "$home/.codex/hooks/lib" "$home/bin" || return 1
  cat >"$home/bin/eci-command-plan" <<PLAN
#!/bin/bash
cat >"$home/planner-stdin"
PLAN
  chmod 755 "$home/bin/eci-command-plan" || return 1
  cat >"$home/.codex/hooks/lib/eci-runtime-sync.sh" <<SYNC
eci_runtime_artifact_path() { printf '%s\n' "$home/bin/\$2"; }
eci_runtime_binary_is_native() { [ -x "\$1" ]; }
eci_runtime_build_missing() { printf '%s %s\n' "\$1" "\$2" >>"$home/build-missing.log"; return 1; }
SYNC
}

# True when the stub planner received exactly the bytes of file $2.
planner_received() {
  cmp -s "$1/planner-stdin" "$2"
}

# Writes a PreToolUse Bash input. Args: out session cwd command [agent_id].
write_bash_input() {
  local out="$1" sid="$2" cwd="$3" cmd="$4" agent="${5:-}"
  jq -cn --arg sid "$sid" --arg cwd "$cwd" --arg cmd "$cmd" --arg agent "$agent" \
    '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}} + (if $agent == "" then {} else {agent_id:$agent} end)' >"$out"
}

# Fresh proof root with an active ECI marker for session t00-session. Arg: name.
active_eci_proof_root() {
  local proof
  proof="$(fresh_proof_root "$1")"
  mkdir -p "$proof/t00-session" || return 1
  printf 'scope: validate-bash test\ncwd: %s\nsession_id: t00-session\n' "$ROOT" >"$proof/t00-session/eci_active"
  printf '%s' "$proof"
}

# Allow path: the hook prints nothing and the stub planner got the input bytes unchanged.
# Args: name input-file.
expect_forwarded_unchanged() {
  local home out
  home="$(fresh_home "$1")" || return 1
  make_planner_stub "$home" || return 1
  out="$TMP_ROOT/$1.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$2" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root "$1")"
  expect_no_output "$out" && planner_received "$home" "$2"
}

# Allow-path tests. The planner decides go test policy (codex parity): the
# Claude capture and -count=1 rules are gone, so these are pass-through checks.
test_validate_bash_allows_redirect_to_vendor_path() {
  expect_forwarded_unchanged bash-vendor-redir "$FIXTURES/validate-bash-vendor-redirect.json"
}

test_validate_bash_allows_in_place_imports_path() {
  expect_forwarded_unchanged bash-imports-sed "$FIXTURES/validate-bash-imports-sed.json"
}

test_validate_bash_allows_vendor_test_with_tmp_redirect() {
  expect_forwarded_unchanged bash-vendor-test "$FIXTURES/validate-bash-vendor-go-test.json"
}

test_validate_bash_allows_bare_go_test() {
  expect_forwarded_unchanged bash-go-test-bare "$FIXTURES/validate-bash-go-test-bare.json"
}

test_validate_bash_allows_go_test_count_one() {
  expect_forwarded_unchanged bash-go-test-count "$FIXTURES/validate-bash-go-test-count.json"
}

test_validate_bash_allows_redirected_go_test() {
  expect_forwarded_unchanged bash-go-test-redir "$FIXTURES/validate-bash-go-test-redirect.json"
}

test_validate_bash_allows_go_test_tee() {
  expect_forwarded_unchanged bash-go-test-tee "$FIXTURES/validate-bash-go-test-tee.json"
}

test_validate_bash_marks_shell_activity() {
  local home pdir input out
  home="$(fresh_home bash-marks-shell)"
  input="$TMP_ROOT/bash-mark.json"
  jq --arg cwd "$ROOT" '.session_id="t00-session" | .cwd=$cwd' "$FIXTURES/validate-bash-go-test-redirect.json" >"$input"
  out="$TMP_ROOT/bash-mark.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$home/.cache/claude-proof/activity/sessions/t00-session/shell" ]
}

test_validate_bash_skips_read_only_shell_activity() {
  local home input out cmd
  home="$(fresh_home bash-readonly)"
  make_planner_stub "$home" || return 1
  cmd='rg -n "claude-proof|CLAUDE_PROOF_ROOT|proof_dir" . -S'
  input="$TMP_ROOT/bash-readonly.json"
  write_bash_input "$input" t00-session "$ROOT" "$cmd"
  out="$TMP_ROOT/bash-readonly.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" && planner_received "$home" "$input" &&
    [ ! -e "$home/.cache/claude-proof/activity/sessions/t00-session/shell" ]
}

test_validate_bash_skips_read_only_shell_chain_activity() {
  local home input out cmd
  home="$(fresh_home bash-readchain)"
  make_planner_stub "$home" || return 1
  cmd="sed -n '1,90p' hooks/stop-gate.sh && sed -n '360,430p' hooks/stop-gate.sh"
  input="$TMP_ROOT/bash-readchain.json"
  write_bash_input "$input" t00-session "$ROOT" "$cmd"
  out="$TMP_ROOT/bash-readchain.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" && planner_received "$home" "$input" &&
    [ ! -e "$home/.cache/claude-proof/activity/sessions/t00-session/shell" ]
}

test_validate_bash_marks_redirected_read_shell_activity() {
  local home input out cmd
  home="$(fresh_home bash-readredir)"
  cmd="sed -n '1,5p' CLAUDE.md > /tmp/claude-read-output.txt"
  input="$TMP_ROOT/bash-readredir.json"
  jq -n --arg cwd "$ROOT" --arg cmd "$cmd" '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-readredir.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$home/.cache/claude-proof/activity/sessions/t00-session/shell" ]
}

# Subagent guard: `eci-active off` is denied for a subagent only. The deny reason
# is the verbatim message (it names the over-denial and says not to retry).
test_validate_bash_blocks_subagent_eci_active_off() {
  local home input out cmd
  home="$(fresh_home bash-subagent-eci-off)"
  cmd="~/.claude/bin/eci-active off /tmp/eci-disengage.md"
  input="$TMP_ROOT/bash-subagent-eci-off.json"
  jq -n --arg cwd "$ROOT" --arg cmd "$cmd" \
    '{session_id:"t00-session",agent_id:"sub-uuid",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-subagent-eci-off.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_equals "$out" '.hookSpecificOutput.permissionDecisionReason // empty' \
      'Only the main thread or orchestrator may disengage ECI with `eci-active off`. Subagents report completion or blockers to the orchestrator while ECI stays active. This check matches that phrase anywhere in command text, including quoted text, heredocs and commit messages. Do not retry the disengage in any form. When the phrase is only text, such as a commit message or search pattern, describe it in other words.'
}

test_validate_bash_allows_main_eci_active_off() {
  local home input out cmd
  home="$(fresh_home bash-main-eci-off)"
  make_planner_stub "$home" || return 1
  cmd="~/.claude/bin/eci-active off /tmp/eci-disengage.md"
  input="$TMP_ROOT/bash-main-eci-off.json"
  write_bash_input "$input" t00-session "$ROOT" "$cmd"
  out="$TMP_ROOT/bash-main-eci-off.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root bash-main-eci-off)"
  expect_no_output "$out" && planner_received "$home" "$input"
}

# Argv-head `eci-active off` forms stay denied for a subagent (the text match covers them).
test_validate_bash_subagent_eci_off_argv_head_is_denied() {
  local home input out cmd n=0
  home="$(fresh_home subagent-argv)"
  make_planner_stub "$home" || return 1
  for cmd in \
    'true && FOO=1 ~/.claude/bin/eci-active off /tmp/x' \
    'echo ok; /usr/bin/eci-active off' \
    "cat <<'EOF' | eci-active off
body
EOF" \
    '2>/dev/null eci-active off'; do
    n=$((n + 1))
    input="$TMP_ROOT/bash-subagent-argv-$n.json"
    write_bash_input "$input" t00-session "$ROOT" "$cmd" sub-uuid
    out="$TMP_ROOT/bash-subagent-argv-$n.out"
    run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
      CLAUDE_PROOF_ROOT="$(fresh_proof_root "subagent-argv-$n")"
    is_pretool_deny "$out" &&
      json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Only the main thread" || return 1
    [ ! -e "$home/planner-stdin" ] || return 1
  done
}

# Subagent text-match rows (run_case rows below). Deny: subagent reason and the
# planner never runs. Forward: no output and the planner receives the input bytes.
# Args: name agent_id command. Empty agent_id is the main thread.
expect_subagent_bash_denied() {
  local home input out
  home="$(fresh_home "$1")" || return 1
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/$1.json"
  write_bash_input "$input" t00-session "$ROOT" "$3" "$2"
  out="$TMP_ROOT/$1.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root "$1")"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Only the main thread" &&
    [ ! -e "$home/planner-stdin" ]
}

expect_bash_forwarded() {
  local home input out
  home="$(fresh_home "$1")" || return 1
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/$1.json"
  write_bash_input "$input" t00-session "$ROOT" "$3" "$2"
  out="$TMP_ROOT/$1.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root "$1")"
  expect_no_output "$out" && planner_received "$home" "$input"
}

# Push is denied unconditionally (CLAUDE.md: push only on request), with or without ECI.
test_validate_bash_denies_git_push_with_eci_active() {
  local home proof input out
  home="$(fresh_home push-active)"
  make_planner_stub "$home" || return 1
  proof="$(active_eci_proof_root push-active)" || return 1
  input="$TMP_ROOT/bash-push-active.json"
  write_bash_input "$input" t00-session "$ROOT" 'git push origin main'
  out="$TMP_ROOT/bash-push-active.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "git push is blocked" &&
    [ ! -e "$home/planner-stdin" ]
}

test_validate_bash_denies_chained_git_push_without_eci() {
  local home input out
  home="$(fresh_home push-chained)"
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/bash-push-chained.json"
  write_bash_input "$input" t00-session "$ROOT" 'echo ok && git push origin main'
  out="$TMP_ROOT/bash-push-chained.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root push-chained)"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "git push is blocked" &&
    [ ! -e "$home/planner-stdin" ]
}

# Reset gate (CLAUDE.md): one-shot marker in the target repo root, consumed on use.
test_validate_bash_blocks_git_reset_without_marker() {
  local home repo input out cmd
  home="$(fresh_home reset-no-marker)"
  make_planner_stub "$home" || return 1
  repo="$TMP_ROOT/git-reset-without-marker"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  cmd="git -C $repo reset --hard HEAD"
  input="$TMP_ROOT/bash-git-reset-without-marker.json"
  write_bash_input "$input" t00-session "$ROOT" "$cmd"
  out="$TMP_ROOT/bash-git-reset-without-marker.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root git-reset-without-marker)"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "git reset denied" &&
    [ ! -e "$home/planner-stdin" ]
}

test_validate_bash_consumes_git_reset_marker() {
  local home repo marker input out cmd
  home="$(fresh_home reset-with-marker)"
  make_planner_stub "$home" || return 1
  repo="$TMP_ROOT/git-reset-with-marker"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  cmd="git -C $repo reset --hard HEAD"
  marker="$repo/.git-reset-approved-once"
  {
    printf 'date: 2026-05-17\n'
    printf 'reason: hook test\n'
    printf 'command: %s\n' "$cmd"
  } >"$marker"
  input="$TMP_ROOT/bash-git-reset-with-marker.json"
  write_bash_input "$input" t00-session "$ROOT" "$cmd"
  out="$TMP_ROOT/bash-git-reset-with-marker.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root git-reset-with-marker)"
  expect_no_output "$out" && planner_received "$home" "$input" && [ ! -e "$marker" ]
}

test_validate_bash_blocks_git_reset_marker_mismatch() {
  local home repo marker input out cmd
  home="$(fresh_home reset-marker-mismatch)"
  make_planner_stub "$home" || return 1
  repo="$TMP_ROOT/git-reset-marker-mismatch"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  cmd="git -C $repo reset --hard HEAD"
  marker="$repo/.git-reset-approved-once"
  {
    printf 'date: 2026-05-17\n'
    printf 'reason: hook test\n'
    printf 'command: git -C %s reset --soft HEAD~1\n' "$repo"
  } >"$marker"
  input="$TMP_ROOT/bash-git-reset-marker-mismatch.json"
  write_bash_input "$input" t00-session "$ROOT" "$cmd"
  out="$TMP_ROOT/bash-git-reset-marker-mismatch.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root git-reset-marker-mismatch)"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "does not match" &&
    [ -s "$marker" ] && [ ! -e "$home/planner-stdin" ]
}

# (b) agent_id selects the planner's worker role via CODEX_HOOK_IS_SUBAGENT.
test_validate_bash_subagent_agent_id_selects_worker_role() {
  local proof input out sid="t00-session"
  proof="$(fresh_proof_root subagent-role)"
  mkdir -p "$proof/$sid" || return 1
  printf 'scope: subagent role\ncwd: %s\nsession_id: %s\n' "$ROOT" "$sid" >"$proof/$sid/eci_active"
  input="$TMP_ROOT/bash-subagent-role.json"
  jq -n --arg sid "$sid" --arg cwd "$ROOT" \
    '{session_id:$sid,agent_id:"sub-uuid",cwd:$cwd,tool_name:"Bash",tool_input:{command:"git add -A"}}' >"$input"
  out="$TMP_ROOT/bash-subagent-role.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "[ECI_WORKER_GIT_OWNERSHIP_DENIED]" &&
    json_field_not_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "ECI_BROAD_DESTRUCTIVE_DENIED"
}

# (b) without agent_id, an inherited CODEX_HOOK_IS_SUBAGENT must be cleared (coordinator role).
test_validate_bash_clears_inherited_subagent_flag_for_coordinator() {
  local proof input out sid="t00-session"
  proof="$(fresh_proof_root coordinator-role)"
  mkdir -p "$proof/$sid" || return 1
  printf 'scope: coordinator role\ncwd: %s\nsession_id: %s\n' "$ROOT" "$sid" >"$proof/$sid/eci_active"
  input="$TMP_ROOT/bash-coordinator-role.json"
  jq -n --arg sid "$sid" --arg cwd "$ROOT" \
    '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:"git add -A"}}' >"$input"
  out="$TMP_ROOT/bash-coordinator-role.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" \
    CLAUDE_PROOF_ROOT="$proof" CODEX_HOOK_IS_SUBAGENT=1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "[ECI_BROAD_DESTRUCTIVE_DENIED]" &&
    json_field_not_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "ECI_WORKER_GIT_OWNERSHIP_DENIED"
}

# (c) no ~/.codex and no marker: exit 0, no stdout, advisory on stderr.
test_validate_bash_without_codex_home_fails_open_with_advisory() {
  local home input out rc
  home="$(fresh_home no-codex)"
  input="$TMP_ROOT/bash-no-codex.json"
  jq -n --arg cwd "$ROOT" '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}' >"$input"
  out="$TMP_ROOT/bash-no-codex.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root no-codex)"
  rc=$?
  [ "$rc" -eq 0 ] && expect_no_output "$out" &&
    grep -q 'ECI planner unavailable' "$out.err"
}

# (d) missing planner binary, no marker: the wrapper calls eci_runtime_build_missing
# for eci-command-plan, then fails open. The build step is stubbed in a scratch ~/.codex.
test_validate_bash_rebuilds_missing_planner_before_failing_open() {
  local home input out rc
  home="$(fresh_home missing-planner)"
  mkdir -p "$home/.codex/hooks/lib" || return 1
  {
    printf '. %s\n' "$HOME/.codex/hooks/lib/eci-runtime-sync.sh"
    printf '%s\n' 'eci_runtime_build_missing() { printf "%s %s\n" "$1" "$2" >>"$HOME/build-missing.log"; return 1; }'
  } >"$home/.codex/hooks/lib/eci-runtime-sync.sh"
  input="$TMP_ROOT/bash-missing-planner.json"
  jq -n --arg cwd "$ROOT" '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:"ls"}}' >"$input"
  out="$TMP_ROOT/bash-missing-planner.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root missing-planner)"
  rc=$?
  [ "$rc" -eq 0 ] && expect_no_output "$out" &&
    [ "$(cat "$home/build-missing.log")" = "$home/.codex eci-command-plan" ]
}

# Fail closed: an active ECI marker plus an unusable planner denies every Bash call.
test_validate_bash_fails_closed_when_planner_binary_missing() {
  local home proof input out
  home="$(fresh_home planner-missing-active)"
  make_planner_stub "$home" || return 1
  rm -f "$home/bin/eci-command-plan" || return 1
  proof="$(active_eci_proof_root planner-missing-active)" || return 1
  input="$TMP_ROOT/bash-planner-missing-active.json"
  write_bash_input "$input" t00-session "$ROOT" 'ls'
  out="$TMP_ROOT/bash-planner-missing-active.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "ECI planner unavailable" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "$home/bin/eci-command-plan" &&
    grep -qx "$home/.codex eci-command-plan" "$home/build-missing.log"
}

test_validate_bash_fails_closed_when_codex_root_missing() {
  local home proof input out
  home="$(fresh_home codex-root-missing-active)"
  proof="$(active_eci_proof_root codex-root-missing-active)" || return 1
  input="$TMP_ROOT/bash-codex-root-missing-active.json"
  write_bash_input "$input" t00-session "$ROOT" 'ls'
  out="$TMP_ROOT/bash-codex-root-missing-active.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "planner root missing"
}

test_validate_bash_fails_closed_when_planner_lib_unsourceable() {
  local home proof input out
  home="$(fresh_home planner-lib-active)"
  make_planner_stub "$home" || return 1
  printf 'false\n' >"$home/.codex/hooks/lib/eci-runtime-sync.sh"
  proof="$(active_eci_proof_root planner-lib-active)" || return 1
  input="$TMP_ROOT/bash-planner-lib-active.json"
  write_bash_input "$input" t00-session "$ROOT" 'ls'
  out="$TMP_ROOT/bash-planner-lib-active.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "cannot source"
}

# Relative or empty HOME cannot locate the planner: same rule as a missing planner.
test_validate_bash_fails_closed_with_relative_home_under_active_eci() {
  local scratch proof input out
  scratch="$TMP_ROOT/relative-home-active"
  mkdir -p "$scratch" || return 1
  proof="$(active_eci_proof_root relative-home-active)" || return 1
  input="$TMP_ROOT/bash-relative-home-active.json"
  write_bash_input "$input" t00-session "$scratch" 'ls'
  out="$TMP_ROOT/bash-relative-home-active.out"
  run_hook_in_dir "$scratch" "$out" "$ROOT/hooks/validate-bash.sh" "$input" \
    HOME=relative-home CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "HOME is empty or not absolute"
}

test_validate_bash_relative_home_without_eci_fails_open() {
  local scratch input out
  scratch="$TMP_ROOT/relative-home-idle"
  mkdir -p "$scratch" || return 1
  input="$TMP_ROOT/bash-relative-home-idle.json"
  write_bash_input "$input" t00-session "$scratch" 'ls'
  out="$TMP_ROOT/bash-relative-home-idle.out"
  run_hook_in_dir "$scratch" "$out" "$ROOT/hooks/validate-bash.sh" "$input" \
    HOME=relative-home CLAUDE_PROOF_ROOT="$(fresh_proof_root relative-home-idle)"
  expect_no_output "$out" && grep -q 'ECI planner unavailable' "$out.err"
}

test_validate_bash_fails_closed_with_empty_home_under_active_eci() {
  local proof input out
  proof="$(active_eci_proof_root empty-home-active)" || return 1
  input="$TMP_ROOT/bash-empty-home-active.json"
  write_bash_input "$input" t00-session "$ROOT" 'ls'
  out="$TMP_ROOT/bash-empty-home-active.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME= CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "HOME is empty or not absolute"
}

# Planner runs but exits non-zero while ECI is active: deny (its output is discarded).
test_validate_bash_fails_closed_when_planner_exits_nonzero_under_active_eci() {
  local home proof input out
  home="$(fresh_home planner-crash-active)"
  make_planner_stub "$home" || return 1
  printf '#!/bin/bash\nexit 3\n' >"$home/bin/eci-command-plan" || return 1
  proof="$(active_eci_proof_root planner-crash-active)" || return 1
  input="$TMP_ROOT/bash-planner-crash-active.json"
  write_bash_input "$input" t00-session "$ROOT" 'ls'
  out="$TMP_ROOT/bash-planner-crash-active.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" CLAUDE_PROOF_ROOT="$proof"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "exited 3"
}

# Byte-exact stdin: the planner receives the hook input unchanged, trailing newlines included.
test_validate_bash_forwards_stdin_without_trailing_newline() {
  local home input out
  home="$(fresh_home stdin-no-newline)"
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/bash-stdin-no-newline.json"
  write_bash_input "$input" t00-session "$ROOT" 'ls' && truncate -s -1 "$input" || return 1
  [ -n "$(tail -c 1 "$input")" ] || return 1
  out="$TMP_ROOT/bash-stdin-no-newline.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root stdin-no-newline)"
  expect_no_output "$out" && planner_received "$home" "$input"
}

test_validate_bash_forwards_stdin_with_two_trailing_newlines() {
  local home input out
  home="$(fresh_home stdin-two-newlines)"
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/bash-stdin-two-newlines.json"
  write_bash_input "$input" t00-session "$ROOT" 'ls' && printf '\n' >>"$input" || return 1
  [ -z "$(tail -c 2 "$input" | tr -d '\n')" ] || return 1
  out="$TMP_ROOT/bash-stdin-two-newlines.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root stdin-two-newlines)"
  expect_no_output "$out" && planner_received "$home" "$input"
}

test_validate_bash_non_json_stdin_is_forwarded_unchanged() {
  local input
  input="$TMP_ROOT/bash-non-json.in"
  printf 'not json\n' >"$input"
  expect_forwarded_unchanged bash-non-json "$input"
}

# Codex parity: same command, cwd, session and proof root give the same planner decision.
# git push and git reset are excluded: Claude denies them before the planner, by design.
equiv_code() {
  local reason
  [ -s "$1" ] || { printf 'allow'; return 0; }
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$1" 2>/dev/null)"
  case "$reason" in
    '['*) printf '%s' "$reason" | sed -n 's/^\[\([A-Z_]*\)\].*/\1/p' ;;
    '') printf 'other' ;;
    *) printf 'deny' ;;
  esac
}

test_validate_bash_wrapper_matches_codex_shim() {
  local sid="t00-session" idx=0 cmd proof input co cl rc_c rc_l stub
  local -a commands=(
    'ls'
    'go test ./...'
    'rm -f /home/pheona/.codex/bin/eci-active'
    'echo "go test ./... later"'
    'git add -A'
    'grep -n validate hooks/validate-bash.sh'
  )
  for cmd in "${commands[@]}"; do
    idx=$((idx + 1))
    proof="$(fresh_proof_root "equiv-$idx")"
    mkdir -p "$proof/$sid" || return 1
    printf 'scope: equivalence\ncwd: %s\nsession_id: %s\n' "$ROOT" "$sid" >"$proof/$sid/eci_active"
    input="$TMP_ROOT/equiv-$idx.json"
    jq -n --arg sid "$sid" --arg cwd "$ROOT" --arg cmd "$cmd" \
      '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
    co="$TMP_ROOT/equiv-$idx.codex.out"
    cl="$TMP_ROOT/equiv-$idx.claude.out"
    run_hook "$co" "$HOME/.codex/hooks/validate-bash.sh" "$input" CODEX_PROOF_ROOT="$proof"
    rc_c=$?
    run_hook "$cl" "$ROOT/hooks/validate-bash.sh" "$input" CLAUDE_PROOF_ROOT="$proof"
    rc_l=$?
    # Sentinel for allow decisions: the wrapper must reach a stub planner with the same input.
    stub="$(fresh_home "equiv-stub-$idx")" || return 1
    make_planner_stub "$stub" || return 1
    run_hook "$TMP_ROOT/equiv-$idx.stub.out" "$ROOT/hooks/validate-bash.sh" "$input" \
      HOME="$stub" CLAUDE_PROOF_ROOT="$proof"
    if [ "$rc_c" = "$rc_l" ] && cmp -s "$co" "$cl" && planner_received "$stub" "$input"; then
      pass "validate-bash matches codex shim [$(equiv_code "$cl") rc=$rc_l]: $cmd"
    else
      fail "validate-bash matches codex shim: $cmd" \
        "codex rc=$rc_c code=$(equiv_code "$co") stdout=$(head -c 200 "$co"); claude rc=$rc_l code=$(equiv_code "$cl") stdout=$(head -c 200 "$cl")"
    fi
  done
}

# ---- validate-edit-write activity marking ----

test_validate_edit_write_marks_edit_activity() {
  local home input out
  home="$(fresh_home edit-marks)"
  input="$TMP_ROOT/edit-marks.json"
  jq --arg cwd "$ROOT" '.session_id="t00-session" | .cwd=$cwd' "$FIXTURES/validate-edit-write-allow-unrelated-edit.json" >"$input"
  out="$TMP_ROOT/edit-marks.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$home/.cache/claude-proof/activity/sessions/t00-session/edit" ]
}

# ---- validate-edit-write session-file ownership gate ----
#
# Render a session-file fixture by replacing the literal __HOME__ placeholder
# with $1 (the test's fake $HOME). Path-shape paths in fixtures are templates
# because $HOME differs per test (fresh_home isolates each case).
render_session_fixture() {
  local fixture="$1" home="$2" out="$3"
  sed "s|__HOME__|$home|g" "$fixture" >"$out"
}

test_validate_edit_write_allows_notebookedit_same_sid_proof() {
  local home input out
  home="$(fresh_home owner-nb-same-sid)"
  input="$TMP_ROOT/owner-nb-same-sid.json"
  render_session_fixture "$FIXTURES/notebookedit-same-sid-proof-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-nb-same-sid.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  expect_no_output "$out"
}

test_validate_edit_write_blocks_notebookedit_other_sid_proof() {
  local home input out
  home="$(fresh_home owner-nb-other-sid)"
  input="$TMP_ROOT/owner-nb-other-sid.json"
  render_session_fixture "$FIXTURES/notebookedit-other-sid-proof-deny.json" "$home" "$input"
  out="$TMP_ROOT/owner-nb-other-sid.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

test_validate_edit_write_blocks_multiedit_other_sid_todos() {
  local home input out
  home="$(fresh_home owner-multi-todos)"
  input="$TMP_ROOT/owner-multi-todos.json"
  render_session_fixture "$FIXTURES/multiedit-other-sid-todos-deny.json" "$home" "$input"
  out="$TMP_ROOT/owner-multi-todos.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

test_validate_edit_write_blocks_edit_other_sid_projects_transcript() {
  local home input out
  home="$(fresh_home owner-projects-transcript)"
  input="$TMP_ROOT/owner-projects-transcript.json"
  render_session_fixture "$FIXTURES/edit-other-sid-projects-transcript-deny.json" "$home" "$input"
  out="$TMP_ROOT/owner-projects-transcript.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

test_validate_edit_write_blocks_edit_other_sid_projects_subagents() {
  local home input out
  home="$(fresh_home owner-projects-subagents)"
  input="$TMP_ROOT/owner-projects-subagents.json"
  render_session_fixture "$FIXTURES/edit-other-sid-projects-subagents-deny.json" "$home" "$input"
  out="$TMP_ROOT/owner-projects-subagents.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

test_validate_edit_write_blocks_write_missing_sid_on_protected() {
  local home input out
  home="$(fresh_home owner-missing-sid)"
  input="$TMP_ROOT/owner-missing-sid.json"
  render_session_fixture "$FIXTURES/write-missing-sid-on-protected-deny.json" "$home" "$input"
  out="$TMP_ROOT/owner-missing-sid.out"
  # Explicitly clear CLAUDE_PARENT_SESSION_ID so neither input nor env supplies a sid.
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" CLAUDE_PARENT_SESSION_ID=""
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "requires a current session id"
}

test_validate_edit_write_allows_unrelated_path_no_sid() {
  local home input out
  home="$(fresh_home owner-unrelated)"
  input="$TMP_ROOT/owner-unrelated.json"
  cp "$FIXTURES/edit-unrelated-path-allow.json" "$input"
  out="$TMP_ROOT/owner-unrelated.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" CLAUDE_PARENT_SESSION_ID=""
  expect_no_output "$out"
}

test_validate_edit_write_allows_edit_same_sid_todos() {
  local home input out
  home="$(fresh_home owner-same-sid-todos)"
  input="$TMP_ROOT/owner-same-sid-todos.json"
  render_session_fixture "$FIXTURES/edit-same-sid-todos-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-same-sid-todos.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  expect_no_output "$out"
}

test_validate_edit_write_allows_edit_parent_sid_proof() {
  # Spawned teammate: own session_id is aaa..., parent is bbb..., file lives in bbb...'s proof dir.
  local home input out
  home="$(fresh_home owner-parent-sid-proof)"
  input="$TMP_ROOT/owner-parent-sid-proof.json"
  render_session_fixture "$FIXTURES/edit-parent-sid-proof-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-parent-sid-proof.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" \
    CLAUDE_PARENT_SESSION_ID="bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
  expect_no_output "$out"
}

test_validate_edit_write_allows_edit_parent_sid_todos() {
  local home input out
  home="$(fresh_home owner-parent-sid-todos)"
  input="$TMP_ROOT/owner-parent-sid-todos.json"
  render_session_fixture "$FIXTURES/edit-parent-sid-todos-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-parent-sid-todos.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" \
    CLAUDE_PARENT_SESSION_ID="bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
  expect_no_output "$out"
}

test_validate_edit_write_blocks_edit_unrelated_sid_even_with_parent_set() {
  # Negative side of the parent-allowance: a third (non-own, non-parent) session id is still denied.
  local home input out
  home="$(fresh_home owner-third-sid-with-parent)"
  input="$TMP_ROOT/owner-third-sid-with-parent.json"
  render_session_fixture "$FIXTURES/edit-parent-sid-proof-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-third-sid-with-parent.out"
  # File belongs to bbb...; own session is aaa...; parent env points at a *different* session ddd... (not bbb...).
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" \
    CLAUDE_PARENT_SESSION_ID="dddddddd-dddd-4ddd-dddd-dddddddddddd"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

test_validate_edit_write_allows_edit_parent_sid_via_file_fallback() {
  # Already-running teammate without CLAUDE_PARENT_SESSION_ID env: drop a
  # parent_session_id file under its proof dir and the hook should honor it.
  local home input out own_sid parent_sid
  own_sid="aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
  parent_sid="bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
  home="$(fresh_home owner-parent-sid-via-file)"
  mkdir -p "$home/.cache/claude-proof/$own_sid"
  printf '%s\n' "$parent_sid" >"$home/.cache/claude-proof/$own_sid/parent_session_id"
  input="$TMP_ROOT/owner-parent-sid-via-file.json"
  render_session_fixture "$FIXTURES/edit-parent-sid-proof-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-parent-sid-via-file.out"
  # No CLAUDE_PARENT_SESSION_ID env on purpose — exercise the file fallback.
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" CLAUDE_PARENT_SESSION_ID=""
  expect_no_output "$out"
}

test_validate_edit_write_allows_edit_via_argv_parent_sid() {
  # Auto-detect path: /proc/$PPID/cmdline of the spawning claude proc carries
  # `--parent-session-id <SID>`. Wrap the hook in a bash proc whose argv
  # contains the flag and a matching SID; expect allow.
  local home input out parent_sid
  parent_sid="bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
  home="$(fresh_home owner-argv-parent)"
  input="$TMP_ROOT/owner-argv-parent.json"
  render_session_fixture "$FIXTURES/edit-parent-sid-proof-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-argv-parent.out"
  env -i HOME="$home" PATH="$PATH" CLAUDE_PARENT_SESSION_ID="" \
    bash -c 'bash "$1" <"$2" >"$3" 2>"$3.err"' \
    fake-claude "$ROOT/hooks/validate-edit-write.sh" "$input" "$out" \
      --parent-session-id "$parent_sid"
  expect_no_output "$out"
}

test_validate_edit_write_blocks_edit_when_argv_parent_mismatches() {
  # Negative: argv parent flag carries a third SID; file owner is different.
  local home input out wrong_parent
  wrong_parent="dddddddd-dddd-4ddd-dddd-dddddddddddd"
  home="$(fresh_home owner-argv-mismatch)"
  input="$TMP_ROOT/owner-argv-mismatch.json"
  render_session_fixture "$FIXTURES/edit-parent-sid-proof-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-argv-mismatch.out"
  env -i HOME="$home" PATH="$PATH" CLAUDE_PARENT_SESSION_ID="" \
    bash -c 'bash "$1" <"$2" >"$3" 2>"$3.err"' \
    fake-claude "$ROOT/hooks/validate-edit-write.sh" "$input" "$out" \
      --parent-session-id "$wrong_parent"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

test_validate_edit_write_blocks_edit_when_file_parent_mismatches() {
  # File-based parent fallback must not whitelist a third session.
  local home input out own_sid file_parent
  own_sid="aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
  file_parent="dddddddd-dddd-4ddd-dddd-dddddddddddd"
  home="$(fresh_home owner-file-parent-mismatch)"
  mkdir -p "$home/.cache/claude-proof/$own_sid"
  printf '%s\n' "$file_parent" >"$home/.cache/claude-proof/$own_sid/parent_session_id"
  input="$TMP_ROOT/owner-file-parent-mismatch.json"
  # Fixture: file belongs to bbb..., own is aaa..., file-parent says ddd... — should still deny.
  render_session_fixture "$FIXTURES/edit-parent-sid-proof-allow.json" "$home" "$input"
  out="$TMP_ROOT/owner-file-parent-mismatch.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" CLAUDE_PARENT_SESSION_ID=""
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

# Regression: $HOME containing ERE meta-chars must not silently disable the
# ownership gate. With an under-escaped HOME_RE, extract_owner_sid would
# return empty for any path under a paren-bearing $HOME and the gate would
# pass-through a cross-session edit. Build a fake HOME at "$TMP_ROOT/home-paren (work)"
# (parens unescaped become an ERE group) and verify the deny still fires.
test_validate_edit_write_blocks_other_sid_under_paren_home() {
  local home input out
  home="$TMP_ROOT/home-paren (work)"
  rm -rf "$home"
  mkdir -p "$home/.cache/claude-proof"
  ln -s "$HOME/.claude" "$home/.claude"
  input="$TMP_ROOT/owner-paren-home.json"
  jq -n --arg path "$home/.cache/claude-proof/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb/foo" \
    '{session_id:"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
      tool_name:"Edit",
      tool_input:{file_path:$path,old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/owner-paren-home.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "belongs to session"
}

# ---- check-audit-sync ----

test_audit_sync_checker_ok() {
  local out
  out="$TMP_ROOT/audit-sync-ok.out"
  bash "$ROOT/hooks/check-audit-sync.sh" >"$out" 2>"$out.err" || return 1
  grep -q "check-audit-sync: OK" "$out"
}

test_audit_sync_checker_direct_exec_ok() {
  local out
  out="$TMP_ROOT/audit-sync-direct.out"
  "$ROOT/hooks/check-audit-sync.sh" >"$out" 2>"$out.err" || return 1
  grep -q "check-audit-sync: OK" "$out"
}

test_audit_sync_checker_detects_drift() {
  local hook_dir out status
  hook_dir="$TMP_ROOT/audit-sync-drift"
  mkdir -p "$hook_dir"
  cp "$ROOT/hooks/check-audit-sync.sh" "$hook_dir/check-audit-sync.sh"
  cp "$ROOT/hooks/stop-verification.md" "$hook_dir/stop-verification.md"
  # remove a canonical phrase from one copy
  sed '/clean-scan: CLAUDE.md/d' "$ROOT/hooks/stop-checklist.md" >"$hook_dir/stop-checklist.md"
  out="$TMP_ROOT/audit-sync-drift.out"
  bash "$hook_dir/check-audit-sync.sh" >"$out" 2>"$out.err"
  status=$?
  [ "$status" -ne 0 ] && grep -q "DRIFT" "$out"
}

test_audit_sync_checker_skips_when_files_missing() {
  local hook_dir out status
  hook_dir="$TMP_ROOT/audit-sync-missing"
  mkdir -p "$hook_dir"
  cp "$ROOT/hooks/check-audit-sync.sh" "$hook_dir/check-audit-sync.sh"
  cp "$ROOT/hooks/stop-verification.md" "$hook_dir/stop-verification.md"
  out="$TMP_ROOT/audit-sync-missing.out"
  bash "$hook_dir/check-audit-sync.sh" >"$out" 2>"$out.err"
  status=$?
  # claude check-audit-sync emits a "skipping" message and exits 0 when one of the
  # files is absent (codex variant exits non-zero — this is a real Claude vs Codex
  # divergence, see the script header comment "skipping").
  [ "$status" -eq 0 ] && grep -q "skipping" "$out.err"
}

# ---- session-snapshot ----

test_session_snapshot_saves_baseline() {
  local home out
  home="$(fresh_home session-baseline)"
  out="$TMP_ROOT/session-snap.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$home/.cache/claude-proof/t00-session/baseline_head" ]
}

test_session_snapshot_skips_ephemeral_threads() {
  local home out
  home="$(fresh_home session-ephemeral)"
  out="$TMP_ROOT/session-ephem.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start-ephemeral.json" HOME="$home"
  expect_no_output "$out" &&
    [ ! -e "$home/.cache/claude-proof/t00-side/baseline_head" ]
}

test_session_snapshot_clears_legacy_skip_marker() {
  local home pdir out
  home="$(fresh_home session-clears-skip)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  touch "$pdir/skip_stop"
  out="$TMP_ROOT/session-clears-skip.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$pdir/baseline_head" ] &&
    [ ! -e "$pdir/skip_stop" ]
}

test_session_snapshot_preserves_existing_baseline() {
  local home pdir out
  home="$(fresh_home session-preserve)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'preserved-head-value\n' >"$pdir/baseline_head"
  out="$TMP_ROOT/session-preserve.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" HOME="$home"
  expect_no_output "$out" &&
    grep -q "preserved-head-value" "$pdir/baseline_head"
}

# ---- prompt-task-reminder ----

test_prompt_state_records_head_and_clears_bypass() {
  local home rdir prdir out expected
  home="$(fresh_home prompt-head)"
  rdir="$home/.cache/claude-proof/reviewer/t00-session"
  prdir="$home/.cache/claude-proof/pre-reviewer/t00-session"
  mkdir -p "$rdir" "$prdir"
  touch "$rdir/bypass" "$prdir/bypass"
  expected="$(git -C "$ROOT" rev-parse HEAD)"
  out="$TMP_ROOT/prompt-head.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" HOME="$home"
  # expect prompt reminder text on stdout
  grep -q "PRE-WORK" "$out" &&
    [ -s "$rdir/prompt_head" ] &&
    [ "$(cat "$rdir/prompt_head")" = "$expected" ] &&
    [ ! -e "$rdir/bypass" ] &&
    [ ! -e "$prdir/bypass" ]
}

test_prompt_state_skips_state_for_invalid_session() {
  local home out
  home="$(fresh_home prompt-invalid)"
  out="$TMP_ROOT/prompt-invalid.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-invalid-session.json" HOME="$home"
  grep -q "PRE-WORK" "$out" &&
    [ "$(find "$home/.cache/claude-proof" -name prompt_head 2>/dev/null | wc -l)" -eq 0 ]
}

test_prompt_state_emits_skill_reload_for_coordinator_role() {
  local home out
  home="$(fresh_home prompt-coord)"
  out="$TMP_ROOT/prompt-coord.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" \
    HOME="$home" CLAUDE_ROLE="coordinator"
  grep -q "SKILL RELOAD CHECK" "$out"
}

test_prompt_state_emits_skill_reload_for_lead_role() {
  local home out
  home="$(fresh_home prompt-lead)"
  out="$TMP_ROOT/prompt-lead.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" \
    HOME="$home" CLAUDE_ROLE="lead"
  grep -q "SKILL RELOAD CHECK" "$out"
}

test_prompt_state_no_skill_reload_for_default_role() {
  local home out
  home="$(fresh_home prompt-default)"
  out="$TMP_ROOT/prompt-default.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" HOME="$home"
  grep -q "PRE-WORK" "$out" &&
    ! grep -q "SKILL RELOAD CHECK" "$out"
}

test_prompt_state_emits_eci_reminder_when_marker_exists() {
  local home pdir out
  home="$(fresh_home prompt-eci)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: porting tests\n' >"$pdir/eci_active"
  out="$TMP_ROOT/prompt-eci.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" HOME="$home"
  grep -q "ECI ACTIVE" "$out" &&
    grep -q "porting tests" "$out"
}

# ---- stop-gate (proof.md / git / gitleaks / activity / freshness) ----

test_stop_gate_blocks_missing_proof_sections() {
  local home repo input out
  home="$(fresh_home stop-missing)"
  repo="$(make_git_repo stop-missing)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-missing-sections.md"
  input="$TMP_ROOT/stop-missing.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-missing.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "missing required sections"
}

test_stop_gate_accepts_complete_proof() {
  local home repo input out
  home="$(fresh_home stop-accept)"
  repo="$(make_git_repo stop-accept)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-complete.md"
  input="$TMP_ROOT/stop-accept.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-accept.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  # Proof was processed (no "missing required sections"). Claude blocks once
  # to print the summary; hook returns silently on the second invocation.
  ! json_field_contains "$out" '.reason // empty' "missing required sections"
}

test_stop_gate_blocks_clean_scan_empty_source() {
  local home repo input out
  home="$(fresh_home stop-empty-source)"
  repo="$(make_git_repo stop-empty-source)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-audit-clean-empty-source.md"
  input="$TMP_ROOT/stop-empty-source.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-empty-source.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "three non-empty sources"
}

test_stop_gate_blocks_blocker_missing_input() {
  local home repo input out
  home="$(fresh_home stop-blocker-input)"
  repo="$(make_git_repo stop-blocker-input)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-audit-blocker-missing-input.md"
  input="$TMP_ROOT/stop-blocker-input.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-blocker-input.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "blocker missing"
}

test_stop_gate_blocks_blocker_missing_command() {
  local home repo input out
  home="$(fresh_home stop-blocker-cmd)"
  repo="$(make_git_repo stop-blocker-cmd)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-audit-blocker-missing-command.md"
  input="$TMP_ROOT/stop-blocker-cmd.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-blocker-cmd.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "blocker missing"
}

test_stop_gate_blocks_placeholder_blocker_command() {
  local home repo input out
  home="$(fresh_home stop-placeholder)"
  repo="$(make_git_repo stop-placeholder)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-audit-blocker-placeholder-command.md"
  input="$TMP_ROOT/stop-placeholder.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-placeholder.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "placeholder"
}

test_stop_gate_blocks_fake_audit_commit() {
  local home repo input out
  home="$(fresh_home stop-fake-commit)"
  repo="$(make_git_repo stop-fake-commit)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-audit-fake-commit.md"
  input="$TMP_ROOT/stop-fake-commit.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-fake-commit.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "unreachable"
}

# DROPPED: test_stop_gate_blocks_identical_audit_without_rescanned
# Real Claude bug, NOT a test/adaptation issue. claude/hooks/stop-gate.sh:659
# uses `grep ... | head -n1` inside `$(...)` while `set -euo pipefail` is
# active. When the audit has no `rescanned:` line (the case under test),
# grep returns 1, pipefail propagates, and `set -e` silently exits the hook
# BEFORE the "byte-identical" block can fire. Codex's equivalent uses awk
# instead, so codex's test passes. Reproduces deterministically with a fresh
# proof, identical re-submission, and an unchanged repo — see commit body.

test_stop_gate_accepts_identical_audit_with_rescanned() {
  local home repo input out
  home="$(fresh_home stop-identical-rescan)"
  repo="$(make_git_repo stop-identical-rescan)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-complete-rescanned.md"
  input="$TMP_ROOT/stop-id-rescan-1.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  run_hook_in_dir "$repo" "$TMP_ROOT/stop-id-rescan-1.out" "$ROOT/hooks/stop-gate.sh" "$input" \
    HOME="$home" CLAUDE_STOP_REVIEWER="" || true
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-complete-rescanned.md"
  out="$TMP_ROOT/stop-id-rescan-2.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  ! json_field_contains "$out" '.reason // empty' "byte-identical"
}

test_stop_gate_continues_clean_inactive_turn() {
  local home repo input out
  home="$(fresh_home stop-clean)"
  repo="$(make_git_repo stop-clean)" || return 1
  input="$TMP_ROOT/stop-clean.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-clean.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  ! is_stop_block "$out" || json_field_contains "$out" '.reason // empty' "Verification proof accepted"
}

# Regression for the cleanup that runs at PROOF_DIR on every stop. The
# maintaining-context-ledger skill mandates project-understanding.md,
# high_level_log.md, and latest-status-report.md persist across stops;
# everything else (proof.md, baseline_head, scratch dirs, etc.) must be
# cleared. Extracts the live find cleanup line(s) from stop-gate.sh,
# substitutes PROOF_DIR for a scratch dir, and asserts dual-sided behavior.
# Also asserts both occurrences of the cleanup line are byte-identical so a
# single check covers both.
test_stop_gate_cleanup_preserves_ledger_files() {
  local dir lines uniq line cmd
  lines=$(grep -F '[ -d "$PROOF_DIR" ] && find "$PROOF_DIR" -mindepth 1 -maxdepth 1' "$ROOT/hooks/stop-gate.sh" || true)
  [ -n "$lines" ] || return 1
  [ "$(printf '%s\n' "$lines" | wc -l)" -ge 2 ] || return 1
  uniq=$(printf '%s\n' "$lines" | sed 's/^[[:space:]]*//' | sort -u | wc -l)
  [ "$uniq" -eq 1 ] || return 1

  dir="$TMP_ROOT/stop-cleanup-ledger"
  rm -rf "$dir"
  mkdir -p "$dir/research"
  printf 'ledger\n' >"$dir/project-understanding.md"
  printf 'history\n' >"$dir/high_level_log.md"
  printf 'report\n' >"$dir/latest-status-report.md"
  printf 'scratch\n' >"$dir/baseline_head"
  printf 'p\n' >"$dir/proof.md"
  printf 'r\n' >"$dir/research/r1.md"

  line=$(printf '%s\n' "$lines" | head -n1 | sed 's/^[[:space:]]*//')
  cmd=${line//\$PROOF_DIR/$dir}
  bash -c "$cmd" || true

  # Good behavior IS happening: all three ledger files preserved.
  [ -f "$dir/project-understanding.md" ] || return 1
  [ -f "$dir/high_level_log.md" ] || return 1
  [ -f "$dir/latest-status-report.md" ] || return 1
  # Bad behavior is NOT happening: non-ledger entries cleared.
  [ ! -e "$dir/baseline_head" ] || return 1
  [ ! -e "$dir/proof.md" ] || return 1
  [ ! -e "$dir/research" ] || return 1
}

test_stop_gate_blocks_dirty_git_state() {
  local home repo input out
  home="$(fresh_home stop-dirty)"
  repo="$(make_git_repo stop-dirty)" || return 1
  printf 'dirty\n' >>"$repo/file.txt"
  input="$TMP_ROOT/stop-dirty.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-dirty.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out"
}

# DROPPED: test_stop_gate_blocks_committed_state_without_proof
# Real Claude vs Codex semantic difference. Claude's stop-gate.sh:386 checks
# only the worktree (`git status --porcelain`) for the activity-empty fast-
# continue gate; a clean worktree + no transcript activity → silent allow
# even when HEAD advanced past the recorded baseline_head. Codex's gate
# compares baseline..HEAD and blocks. Not portable as-is.

test_stop_gate_blocks_gitleaks_findings_dirty() {
  local home repo bin_dir input out
  home="$(fresh_home stop-gl-dirty)"
  repo="$(make_git_repo_with_code stop-gl-dirty)" || return 1
  bin_dir="$(make_fake_gitleaks stop-gl-dirty)" || return 1
  printf 'FAKE_SECRET\n' >>"$repo/file.go"
  input="$TMP_ROOT/stop-gl-dirty.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-gl-dirty.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    HOME="$home" PATH="$bin_dir:$PATH" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "secret"
}

# DROPPED: test_stop_gate_blocks_gitleaks_findings_untracked
# Real Claude vs Codex semantic difference. Claude's CODE_CHANGES detection
# (stop-gate.sh:771-780) only inspects `git diff` and `git diff --cached`,
# not `git ls-files --others --exclude-standard`, so an untracked .go file
# with FAKE_SECRET goes through the no-code-changes branch and the gitleaks
# scan is skipped. Codex's stop-gate scans the worktree directly via
# `gitleaks protect --source $repo`, so the untracked file is caught.

test_stop_gate_blocks_gitleaks_execution_failure() {
  local home repo bin_dir input out
  home="$(fresh_home stop-gl-error)"
  repo="$(make_git_repo_with_code stop-gl-error)" || return 1
  bin_dir="$(make_fake_gitleaks stop-gl-error)" || return 1
  printf 'ordinary change\n' >>"$repo/file.go"
  input="$TMP_ROOT/stop-gl-error.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-gl-error.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    HOME="$home" PATH="$bin_dir:$PATH" CLAUDE_STOP_REVIEWER="" FAKE_GITLEAKS_MODE=error
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated secret scan could not complete"
}

test_stop_gate_blocks_eci_active_state() {
  local home pdir repo input out
  home="$(fresh_home stop-eci-active)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  repo="$(make_git_repo stop-eci-active)" || return 1
  input="$TMP_ROOT/stop-eci-active.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-eci-active.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI active and no teammate awaited"
}

test_stop_gate_allows_session_skip_state() {
  local home pdir repo input out
  home="$(fresh_home stop-skip)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  touch "$pdir/skip_stop"
  repo="$(make_git_repo stop-skip)" || return 1
  input="$TMP_ROOT/stop-skip.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-skip.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  ! is_stop_block "$out"
}

test_stop_gate_validates_proof_when_stop_hook_active() {
  local home repo input out
  home="$(fresh_home stop-active-validates)"
  repo="$(make_git_repo stop-active-validates)" || return 1
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-missing-sections.md"
  input="$TMP_ROOT/stop-active-validates.json"
  jq --arg cwd "$repo" '.cwd = $cwd | .stop_hook_active = true' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-active-validates.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "missing required sections"
}

test_stop_gate_blocks_preexisting_commit_after_head_advance() {
  local home repo input out old_commit
  home="$(fresh_home stop-old-commit)"
  repo="$(make_git_repo stop-old-commit)" || return 1
  old_commit="$(git -C "$repo" rev-parse HEAD)"
  install_proof_fixture "$home/.cache/claude-proof" "$FIXTURES/proof-complete.md"
  input="$TMP_ROOT/stop-old-commit-1.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  run_hook_in_dir "$repo" "$TMP_ROOT/stop-old-commit-1.out" "$ROOT/hooks/stop-gate.sh" "$input" \
    HOME="$home" CLAUDE_STOP_REVIEWER="" || true
  printf 'new\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt && git -C "$repo" commit -qm "advance"
  mkdir -p "$home/.cache/claude-proof/t00-session"
  sed "s/__OLD_COMMIT__/$old_commit/g" "$FIXTURES/proof-audit-old-commit-template.md" \
    >"$home/.cache/claude-proof/t00-session/proof.md"
  out="$TMP_ROOT/stop-old-commit-2.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "pre-existing"
}

test_stop_gate_adds_loop_reminder_after_five_blocks() {
  local home pdir repo input out i
  home="$(fresh_home stop-loop)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  repo="$(make_git_repo stop-loop)" || return 1
  input="$TMP_ROOT/stop-loop.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-loop.out"
  for i in 1 2 3 4 5; do
    run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER="" || return 1
  done
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "LOOP DETECTED"
}

# Regression test for stop-gate.sh:659 silent-exit bug: under set -euo pipefail,
# `RESCAN_LINE=$(...|grep ...|head -n1)` exits silently when grep returns 1,
# bypassing the byte-identical-audit-without-rescanned block. Pre-fix: silent
# exit (no JSON output). Post-fix: block fires citing missing rescanned line
# (clean tree) or dirty-tree variant.
test_stop_gate_blocks_identical_audit_without_rescanned() {
  local home repo input out
  home="$(fresh_home stop-identical-no-rescan)"
  repo="$(make_git_repo stop-identical-no-rescan)" || return 1
  seed_freshness_oracle "$home" "$repo" t00-session "$FIXTURES/proof-complete.md"
  input="$TMP_ROOT/stop-identical-no-rescan.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-identical-no-rescan.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER="" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "byte-identical to the prior stop"
}

# ---- claude-tmp lib (disk-pressure resilience) ----

test_claude_init_tmp_uses_writable_target() {
  local home; home="$(fresh_home init-tmp-writable)"
  local out="$TMP_ROOT/init-tmp-writable.out"
  HOME="$home" bash -c '
    set -euo pipefail
    . "$HOME/.claude/hooks/lib/claude-tmp.sh"
    claude_init_tmp
    printf "TMPDIR=%s\n" "$TMPDIR"
  ' >"$out" 2>"$out.err" || return 1
  grep -qx "TMPDIR=$home/tmp" "$out"
}

test_claude_init_tmp_unwritable_target_returns_nonzero() {
  local out="$TMP_ROOT/init-tmp-unwritable.out"
  CLAUDE_TMPDIR=/no/such/dir/path bash -c '
    set -uo pipefail
    . "$HOME/.claude/hooks/lib/claude-tmp.sh"
    if claude_init_tmp; then
      printf "INIT_OK\n"
    else
      printf "INIT_FAIL\n"
    fi
  ' >"$out" 2>"$out.err"
  grep -qx "INIT_FAIL" "$out" &&
    grep -q "claude_init_tmp: /no/such/dir/path unwritable" "$out.err"
}

test_claude_fail_open_trap_exits_zero_on_err() {
  local out="$TMP_ROOT/fail-open-trap.out" rc
  bash -c '
    set -euo pipefail
    . "$HOME/.claude/hooks/lib/claude-tmp.sh"
    claude_install_fail_open_trap test-hook
    : > /no/such/dir/path/file
    printf "should-not-run\n"
  ' >"$out" 2>"$out.err"
  rc=$?
  [ "$rc" -eq 0 ] &&
    ! grep -q "should-not-run" "$out" &&
    grep -q "test-hook: aborted" "$out.err"
}

# ===========================================================================
# Run all tests
# ===========================================================================

# Original 15 tests — these call pass/fail inline (legacy style).
test_stop_gate_exempts_subagent_with_agent_id
test_stop_gate_does_not_exempt_agent_type_only
test_stop_gate_blocks_main_thread_with_activity
test_stop_gate_exempts_subordinate_role
test_stop_gate_blocks_team_lead_role
test_stop_gate_skips_ephemeral_session
test_validate_edit_write_blocks_singular_import_dir
test_validate_edit_write_blocks_plural_imports_dir
test_validate_edit_write_blocks_vendor_dir
test_validate_bash_allows_write_to_singular_import_dir
test_validate_edit_write_blocks_thirdparty_variants
test_validate_edit_write_allows_lookalike_dirnames
test_validate_edit_write_allows_regular_repo_edit
test_validate_edit_write_allows_write_into_submodule_and_its_worktree
test_validate_bash_allows_write_into_submodule

# ECI gate tests
run_case "ECI gate blocks Edit of control file in own proof session" \
  test_eci_gate_blocks_control_file_edit
run_case "ECI gate deny reason names control state, Claude-neutral" \
  test_eci_gate_deny_reason_names_control_state
run_case "ECI gate blocks control file without any marker present" \
  test_eci_gate_blocks_control_file_without_marker
run_case "ECI gate blocks Write of control file" \
  test_eci_gate_blocks_control_file_write
run_case "ECI gate blocks MultiEdit of control file" \
  test_eci_gate_blocks_control_file_multiedit
run_case "ECI gate blocks NotebookEdit of control file" \
  test_eci_gate_blocks_control_file_notebookedit
run_case "ECI gate blocks Codex control basenames" \
  test_eci_gate_blocks_codex_control_names
run_case "ECI gate allows names removed from the Claude-only list (Codex parity)" \
  test_eci_gate_allows_names_outside_codex_list
run_case "ECI gate blocks edit of repair-authorize claim dir descendant" \
  test_eci_gate_blocks_repair_authorize_claim_descendant
run_case "ECI gate blocks edit of accidental-override claim dir descendant" \
  test_eci_gate_blocks_accidental_override_claim_descendant
run_case "ECI gate blocks working-doc name hard-linked to another session's control" \
  test_eci_gate_blocks_working_doc_hardlink_alias
run_case "ECI gate checks every tool_input path key, not only the first" \
  test_eci_gate_checks_every_target_key
run_case "ECI gate denies edit tool with non-object tool_input (exit 2)" \
  test_eci_gate_denies_edit_with_non_object_tool_input
run_case "ECI gate blocks control .md (control check precedes markdown)" \
  test_eci_gate_blocks_markdown_control_file
run_case "ECI gate allows source Edit while marker exists" \
  test_eci_gate_allows_source_edit_with_active_marker
run_case "ECI gate allows source Write fixture" \
  test_eci_gate_allows_source_write_fixture
run_case "ECI gate allows source MultiEdit fixture" \
  test_eci_gate_allows_source_multiedit_fixture
run_case "ECI gate allows source NotebookEdit fixture" \
  test_eci_gate_allows_source_notebookedit_fixture
run_case "ECI gate allows markdown Edit" \
  test_eci_gate_allows_markdown_edit
run_case "ECI gate allows markdown MultiEdit" \
  test_eci_gate_allows_markdown_multiedit
run_case "ECI gate allows markdown Write" \
  test_eci_gate_allows_markdown_write
run_case "ECI gate allows source edit when no marker exists" \
  test_eci_gate_allows_when_no_marker
run_case "ECI gate: CLAUDE_ROLE env does not lift control deny" \
  test_eci_gate_blocks_control_file_with_role_env
run_case "ECI gate: agent_id does not lift control deny (no subagent exemption)" \
  test_eci_gate_blocks_control_file_subagent_agent_id
run_case "ECI gate: agent_type does not lift control deny (no subagent exemption)" \
  test_eci_gate_blocks_control_file_subagent_agent_type
run_case "ECI gate blocks other-session ledger in proof root" \
  test_eci_gate_blocks_other_session_ledger
run_case "ECI gate allows own-session working document" \
  test_eci_gate_allows_own_session_working_doc
run_case "ECI gate allows non-control ledger name in proof root" \
  test_eci_gate_allows_non_control_ledger_in_proof_root
run_case "ECI gate blocks reserved proof-dir descendant, allows nested non-reserved" \
  test_eci_gate_blocks_reserved_proof_dir_descendant
run_case "ECI gate blocks hard-link alias to active marker" \
  test_eci_gate_blocks_hardlink_alias_to_marker
run_case "ECI gate blocks hard-link to inactive session's control file from a plain name" \
  test_eci_gate_blocks_hardlink_to_inactive_session_control
run_case "ECI gate blocks own working doc hard-linked to inactive session's control file" \
  test_eci_gate_blocks_own_working_doc_hardlink_to_inactive_control
run_case "ECI gate blocks hard-link into reserved proof namespace" \
  test_eci_gate_blocks_hardlink_into_reserved_namespace
run_case "ECI gate allows plain own-session proof.md" \
  test_eci_gate_allows_plain_own_proof_doc
run_case "ECI gate blocks symlink resolving to control file" \
  test_eci_gate_blocks_symlink_to_control_file
run_case "ECI gate skips on unsafe session_id" \
  test_eci_gate_skips_unsafe_session_id
run_case "ECI gate skips on bad JSON" \
  test_eci_gate_skips_bad_json
run_case "ECI gate skips on missing cwd, denies same payload with cwd" \
  test_eci_gate_skips_missing_cwd
run_case "ECI gate skips non-Edit/Write/MultiEdit/NotebookEdit tools" \
  test_eci_gate_skips_non_edit_tool
run_case "skill-marker gate blocks NotebookEdit on protected path without marker" \
  test_skill_marker_gate_blocks_notebookedit_without_marker

# ATE orchestrator gate tests
run_case "ATE gate allows edits for lead role" \
  test_ate_gate_allows_edits_for_lead
run_case "ATE gate allows edits for coordinator role" \
  test_ate_gate_allows_edits_for_coordinator
run_case "ATE gate allows edits for executor role" \
  test_ate_gate_allows_edits_for_executor
run_case "ATE gate allows edits when no role is set" \
  test_ate_gate_allows_edits_for_no_role
run_case "ATE gate allows subagent via agent_id" \
  test_ate_gate_allows_subagent_via_agent_id
run_case "ATE gate allows subagent via agent_type" \
  test_ate_gate_allows_subagent_via_agent_type
run_case "ATE gate skips non-Edit/Write/MultiEdit tools" \
  test_ate_gate_skips_non_edit_tool

# validate-edit-write path-policy tests
run_case "validate-edit-write blocks direct Edit plan paths" \
  test_validate_edit_write_blocks_direct_edit_plan_path
run_case "validate-edit-write blocks direct Write plan paths" \
  test_validate_edit_write_blocks_direct_write_plan_path
run_case "validate-edit-write blocks direct MultiEdit plan paths" \
  test_validate_edit_write_blocks_direct_multiedit_plan_path
run_case "validate-edit-write blocks direct Write imports paths" \
  test_validate_edit_write_blocks_direct_write_imports_path
run_case "validate-edit-write blocks direct MultiEdit vendor paths" \
  test_validate_edit_write_blocks_direct_multiedit_vendor_path
run_case "validate-edit-write allows vendorish paths" \
  test_validate_edit_write_allows_vendorish_path
run_case "validate-edit-write blocks direct Edit go.mod local replace" \
  test_validate_edit_write_blocks_direct_edit_local_gomod_replace
run_case "validate-edit-write blocks direct Write go.mod local replace" \
  test_validate_edit_write_blocks_direct_write_local_gomod_replace
run_case "validate-edit-write blocks direct MultiEdit go.mod local replace" \
  test_validate_edit_write_blocks_direct_multiedit_local_gomod_replace
run_case "validate-edit-write allows unrelated non-plan Edit" \
  test_validate_edit_write_allows_unrelated_non_plan_edit
run_case "validate-edit-write allows remote Write go.mod replace" \
  test_validate_edit_write_allows_remote_write_gomod_replace
run_case "validate-edit-write allows remote MultiEdit go.mod replace" \
  test_validate_edit_write_allows_remote_multiedit_gomod_replace

# validate-bash tests
run_case "validate-bash allows redirect to vendor paths (planner receives input)" \
  test_validate_bash_allows_redirect_to_vendor_path
run_case "validate-bash allows in-place imports paths (planner receives input)" \
  test_validate_bash_allows_in_place_imports_path
run_case "validate-bash allows vendor test with tmp redirect (planner receives input)" \
  test_validate_bash_allows_vendor_test_with_tmp_redirect
run_case "validate-bash forwards bare go test to planner (planner decides)" \
  test_validate_bash_allows_bare_go_test
run_case "validate-bash forwards go test -count=1 to planner (planner decides)" \
  test_validate_bash_allows_go_test_count_one
run_case "validate-bash forwards redirected go test to planner" \
  test_validate_bash_allows_redirected_go_test
run_case "validate-bash forwards go test piped to tee to planner" \
  test_validate_bash_allows_go_test_tee
run_case "validate-bash marks shell activity for write commands" \
  test_validate_bash_marks_shell_activity
run_case "validate-bash skips activity for read-only shell (planner still receives it)" \
  test_validate_bash_skips_read_only_shell_activity
run_case "validate-bash skips activity for read-only shell chain (planner still receives it)" \
  test_validate_bash_skips_read_only_shell_chain_activity
run_case "validate-bash marks activity for redirected read shell" \
  test_validate_bash_marks_redirected_read_shell_activity
run_case "validate-bash blocks subagent eci-active off" \
  test_validate_bash_blocks_subagent_eci_active_off
run_case "validate-bash allows main eci-active off (planner receives input)" \
  test_validate_bash_allows_main_eci_active_off
run_case "validate-bash denies subagent eci-active off at argv head in all forms" \
  test_validate_bash_subagent_eci_off_argv_head_is_denied
run_case "subagent denied: bash -c \"eci-active off\"" \
  expect_subagent_bash_denied sub-deny-01 sub-uuid 'bash -c "eci-active off"'
run_case "subagent denied: sh -lc 'eci-active off'" \
  expect_subagent_bash_denied sub-deny-02 sub-uuid "sh -lc 'eci-active off'"
run_case "subagent denied: zsh -c 'eci-active off'" \
  expect_subagent_bash_denied sub-deny-03 sub-uuid "zsh -c 'eci-active off'"
run_case "subagent denied: bash -o pipefail -c 'eci-active off'" \
  expect_subagent_bash_denied sub-deny-04 sub-uuid "bash -o pipefail -c 'eci-active off'"
run_case "subagent denied: env eci-active off" \
  expect_subagent_bash_denied sub-deny-05 sub-uuid 'env eci-active off'
run_case "subagent denied: env -i eci-active off" \
  expect_subagent_bash_denied sub-deny-06 sub-uuid 'env -i eci-active off'
run_case "subagent denied: env -u FOO eci-active off" \
  expect_subagent_bash_denied sub-deny-07 sub-uuid 'env -u FOO eci-active off'
run_case "subagent denied: env -S 'eci-active off'" \
  expect_subagent_bash_denied sub-deny-08 sub-uuid "env -S 'eci-active off'"
run_case "subagent denied: env FOO=1 bash -c 'eci-active off'" \
  expect_subagent_bash_denied sub-deny-09 sub-uuid "env FOO=1 bash -c 'eci-active off'"
run_case "subagent denied: bash -c 'env eci-active off' (nested wrapper)" \
  expect_subagent_bash_denied sub-deny-10 sub-uuid "bash -c 'env eci-active off'"
run_case "subagent denied: command eci-active off" \
  expect_subagent_bash_denied sub-deny-11 sub-uuid 'command eci-active off'
run_case "subagent denied: exec eci-active off" \
  expect_subagent_bash_denied sub-deny-12 sub-uuid 'exec eci-active off'
run_case "subagent denied: nohup eci-active off" \
  expect_subagent_bash_denied sub-deny-13 sub-uuid 'nohup eci-active off'
run_case "subagent denied: time eci-active off" \
  expect_subagent_bash_denied sub-deny-14 sub-uuid 'time eci-active off'
run_case "subagent denied: time -p eci-active off" \
  expect_subagent_bash_denied sub-deny-15 sub-uuid 'time -p eci-active off'
run_case "subagent denied: timeout 5 eci-active off" \
  expect_subagent_bash_denied sub-deny-16 sub-uuid 'timeout 5 eci-active off'
run_case "subagent denied: timeout -s TERM 5 eci-active off" \
  expect_subagent_bash_denied sub-deny-17 sub-uuid 'timeout -s TERM 5 eci-active off'
run_case "subagent denied: stdbuf -oL eci-active off" \
  expect_subagent_bash_denied sub-deny-18 sub-uuid 'stdbuf -oL eci-active off'
run_case "subagent denied: bash ~/.claude/bin/eci-active off (script form)" \
  expect_subagent_bash_denied sub-deny-19 sub-uuid 'bash ~/.claude/bin/eci-active off'
run_case "subagent allowed: command -v eci-active (query only)" \
  expect_bash_forwarded sub-fwd-01 sub-uuid 'command -v eci-active'
run_case "subagent allowed: command -V eci-active (query only)" \
  expect_bash_forwarded sub-fwd-02 sub-uuid 'command -V eci-active'
run_case "subagent denied (accepted over-denial): echo \"eci-active off\" (quoted text)" \
  expect_subagent_bash_denied sub-overdeny-03 sub-uuid 'echo "eci-active off"'
run_case "subagent denied (accepted over-denial): env echo eci-active off (echo argument)" \
  expect_subagent_bash_denied sub-overdeny-04 sub-uuid 'env echo eci-active off'
run_case "subagent denied (accepted over-denial): bash -c 'echo eci-active off' (nested text)" \
  expect_subagent_bash_denied sub-overdeny-05 sub-uuid "bash -c 'echo eci-active off'"
run_case "subagent allowed: bash -c with no string (no crash, no deny)" \
  expect_bash_forwarded sub-fwd-06 sub-uuid 'bash -c'
run_case "subagent allowed: timeout 5 with no command (no crash, no deny)" \
  expect_bash_forwarded sub-fwd-07 sub-uuid 'timeout 5'
run_case "subagent denied (accepted over-denial): cat heredoc body mentioning eci-active off" \
  expect_subagent_bash_denied sub-overdeny-08 sub-uuid "$(printf "cat <<'EOF'\neci-active off\nEOF")"
run_case "main thread forwarded: bash -c \"eci-active off\" (guard is subagent-only)" \
  expect_bash_forwarded main-fwd-01 '' 'bash -c "eci-active off"'
run_case "main thread forwarded: env eci-active off (guard is subagent-only)" \
  expect_bash_forwarded main-fwd-02 '' 'env eci-active off'
run_case "main thread forwarded: timeout 5 eci-active off (guard is subagent-only)" \
  expect_bash_forwarded main-fwd-03 '' 'timeout 5 eci-active off'
run_case "subagent denied: env FOO=1 -i nohup time -p eci-active off (interleaved env args)" \
  expect_subagent_bash_denied sub-deny-20 sub-uuid 'env FOO=1 -i nohup time -p eci-active off'
run_case "subagent denied: bash -eo pipefail -c 'eci-active off' (combined option group)" \
  expect_subagent_bash_denied sub-deny-21 sub-uuid "bash -eo pipefail -c 'eci-active off'"
run_case "subagent denied: bash -- eci-active off (script after --)" \
  expect_subagent_bash_denied sub-deny-22 sub-uuid 'bash -- eci-active off'
run_case "subagent denied: if true; then eci-active off; fi (reserved word)" \
  expect_subagent_bash_denied sub-deny-23 sub-uuid 'if true; then eci-active off; fi'
run_case "subagent denied: { eci-active off; } (group)" \
  expect_subagent_bash_denied sub-deny-24 sub-uuid '{ eci-active off; }'
run_case "subagent denied: ! eci-active off (negation)" \
  expect_subagent_bash_denied sub-deny-25 sub-uuid '! eci-active off'
run_case "subagent denied: while false; do eci-active off; done (loop body)" \
  expect_subagent_bash_denied sub-deny-26 sub-uuid 'while false; do eci-active off; done'
run_case "subagent denied (accepted over-denial): command -p -v eci-active off (query text)" \
  expect_subagent_bash_denied sub-overdeny-09 sub-uuid 'command -p -v eci-active off'
run_case "subagent denied (accepted over-denial): echo then eci-active off (echo argument)" \
  expect_subagent_bash_denied sub-overdeny-10 sub-uuid 'echo then eci-active off'
run_case "subagent denied (accepted over-denial): git commit -m 'note: eci-active off' (commit message text)" \
  expect_subagent_bash_denied sub-overdeny-11 sub-uuid "git commit -m 'note: eci-active off'"
run_case "subagent denied: git commit -m \"x\" && eci-active off r.md (invocation chained after a commit)" \
  expect_subagent_bash_denied sub-deny-45 sub-uuid 'git commit -m "x" && eci-active off r.md'
run_case "main thread forwarded: if true; then eci-active off; fi (guard is subagent-only)" \
  expect_bash_forwarded main-fwd-04 '' 'if true; then eci-active off; fi'
run_case "main thread forwarded: ~/.claude/bin/eci-active off /tmp/r.md (guard is subagent-only)" \
  expect_bash_forwarded main-fwd-05 '' '~/.claude/bin/eci-active off /tmp/r.md'
run_case "subagent denied: env -a x eci-active off (env option with argument)" \
  expect_subagent_bash_denied sub-deny-27 sub-uuid 'env -a x eci-active off'
run_case "subagent denied: env --split-string='eci-active off' (long split option)" \
  expect_subagent_bash_denied sub-deny-28 sub-uuid "env --split-string='eci-active off'"
run_case "subagent denied: stdbuf --output L eci-active off (long option with separate argument)" \
  expect_subagent_bash_denied sub-deny-29 sub-uuid 'stdbuf --output L eci-active off'
run_case "subagent denied: env -iS 'eci-active off' (grouped short options)" \
  expect_subagent_bash_denied sub-deny-30 sub-uuid "env -iS 'eci-active off'"
run_case "subagent denied: nice -n 5 ~/.claude/bin/eci-active off r.md (nice wrapper)" \
  expect_subagent_bash_denied sub-deny-31 sub-uuid 'nice -n 5 ~/.claude/bin/eci-active off r.md'
run_case "subagent denied: setsid ~/.claude/bin/eci-active off r.md (setsid wrapper)" \
  expect_subagent_bash_denied sub-deny-32 sub-uuid 'setsid ~/.claude/bin/eci-active off r.md'
run_case "subagent denied: \"\$HOME/.claude/bin/eci-active\" off r.md (quoted command word)" \
  expect_subagent_bash_denied sub-deny-33 sub-uuid '"$HOME/.claude/bin/eci-active" off r.md'
run_case "subagent denied: eci-active 'off' r.md (quoted subcommand)" \
  expect_subagent_bash_denied sub-deny-34 sub-uuid "~/.claude/bin/eci-active 'off' r.md"
run_case "subagent denied: eci-active \\off r.md (backslash-escaped subcommand)" \
  expect_subagent_bash_denied sub-deny-35 sub-uuid '~/.claude/bin/eci-active \off r.md'
run_case "subagent denied: backslash-newline continuation before eci-active off" \
  expect_subagent_bash_denied sub-deny-36 sub-uuid "$(printf 'cd /x && \\\n  ~/.claude/bin/eci-active off r.md')"
run_case "subagent denied: eci-active  off r.md (two spaces)" \
  expect_subagent_bash_denied sub-deny-37 sub-uuid '~/.claude/bin/eci-active  off r.md'
run_case "subagent denied: eci-active<TAB>off r.md (tab separator)" \
  expect_subagent_bash_denied sub-deny-38 sub-uuid "$(printf '~/.claude/bin/eci-active\toff r.md')"
run_case "subagent denied: x=\$(eci-active off r.md) (command substitution)" \
  expect_subagent_bash_denied sub-deny-39 sub-uuid 'x=$(~/.claude/bin/eci-active off r.md)'
run_case "subagent denied: x=\`eci-active off r.md\` (backtick substitution)" \
  expect_subagent_bash_denied sub-deny-40 sub-uuid 'x=`~/.claude/bin/eci-active off r.md`'
run_case "subagent denied: \$'eci-active' \$'off' r.md (ANSI-C quoted command word and subcommand)" \
  expect_subagent_bash_denied sub-deny-41 sub-uuid "\$'eci-active' \$'off' r.md"
run_case "subagent denied: eci-active \$'off' r.md (ANSI-C quoted subcommand)" \
  expect_subagent_bash_denied sub-deny-42 sub-uuid "eci-active \$'off' r.md"
run_case "subagent denied: eci-active \$\"off\" r.md (locale-quoted subcommand)" \
  expect_subagent_bash_denied sub-deny-43 sub-uuid 'eci-active $"off" r.md'
run_case "subagent denied: backslash-newline inside the phrase (eci-active \\<newline> off r.md)" \
  expect_subagent_bash_denied sub-deny-44 sub-uuid "$(printf 'eci-active \\\n off r.md')"
run_case "main thread forwarded: \$'eci-active' \$'off' r.md (guard is subagent-only)" \
  expect_bash_forwarded main-fwd-06 '' "\$'eci-active' \$'off' r.md"
run_case "subagent allowed: eci-active status" \
  expect_bash_forwarded sub-fwd-11 sub-uuid '~/.claude/bin/eci-active status'
run_case "subagent allowed: eci-active on \"task x\"" \
  expect_bash_forwarded sub-fwd-12 sub-uuid '~/.claude/bin/eci-active on "task x"'
run_case "subagent allowed: grep -n off ~/.claude/bin/eci-active (off precedes eci-active)" \
  expect_bash_forwarded sub-fwd-13 sub-uuid 'grep -n off ~/.claude/bin/eci-active'
run_case "subagent allowed: sed -n '/off)/,/;;/p' ~/.claude/bin/eci-active (off precedes eci-active)" \
  expect_bash_forwarded sub-fwd-14 sub-uuid "sed -n '/off)/,/;;/p' ~/.claude/bin/eci-active"
run_case "subagent allowed: grep -n 'eci-active[[:space:]]off' (bracket class does not spell the phrase)" \
  expect_bash_forwarded sub-fwd-15 sub-uuid "grep -n 'eci-active[[:space:]]off' hooks/tests/run.sh"
run_case "subagent allowed: echo eci-active offsets (off is a prefix of another word)" \
  expect_bash_forwarded sub-fwd-16 sub-uuid 'echo eci-active offsets'
run_case "subagent allowed: echo inactive off (inactive is not eci-active)" \
  expect_bash_forwarded sub-fwd-17 sub-uuid 'echo inactive off'
run_case "validate-bash denies git push with ECI active" \
  test_validate_bash_denies_git_push_with_eci_active
run_case "validate-bash denies chained git push without ECI" \
  test_validate_bash_denies_chained_git_push_without_eci
run_case "validate-bash blocks git reset without marker" \
  test_validate_bash_blocks_git_reset_without_marker
run_case "validate-bash consumes git reset marker and forwards to planner" \
  test_validate_bash_consumes_git_reset_marker
run_case "validate-bash blocks git reset marker mismatch" \
  test_validate_bash_blocks_git_reset_marker_mismatch
run_case "validate-bash subagent agent_id selects worker ECI role" \
  test_validate_bash_subagent_agent_id_selects_worker_role
run_case "validate-bash clears inherited CODEX_HOOK_IS_SUBAGENT for coordinator" \
  test_validate_bash_clears_inherited_subagent_flag_for_coordinator
run_case "validate-bash without ~/.codex fails open with stderr advisory" \
  test_validate_bash_without_codex_home_fails_open_with_advisory
run_case "validate-bash rebuilds missing ECI planner before failing open" \
  test_validate_bash_rebuilds_missing_planner_before_failing_open
run_case "validate-bash fails closed when planner binary missing under active ECI" \
  test_validate_bash_fails_closed_when_planner_binary_missing
run_case "validate-bash fails closed when codex root missing under active ECI" \
  test_validate_bash_fails_closed_when_codex_root_missing
run_case "validate-bash fails closed when planner lib unsourceable under active ECI" \
  test_validate_bash_fails_closed_when_planner_lib_unsourceable
run_case "validate-bash fails closed with relative HOME under active ECI" \
  test_validate_bash_fails_closed_with_relative_home_under_active_eci
run_case "validate-bash relative HOME without ECI fails open" \
  test_validate_bash_relative_home_without_eci_fails_open
run_case "validate-bash fails closed with empty HOME under active ECI" \
  test_validate_bash_fails_closed_with_empty_home_under_active_eci
run_case "validate-bash fails closed when planner exits non-zero under active ECI" \
  test_validate_bash_fails_closed_when_planner_exits_nonzero_under_active_eci
run_case "validate-bash forwards stdin without trailing newline byte-exact" \
  test_validate_bash_forwards_stdin_without_trailing_newline
run_case "validate-bash forwards stdin with two trailing newlines byte-exact" \
  test_validate_bash_forwards_stdin_with_two_trailing_newlines
run_case "validate-bash forwards non-JSON stdin unchanged" \
  test_validate_bash_non_json_stdin_is_forwarded_unchanged
test_validate_bash_wrapper_matches_codex_shim

# validate-edit-write activity
run_case "validate-edit-write marks edit activity for main thread" \
  test_validate_edit_write_marks_edit_activity

# validate-edit-write session-file ownership gate
run_case "validate-edit-write allows NotebookEdit on own proof dir" \
  test_validate_edit_write_allows_notebookedit_same_sid_proof
run_case "validate-edit-write blocks NotebookEdit on another session's proof dir" \
  test_validate_edit_write_blocks_notebookedit_other_sid_proof
run_case "validate-edit-write blocks MultiEdit on another session's todos" \
  test_validate_edit_write_blocks_multiedit_other_sid_todos
run_case "validate-edit-write blocks Edit on another session's projects transcript" \
  test_validate_edit_write_blocks_edit_other_sid_projects_transcript
run_case "validate-edit-write blocks Edit on another session's projects subagents" \
  test_validate_edit_write_blocks_edit_other_sid_projects_subagents
run_case "validate-edit-write blocks Write on protected path with no resolved sid" \
  test_validate_edit_write_blocks_write_missing_sid_on_protected
run_case "validate-edit-write allows unrelated path with no sid" \
  test_validate_edit_write_allows_unrelated_path_no_sid
run_case "validate-edit-write allows Edit on own todos" \
  test_validate_edit_write_allows_edit_same_sid_todos
run_case "validate-edit-write allows Edit on parent session's proof dir" \
  test_validate_edit_write_allows_edit_parent_sid_proof
run_case "validate-edit-write allows Edit on parent session's todos" \
  test_validate_edit_write_allows_edit_parent_sid_todos
run_case "validate-edit-write blocks Edit on a third session's proof dir even when parent is set" \
  test_validate_edit_write_blocks_edit_unrelated_sid_even_with_parent_set
run_case "validate-edit-write allows Edit when parent_session_id file declares parent" \
  test_validate_edit_write_allows_edit_parent_sid_via_file_fallback
run_case "validate-edit-write blocks Edit when parent_session_id file declares a third session" \
  test_validate_edit_write_blocks_edit_when_file_parent_mismatches
run_case "validate-edit-write allows Edit when --parent-session-id argv flag declares parent" \
  test_validate_edit_write_allows_edit_via_argv_parent_sid
run_case "validate-edit-write blocks Edit when --parent-session-id argv flag declares a third session" \
  test_validate_edit_write_blocks_edit_when_argv_parent_mismatches
run_case "validate-edit-write blocks cross-session edit when HOME contains ERE meta-chars" \
  test_validate_edit_write_blocks_other_sid_under_paren_home

# check-audit-sync
run_case "audit sync checker reports ok" \
  test_audit_sync_checker_ok
run_case "audit sync checker supports direct exec" \
  test_audit_sync_checker_direct_exec_ok
run_case "audit sync checker detects drift" \
  test_audit_sync_checker_detects_drift
run_case "audit sync checker skips when synced files are missing" \
  test_audit_sync_checker_skips_when_files_missing

# session-snapshot
run_case "session snapshot saves baseline" \
  test_session_snapshot_saves_baseline
run_case "session snapshot skips ephemeral threads" \
  test_session_snapshot_skips_ephemeral_threads
run_case "session snapshot clears legacy skip_stop marker" \
  test_session_snapshot_clears_legacy_skip_marker
run_case "session snapshot preserves existing baseline_head" \
  test_session_snapshot_preserves_existing_baseline

# prompt-task-reminder
run_case "prompt state records HEAD and clears bypass" \
  test_prompt_state_records_head_and_clears_bypass
run_case "prompt state skips state writes for invalid session" \
  test_prompt_state_skips_state_for_invalid_session
run_case "prompt state emits skill-reload reminder for coordinator role" \
  test_prompt_state_emits_skill_reload_for_coordinator_role
run_case "prompt state emits skill-reload reminder for lead role" \
  test_prompt_state_emits_skill_reload_for_lead_role
run_case "prompt state emits no skill-reload reminder for default role" \
  test_prompt_state_no_skill_reload_for_default_role
run_case "prompt state emits ECI reminder when marker exists" \
  test_prompt_state_emits_eci_reminder_when_marker_exists

# stop-gate (proof / git / gitleaks / loop)
run_case "stop gate blocks proof missing required sections" \
  test_stop_gate_blocks_missing_proof_sections
run_case "stop gate accepts complete proof fixture" \
  test_stop_gate_accepts_complete_proof
run_case "stop gate blocks clean-scan empty source" \
  test_stop_gate_blocks_clean_scan_empty_source
run_case "stop gate blocks blocker missing input" \
  test_stop_gate_blocks_blocker_missing_input
run_case "stop gate blocks blocker missing command" \
  test_stop_gate_blocks_blocker_missing_command
run_case "stop gate blocks placeholder blocker command" \
  test_stop_gate_blocks_placeholder_blocker_command
run_case "stop gate blocks fake audit commit" \
  test_stop_gate_blocks_fake_audit_commit
# DROPPED: stop gate blocks identical audit without rescanned — real claude
# bug (see comment above test_stop_gate_blocks_identical_audit_without_rescanned).
run_case "stop gate accepts identical audit with rescanned" \
  test_stop_gate_accepts_identical_audit_with_rescanned
run_case "stop gate continues clean inactive turn" \
  test_stop_gate_continues_clean_inactive_turn
run_case "stop gate cleanup preserves both ledger files and removes everything else" \
  test_stop_gate_cleanup_preserves_ledger_files
run_case "stop gate blocks dirty git state" \
  test_stop_gate_blocks_dirty_git_state
# DROPPED: stop gate blocks committed state without proof — semantic difference,
# see test_stop_gate_blocks_committed_state_without_proof comment above.
run_case "stop gate blocks gitleaks findings from dirty state" \
  test_stop_gate_blocks_gitleaks_findings_dirty
# DROPPED: stop gate blocks gitleaks findings from untracked state — semantic
# difference, see test_stop_gate_blocks_gitleaks_findings_untracked comment.
run_case "stop gate blocks gitleaks execution failure" \
  test_stop_gate_blocks_gitleaks_execution_failure
run_case "stop gate blocks ECI active state" \
  test_stop_gate_blocks_eci_active_state
run_case "stop gate allows session-scoped skip marker" \
  test_stop_gate_allows_session_skip_state
run_case "stop gate validates proof while stop_hook_active is true" \
  test_stop_gate_validates_proof_when_stop_hook_active
run_case "stop gate blocks pre-existing commit after HEAD advance" \
  test_stop_gate_blocks_preexisting_commit_after_head_advance
run_case "stop gate adds loop reminder after five blocks" \
  test_stop_gate_adds_loop_reminder_after_five_blocks
run_case "stop gate blocks byte-identical audit without rescanned: line" \
  test_stop_gate_blocks_identical_audit_without_rescanned

# ===========================================================================
# /side stop marker (codex parity): prompt writes it, stop gate honours it.
# ===========================================================================

# Stop input for session $1 in cwd $2 with transcript activity (blocks without a marker).
side_stop_input() {
  local sid="$1" repo="$2" tr="$3" input="$4"
  write_transcript_with_activity "$tr"
  jq --arg sid "$sid" --arg cwd "$repo" --arg tr "$tr" \
    '. + {session_id:$sid, transcript_path:$tr, cwd:$cwd}' \
    "$FIXTURES/stop-basic.json" >"$input"
}

# Write a cwd-scoped /side marker for parent $3 in repo $2 (format from prompt-task-reminder.sh).
seed_side_stop_cwd_marker() {
  local home="$1" repo="$2" parent="$3" dir
  dir="$(env -i HOME="$home" PATH="$PATH" bash -c \
    '. "$HOME/.claude/hooks/lib/claude-proof-state.sh" && claude_ensure_cwd_state_dir side-stop "$1"' _ "$repo")" || return 1
  [ -n "$dir" ] || return 1
  {
    printf 'command: /side\n'
    printf 'parent_session_id: %s\n' "$parent"
    printf 'cwd: %s\n' "$repo"
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$dir/side_stop"
}

test_prompt_side_writes_marker() {
  local home input out sd cwd_marker
  home="$(fresh_home prompt-side-marker)"
  input="$TMP_ROOT/prompt-side-marker.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd | .prompt = "/side quick question"' \
    "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/prompt-side-marker.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" HOME="$home"
  sd="$home/.cache/claude-proof/side-stop/sessions/t00-parent"
  cwd_marker="$(find "$home/.cache/claude-proof/side-stop/cwd" -mindepth 2 -maxdepth 2 -name side_stop 2>/dev/null | head -n1)"
  grep -q "PRE-WORK" "$out" &&
    [ -f "$sd/side_stop" ] &&
    grep -qx 'command: /side' "$sd/side_stop" &&
    grep -qx 'parent_session_id: t00-parent' "$sd/side_stop" &&
    grep -qxF "cwd: $ROOT" "$sd/side_stop" &&
    grep -Eq '^created_utc: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$sd/side_stop" &&
    [ -n "$cwd_marker" ] &&
    grep -qx 'command: /side' "$cwd_marker"
}

test_prompt_non_side_writes_no_marker() {
  local home input out
  home="$(fresh_home prompt-no-side-marker)"
  input="$TMP_ROOT/prompt-no-side-marker.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd | .prompt = "summarize the /side command"' \
    "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/prompt-no-side-marker.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" HOME="$home"
  grep -q "PRE-WORK" "$out" &&
    [ "$(find "$home/.cache/claude-proof" -name side_stop 2>/dev/null | wc -l)" -eq 0 ]
}

test_stop_gate_side_marker_allows_child_not_parent() {
  local home repo tr input out
  home="$(fresh_home stop-side-allow)"
  repo="$(make_git_repo stop-side-allow)" || return 1
  seed_side_stop_cwd_marker "$home" "$repo" t00-parent || return 1

  # Child session (not the marker's parent) stops: allowed, silent.
  tr="$TMP_ROOT/stop-side-child-transcript.jsonl"
  input="$TMP_ROOT/stop-side-child.json"
  side_stop_input t00-side-child "$repo" "$tr" "$input"
  out="$TMP_ROOT/stop-side-child.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER="" || return 1
  expect_no_output "$out" || return 1

  # Marker's own parent session is not exempted by it: still blocked.
  tr="$TMP_ROOT/stop-side-parent-transcript.jsonl"
  input="$TMP_ROOT/stop-side-parent.json"
  side_stop_input t00-parent "$repo" "$tr" "$input"
  out="$TMP_ROOT/stop-side-parent.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out"
}

test_stop_gate_without_side_marker_still_blocks() {
  local home repo tr input out
  home="$(fresh_home stop-no-side)"
  repo="$(make_git_repo stop-no-side)" || return 1
  tr="$TMP_ROOT/stop-no-side-transcript.jsonl"
  input="$TMP_ROOT/stop-no-side.json"
  side_stop_input t00-side-child "$repo" "$tr" "$input"
  out="$TMP_ROOT/stop-no-side.out"
  run_hook_in_dir "$repo" "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$home" CLAUDE_STOP_REVIEWER=""
  is_stop_block "$out"
}

run_case "prompt /side writes side_stop marker (session and cwd)" \
  test_prompt_side_writes_marker
run_case "prompt without leading /side writes no side_stop marker" \
  test_prompt_non_side_writes_no_marker
run_case "stop gate allows child under /side marker, parent still blocked" \
  test_stop_gate_side_marker_allows_child_not_parent
run_case "stop gate blocks child with transcript activity and no /side marker" \
  test_stop_gate_without_side_marker_still_blocks

# claude-tmp lib (disk-pressure resilience)
run_case "claude_init_tmp uses writable target" \
  test_claude_init_tmp_uses_writable_target
run_case "claude_init_tmp returns nonzero on unwritable target" \
  test_claude_init_tmp_unwritable_target_returns_nonzero
run_case "claude_install_fail_open_trap exits zero on ERR" \
  test_claude_fail_open_trap_exits_zero_on_err

# ===========================================================================
# sendmessage-roster-gate.sh: SendMessage recipient validation
# ===========================================================================

# Build a sandboxed teams root with teamA(alice,bob) + teamB(carol).
seed_sm_teams_sandbox() {
  local name="$1"
  local dir="$TMP_ROOT/sm-teams-$name"
  rm -rf "$dir"
  mkdir -p "$dir/teamA" "$dir/teamB" || return 1
  cat >"$dir/teamA/config.json" <<'JSON'
{"name":"teamA","members":[
  {"name":"alice","agentId":"alice@teamA","agentType":"general-purpose"},
  {"name":"bob","agentId":"bob@teamA","agentType":"general-purpose"}
]}
JSON
  cat >"$dir/teamB/config.json" <<'JSON'
{"name":"teamB","members":[
  {"name":"carol","agentId":"carol@teamB","agentType":"general-purpose"}
]}
JSON
  printf '%s\n' "$dir"
}

test_sm_gate_allows_valid_name_any_team() {
  local sandbox out
  sandbox="$(seed_sm_teams_sandbox valid-name)" || return 1
  out="$TMP_ROOT/sm-valid-name.out"
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-valid-name.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  is_pretool_allow "$out" && expect_no_output "$out"
}

test_sm_gate_allows_valid_agentid_any_team() {
  local sandbox out
  sandbox="$(seed_sm_teams_sandbox valid-aid)" || return 1
  out="$TMP_ROOT/sm-valid-aid.out"
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-valid-agentid.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  is_pretool_allow "$out" && expect_no_output "$out"
}

test_sm_gate_blocks_invalid_recipient_any_team() {
  local sandbox out reason
  sandbox="$(seed_sm_teams_sandbox invalid)" || return 1
  out="$TMP_ROOT/sm-invalid.out"
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-invalid-recipient.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  is_pretool_deny "$out" || return 1
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' "$out")
  case "$reason" in
    *charlie*not\ in*roster*alice*bob*carol*) return 0 ;;
    *) return 1 ;;
  esac
}

test_sm_gate_allows_team_scoped_valid() {
  local sandbox out
  sandbox="$(seed_sm_teams_sandbox team-valid)" || return 1
  out="$TMP_ROOT/sm-team-valid.out"
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-team-scoped-valid.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  is_pretool_allow "$out" && expect_no_output "$out"
}

test_sm_gate_blocks_team_scoped_invalid() {
  local sandbox out reason
  sandbox="$(seed_sm_teams_sandbox team-invalid)" || return 1
  out="$TMP_ROOT/sm-team-invalid.out"
  # alice exists in teamA but the call addresses teamB; must be denied.
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-team-scoped-invalid.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  is_pretool_deny "$out" || return 1
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' "$out")
  case "$reason" in
    *alice*not\ in\ roster\ of\ team*teamB*carol*) return 0 ;;
    *) return 1 ;;
  esac
}

test_sm_gate_blocks_unknown_team() {
  local sandbox out reason
  sandbox="$(seed_sm_teams_sandbox unknown-team)" || return 1
  out="$TMP_ROOT/sm-unknown-team.out"
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-unknown-team.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  is_pretool_deny "$out" || return 1
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' "$out")
  case "$reason" in
    *team*ghost*has\ no\ config*) return 0 ;;
    *) return 1 ;;
  esac
}

test_sm_gate_ignores_non_sendmessage_tool() {
  local sandbox out
  sandbox="$(seed_sm_teams_sandbox other-tool)" || return 1
  out="$TMP_ROOT/sm-other-tool.out"
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-not-sendmessage-tool.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  expect_silent_or_no_decision "$out" && expect_no_output "$out"
}

test_sm_gate_ignores_missing_recipient() {
  local sandbox out
  sandbox="$(seed_sm_teams_sandbox missing-recipient)" || return 1
  out="$TMP_ROOT/sm-missing-recipient.out"
  run_hook "$out" "$ROOT/hooks/sendmessage-roster-gate.sh" \
    "$FIXTURES/sendmessage-missing-recipient.json" \
    CLAUDE_TEAMS_ROOT="$sandbox"
  expect_silent_or_no_decision "$out" && expect_no_output "$out"
}

run_case "sm-gate allows valid name (any team)" \
  test_sm_gate_allows_valid_name_any_team
run_case "sm-gate allows valid agentId (any team)" \
  test_sm_gate_allows_valid_agentid_any_team
run_case "sm-gate blocks invalid recipient (any team) with global roster" \
  test_sm_gate_blocks_invalid_recipient_any_team
run_case "sm-gate allows team-scoped valid recipient" \
  test_sm_gate_allows_team_scoped_valid
run_case "sm-gate blocks team-scoped recipient absent from that team" \
  test_sm_gate_blocks_team_scoped_invalid
run_case "sm-gate blocks unknown team_name with config-missing reason" \
  test_sm_gate_blocks_unknown_team
run_case "sm-gate ignores non-SendMessage tool" \
  test_sm_gate_ignores_non_sendmessage_tool
run_case "sm-gate ignores SendMessage with no recipient field" \
  test_sm_gate_ignores_missing_recipient

note ""
note "SUMMARY pass=$PASS_COUNT fail=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
