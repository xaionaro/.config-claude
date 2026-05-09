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

test_stop_gate_exempts_subagent_with_agent_type() {
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

  if [ "$decision" = "no-decision" ]; then
    pass "stop-gate exempts subagent with agent_type (no agent_id, no CLAUDE_ROLE)"
  else
    fail "stop-gate exempts subagent with agent_type (no agent_id, no CLAUDE_ROLE)" \
         "decision=$decision; expected silent exit. Output: $(head -c 300 "$out")"
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

test_validate_edit_write_blocks_submodule_edit() {
  local repo sub input out decision
  repo="$TMP_ROOT/sup-repo-$$"
  sub="$repo/sub"
  mkdir -p "$repo/.git" "$sub"
  printf 'gitdir: %s/modules/sub\n' "$repo/.git" >"$sub/.git"
  echo "package x" >"$sub/file.go"

  input="$TMP_ROOT/edit-submod.json"
  jq -n --arg fp "$sub/file.go" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"x",new_string:"y"}}' >"$input"
  out="$TMP_ROOT/edit-submod.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "deny" ]; then
    pass "validate-edit-write denies edits inside a git submodule"
  else
    fail "validate-edit-write denies edits inside a git submodule" \
         "decision=$decision; expected deny. Output: $(head -c 300 "$out")"
  fi
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

test_validate_bash_allows_write_into_submodule() {
  # Submodule write blocking is the file-edit tools' job (Edit/Write/MultiEdit
  # via validate-edit-write.sh). Bash is intentionally NOT gated on submodule
  # paths — running scripts/builds inside submodules is a normal workflow.
  local repo sub input out decision
  repo="$TMP_ROOT/sup-repo-bash-$$"
  sub="$repo/sub"
  mkdir -p "$repo/.git" "$sub"
  printf 'gitdir: %s/modules/sub\n' "$repo/.git" >"$sub/.git"

  input="$TMP_ROOT/bash-submod.json"
  jq -n --arg cmd "echo y > $sub/file.go" '{tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-submod.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" != "deny" ]; then
    pass "validate-bash allows writes into a git submodule"
  else
    fail "validate-bash allows writes into a git submodule" \
         "decision=$decision; expected non-deny. Output: $(head -c 300 "$out")"
  fi
}

test_validate_bash_allows_write_to_singular_import_dir() {
  local input out decision
  input="$TMP_ROOT/bash-singular-import.json"
  cat >"$input" <<'EOF'
{"tool_name":"Bash","tool_input":{"command":"echo x > wingout/import/ffstream/main.go"}}
EOF
  out="$TMP_ROOT/bash-singular-import.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" = "no-decision" ]; then
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

# ---- ECI gate (PreToolUse on Edit|Write|MultiEdit) ----

test_eci_gate_blocks_code_edit() {
  local home pdir input out
  home="$(fresh_home eci-code-edit)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  input="$TMP_ROOT/eci-code-edit.json"
  jq -n '{session_id:"t00-session",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/eci-code-edit.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  is_pretool_deny "$out"
}

test_eci_gate_message_mentions_clean_pass_user_closed() {
  local home pdir input out
  home="$(fresh_home eci-msg)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  input="$TMP_ROOT/eci-msg.json"
  jq -n '{session_id:"t00-session",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/eci-msg.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "clean-pass" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "user-closed" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "delegate"
}

test_eci_gate_blocks_code_write() {
  local home pdir input out
  home="$(fresh_home eci-code-write)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  out="$TMP_ROOT/eci-code-write.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-write-code.json" HOME="$home"
  is_pretool_deny "$out"
}

test_eci_gate_blocks_code_multiedit() {
  local home pdir input out
  home="$(fresh_home eci-code-multi)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  out="$TMP_ROOT/eci-code-multi.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-multiedit.json" HOME="$home"
  is_pretool_deny "$out"
}

test_eci_gate_allows_markdown_edit() {
  local home pdir out
  home="$(fresh_home eci-md-edit)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  out="$TMP_ROOT/eci-md-edit.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-edit-markdown.json" HOME="$home"
  expect_no_output "$out"
}

test_eci_gate_allows_markdown_multiedit() {
  local home pdir out
  home="$(fresh_home eci-md-multi)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  out="$TMP_ROOT/eci-md-multi.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-multiedit-markdown.json" HOME="$home"
  expect_no_output "$out"
}

test_eci_gate_allows_markdown_write() {
  local home pdir out
  home="$(fresh_home eci-md-write)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  out="$TMP_ROOT/eci-md-write.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-write-markdown.json" HOME="$home"
  expect_no_output "$out"
}

