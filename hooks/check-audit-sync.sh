#!/bin/bash
# Detect-tier sync check for the Rule-compliance self-audit section.
# Both stop-verification.md (Step 5) and stop-checklist.md contain the
# same grammar prose and the same sync-comment marker. This script checks
# that the key canonical phrases are present in both, so drift is caught
# before it causes the proof.md gate to accept or reject malformed audits.
#
# Usage:
#   hooks/check-audit-sync.sh          # run directly
#   git diff --cached | hooks/check-audit-sync.sh  # pipe from pre-commit hook
#
# Exit 0 = in sync. Exit 1 = drift detected (prints what drifted).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
VER="$HOOK_DIR/stop-verification.md"
CHK="$HOOK_DIR/stop-checklist.md"

if [ ! -f "$VER" ] || [ ! -f "$CHK" ]; then
  echo "check-audit-sync: one of the files is missing — skipping" >&2
  exit 0
fi

FAIL=0
check_phrase() {
  local phrase="$1"
  local normed_phrase
  normed_phrase=$(printf '%s' "$phrase" | tr -s ' \n\t' ' ' | xargs)
  if ! grep -qF "$phrase" "$VER"; then
    echo "DRIFT: '$phrase' missing from stop-verification.md"
    FAIL=1
  fi
  if ! grep -qF "$phrase" "$CHK"; then
    echo "DRIFT: '$phrase' missing from stop-checklist.md"
    FAIL=1
  fi
}

# --- Canonical phrases that MUST appear in both files ---

# Audit subject (the rule that separates "what agent did" from "what user said")
check_phrase "The audit subject is the written rule"

# Scope (last-turn-only boundary)
check_phrase "the last turn only"

# Form A key syntax
check_phrase "clean-scan: CLAUDE.md"

# Form B key syntax
check_phrase "Violation:"

# Correction required (the two files phrase this slightly differently; use a common substring)
check_phrase "correction marker"

# Both must have the sync comment pointing to the other file
if ! grep -q "Keep in sync" "$VER"; then
  echo "DRIFT: stop-verification.md is missing its '<!-- Keep in sync -->' marker"
  FAIL=1
fi
if ! grep -q "Keep in sync" "$CHK"; then
  echo "DRIFT: stop-checklist.md is missing its '<!-- Keep in sync -->' marker"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "check-audit-sync: OK (6 phrases verified in both files)"
fi
exit "$FAIL"
