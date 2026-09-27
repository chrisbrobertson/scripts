#!/bin/bash
# test-babysit-review-feedback.sh — recording-stub coverage for
# collect_pr_feedback() in babysit-with-review.sh (QA-TEST-PLAN.md TC-2.10 /
# TC-2.11). No network: gh is a stub on PATH that forwards the script's real
# --json/-q/--jq arguments to the real jq binary against canned fixture JSON,
# so the actual embedded jq filters run, not a bash re-implementation of them.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-with-review.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH; this harness needs it to exercise the real gh --jq filters" >&2
  exit 0
fi
# Resolve jq's absolute path now, before run_feedback() restricts PATH to
# "$TMP/bin:/usr/bin:/bin" for the stubbed subshell — a jq installed elsewhere
# (e.g. Homebrew's /opt/homebrew/bin or /usr/local/bin) would otherwise vanish
# from the stub's PATH even though this preflight check passed.
JQ_BIN=$(command -v jq)

mkdir -p "$TMP/bin"

# ---------- fixtures ----------
# Mirrors the shape gh actually returns for each --json field: pr view wraps
# in {"reviews": [...]} / {"comments": [...]}; gh api returns a bare array.
REVIEWS_JSON='{"reviews":[
  {"author":{"login":"coderabbitai"},"state":"COMMENTED","body":"Looks mostly good, one nit below."},
  {"author":{"login":"codex-bot"},"state":"COMMENTED","body":"**Codex review — PR #7 cycle 1 of 6**\nold codex findings"},
  {"author":{"login":"claude-bot"},"state":"COMMENTED","body":"**Claude review — PR #7 cycle 1 of 6**\nold claude findings"},
  {"author":{"login":"babysit-bot"},"state":"COMMENTED","body":"**babysit-with-review: review cycle bailed — manual review required**\nReason: x"},
  {"author":{"login":"ghost"},"state":"COMMENTED","body":""}
]}'
COMMENTS_JSON='{"comments":[
  {"author":{"login":"human"},"body":"please also rename foo"},
  {"author":{"login":"codex-bot"},"body":"**Codex review — PR #7 cycle 2 of 6**\nself-posted, should be excluded"}
]}'
INLINE_JSON='[
  {"user":{"login":"human"},"path":"a.sh","line":3,"body":"off-by-one here"}
]'

cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
printf 'CALL=gh %s\n' "\$*" >> "\$RECORD"
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
  printf '%s' "\${STUB_OWNER_REPO:-o/r}"
  exit 0
fi
json_field=""; jq_filter=""
args=("\$@")
i=0
while [ "\$i" -lt "\${#args[@]}" ]; do
  case "\${args[\$i]}" in
    --json) json_field="\${args[\$((i+1))]}" ;;
    --jq|-q) jq_filter="\${args[\$((i+1))]}" ;;
  esac
  i=\$((i+1))
done
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  case "\$json_field" in
    reviews) data='$REVIEWS_JSON' ;;
    comments) data='$COMMENTS_JSON' ;;
    *) data='{}' ;;
  esac
  printf '%s' "\$data" | "$JQ_BIN" -r "\$jq_filter"
  exit 0
fi
if [ "\$1" = "api" ]; then
  printf '%s' '$INLINE_JSON' | "$JQ_BIN" -r "\$jq_filter"
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

run_feedback() {
  local out="$1" record="$2"
  : > "$record"
  ( RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" \
      BABYSIT_TEST_MODE=review-feedback TEST_PR_NUM=7 "$SCRIPT" ) > "$out" 2>/dev/null
}

run_feedback "$TMP/feedback.out" "$TMP/feedback.record"

# ---------- TC-2.10: existing CodeRabbit-style feedback is included ----------
assert_grep "TC-2.10 CodeRabbit review body included" "Looks mostly good, one nit below." "$TMP/feedback.out"
assert_grep "TC-2.10 review author attributed" "### Review by coderabbitai [COMMENTED]" "$TMP/feedback.out"
assert_grep "TC-2.10 top-level human comment included" "please also rename foo" "$TMP/feedback.out"
assert_grep "TC-2.10 inline diff comment included" "off-by-one here" "$TMP/feedback.out"
assert_grep "TC-2.10 inline comment attributed with path:line" "### Inline comment by human on a.sh:3" "$TMP/feedback.out"

# ---------- TC-2.11: self-posted Codex/Claude/babysit comments excluded ----------
assert_not_grep "TC-2.11 self-posted Codex review excluded" "old codex findings" "$TMP/feedback.out"
assert_not_grep "TC-2.11 self-posted Claude review excluded" "old claude findings" "$TMP/feedback.out"
assert_not_grep "TC-2.11 self-posted babysit bail comment excluded" "Reason: x" "$TMP/feedback.out"
assert_not_grep "TC-2.11 self-posted Codex top-level comment excluded" "self-posted, should be excluded" "$TMP/feedback.out"

# ---------- empty-body reviews are dropped, not rendered as blank sections ----------
assert_not_grep "empty-body review not attributed" "### Review by ghost" "$TMP/feedback.out"

# ---------- gh call sequence matches the function's real call shape ----------
assert_grep "collect_pr_feedback probes repo nameWithOwner first" "CALL=gh repo view --json nameWithOwner -q .nameWithOwner" "$TMP/feedback.record"
assert_grep "collect_pr_feedback queries reviews" "CALL=gh pr view 7 --json reviews --jq" "$TMP/feedback.record"
assert_grep "collect_pr_feedback queries comments" "CALL=gh pr view 7 --json comments --jq" "$TMP/feedback.record"
assert_grep "collect_pr_feedback queries inline review comments via gh api" "CALL=gh api repos/o/r/pulls/7/comments --jq" "$TMP/feedback.record"

# ---------- no feedback at all falls back to the documented "(none)" marker ----------
run_feedback_empty() {
  : > "$TMP/empty.record"
  ( RECORD="$TMP/empty.record" PATH="$TMP/bin:/usr/bin:/bin" STUB_OWNER_REPO="empty/repo" \
      BABYSIT_TEST_MODE=review-feedback TEST_PR_NUM=99 "$SCRIPT" ) > "$TMP/empty.out" 2>/dev/null
}
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf '%s' "${STUB_OWNER_REPO:-o/r}"
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
run_feedback_empty
assert_grep "no feedback falls back to (none)" "(none)" "$TMP/empty.out"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
