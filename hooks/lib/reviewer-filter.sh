# Shellcheck-friendly library — sourced, never executed.
# shellcheck shell=bash
#
# Shingle filter: drops violations whose `rule` text shares <0.15 3-gram
# word-shingle overlap with the rule corpus (CLAUDE.md + stop-checklist.md
# + MEMORY.md). Catches paraphrase-fabricated rules that don't quote any
# real fragment; preserves true violations that quote even fragments of
# real rule text. If all violations drop, force verdict=pass.
#
# Used by BOTH the production hook (system-prompt-reviewer.sh) and the
# test harness (tests/reviewer/run.sh) so the harness measures the same
# behavior production sees. Single source of truth.
#
# API:
#   filter_violations <result-json-string>
#     stdout: filtered JSON (same shape; verdict may be flipped to "pass")
#     stderr: nothing on success
#     exit  : 0 always; on any internal error the original input is
#             echoed back unchanged so the caller never has to worry
#             about losing data on a bad parse.

# Resolve the rule corpus path once. Override-able via env for tests.
: "${REVIEWER_FILTER_CORPUS_FILES:=$HOME/.claude/CLAUDE.md $HOME/.claude/hooks/stop-checklist.md $HOME/.claude/projects/-home-streaming--claude/memory/MEMORY.md}"

# Shingle overlap threshold. Lower = more permissive (keep more violations).
: "${REVIEWER_FILTER_THRESHOLD:=0.15}"

filter_violations() {
  local result_json=$1
  if [ -z "$result_json" ]; then
    printf '%s' "$result_json"
    return 0
  fi

  # Concatenate the corpus once per call. Missing files silently skipped
  # (cat warns to stderr; redirect to /dev/null).
  local corpus_text
  # shellcheck disable=SC2086 # word-split intentional: paths are space-separated
  corpus_text=$(cat $REVIEWER_FILTER_CORPUS_FILES 2>/dev/null)

  # Pure-Python implementation (python3 verified present in env). On any
  # parse failure or missing python, fall back to the unmodified input.
  local filtered
  filtered=$(printf '%s' "$result_json" | python3 -c '
import sys, json, re
corpus = sys.argv[1].lower()
threshold = float(sys.argv[2])
cw = re.sub(r"\s+", " ", corpus).split()
cg = set(" ".join(cw[i:i+3]) for i in range(len(cw)-2))
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
kept = []
for v in d.get("violations", []) or []:
    rw = re.sub(r"\s+", " ", (v.get("rule") or "").lower()).split()
    rg = set(" ".join(rw[i:i+3]) for i in range(len(rw)-2))
    if rg and len(rg & cg) / len(rg) >= threshold:
        kept.append(v)
d["violations"] = kept
if not kept and d.get("verdict") == "fail":
    d["verdict"] = "pass"
print(json.dumps(d))
' "$corpus_text" "$REVIEWER_FILTER_THRESHOLD" 2>/dev/null)

  if [ -z "$filtered" ]; then
    # Anything went wrong → pass through unchanged. Filter is best-effort.
    printf '%s' "$result_json"
  else
    printf '%s' "$filtered"
  fi
}
