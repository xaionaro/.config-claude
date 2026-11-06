#!/usr/bin/env bash
# Standalone tests for the Claude first-tool-call admission reviewer.
# Drives the real shim -> controller -> worker chain against a local mock
# reviewer. The admitted prompt comes only from the writer's capture (no
# transcript fallback, codex parity). HOOK_ROOT overrides the hooks directory
# under test (used for the deliberate-mutation check). Every case asserts the
# positive effect and the absence of the bad effect.

set -uo pipefail

HOOK_ROOT="${HOOK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHIM="$HOOK_ROOT/edit-bash-pre-reviewer.sh"
WRITER="$HOOK_ROOT/pre-reviewer-prompt-capture.sh"
WORKER="$HOOK_ROOT/lib/edit-bash-pre-reviewer-worker.sh"
WORK="$(mktemp -d "$HOME/tmp/edit-pre-reviewer-test.XXXXXX")"
HOME_DIR="$WORK/home"
PROOF_DIR="$WORK/proof"
MOCK_DIR="$WORK/mock"
MOCK_PID=""
PASS=0
FAIL=0
DENY_VERDICT='{"verdict":"deny","reason":"Load debugging-discipline before editing."}'
ALLOW_VERDICT='{"verdict":"allow","reason":"Trivial lookup."}'

cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  [ -n "$MOCK_PID" ] && wait "$MOCK_PID" 2>/dev/null
  if [ "${KEEP_WORK:-0}" = 1 ]; then
    printf 'work kept: %s\n' "$WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/.claude/projects/proj" "$PROOF_DIR" "$MOCK_DIR"

cat >"$WORK/mock_server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        with open(STATE / "requests.jsonl", "ab") as log:
            log.write(json.dumps(body.decode("utf-8")).encode() + b"\n")
        out = json.dumps({"message": {"content": (STATE / "verdict").read_text()}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(STATE / "port").write_text(str(server.server_address[1]))
server.serve_forever()
PY
/usr/bin/python3 "$WORK/mock_server.py" "$MOCK_DIR" &
MOCK_PID=$!
for _ in $(seq 1 100); do
  [ -s "$MOCK_DIR/port" ] && break
  sleep 0.05
done
[ -s "$MOCK_DIR/port" ] || { echo "mock reviewer did not start" >&2; exit 1; }
MOCK_URL="ollama:http://127.0.0.1:$(cat "$MOCK_DIR/port"):mock-model"

assert_eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf 'ok   - %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL - %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
}

set_verdict() {
  printf '%s' "$1" >"$MOCK_DIR/verdict"
}

request_count() {
  if [ -f "$MOCK_DIR/requests.jsonl" ]; then
    wc -l <"$MOCK_DIR/requests.jsonl" | tr -d ' '
  else
    echo 0
  fi
}

last_user_message() {
  tail -n1 "$MOCK_DIR/requests.jsonl" | jq -r 'fromjson | .messages[1].content'
}

# run_shim <input-json> [opt-in value | unset]; sets OUT and RC.
run_shim() {
  local input="$1" optin="${2-$MOCK_URL}"
  if [ "$optin" = unset ]; then
    OUT=$(env -i PATH=/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
      bash "$SHIM" <<<"$input")
  else
    OUT=$(env -i PATH=/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
      CLAUDE_EDIT_PRE_REVIEWER="$optin" bash "$SHIM" <<<"$input")
  fi
  RC=$?
}

decision_of() {
  printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}

# write_transcript <session> <prompt_id> <prompt text>; prints the transcript path.
write_transcript() {
  local file="$HOME_DIR/.claude/projects/proj/$1.jsonl"
  printf '%s\n' '{"type":"mode","mode":"normal"}' >"$file"
  jq -cn --arg p "$2" --arg t "$3" \
    '{type:"user",promptId:$p,origin:{kind:"human"},message:{role:"user",content:$t}}' >>"$file"
  printf '%s\n' "$file"
}

# write_capture <session> <prompt_id> <prompt text>: runs the UserPromptSubmit writer.
write_capture() {
  jq -cn --arg s "$1" --arg p "$2" --arg t "$3" \
    '{session_id:$s,prompt_id:$p,prompt:$t,cwd:"/work/proj",hook_event_name:"UserPromptSubmit"}' |
    env -i PATH=/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
      CLAUDE_EDIT_PRE_REVIEWER="$MOCK_URL" bash "$WRITER"
}

# The reader's key: sha256 of the JSON-encoded turn id, computed independently here.
turn_key() {
  printf '%s' "\"$1\"" | sha256sum | cut -d' ' -f1
}

capture_file() { # session prompt_id
  printf '%s/pre-reviewer/%s/capture-turn-%s.json\n' "$PROOF_DIR" "$1" "$(turn_key "$2")"
}

# hook_json <session> <prompt_id> <tool_name> <tool_input_json> <transcript_path> [extra_json]
hook_json() {
  local extra="${6:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg s "$1" --arg p "$2" --arg tn "$3" --argjson ti "$4" --arg tp "$5" \
    --argjson extra "$extra" \
    '{session_id:$s,prompt_id:$p,cwd:"/work/proj",transcript_path:$tp,
      hook_event_name:"PreToolUse",tool_name:$tn,tool_input:$ti,tool_use_id:"tu-1"} + $extra'
}

