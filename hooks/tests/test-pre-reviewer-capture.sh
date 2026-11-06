#!/usr/bin/env bash
# Standalone tests for the Claude pre-reviewer prompt capture.
# (a) writer output, and the validator contract the reader relies on
# (b) worker with a capture present, including a lagging transcript
# (c) malformed writer input: exit 0, no output, no state written
# (d) worker with the capture absent
# HOOK_ROOT overrides the hooks directory under test (deliberate-mutation check).
# Every case asserts the positive effect and the absence of the bad effect.

set -uo pipefail

HOOK_ROOT="${HOOK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WRITER="$HOOK_ROOT/pre-reviewer-prompt-capture.sh"
SHIM="$HOOK_ROOT/edit-bash-pre-reviewer.sh"
VALIDATOR="$HOOK_ROOT/lib/turn_capture_validator.py"
WORK="$(mktemp -d "$HOME/tmp/pre-reviewer-capture-test.XXXXXX")"
HOME_DIR="$WORK/home"
PROOF_DIR="$WORK/proof"
MOCK_DIR="$WORK/mock"
MOCK_PID=""
PASS=0
FAIL=0
CWD=/work/proj
PROMPT='Fix the parser bug in lib/parse.go and add a regression test'
DENY_VERDICT='{"verdict":"deny","reason":"Load debugging-discipline before editing."}'

cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  [ -n "$MOCK_PID" ] && wait "$MOCK_PID" 2>/dev/null
  rm -rf -- "$WORK"
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
printf '%s' "$DENY_VERDICT" >"$MOCK_DIR/verdict"

assert_eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf 'ok   - %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL - %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
}

request_count() {
  if [ -f "$MOCK_DIR/requests.jsonl" ]; then
    wc -l <"$MOCK_DIR/requests.jsonl" | tr -d ' '
  else
    echo 0
  fi
}

# Hook input for UserPromptSubmit, as Claude Code sends it (prompt_id is documented).
user_prompt_json() { # session prompt_id prompt
  jq -cn --arg s "$1" --arg p "$2" --arg t "$3" --arg c "$CWD" \
    --arg tp "$HOME_DIR/.claude/projects/proj/$1.jsonl" \
    '{session_id:$s, prompt_id:$p, prompt:$t, cwd:$c, transcript_path:$tp,
      hook_event_name:"UserPromptSubmit"}'
}

# Hook input for the PreToolUse Bash call of a turn. Reader side.
pre_tool_json() { # session prompt_id command
  jq -cn --arg s "$1" --arg p "$2" --arg c "$CWD" --arg cmd "$3" \
    --arg tp "$HOME_DIR/.claude/projects/proj/$1.jsonl" \
    '{session_id:$s, prompt_id:$p, cwd:$c, transcript_path:$tp,
      hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$cmd},
      tool_use_id:"tu-1"}'
}

# Transcript for a session: a mode record, then one human record for $2 if non-empty.
write_transcript() { # session prompt_id(or "") text
  local file="$HOME_DIR/.claude/projects/proj/$1.jsonl"

  printf '%s\n' '{"type":"mode","mode":"normal"}' >"$file"
  [ -n "$2" ] || return 0
  jq -cn --arg p "$2" --arg t "$3" \
    '{type:"user",promptId:$p,origin:{kind:"human"},message:{role:"user",content:$t}}' >>"$file"
}

# run_writer FILE: runs the writer on the raw hook input in FILE with the opt-in set;
# sets OUT and RC.
run_writer() {
  OUT=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
    CLAUDE_EDIT_PRE_REVIEWER="$MOCK_URL" bash "$WRITER" <"$1" 2>&1)
  RC=$?
}

# run_worker FILE: runs the PreToolUse shim with the opt-in set; sets OUT and RC.
run_worker() {
  OUT=$(env -i PATH=/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
    CLAUDE_EDIT_PRE_REVIEWER="$MOCK_URL" bash "$SHIM" <"$1" 2>/dev/null)
  RC=$?
}

# The reader's key: sha256 of the JSON-encoded turn id, computed independently here.
capture_file() { # session prompt_id
  local key
  key="$(printf '%s' "\"$2\"" | sha256sum | cut -d' ' -f1)"
  printf '%s/pre-reviewer/%s/capture-turn-%s.json\n' "$PROOF_DIR" "$1" "$key"
}

stray_temp_count() {
  find "$PROOF_DIR" -name '.capture-turn-*' 2>/dev/null | wc -l | tr -d ' '
}

echo "== (a) writer output and reader contract"
user_prompt_json "sess-a" prompt-a "$PROMPT" >"$WORK/in-a.json"
run_writer "$WORK/in-a.json"
CAP_A="$(capture_file sess-a prompt-a)"
assert_eq "a: writer rc 0" 0 "$RC"
assert_eq "a: writer prints nothing" "" "$OUT"
assert_eq "a: capture exists at the reader's path" 1 "$([ -f "$CAP_A" ] && echo 1 || echo 0)"
assert_eq "a: capture mode 0600" 600 "$(stat -c %a "$CAP_A" 2>/dev/null)"
assert_eq "a: capture JSON is turn_id + prompt" \
  "$(jq -cn --arg p "$PROMPT" '{turn_id:"prompt-a", prompt:$p}')" "$(jq -c . "$CAP_A" 2>/dev/null)"