test_eci_gate_allows_when_no_marker() {
  local home input out
  home="$(fresh_home eci-no-marker)"
  input="$TMP_ROOT/eci-no-marker.json"
  jq -n '{session_id:"t00-session",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/eci-no-marker.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  expect_no_output "$out"
}

test_eci_gate_blocks_role_spoof() {
  local home pdir input out
  home="$(fresh_home eci-role-spoof)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  input="$TMP_ROOT/eci-role-spoof.json"
  jq -n '{session_id:"t00-session",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/eci-role-spoof.out"
  # CLAUDE_ROLE does not bypass the ECI gate (only agent_id/agent_type do).
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" CLAUDE_ROLE="eci-implementer"
  is_pretool_deny "$out"
}

test_eci_gate_allows_subagent_via_agent_id() {
  local home pdir input out
  home="$(fresh_home eci-agent-id)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  input="$TMP_ROOT/eci-agent-id.json"
  jq -n '{session_id:"t00-session",agent_id:"sub-uuid",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/eci-agent-id.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  expect_no_output "$out"
}

test_eci_gate_allows_subagent_via_agent_type() {
  local home pdir input out
  home="$(fresh_home eci-agent-type)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  input="$TMP_ROOT/eci-agent-type.json"
  jq -n '{session_id:"t00-session",agent_type:"general-purpose",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/eci-agent-type.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  expect_no_output "$out"
}

test_eci_gate_skips_unsafe_session_id() {
  local home input out
  home="$(fresh_home eci-unsafe-sid)"
  input="$TMP_ROOT/eci-unsafe-sid.json"
  jq -n '{session_id:"../bad",tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/eci-unsafe-sid.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  expect_no_output "$out"
}

test_eci_gate_skips_non_edit_tool() {
  local home input out
  home="$(fresh_home eci-non-edit)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  input="$TMP_ROOT/eci-non-edit.json"
  jq -n '{session_id:"t00-session",tool_name:"Bash",tool_input:{command:"ls"}}' >"$input"
  out="$TMP_ROOT/eci-non-edit.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home"
  expect_no_output "$out"
}

