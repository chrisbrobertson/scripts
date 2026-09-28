#!/bin/bash
# test-babysit-review-merge-draft.sh — recording-stub coverage for
# merge_reviewed_pr() in babysit-with-review.sh.
#
# Regression for a real stuck PR (#60 in this repo's own backlog): a PR can
# reach the zero-blocking-findings success path while still marked draft —
# e.g. the implementer opened it with `gh pr create --draft`, or an earlier
# bail drafted it via a label with no undraft retry sweep (only
# review-mcp-outage has one). `gh pr merge` fails on a draft PR, and before
# this fix nothing un-drafted the PR first, so the codex-review=success
# status landed but the PR sat open and draft forever.
#
# No network: gh and git are stubs on PATH.
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
# Exact whole-line match — needed wherever one call's log line is a textual
# prefix of another (e.g. "pr merge 60 --squash --delete-branch" is a prefix
# of the same line with "--auto" appended), so a plain substring grep can't
# tell the two calls apart.
assert_line_count() {  # <name> <exact_line> <expected_count> <file>
  local name="$1" line="$2" expected="$3" file="$4" actual
  actual=$(grep -Fxc -- "$line" "$file" 2>/dev/null || echo 0)
  if [ "$actual" = "$expected" ]; then pass "$name"; else
    echo "  expected $expected occurrence(s) of '$line', got $actual in $file" >&2
    sed 's/^/    /' "$file" >&2
    fail "$name"
  fi
}

mkdir -p "$TMP/bin"

# gh: records every invocation. `pr ready` and `pr merge` exit codes are
# controlled by STUB_READY_RC / STUB_MERGE_RC so each case can force the
# scenario it's testing.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$*" in
  "repo view"*) printf '%s' "${STUB_OWNER_REPO:-o/r}"; exit 0 ;;
  "pr view"*"headRefOid"*) printf '%s' "${STUB_HEAD_SHA:-deadbeef}"; exit 0 ;;
  "api -X POST repos/"*"/statuses/"*) exit "${STUB_STATUS_RC:-0}" ;;
  "pr ready "*) exit "${STUB_READY_RC:-0}" ;;
  "pr merge "*"--auto"*) exit "${STUB_MERGE_AUTO_RC:-0}" ;;
  "pr merge "*) exit "${STUB_MERGE_RC:-0}" ;;
  "pr edit "*"--add-label review-merge-failed"*) exit "${STUB_EDIT_RC:-0}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# git: only checkout/pull/branch/rev-parse are reached; none need real repo
# state since merge_reviewed_pr swallows their failures with `|| true`.
cat > "$TMP/bin/git" <<'STUB'
#!/bin/bash
printf 'CALL=git %s\n' "$*" >> "$RECORD"
case "$1" in
  rev-parse) printf 'pr-branch\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/git"