assert_eq "a: no stray temp files" 0 "$(stray_temp_count)"
assert_eq "a: validator returns the prompt for its turn" "$PROMPT" \
  "$(/usr/bin/python3 "$VALIDATOR" '"prompt-a"' <"$CAP_A" 2>/dev/null)"
/usr/bin/python3 "$VALIDATOR" '"prompt-a"' <"$CAP_A" >/dev/null 2>&1
assert_eq "a: validator rc 0 for its turn" 0 "$?"
/usr/bin/python3 "$VALIDATOR" '"prompt-other"' <"$CAP_A" >/dev/null 2>&1
assert_eq "a: validator rejects another turn" 1 "$?"

user_prompt_json "sess-a" prompt-r "deploy with API_KEY=hunter2hunter2 now" >"$WORK/in-r.json"
run_writer "$WORK/in-r.json"
CAP_R="$(capture_file sess-a prompt-r)"
assert_eq "a-redact: secret absent from capture" 0 "$(grep -c hunter2 "$CAP_R" 2>/dev/null || true)"
assert_eq "a-redact: redaction marker present" 1 "$(grep -c '\[REDACTED\]' "$CAP_R" 2>/dev/null || true)"

LONG="$(head -c 3999 /dev/zero | tr '\0' a)é"
LONG+="x"
jq -cn --arg s sess-a --arg p prompt-l --arg t "$LONG" \
  '{session_id:$s, prompt_id:$p, prompt:$t, hook_event_name:"UserPromptSubmit"}' >"$WORK/in-l.json"
run_writer "$WORK/in-l.json"
CAP_L="$(capture_file sess-a prompt-l)"
assert_eq "a-cap: multibyte char crossing the cap is omitted whole (3999 bytes)" 3999 \
  "$(jq -j .prompt "$CAP_L" 2>/dev/null | LC_ALL=C wc -c | tr -d ' ')"
assert_eq "a-cap: no replacement character" 0 \
  "$(jq -j .prompt "$CAP_L" 2>/dev/null | grep -c $'\xef\xbf\xbd' || true)"

jq -cn '{session_id:"sess-a", prompt_id:"prompt-n", prompt:42, hook_event_name:"UserPromptSubmit"}' \
  >"$WORK/in-n.json"
run_writer "$WORK/in-n.json"
assert_eq "a-nonstring: rc 0" 0 "$RC"
assert_eq "a-nonstring: no capture for a non-string prompt" 0 \
  "$([ -e "$(capture_file sess-a prompt-n)" ] && echo 1 || echo 0)"

echo "== (c) malformed writer input: rc 0, no output, no state"
malformed_case() { # name file
  rm -rf -- "$PROOF_DIR"
  run_writer "$2"
  assert_eq "c: $1 rc 0" 0 "$RC"
  assert_eq "c: $1 no output" "" "$OUT"
  assert_eq "c: $1 no state written" 0 \
    "$(find "$PROOF_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
}
printf 'not json' >"$WORK/c1.json"
malformed_case "not JSON" "$WORK/c1.json"
printf '[{"session_id":"s","prompt_id":"p","prompt":"x"}]' >"$WORK/c2.json"
malformed_case "JSON array" "$WORK/c2.json"
printf '{"session_id":"s","prompt_id":"p","prompt":"a\000b"}' >"$WORK/c3.json"
malformed_case "raw NUL byte" "$WORK/c3.json"
printf '{"session_id":"s","prompt_id":"p","prompt":"\377"}' >"$WORK/c4.json"
malformed_case "invalid UTF-8" "$WORK/c4.json"
jq -cn --arg t "$(head -c 70000 /dev/zero | tr '\0' a)" \
  '{session_id:"s", prompt_id:"p", prompt:$t}' >"$WORK/c5.json"
malformed_case "input over 64 KiB" "$WORK/c5.json"
jq -cn '{session_id:"s", prompt:"x"}' >"$WORK/c6.json"
malformed_case "missing prompt_id" "$WORK/c6.json"
jq -cn '{session_id:"s", prompt_id:"", prompt:"x"}' >"$WORK/c7.json"
malformed_case "empty prompt_id" "$WORK/c7.json"
jq -cn '{session_id:"../escape", prompt_id:"p", prompt:"x"}' >"$WORK/c8.json"
malformed_case "unsafe session_id" "$WORK/c8.json"
jq -cn '{prompt_id:"p", prompt:"x"}' >"$WORK/c9.json"
malformed_case "missing session_id" "$WORK/c9.json"
jq -cn --arg p "$(head -c 5000 /dev/zero | tr '\0' a)" \
  '{session_id:"s", prompt_id:$p, prompt:"x"}' >"$WORK/c10.json"
