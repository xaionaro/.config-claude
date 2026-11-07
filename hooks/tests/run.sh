#!/usr/bin/env bash
# Hook regression test runner. Adapted from /home/streaming/.codex/hooks/tests/run.sh
# with Claude-specific tooling, paths, and the role-exemption matrix.
#
# Many Claude hooks resolve state via $HOME/tmp/agent/proof/ (the default
# claude_configured_proof_root when CLAUDE_PROOF_ROOT is unset). To isolate,
# ported tests run hooks under a fake HOME
# that symlinks .claude -> the real ~/.claude (so hook source paths resolve)
# while ~/tmp/agent/proof lives entirely in the test sandbox.

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

# fresh proof root per test; isolated from the real proof root.
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

# The fake HOME that fresh_home builds for test name $1. Use it to inspect a HOME
# after the run; the layout lives only here.
home_dir_for_test() {
  printf '%s' "$TMP_ROOT/home-$1"
}

# Build an isolated HOME for ported tests. Symlinks .claude → real one so the
# hooks can `source $HOME/.claude/hooks/lib/claude-proof-state.sh`. The fake
# HOME's $HOME/tmp/agent/proof remains entirely test-controlled.
fresh_home() {
  local dir
  dir="$(home_dir_for_test "$1")"
  rm -rf "$dir"
  mkdir -p "$dir/tmp/agent/proof"
  ln -s "$HOME/.claude" "$dir/.claude"
  printf '%s' "$dir"
}

