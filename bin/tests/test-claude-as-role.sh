#!/bin/bash
# Tests for claude-as-role wrapper.
#
# Stubs the underlying ~/.claude/bin/claude with a script that prints
# CLAUDE_ROLE + argv, so we can verify the wrapper sets env and forwards
# args correctly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/../claude-as-role"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Stub HOME with a fake claude that echoes env+args.
TEST_HOME="$TMPROOT/home"
mkdir -p "$TEST_HOME/.claude/bin"
cat > "$TEST_HOME/.claude/bin/claude" <<'STUB'
#!/bin/bash
echo "ROLE=${CLAUDE_ROLE:-<unset>}"
echo "ARGV=$*"
STUB
chmod +x "$TEST_HOME/.claude/bin/claude"

PASS=0
FAIL=0

assert() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS  $name"; PASS=$((PASS + 1))
  else
    echo "FAIL  $name"; echo "  expected: $expected"; echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# 1. No args -> usage to stderr, exit 2
out=$(env -u CLAUDE_ROLE HOME="$TEST_HOME" PATH="$PATH" "$WRAPPER" 2>&1 >/dev/null)
rc=$?
assert "no args exits 2" "2" "$rc"
case "$out" in
  *"usage: claude-as-role"*) echo "PASS  no args usage line"; PASS=$((PASS + 1));;
  *) echo "FAIL  no args usage line — got: $out"; FAIL=$((FAIL + 1));;
esac

# 2. Unknown role -> error to stderr, exit 2
out=$(env -u CLAUDE_ROLE HOME="$TEST_HOME" PATH="$PATH" "$WRAPPER" bogus 2>&1 >/dev/null)
rc=$?
assert "bogus role exits 2" "2" "$rc"
case "$out" in
  *"unknown role 'bogus'"*) echo "PASS  bogus role error line"; PASS=$((PASS + 1));;
  *) echo "FAIL  bogus role error line — got: $out"; FAIL=$((FAIL + 1));;
esac

# 3. Valid role -> env propagates, args forward, rc=0
out=$(env -u CLAUDE_ROLE HOME="$TEST_HOME" PATH="$PATH" "$WRAPPER" reviewer --foo bar 2>&1)
rc=$?
assert "reviewer rc=0" "0" "$rc"
assert "reviewer env propagated" "ROLE=reviewer" "$(echo "$out" | head -1)"
assert "reviewer args forwarded" "ARGV=--foo bar" "$(echo "$out" | tail -1)"

# 4. eci-implementer (canonical role with hyphen) -> propagates as-is
out=$(env -u CLAUDE_ROLE HOME="$TEST_HOME" PATH="$PATH" "$WRAPPER" eci-implementer 2>&1)
assert "eci-implementer env" "ROLE=eci-implementer" "$(echo "$out" | head -1)"

# 5. Caller's own CLAUDE_ROLE is overridden by the role arg
out=$(CLAUDE_ROLE=lead HOME="$TEST_HOME" PATH="$PATH" "$WRAPPER" verifier 2>&1)
assert "wrapper overrides inherited env" "ROLE=verifier" "$(echo "$out" | head -1)"

echo
echo "TOTAL: $((PASS + FAIL))  PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