malformed_case "turn id over 4096 bytes" "$WORK/c10.json"
printf '{"session_id":"s","prompt_id":"p","prompt":"x"}{"a":1}' >"$WORK/c11.json"
malformed_case "two JSON objects" "$WORK/c11.json"
printf '{"session_id":"s","prompt_id":"p","prompt":"\\u0000"}' >"$WORK/c12.json"
malformed_case "JSON-escaped NUL in prompt" "$WORK/c12.json"

echo "== (b) worker with a capture present"
write_transcript sess-b1 prompt-b1 "$PROMPT"
user_prompt_json "sess-b1" prompt-b1 "$PROMPT" >"$WORK/in-b1.json"
run_writer "$WORK/in-b1.json"
pre_tool_json "sess-b1" prompt-b1 "go test ./..." >"$WORK/pre-b1.json"
before=$(request_count)
run_worker "$WORK/pre-b1.json"
assert_eq "b1: transcript matches, capture present: deny emitted" deny \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
assert_eq "b1: transcript matches, capture present: one reviewer request" 1 \
  "$(( $(request_count) - before ))"

# Lagging transcript: the turn's own record is not flushed yet. The capture must
# still supply the admitted prompt, as in the Codex worker.
write_transcript sess-b2 prompt-old "an earlier prompt"
user_prompt_json "sess-b2" prompt-b2 "$PROMPT" >"$WORK/in-b2.json"
run_writer "$WORK/in-b2.json"
pre_tool_json "sess-b2" prompt-b2 "go test ./..." >"$WORK/pre-b2.json"
before=$(request_count)
run_worker "$WORK/pre-b2.json"
assert_eq "b2: lagging transcript, capture present: deny emitted (Codex parity)" deny \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
assert_eq "b2: lagging transcript, capture present: one reviewer request" 1 \
  "$(( $(request_count) - before ))"

echo "== (d) worker with the capture absent"
write_transcript sess-d1 prompt-d1 "$PROMPT"
pre_tool_json "sess-d1" prompt-d1 "go test ./..." >"$WORK/pre-d1.json"
before=$(request_count)
run_worker "$WORK/pre-d1.json"
assert_eq "d1: no capture, transcript matches: deny as before" deny \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
assert_eq "d1: no capture, transcript matches: one reviewer request" 1 \
  "$(( $(request_count) - before ))"
assert_eq "d1: rc 0" 0 "$RC"

pre_tool_json "sess-d2" prompt-d2 "go test ./..." >"$WORK/pre-d2.json"
before=$(request_count)
run_worker "$WORK/pre-d2.json"
assert_eq "d2: no capture, no transcript: rc 0" 0 "$RC"
assert_eq "d2: no capture, no transcript: no output" "" "$OUT"
assert_eq "d2: no capture, no transcript: no reviewer request" 0 \
  "$(( $(request_count) - before ))"

echo "== (f) prune: expired turn state removed, fresh kept"
# Epoch-0 mtime is older than the one-hour retention for any real clock: no flakiness.
STATE_F="$PROOF_DIR/pre-reviewer/sess-f"
mkdir -p "$STATE_F"
printf '{}' >"$STATE_F/capture-turn-stale.json"
touch -d @0 "$STATE_F/capture-turn-stale.json"
printf '{}' >"$STATE_F/capture-turn-fresh.json"
user_prompt_json "sess-f" prompt-f "$PROMPT" >"$WORK/in-f.json"
run_writer "$WORK/in-f.json"
assert_eq "f: writer rc 0" 0 "$RC"
assert_eq "f: expired capture pruned" 0 "$([ -e "$STATE_F/capture-turn-stale.json" ] && echo 1 || echo 0)"
assert_eq "f: fresh capture kept" 1 "$([ -e "$STATE_F/capture-turn-fresh.json" ] && echo 1 || echo 0)"

echo "== (e) default-off: opt-in unset"
rm -rf -- "$PROOF_DIR"
OUT=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
  bash "$WRITER" <"$WORK/in-a.json" 2>&1)
RC=$?
assert_eq "e-writer: opt-in unset rc 0" 0 "$RC"
assert_eq "e-writer: opt-in unset no output" "" "$OUT"
assert_eq "e-writer: opt-in unset writes no state" 0 \
  "$(find "$PROOF_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
before=$(request_count)
pre_tool_json "sess-e" prompt-e "go test ./..." >"$WORK/pre-e.json"
OUT=$(env -i PATH=/usr/bin:/bin HOME="$HOME_DIR" CLAUDE_PROOF_ROOT="$PROOF_DIR" \
  bash "$SHIM" <"$WORK/pre-e.json" 2>/dev/null)
RC=$?
assert_eq "e-reader: opt-in unset rc 0" 0 "$RC"
assert_eq "e-reader: opt-in unset no output" "" "$OUT"
assert_eq "e-reader: opt-in unset no reviewer request" 0 "$(( $(request_count) - before ))"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
