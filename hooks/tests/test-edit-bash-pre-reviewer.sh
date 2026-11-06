#!/usr/bin/env bash
# Standalone tests for the Claude first-tool-call admission reviewer.
# Drives the real shim -> controller -> worker chain against a local mock
# reviewer. HOOK_ROOT overrides the hooks directory under test (used for the
# deliberate-mutation check). Every case asserts the positive effect and the
# absence of the bad effect.

set -uo pipefail

HOOK_ROOT="${HOOK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHIM="$HOOK_ROOT/edit-bash-pre-reviewer.sh"
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

# 2. Opt-in set, mock allow: allow (no decision output); reviewer saw the admitted prompt.
set_verdict "$ALLOW_VERDICT"
S=sess-allow P=turn-allow
F=$(write_transcript "$S" "$P" "$PROMPT")
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
run_shim "$(hook_json "$S" "$P" Read '{"file_path":"/x"}' "$F")"
assert_eq "non-gated tool Read: no output" "" "$OUT"
assert_eq "malformed and out-of-scope: no reviewer request" "$before" "$(request_count)"

# 6. Bypass marker in the pre-reviewer state dir disables review (and its absence enables it).
S=sess-bypass-off P=turn-bypass-off
F=$(write_transcript "$S" "$P" "$PROMPT")
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "no bypass marker: deny" deny "$(decision_of)"
S=sess-bypass-on P=turn-bypass-on
F=$(write_transcript "$S" "$P" "$PROMPT")
mkdir -p "$PROOF_DIR/pre-reviewer/$S"
: >"$PROOF_DIR/pre-reviewer/$S/bypass"
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "bypass marker present: no output" "" "$OUT"
assert_eq "bypass marker present: no reviewer request" "$before" "$(request_count)"

# 7. A touch of the bypass path is allowed through without review.
S=sess-touch P=turn-touch
F=$(write_transcript "$S" "$P" "$PROMPT")
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "{\"command\":\"touch $PROOF_DIR/pre-reviewer/$S/bypass\"}" "$F")"
assert_eq "touch bypass command: no output" "" "$OUT"
assert_eq "touch bypass command: no reviewer request" "$before" "$(request_count)"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "after touch of other turn: a normal command is reviewed" deny "$(decision_of)"

# 8. Subagent calls (agent_id present) are not reviewed.
S=sess-sub P=turn-sub
F=$(write_transcript "$S" "$P" "$PROMPT")
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F" '{"agent_id":"agent-1","agent_type":"Explore"}')"
assert_eq "subagent call: no output" "" "$OUT"
assert_eq "subagent call: no reviewer request" "$before" "$(request_count)"
S=sess-main P=turn-main
F=$(write_transcript "$S" "$P" "$PROMPT")
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "main-agent call with same input: deny" deny "$(decision_of)"

# 9. Transcript lagging behind the hook (promptId mismatch) and foreign transcript path: no review.
S=sess-lag P=turn-lag
F=$(write_transcript "$S" "turn-older" "$PROMPT")
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "transcript promptId mismatch: no output" "" "$OUT"
assert_eq "transcript promptId mismatch: no reviewer request" "$before" "$(request_count)"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" /etc/passwd)"
assert_eq "transcript outside projects root: no output" "" "$OUT"
assert_eq "transcript outside projects root: no reviewer request" "$before" "$(request_count)"

# 10. Prompt far back in a long transcript (beyond the first read chunk) is still found.
S=sess-far P=turn-far
F=$(write_transcript "$S" "$P" "$PROMPT")
filler=$(head -c 1000 /dev/zero | tr '\0' x)
for _ in $(seq 1 300); do
  jq -cn --arg f "$filler" \
    '{type:"user",message:{role:"user",content:[{type:"tool_result",content:$f}]}}' >>"$F"
done
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "long transcript: prompt found, deny" deny "$(decision_of)"

# 11. Prompt over the 64 KiB admission budget is not admitted.
S=sess-big P=turn-big
big=$(head -c 70000 /dev/zero | tr '\0' a)
F=$(write_transcript "$S" "$P" "$big")
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")"
assert_eq "oversized prompt: no output" "" "$OUT"
assert_eq "oversized prompt: no reviewer request" "$before" "$(request_count)"

# 12. Unsupported or malformed opt-in value: no review.
S=sess-env P=turn-env
F=$(write_transcript "$S" "$P" "$PROMPT")
before=$(request_count)
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")" claude
assert_eq "unsupported backend 'claude': no output" "" "$OUT"
run_shim "$(hook_json "$S" "$P" Bash "$GO_TEST" "$F")" "ollama:bad"
assert_eq "malformed backend spec: no output" "" "$OUT"
assert_eq "invalid opt-in values: no reviewer request" "$before" "$(request_count)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