run_merge() {  # <record> [env assignments...]
  local record="$1"; shift
  : > "$record"
  # `env` (not a bare VAR=val prefix) because "$@" sits between literal
  # VAR=val words below: once bash sees an expansion in assignment-prefix
  # position it stops treating later literal VAR=val words as assignments,
  # even when "$@" is empty — they'd otherwise be run as a bogus command.
  ( env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" DEFAULT_BRANCH=main \
      "$@" BABYSIT_TEST_MODE=review-merge TEST_PR_NUM=60 TEST_CYCLE=1 "$SCRIPT" ) \
    >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- clean success path ----------
r="$TMP/clean.record"
run_merge "$r"
assert_grep "clean merge: status POST happens" "CALL=gh api -X POST repos/o/r/statuses/deadbeef" "$r"
assert_line_count "clean merge: gh pr ready is called exactly once" "CALL=gh pr ready 60" 1 "$r"
assert_line_count "clean merge: gh pr merge --auto is attempted" "CALL=gh pr merge 60 --squash --delete-branch --auto --match-head-commit deadbeef" 1 "$r"
if [ "$(grep -nFx 'CALL=gh pr ready 60' "$r" | head -1 | cut -d: -f1)" -lt "$(grep -nFx 'CALL=gh pr merge 60 --squash --delete-branch --auto --match-head-commit deadbeef' "$r" | head -1 | cut -d: -f1)" ]; then
  pass "clean merge: gh pr ready runs before gh pr merge (the actual fix)"
else
  fail "clean merge: gh pr ready runs before gh pr merge (the actual fix)"
fi
assert_grep "clean merge: local branch reset to default branch" "CALL=git checkout main" "$r"

# ---------- gh pr ready fails (e.g. PR was somehow already non-draft, or a
# transient gh error) — the merge must still be attempted, not abandoned ----------
r="$TMP/ready-fails.record"
run_merge "$r" STUB_READY_RC=1
assert_line_count "ready failure: gh pr ready is still called" "CALL=gh pr ready 60" 1 "$r"
assert_line_count "ready failure: merge is attempted anyway (best-effort undraft)" "CALL=gh pr merge 60 --squash --delete-branch --auto --match-head-commit deadbeef" 1 "$r"
assert_grep "ready failure: a warning is logged, not a silent skip" "gh pr ready failed for PR #60; attempting merge anyway" "$TMP/err"

# ---------- status POST fails: must not attempt ready/merge without the
# codex-review status set (branch-protection bypass guard) ----------
r="$TMP/status-fails.record"
run_merge "$r" STUB_STATUS_RC=1
assert_not_grep "status failure: gh pr ready is NOT called" "CALL=gh pr ready 60" "$r"
assert_not_grep "status failure: gh pr merge is NOT called" "CALL=gh pr merge 60" "$r"

# ---------- --auto merge rejected (e.g. auto-merge disabled on the repo),
# falls back to a direct merge ----------
r="$TMP/auto-fallback.record"
run_merge "$r" STUB_MERGE_AUTO_RC=1
assert_line_count "auto-merge fallback: --auto attempted first" "CALL=gh pr merge 60 --squash --delete-branch --auto --match-head-commit deadbeef" 1 "$r"
assert_line_count "auto-merge fallback: falls back to a plain merge" "CALL=gh pr merge 60 --squash --delete-branch --match-head-commit deadbeef" 1 "$r"

# ---------- both merge attempts fail (e.g. transient CI/branch-protection
# race): regression for the actual PR #60 in this repo's backlog — before
# this fix, a merge failure after a clean review just logged a WARNING and
# left the PR open with no label, so the stalled-PR retry sweep (which only
# ever searches by label) could never rediscover it. Now it must be labelled
# review-merge-failed so the sweep finds it on a later iteration ----------
r="$TMP/both-merges-fail.record"
run_merge "$r" STUB_MERGE_AUTO_RC=1 STUB_MERGE_RC=1
assert_grep "both merges fail: review-merge-failed label is created" "CALL=gh label create review-merge-failed" "$r"
assert_grep "both merges fail: review-merge-failed label is added to the PR" "CALL=gh pr edit 60 --add-label review-merge-failed" "$r"
assert_grep "both merges fail: an explanatory comment is posted" "CALL=gh pr comment 60 --body-file -" "$r"
assert_not_grep "both merges fail: the PR is NOT re-drafted (review already passed, status already green)" "CALL=gh pr ready 60 --undo" "$r"

# ---------- both merges fail AND the merge-failure label itself can't be
# applied: fail-closed (#107) — the stalled-PR retry sweep only ever
# searches by label, so an unlabelled PR here would sit undiscoverable while
# the outer loop moves on to new work (the exact #60 orphan class this
# function exists to close). Must halt, not swallow the failure ----------
r="$TMP/label-fails.record"
run_merge "$r" STUB_MERGE_AUTO_RC=1 STUB_MERGE_RC=1 STUB_EDIT_RC=1
rc=$(cat "$TMP/rc")
if [ "$rc" -ne 0 ]; then pass "label failure: wrapper halts (non-zero exit) rather than continuing"; else fail "label failure: wrapper halts (non-zero exit) rather than continuing"; fi
assert_grep "label failure: an ERROR is logged" "ERROR: gh pr edit --add-label failed for PR #60" "$TMP/err"

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
