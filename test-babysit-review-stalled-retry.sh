#!/bin/bash
# test-babysit-review-stalled-retry.sh — recording-stub coverage for the
# outer loop's stalled-PR retry sweep in babysit-with-review.sh (the sweep
# added for #82, tightened for #104).
#
# Two BLOCKING regressions this guards against:
#   1. The sweep finds a stalled PR by searching `gh pr list --label <l>`, so
#      the label must still be on the PR when the sweep runs. Confirms the
#      sweep issues `gh pr edit --remove-label` ITSELF rather than requiring
#      the operator to have removed it already (removing it first makes the
#      search find nothing and strands the PR in draft — see #104).
#   2. The sweep must NOT call `gh pr ready` before the re-review completes;
#      only a clean review may un-draft a PR (merge_reviewed_pr does that).
#      Un-drafting up front would expose an unreviewed PR to merging.
#
# Runs a real outer-loop iteration (BABYSIT_TEST_MODE unset) against a real
# git repo (preflight needs real git state) with only `gh` stubbed on PATH.
# The reviewer binary (codex) is deliberately absent from PATH so
# run_review_cycle takes its graceful-degradation early return right after
# checkout — no further gh/git calls — keeping the fixture minimal while
# still proving the sweep invoked the real run_review_cycle() for the right
# PR. No Claude/Codex network calls.
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

mkdir -p "$TMP/bin"

# gh: records every invocation. `pr list --label X` answers with the PR
# number configured for that label via STUB_PR_<LABEL_UPPER>, or empty
# (no match) otherwise — standing in for "this label isn't on any open PR".
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$*" in
  "repo view"*) echo main; exit 0 ;;
  "pr list --state open --label review-codex-outdated"*) printf '%s' "${STUB_PR_OUTDATED:-}"; exit 0 ;;
  "pr list --state open --label review-mcp-outage"*) printf '%s' "${STUB_PR_MCP:-}"; exit 0 ;;
  "pr list --state open --label review-codex-no-credits"*) printf '%s' "${STUB_PR_CREDITS:-}"; exit 0 ;;
  "pr edit "*"--remove-label"*) exit 0 ;;
  "pr ready "*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# Real git repo satisfying pre-flight: bare origin + a clone with one commit
# on "main", already pushed (clean, not ahead/behind). Real git binary is
# used (only gh is stubbed), matching make_preflight_repo() in
# test-babysit-with-review-cli.sh.
make_repo() {
  local dir="$1"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/work" >/dev/null 2>&1
  (
    cd "$dir/work"
    git config user.email test@test.com
    git config user.name test
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo base > tracked.txt
    git add tracked.txt
    git commit -q -m init
    git push -q -u origin main
  )
}

run_outer_iteration() {  # <record> [env assignments...]
  local record="$1"; shift
  : > "$record"
  local repo_dir="$TMP/repo-$$-$RANDOM"
  mkdir -p "$repo_dir"
  make_repo "$repo_dir"
  (
    cd "$repo_dir/work" && env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home-$$-$RANDOM" \
      MAX_ITER=1 SLEEP_SEC=0 BABYSIT_TEST_MODE= "$@" "$SCRIPT"
  ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- a PR is stalled behind review-codex-outdated ----------
r="$TMP/outdated.record"
run_outer_iteration "$r" STUB_PR_OUTDATED=96
assert_grep "stalled retry: sweep removes the label itself" "CALL=gh pr edit 96 --remove-label review-codex-outdated" "$r"
assert_not_grep "stalled retry: sweep does not un-draft before the review runs (BLOCKING #2)" "CALL=gh pr ready 96" "$r"
assert_grep "stalled retry: run_review_cycle actually ran for the stalled PR" "codex CLI not found; skipping review cycle (PR #96 remains open for external review)" "$TMP/err"
assert_grep "stalled retry: outer loop logs which PR/label it's retrying" "[outer] retrying review cycle for PR #96 (review-codex-outdated)" "$TMP/err"

# ---------- no resumable label on any open PR: sweep is a no-op ----------
r="$TMP/none.record"
run_outer_iteration "$r"
assert_not_grep "no stalled PR: sweep never removes a label" "--remove-label" "$r"
assert_not_grep "no stalled PR: sweep never calls gh pr ready" "pr ready" "$r"

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