# proof_dir under a fake HOME for a session id (mirrors hook's $HOME/tmp/agent/proof/$SID layout).
proof_dir_in_home() {
  local home="$1" sid="$2"
  local d="$home/tmp/agent/proof/$sid"
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

# Link the published ECI Go runtime (~/tmp/eci-runtime) into fake HOME $1, as
# the Codex suite does. prompt-task-reminder needs its eci-hook-helper.
link_eci_runtime() {
  mkdir -p "$1/tmp" && ln -s "$HOME/tmp/eci-runtime" "$1/tmp/eci-runtime"
}

# Link the real Codex planner root and runtime into fake HOME $1, so that
# validate-bash runs the real eci-command-plan. Never combine with
# make_planner_stub: the stub writes under $1/.codex.
link_real_planner() {
  link_eci_runtime "$1" && ln -s "$HOME/.codex" "$1/.codex"
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
expect_no_output() {
  [ ! -s "$1" ]
}

with_cwd_fixture() {
  local src="$1" dst="$2"
  jq --arg cwd "$ROOT" '.cwd = $cwd' "$src" >"$dst"
}

# write a baseline_head referring to the repo's current HEAD
seed_baseline_head() {
  local proof_dir="$1" repo="$2"
  mkdir -p "$proof_dir"
  git -C "$repo" rev-parse HEAD >"$proof_dir/baseline_head" 2>/dev/null
}

# ===========================================================================
# ORIGINAL 15 TESTS — preserved verbatim from the start-here scaffold.
# ===========================================================================

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
  # Control: the hook does run on submodule paths (a go.mod local replace inside
  # one is still denied).
  jq -n --arg fp "$r/super/sub/go.mod" '{tool_name:"Write",tool_input:{file_path:$fp,content:"replace example.com/m => ../m\n"}}' >"$input"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input"
  if ! { is_pretool_deny "$out" && json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason' "local relative replace"; }; then
    bad="$bad [control: expected go.mod local replace deny inside submodule, out=$(head -c 200 "$out")]"
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
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-ctl-edit.json"
  out="$TMP_ROOT/eci-ctl-edit.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
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
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-ctl-write.json"
  out="$TMP_ROOT/eci-ctl-write.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/goal_state"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_blocks_control_file_multiedit() {
  local home pdir input out
  home="$(eci_active_home eci-ctl-multi)"
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-ctl-multi.json"
  out="$TMP_ROOT/eci-ctl-multi.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"MultiEdit",cwd:$cwd,tool_input:{file_path:$p,edits:[{old_string:"old",new_string:"new"}]}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_blocks_control_file_notebookedit() {
  local home pdir input out
  home="$(eci_active_home eci-ctl-notebook)"
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-ctl-notebook.json"
  out="$TMP_ROOT/eci-ctl-notebook.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$p,new_source:"x = 1"}}' --arg p "$pdir/eci_wait"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

# Basenames on the Codex control list are denied in the proof root.
test_eci_gate_blocks_codex_control_names() {
  local home pdir name input out
  home="$(eci_active_home eci-codex-names)"
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-removed-names.json"
  out="$TMP_ROOT/eci-removed-names.out"
  for name in eci_teammate_pending ate_active task_active skip_stop summary-to-print.md parent_session_id gitleaks-findings.txt git-status-at-accept.txt last-result.md; do
    eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$pdir/$name"
    run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out" || return 1
  done
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$home/tmp/agent/proof/copilot/x.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Claim directories are coordinator-owned recursively (Codex parity).
test_eci_gate_blocks_repair_authorize_claim_descendant() {
  local home pdir input out
  home="$(eci_active_home eci-repair-claim)"
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-repair-claim.json"
  out="$TMP_ROOT/eci-repair-claim.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci-wait-repair-authorize.claim/inner.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_blocks_accidental_override_claim_descendant() {
  local home pdir input out
  home="$(eci_active_home eci-accidental-claim)"
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-accidental-claim.json"
  out="$TMP_ROOT/eci-accidental-claim.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/.eci-accidental-mistake-override.claim/inner.txt"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

# Control check precedes the Markdown allowance: a control .md is denied.
test_eci_gate_blocks_markdown_control_file() {
  local home pdir input out
  home="$(eci_active_home eci-md-ctl)"
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
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
  other="$home/tmp/agent/proof/t01-other"
  input="$TMP_ROOT/eci-other-ledger.json"
  out="$TMP_ROOT/eci-other-ledger.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' --arg p "$other/project-understanding.yaml"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && is_pretool_deny "$out"
}

test_eci_gate_allows_own_session_working_doc() {
  local home pdir input out
  home="$(eci_active_home eci-own-doc)"
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-reserved.json"
  out="$TMP_ROOT/eci-reserved.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$home/tmp/agent/proof/reviewer/nested/state.json"
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
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
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
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/eci-unsafe-sid.json"
  out="$TMP_ROOT/eci-unsafe-sid.out"
  eci_input "$input" '{session_id:"../bad",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" HOME="$home" && expect_no_output "$out"
}

# Missing cwd skips the gate; the same payload with cwd is denied.
test_eci_gate_skips_missing_cwd() {
  local home pdir input out
  home="$(eci_active_home eci-no-cwd)"
  pdir="$home/tmp/agent/proof/t00-session"
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
  reserved="$home/tmp/agent/proof/eci"
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
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_validate_edit_write_blocks_direct_write_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-gomod-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-write.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_validate_edit_write_blocks_direct_multiedit_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-gomod-multi.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-multiedit.json"
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
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

# bash writes a here-string longer than the pipe capacity (64 KiB) to a temp
# file; when that write fails, the redirection fails, the command never runs and
# its variable stays empty. `ulimit -f 32` (KiB, in a subshell) makes that write
# fail for a text over 32 KiB while the small files a hook writes still work.
# (An unwritable or missing TMPDIR does not: bash falls back to /tmp.)
#
# A go.mod Write of about 94 KB whose last line is $2. Args: name last-line
# file-limit(32|unlimited) verdict(deny|allow).
expect_large_gomod_write() {
  local name="$1" last="$2" limit="$3" verdict="$4" home body input out
  home="$(fresh_home "$name")" || return 1
  body="$TMP_ROOT/$name.body"
  awk 'BEGIN { for (i = 0; i < 2000; i++) printf "// filler line %05d of a large go.mod payload\n", i }' >"$body" || return 1
  printf '%s\n' "$last" >>"$body" || return 1
  [ "$(wc -c <"$body")" -gt 70000 ] || return 1
  input="$TMP_ROOT/$name.json"
  jq -n --rawfile content "$body" \
    '{tool_name:"Write",tool_input:{file_path:"sample/go.mod",content:$content}}' >"$input" || return 1
  out="$TMP_ROOT/$name.out"
  ( ulimit -f "$limit" && run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$home" ) || return 1
  case "$verdict" in
  deny)
    is_pretool_deny "$out" &&
      json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
    ;;
  allow) expect_no_output "$out" ;;
  *) return 1 ;;
  esac
}

test_validate_edit_write_denies_large_gomod_replace_when_a_temp_file_cannot_be_written() {
  expect_large_gomod_write edit-big-gomod-deny 'replace example.com/m => ../m' 32 deny
}

test_validate_edit_write_denies_large_gomod_replace_when_a_temp_file_can_be_written() {
  expect_large_gomod_write edit-big-gomod-deny-free 'replace example.com/m => ../m' unlimited deny
}

test_validate_edit_write_allows_large_remote_gomod_replace_when_a_temp_file_cannot_be_written() {
  expect_large_gomod_write edit-big-gomod-allow 'replace example.com/m => example.com/fork v1.0.0' 32 allow
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

# True when hook output file $1 is the subagent-guard deny (verdict deny, reason
# contains "Only the main thread") and the stub planner in HOME $2 never ran, so
# the guard denied before the planner.
subagent_guard_denied() {
  is_pretool_deny "$1" &&
    json_field_contains "$1" '.hookSpecificOutput.permissionDecisionReason // empty' "Only the main thread" &&
    [ ! -e "$2/planner-stdin" ]
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

# Shell activity is recorded by the Codex planner (recordHookActivity), so the
# rows that expect an activity marker run the real planner.
test_validate_bash_marks_shell_activity() {
  local home pdir input out
  home="$(fresh_home bash-marks-shell)"
  link_real_planner "$home" || return 1
  input="$TMP_ROOT/bash-mark.json"
  jq --arg cwd "$ROOT" '.session_id="t00-session" | .cwd=$cwd' "$FIXTURES/validate-bash-go-test-redirect.json" >"$input"
  out="$TMP_ROOT/bash-mark.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$home/tmp/agent/proof/activity/sessions/t00-session/shell" ]
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
    [ ! -e "$home/tmp/agent/proof/activity/sessions/t00-session/shell" ]
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
    [ ! -e "$home/tmp/agent/proof/activity/sessions/t00-session/shell" ]
}

test_validate_bash_marks_redirected_read_shell_activity() {
  local home input out cmd
  home="$(fresh_home bash-readredir)"
  link_real_planner "$home" || return 1
  cmd="sed -n '1,5p' CLAUDE.md > /tmp/claude-read-output.txt"
  input="$TMP_ROOT/bash-readredir.json"
  jq -n --arg cwd "$ROOT" --arg cmd "$cmd" '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-readredir.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$home/tmp/agent/proof/activity/sessions/t00-session/shell" ]
}

# Allow outcome for a write command (make build): the hook prints nothing and the
# stub planner receives the input unchanged. Callers then check the shell-activity
# marker, $home/tmp/agent/proof/activity/sessions/t00-session/shell, which only
# the main thread gets. The hook writes that marker before it calls the planner,
# so the stub does not make marking happen; it shows that nothing denied the
# command first. Args: home name agent_id (empty agent_id is the main thread).
expect_write_command_forwarded() {
  local home="$1" input out
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/$2.json"
  write_bash_input "$input" t00-session "$ROOT" 'make build' "$3"
  out="$TMP_ROOT/$2.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home"
  expect_no_output "$out" && planner_received "$home" "$input"
}

test_validate_bash_subagent_write_command_leaves_no_shell_activity() {
  local home
  home="$(fresh_home bash-subagent-write-marker)" || return 1
  expect_write_command_forwarded "$home" bash-subagent-write-marker sub-uuid &&
    [ ! -e "$home/tmp/agent/proof/activity/sessions/t00-session/shell" ]
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
    subagent_guard_denied "$out" "$home" || return 1
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
  subagent_guard_denied "$out" "$home"
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

# Pins the subagent test of validate-bash (claude_hook_is_subagent_context: the
# input's .agent_id // empty is non-empty) for one shape of the identity fields.
# The command is the disengage text, so the verdict shows in the outcome: a
# subagent is denied before the planner, the main thread is forwarded to it
# unchanged. jq's `//` treats null and false as absent; "" is empty; 0 and any
# non-empty string are present. Args: name verdict(deny|forward) identity-fields-json.
expect_bash_identity_fields_verdict() {
  local home input out
  home="$(fresh_home "$1")" || return 1
  make_planner_stub "$home" || return 1
  input="$TMP_ROOT/$1.json"
  jq -cn --arg cwd "$ROOT" --argjson identity "$3" \
    '{session_id:"t00-session",cwd:$cwd,tool_name:"Bash",tool_input:{command:"~/.claude/bin/eci-active off r.md"}} + $identity' >"$input" || return 1
  out="$TMP_ROOT/$1.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$(fresh_proof_root "$1")"
  case "$2" in
  deny) subagent_guard_denied "$out" "$home" ;;
  forward) expect_no_output "$out" && planner_received "$home" "$input" ;;
  *) return 1 ;;
  esac
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

# Unusable temp dir: validate-bash keeps the hook input in memory and needs no
# temp file, so its guards still run. TMPDIR and CLAUDE_TMPDIR (which
# claude_init_tmp would otherwise turn into $HOME/tmp) sit under a regular file,
# so mktemp fails even for root. The HOME has a stub planner so that "the planner
# ran" is observable. Args: name agent_id command [proof].
run_bash_unstageable() {
  local home input tmpdir proof="${4:-}"
  home="$(fresh_home "$1")" || return 1
  make_planner_stub "$home" || return 1
  : >"$TMP_ROOT/$1.not-a-dir" || return 1
  tmpdir="$TMP_ROOT/$1.not-a-dir/tmp"
  # Precondition: a temp file really cannot be created here.
  ! mktemp "$tmpdir/validate-bash.XXXXXX" >/dev/null 2>&1 || return 1
  input="$TMP_ROOT/$1.json"
  write_bash_input "$input" t00-session "$ROOT" "$3" "$2"
  [ -n "$proof" ] || proof="$(fresh_proof_root "$1")"
  run_hook "$TMP_ROOT/$1.out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$home" \
    CLAUDE_PROOF_ROOT="$proof" TMPDIR="$tmpdir" CLAUDE_TMPDIR="$tmpdir"
}

# Subagent guard on in-memory input: denied, and the planner never runs.
expect_unstageable_subagent_denied() {
  local out="$TMP_ROOT/$1.out"
  run_bash_unstageable "$1" sub-uuid "$2" || return 1
  subagent_guard_denied "$out" "$(home_dir_for_test "$1")"
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
    [ -s "$home/tmp/agent/proof/activity/sessions/t00-session/edit" ]
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
  mkdir -p "$home/tmp/agent/proof/$own_sid"
  printf '%s\n' "$file_parent" >"$home/tmp/agent/proof/$own_sid/parent_session_id"
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
# pass-through a cross-session edit. Build a fake HOME whose name has parens
# (fresh_home "paren (work)"; unescaped parens become an ERE group) and verify
# the deny still fires.
test_validate_edit_write_blocks_other_sid_under_paren_home() {
  local home input out
  home="$(fresh_home "paren (work)")" || return 1
  input="$TMP_ROOT/owner-paren-home.json"
  jq -n --arg path "$home/tmp/agent/proof/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb/foo" \
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

# ---- session-snapshot ----

test_session_snapshot_saves_baseline() {
  local home out
  home="$(fresh_home session-baseline)"
  out="$TMP_ROOT/session-snap.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" HOME="$home"
  json_field_contains "$out" '.hookSpecificOutput.additionalContext // empty' "CLAUDE.md" &&
    [ -s "$home/tmp/agent/proof/t00-session/baseline_head" ]
}

test_session_snapshot_skips_ephemeral_threads() {
  local home out
  home="$(fresh_home session-ephemeral)"
  out="$TMP_ROOT/session-ephem.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start-ephemeral.json" HOME="$home"
  expect_no_output "$out" &&
    [ ! -e "$home/tmp/agent/proof/t00-side/baseline_head" ]
}

test_session_snapshot_clears_legacy_skip_marker() {
  local home pdir out
  home="$(fresh_home session-clears-skip)"
  pdir="$(proof_dir_in_home "$home" t00-session)"
  touch "$pdir/skip_stop"
  out="$TMP_ROOT/session-clears-skip.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" HOME="$home"
  json_field_contains "$out" '.hookSpecificOutput.additionalContext // empty' "CLAUDE.md" &&
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
  json_field_contains "$out" '.hookSpecificOutput.additionalContext // empty' "CLAUDE.md" &&
    grep -q "preserved-head-value" "$pdir/baseline_head"
}

# ---- prompt-task-reminder ----

# prompt-task-reminder prints only the status-report reminder (Codex), so an
# ordinary prompt has no stdout. Its state steps need the eci-hook-helper.
test_prompt_state_records_head_and_clears_bypass() {
  local home rdir out expected
  home="$(fresh_home prompt-head)"
  link_eci_runtime "$home" || return 1
  rdir="$home/tmp/agent/proof/reviewer/t00-session"
  mkdir -p "$rdir"
  touch "$rdir/bypass"
  expected="$(git -C "$ROOT" rev-parse HEAD)"
  out="$TMP_ROOT/prompt-head.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" HOME="$home"
  expect_no_output "$out" &&
    [ -s "$rdir/prompt_head" ] &&
    [ "$(cat "$rdir/prompt_head")" = "$expected" ] &&
    [ ! -e "$rdir/bypass" ]
}

test_prompt_state_skips_state_for_invalid_session() {
  local home out
  home="$(fresh_home prompt-invalid)"
  link_eci_runtime "$home" || return 1
  out="$TMP_ROOT/prompt-invalid.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-invalid-session.json" HOME="$home"
  expect_no_output "$out" &&
    [ "$(find "$home/tmp/agent/proof" -name prompt_head 2>/dev/null | wc -l)" -eq 0 ]
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
    grep -qF "[ECI_TMPDIR_UNWRITABLE]" "$out.err" &&
    grep -qF "target=/no/such/dir/path" "$out.err"
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
    grep -qF "[ECI_HOOK_FAIL_OPEN]" "$out.err" &&
    grep -qF "hook=test-hook," "$out.err"
}

# ===========================================================================
# Run all tests
# ===========================================================================

test_validate_bash_allows_write_to_singular_import_dir
test_validate_edit_write_allows_lookalike_dirnames
test_validate_edit_write_allows_regular_repo_edit
test_validate_edit_write_allows_write_into_submodule_and_its_worktree
test_validate_bash_allows_write_into_submodule

# ECI gate tests
run_case "ECI gate blocks Edit of control file in own proof session" \
  test_eci_gate_blocks_control_file_edit
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
run_case "ECI gate blocks symlink resolving to control file" \
  test_eci_gate_blocks_symlink_to_control_file
run_case "ECI gate skips on unsafe session_id" \
  test_eci_gate_skips_unsafe_session_id
run_case "ECI gate skips on missing cwd, denies same payload with cwd" \
  test_eci_gate_skips_missing_cwd
run_case "ECI gate skips non-Edit/Write/MultiEdit/NotebookEdit tools" \
  test_eci_gate_skips_non_edit_tool

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
run_case "validate-edit-write denies a large go.mod local replace when a temp file cannot be written" \
  test_validate_edit_write_denies_large_gomod_replace_when_a_temp_file_cannot_be_written
run_case "validate-edit-write denies a large go.mod local replace when a temp file can be written" \
  test_validate_edit_write_denies_large_gomod_replace_when_a_temp_file_can_be_written
run_case "validate-edit-write allows a large go.mod remote replace when a temp file cannot be written" \
  test_validate_edit_write_allows_large_remote_gomod_replace_when_a_temp_file_cannot_be_written

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
run_case "validate-bash leaves no shell activity marker for a subagent write command (planner stub)" \
  test_validate_bash_subagent_write_command_leaves_no_shell_activity
run_case "validate-bash blocks subagent eci-active off" \
  test_validate_bash_blocks_subagent_eci_active_off
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
run_case "subagent denied: backslash-newline inside the word off (eci-active o\\<newline>ff r.md)" \
  expect_subagent_bash_denied sub-deny-46 sub-uuid "$(printf 'eci-active o\\\nff r.md')"
run_case "subagent denied: backslash-newline inside the word eci-active (eci-ac\\<newline>tive off r.md)" \
  expect_subagent_bash_denied sub-deny-47 sub-uuid "$(printf 'eci-ac\\\ntive off r.md')"
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
run_case "subagent allowed: backslash-newline inside another word (eci-active st\\<newline>atus joins to status)" \
  expect_bash_forwarded sub-fwd-18 sub-uuid "$(printf '~/.claude/bin/eci-active st\\\natus')"
run_case "subagent predicate pin: no agent_id is the main thread (forwarded)" \
  expect_bash_identity_fields_verdict identity-absent forward '{}'
run_case "subagent predicate pin: agent_id \"\" is the main thread (forwarded)" \
  expect_bash_identity_fields_verdict identity-empty forward '{"agent_id":""}'
run_case "subagent predicate pin: agent_id null is the main thread (forwarded)" \
  expect_bash_identity_fields_verdict identity-null forward '{"agent_id":null}'
run_case "subagent predicate pin: agent_id false is the main thread (forwarded)" \
  expect_bash_identity_fields_verdict identity-false forward '{"agent_id":false}'
run_case "subagent predicate pin: agent_type without agent_id is the main thread (forwarded)" \
  expect_bash_identity_fields_verdict identity-type-only forward '{"agent_type":"general-purpose"}'
run_case "subagent predicate pin: agent_id 0 is a subagent (denied)" \
  expect_bash_identity_fields_verdict identity-zero deny '{"agent_id":0}'
run_case "subagent predicate pin: agent_id \"x\" is a subagent (denied)" \
  expect_bash_identity_fields_verdict identity-string deny '{"agent_id":"x"}'
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
run_case "validate-bash rebuilds missing ECI planner before failing open" \
  test_validate_bash_rebuilds_missing_planner_before_failing_open
run_case "validate-bash forwards stdin without trailing newline byte-exact" \
  test_validate_bash_forwards_stdin_without_trailing_newline
run_case "validate-bash forwards stdin with two trailing newlines byte-exact" \
  test_validate_bash_forwards_stdin_with_two_trailing_newlines
run_case "validate-bash forwards non-JSON stdin unchanged" \
  test_validate_bash_non_json_stdin_is_forwarded_unchanged
run_case "validate-bash in-memory input (cannot stage): subagent eci-active off is denied" \
  expect_unstageable_subagent_denied in-mem-sub-deny 'bash -c "~/.claude/bin/eci-active off r.md"'
test_validate_bash_wrapper_matches_codex_shim

# validate-edit-write activity
run_case "validate-edit-write marks edit activity for main thread" \
  test_validate_edit_write_marks_edit_activity

# validate-edit-write session-file ownership gate
run_case "validate-edit-write allows NotebookEdit on own proof dir" \
  test_validate_edit_write_allows_notebookedit_same_sid_proof
run_case "validate-edit-write blocks NotebookEdit on another session's proof dir" \
  test_validate_edit_write_blocks_notebookedit_other_sid_proof
run_case "validate-edit-write blocks Edit on another session's projects transcript" \
  test_validate_edit_write_blocks_edit_other_sid_projects_transcript
run_case "validate-edit-write blocks Write on protected path with no resolved sid" \
  test_validate_edit_write_blocks_write_missing_sid_on_protected
run_case "validate-edit-write allows unrelated path with no sid" \
  test_validate_edit_write_allows_unrelated_path_no_sid
run_case "validate-edit-write allows Edit on own todos" \
  test_validate_edit_write_allows_edit_same_sid_todos
run_case "validate-edit-write allows Edit on parent session's todos" \
  test_validate_edit_write_allows_edit_parent_sid_todos
run_case "validate-edit-write blocks Edit on a third session's proof dir even when parent is set" \
  test_validate_edit_write_blocks_edit_unrelated_sid_even_with_parent_set
run_case "validate-edit-write blocks Edit when parent_session_id file declares a third session" \
  test_validate_edit_write_blocks_edit_when_file_parent_mismatches
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

# ===========================================================================
# /side stop marker (codex parity): prompt writes it, stop gate honours it.
# ===========================================================================

test_prompt_side_writes_marker() {
  local home input out sd cwd_marker
  home="$(fresh_home prompt-side-marker)"
  link_eci_runtime "$home" || return 1
  input="$TMP_ROOT/prompt-side-marker.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd | .prompt = "/side quick question"' \
    "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/prompt-side-marker.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" HOME="$home"
  sd="$home/tmp/agent/proof/side-stop/sessions/t00-parent"
  cwd_marker="$(find "$home/tmp/agent/proof/side-stop/cwd" -mindepth 2 -maxdepth 2 -name side_stop 2>/dev/null | head -n1)"
  expect_no_output "$out" &&
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
  link_eci_runtime "$home" || return 1
  input="$TMP_ROOT/prompt-no-side-marker.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd | .prompt = "summarize the /side command"' \
    "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/prompt-no-side-marker.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" HOME="$home"
  # prompt_head is the sentinel that the hook reached its /side step.
  expect_no_output "$out" &&
    [ -s "$home/tmp/agent/proof/reviewer/t00-parent/prompt_head" ] &&
    [ "$(find "$home/tmp/agent/proof" -name side_stop 2>/dev/null | wc -l)" -eq 0 ]
}

run_case "prompt /side writes side_stop marker (session and cwd)" \
  test_prompt_side_writes_marker
run_case "prompt without leading /side writes no side_stop marker" \
  test_prompt_non_side_writes_no_marker

# claude-tmp lib (disk-pressure resilience)
run_case "claude_init_tmp uses writable target" \
  test_claude_init_tmp_uses_writable_target
run_case "claude_init_tmp returns nonzero on unwritable target" \
  test_claude_init_tmp_unwritable_target_returns_nonzero
run_case "claude_install_fail_open_trap exits zero on ERR" \
  test_claude_fail_open_trap_exits_zero_on_err

# ---- pretooluse-edit-dispatch.sh (Codex edit dispatch) ----
# The dispatch runs validate-edit-write.sh and eci-active-gate.sh on the same
# input and relays the first well-formed deny; ordinary edits pass silently.
test_edit_dispatch_relays_eci_gate_deny() {
  local home pdir input out
  home="$(eci_active_home dispatch-ctl)"
  pdir="$home/tmp/agent/proof/t00-session"
  input="$TMP_ROOT/dispatch-ctl.json"
  out="$TMP_ROOT/dispatch-ctl.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$pdir/eci_active"
  run_hook "$out" "$ROOT/hooks/pretooluse-edit-dispatch.sh" "$input" HOME="$home" TMPDIR="$home/tmp" &&
    is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "ECI_CONTROL_OWNER_REQUIRED"
}

test_edit_dispatch_allows_ordinary_edit() {
  local home input out
  home="$(fresh_home dispatch-plain)"
  input="$TMP_ROOT/dispatch-plain.json"
  out="$TMP_ROOT/dispatch-plain.out"
  eci_input "$input" '{session_id:"t00-session",tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' --arg p "$home/work/notes.txt"
  run_hook "$out" "$ROOT/hooks/pretooluse-edit-dispatch.sh" "$input" HOME="$home" TMPDIR="$home/tmp" &&
    expect_no_output "$out"
}

run_case "edit dispatch relays the eci-active-gate deny for a control file" \
  test_edit_dispatch_relays_eci_gate_deny
run_case "edit dispatch allows an ordinary edit" \
  test_edit_dispatch_allows_ordinary_edit

note ""
note "SUMMARY pass=$PASS_COUNT fail=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