PROMPT='Fix the parser bug in lib/parse.go and add a regression test'
GO_TEST='{"command":"go test ./..."}'

# 1. Opt-in unset: inert. No output, rc 0, no reviewer call, no state written.
set_verdict "$DENY_VERDICT"
S=sess-unset P=turn-unset
F=$(write_transcript "$S" "$P" "$PROMPT")
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")" unset
assert_eq "opt-in unset: rc 0" 0 "$RC"
assert_eq "opt-in unset: no output" "" "$OUT"
assert_eq "opt-in unset: no reviewer request" "$before" "$(request_count)"
assert_eq "opt-in unset: no state dir created" no "$([ -e "$PROOF_DIR/pre-reviewer/$S" ] && echo yes || echo no)"

# 1b. Worker run directly with the opt-in unset (the shim is bypassed): still no state dir.
S=sess-unset-worker P=turn-unset-worker
F=$(write_transcript "$S" "$P" "$PROMPT")
hook_json "$S" "$P" Bash "$GO_TEST" "$F" >"$WORK/unset-worker.json"
OUT=$(env -i PATH=/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
  bash "$WORKER" <"$WORK/unset-worker.json" 2>/dev/null)
RC=$?
assert_eq "worker, opt-in unset: rc 0" 0 "$RC"
assert_eq "worker, opt-in unset: no output" "" "$OUT"
assert_eq "worker, opt-in unset: no state dir created" no \
  "$([ -e "$PROOF_DIR/pre-reviewer/$S" ] && echo yes || echo no)"

# 2. Opt-in set, mock allow: allow (no decision output); reviewer saw the admitted prompt.
set_verdict "$ALLOW_VERDICT"
S=sess-allow P=turn-allow
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "allow: rc 0" 0 "$RC"
assert_eq "allow: no decision output" "" "$OUT"
assert_eq "allow: exactly one reviewer request" "$((before + 1))" "$(request_count)"
assert_eq "allow: reviewer saw admitted prompt" yes \
  "$([[ "$(last_user_message)" == *"LAST USER MESSAGE:"*"Fix the parser bug"* ]] && echo yes || echo no)"
assert_eq "allow: reviewer saw tool input" yes \
  "$([[ "$(last_user_message)" == *'TOOL INPUT: {"command":"go test ./..."}'* ]] && echo yes || echo no)"

# 3. Opt-in set, mock deny: deny with the reviewer reason.
set_verdict "$DENY_VERDICT"
S=sess-deny P=turn-deny
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "deny: rc 0" 0 "$RC"
assert_eq "deny: permissionDecision is deny" deny "$(decision_of)"
assert_eq "deny: hookEventName is PreToolUse" PreToolUse \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
assert_eq "deny: reason carries reviewer reason" yes \
  "$([[ "$OUT" == *"Load debugging-discipline before editing."* ]] && echo yes || echo no)"
assert_eq "deny: exactly one reviewer request" "$((before + 1))" "$(request_count)"

# 4. Second tool call of the same turn is not reviewed again (claim suppresses).
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Edit '{"file_path":"/work/proj/lib/parse.go","old_string":"a","new_string":"b"}' "$F")"
assert_eq "same turn second call: no output" "" "$OUT"
assert_eq "same turn second call: no reviewer request" "$before" "$(request_count)"

# 5. Malformed or out-of-scope input: no output, rc 0, no reviewer call.
set_verdict "$DENY_VERDICT"
before=$(request_count)
run_shim 'not json'
assert_eq "malformed non-JSON: rc 0" 0 "$RC"
assert_eq "malformed non-JSON: no output" "" "$OUT"
run_shim '{}'
assert_eq "empty object: no output" "" "$OUT"
S=sess-read P=turn-read
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
run_shim "$(hook_json "$S" "$P" Read '{"file_path":"/x"}' "$F")"
assert_eq "non-gated tool Read: no output" "" "$OUT"
assert_eq "malformed and out-of-scope: no reviewer request" "$before" "$(request_count)"