# Broadening: NotebookEdit must be policed identically to Edit/Write/MultiEdit.
# Pre-fix the gate's tool-case statement excludes NotebookEdit and silently
# exits, bypassing the policy. Post-fix the gate denies just like the others.
test_eci_gate_blocks_code_notebookedit() {
  local home pdir out
  home="$(fresh_home eci-code-notebook)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  printf 'task: test\n' >"$pdir/eci_active"
  out="$TMP_ROOT/eci-code-notebook.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/notebookedit-eci-active-deny.json" HOME="$home"
  is_pretool_deny "$out"
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

test_ate_gate_denies_edits_for_lead() {
  local input out
  input="$TMP_ROOT/ate-lead.json"
  jq -n '{tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-lead.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="lead"
  is_pretool_deny "$out"
}

test_ate_gate_denies_edits_for_coordinator() {
  local input out
  input="$TMP_ROOT/ate-coord.json"
  jq -n '{tool_name:"Edit",tool_input:{file_path:"src/file.go",old_string:"a",new_string:"b"}}' >"$input"
  out="$TMP_ROOT/ate-coord.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$input" CLAUDE_ROLE="coordinator"
  is_pretool_deny "$out"
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

test_validate_bash_allows_redirect_to_vendor_path() {
  local out
  out="$TMP_ROOT/bash-vendor-redir.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-vendor-redirect.json"
  expect_no_output "$out"
}

test_validate_bash_allows_in_place_imports_path() {
  local out
  out="$TMP_ROOT/bash-imports-sed.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-imports-sed.json"
  expect_no_output "$out"
}

test_validate_bash_allows_vendor_test_with_tmp_redirect() {
  local out
  out="$TMP_ROOT/bash-vendor-test.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-vendor-go-test.json"
  expect_no_output "$out"
}

test_validate_bash_blocks_bare_go_test() {
  local out
  out="$TMP_ROOT/bash-go-test-bare.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-bare.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "captured to a file"
}

test_validate_bash_blocks_go_test_count_one() {
  local out
  out="$TMP_ROOT/bash-go-test-count.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-count.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "-count=1"
}

test_validate_bash_allows_redirected_go_test() {
  local out
  out="$TMP_ROOT/bash-go-test-redir.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-redirect.json"
  expect_no_output "$out"
}

test_validate_bash_allows_go_test_tee() {
  local out
  out="$TMP_ROOT/bash-go-test-tee.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-tee.json"
  expect_no_output "$out"
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
  cmd='rg -n "claude-proof|CLAUDE_PROOF_ROOT|proof_dir" . -S'
  input="$TMP_ROOT/bash-readonly.json"
  jq -n --arg cwd "$ROOT" --arg cmd "$cmd" '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-readonly.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" &&
    [ ! -e "$home/.cache/claude-proof/activity/sessions/t00-session/shell" ]
}

test_validate_bash_skips_read_only_shell_chain_activity() {
  local home input out cmd
  home="$(fresh_home bash-readchain)"
  cmd="sed -n '1,90p' hooks/stop-gate.sh && sed -n '360,430p' hooks/stop-gate.sh"
  input="$TMP_ROOT/bash-readchain.json"
  jq -n --arg cwd "$ROOT" --arg cmd "$cmd" '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-readchain.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" &&
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
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Only the main thread"
}

test_validate_bash_allows_main_eci_active_off() {
  local home input out cmd
  home="$(fresh_home bash-main-eci-off)"
  cmd="~/.claude/bin/eci-active off /tmp/eci-disengage.md"
  input="$TMP_ROOT/bash-main-eci-off.json"
  jq -n --arg cwd "$ROOT" --arg cmd "$cmd" \
    '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-main-eci-off.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out"
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
    json_field_contains "$out" '.reason // empty' "ECI is active"
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
test_stop_gate_exempts_subagent_with_agent_type
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
test_validate_edit_write_blocks_submodule_edit
test_validate_edit_write_allows_regular_repo_edit
test_validate_bash_allows_write_into_submodule

# ECI gate tests
run_case "ECI gate blocks code Edit when marker exists" \
  test_eci_gate_blocks_code_edit
run_case "ECI gate message names clean-pass/user-closed teardown" \
  test_eci_gate_message_mentions_clean_pass_user_closed
run_case "ECI gate blocks code Write when marker exists" \
  test_eci_gate_blocks_code_write
run_case "ECI gate blocks code MultiEdit when marker exists" \
  test_eci_gate_blocks_code_multiedit
run_case "ECI gate allows markdown Edit while marker exists" \
  test_eci_gate_allows_markdown_edit
run_case "ECI gate allows markdown MultiEdit while marker exists" \
  test_eci_gate_allows_markdown_multiedit
run_case "ECI gate allows markdown Write while marker exists" \
  test_eci_gate_allows_markdown_write
run_case "ECI gate allows when no marker exists" \
  test_eci_gate_allows_when_no_marker
run_case "ECI gate blocks CLAUDE_ROLE spoof through marker" \
  test_eci_gate_blocks_role_spoof
run_case "ECI gate allows subagent via agent_id" \
  test_eci_gate_allows_subagent_via_agent_id
run_case "ECI gate allows subagent via agent_type" \
  test_eci_gate_allows_subagent_via_agent_type
run_case "ECI gate skips on unsafe session_id" \
  test_eci_gate_skips_unsafe_session_id
run_case "ECI gate skips non-Edit/Write/MultiEdit tools" \
  test_eci_gate_skips_non_edit_tool
run_case "ECI gate blocks code NotebookEdit when marker exists" \
  test_eci_gate_blocks_code_notebookedit
run_case "skill-marker gate blocks NotebookEdit on protected path without marker" \
  test_skill_marker_gate_blocks_notebookedit_without_marker

# ATE orchestrator gate tests
run_case "ATE gate denies edits for lead role" \
  test_ate_gate_denies_edits_for_lead
run_case "ATE gate denies edits for coordinator role" \
  test_ate_gate_denies_edits_for_coordinator
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
run_case "validate-bash allows redirect to vendor paths" \
  test_validate_bash_allows_redirect_to_vendor_path
run_case "validate-bash allows in-place imports paths" \
  test_validate_bash_allows_in_place_imports_path
run_case "validate-bash allows vendor test with tmp redirect" \
  test_validate_bash_allows_vendor_test_with_tmp_redirect
run_case "validate-bash blocks bare go test" \
  test_validate_bash_blocks_bare_go_test
run_case "validate-bash blocks go test -count=1" \
  test_validate_bash_blocks_go_test_count_one
run_case "validate-bash allows redirected go test" \
  test_validate_bash_allows_redirected_go_test
run_case "validate-bash allows go test piped to tee" \
  test_validate_bash_allows_go_test_tee
run_case "validate-bash marks shell activity for write commands" \
  test_validate_bash_marks_shell_activity
run_case "validate-bash skips activity for read-only shell" \
  test_validate_bash_skips_read_only_shell_activity
run_case "validate-bash skips activity for read-only shell chain" \
  test_validate_bash_skips_read_only_shell_chain_activity
run_case "validate-bash marks activity for redirected read shell" \
  test_validate_bash_marks_redirected_read_shell_activity
run_case "validate-bash blocks subagent eci-active off" \
  test_validate_bash_blocks_subagent_eci_active_off
run_case "validate-bash allows main eci-active off" \
  test_validate_bash_allows_main_eci_active_off

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