# 6. Bypass marker in the pre-reviewer state dir disables review (and its absence enables it).
S=sess-bypass-off P=turn-bypass-off
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "no bypass marker: deny" deny "$(decision_of)"
S=sess-bypass-on P=turn-bypass-on
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
mkdir -p "$PROOF_DIR/pre-reviewer/$S"
: >"$PROOF_DIR/pre-reviewer/$S/bypass"
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "bypass marker present: no output" "" "$OUT"
assert_eq "bypass marker present: no reviewer request" "$before" "$(request_count)"

# 7. A touch of the bypass path is allowed through without review.
S=sess-touch P=turn-touch
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "{\"command\":\"touch $PROOF_DIR/pre-reviewer/$S/bypass\"}" "$F")"
assert_eq "touch bypass command: no output" "" "$OUT"
assert_eq "touch bypass command: no reviewer request" "$before" "$(request_count)"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "after touch of bypass path (no marker written): normal command reviewed" deny "$(decision_of)"

# 8. Subagent calls (agent_id present) are not reviewed; the main thread with the same input is.
S=sess-sub P=turn-sub
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F" '{"agent_id":"agent-1","agent_type":"Explore"}')"
assert_eq "subagent call (agent_id): no output" "" "$OUT"
assert_eq "subagent call (agent_id): no reviewer request" "$before" "$(request_count)"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "main-agent call with same input: deny" deny "$(decision_of)"

# 9. Main thread started with --agent: agent_type set, no agent_id. Docs: agent_type is
# present for --agent sessions too, so this is NOT a subagent and must be reviewed.
S=sess-main-agent P=turn-main-agent
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F" '{"agent_type":"general-purpose"}')"
assert_eq "main thread with agent_type, no agent_id: deny" deny "$(decision_of)"

# 10. No capture: no review and no deny, even when the transcript holds the prompt (no fallback).
S=sess-nocap P=turn-nocap
F=$(write_transcript "$S" "$P" "$PROMPT")
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "no capture, transcript matches: no output" "" "$OUT"
assert_eq "no capture, transcript matches: no reviewer request" "$before" "$(request_count)"

# 11. Capture present: the capture supplies the prompt. A lagging or foreign transcript does not matter.
S=sess-lag P=turn-lag
F=$(write_transcript "$S" "turn-older" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "capture present, transcript promptId lags: deny" deny "$(decision_of)"
S=sess-foreign P=turn-foreign
write_capture "$S" "$P" "$PROMPT"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" /etc/passwd)"
assert_eq "capture present, transcript outside projects root: deny" deny "$(decision_of)"

# 12. Prompt over the 64 KiB admission budget is refused by the writer: no capture, no review.
S=sess-big P=turn-big
big=$(head -c 70000 /dev/zero | tr '\0' a)
F=$(write_transcript "$S" "$P" "$big")
write_capture "$S" "$P" "$big"
before=$(request_count)
assert_eq "oversized prompt: writer stores no capture" no \
  "$([ -e "$(capture_file "$S" "$P")" ] && echo yes || echo no)"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "oversized prompt: no output" "" "$OUT"
assert_eq "oversized prompt: no reviewer request" "$before" "$(request_count)"

# 13. Unsupported or malformed opt-in value: no review.
S=sess-env P=turn-env
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")" claude
assert_eq "unsupported backend 'claude': no output" "" "$OUT"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")" "ollama:bad"
assert_eq "malformed backend spec: no output" "" "$OUT"
assert_eq "invalid opt-in values: no reviewer request" "$before" "$(request_count)"

# 14. A capture stored under this turn's key but carrying another turn_id is rejected by the
# validator and must not be reviewed.
S=sess-mismatch
write_capture "$S" turn-x "$PROMPT"
cp -- "$(capture_file "$S" turn-x)" "$(capture_file "$S" turn-y)"
F=$(write_transcript "$S" turn-y "$PROMPT")
before=$(request_count)
run_shim "$(hook_json "$S" turn-y Bash "$GO_TEST" "$F")"
assert_eq "capture with another turn_id: no output" "" "$OUT"
assert_eq "capture with another turn_id: no reviewer request" "$before" "$(request_count)"

# 15. Secret in the Bash command is redacted before the reviewer request is sent.
S=sess-redact P=turn-redact
F=$(write_transcript "$S" "$P" "$PROMPT")
write_capture "$S" "$P" "$PROMPT"
secret_input=$(jq -cn '{command:"API_KEY=hunter2hunter2 go test ./..."}')
run_shim "$(hook_json "$S" "$P" Bash "$secret_input" "$F")"
assert_eq "secret command: deny (reviewed)" deny "$(decision_of)"
assert_eq "tool_input secret redacted in reviewer request body: secret absent" no \
  "$([[ "$(last_user_message)" == *hunter2* ]] && echo yes || echo no)"
assert_eq "tool_input secret redacted in reviewer request body: marker present" yes \
  "$([[ "$(last_user_message)" == *"[REDACTED]"* ]] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
