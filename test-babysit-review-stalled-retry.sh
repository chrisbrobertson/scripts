#!/bin/bash
# test-babysit-review-stalled-retry.sh — recording-stub coverage for the
# outer loop's stalled-PR retry sweep in babysit-with-review.sh (the sweep
# added for #82, tightened for #104, tightened again in PR #104's own review
# cycle for the reviewer-unavailable fallthrough below).
#
# Regressions this guards against:
#   1. The sweep finds a stalled PR by searching `gh pr list --label <l>`, so
#      the label must still be on the PR when the sweep runs. Confirms the
#      sweep issues `gh pr edit --remove-label` ITSELF — but only once the
#      reviewer CLI is confirmed available (see #3) — rather than requiring
#      the operator to have removed it already (removing it first makes the
#      search find nothing and strands the PR in draft — see #104).
#   2. The sweep must NOT call `gh pr ready` (undraft-for-merge) before the
#      re-review completes; only a clean review may un-draft a PR
#      (merge_reviewed_pr does that). Un-drafting up front would expose an
#      unreviewed PR to merging.
#   3. When the reviewer CLI is still unavailable, the sweep must leave the
#      label in place (so a later run can find the PR again) AND must not
#      fall through to starting new implementer work — a stalled PR awaiting
#      review takes priority over new work, otherwise unreviewed work piles
#      up behind the stall (flagged in PR #104's own review cycle).
#   4. If the `gh pr edit --remove-label` call itself fails, the sweep must
#      not run the review cycle over a stale resumable label — a later
#      review-incomplete bail would leave that label for the next sweep to
#      wrongly retry a PR meant for manual intervention (RECOMMENDED,
#      PR #104 review cycle 1).
#
# Runs a real outer-loop iteration (BABYSIT_TEST_MODE unset) against a real
# git repo (preflight needs real git state) with `gh` and (for scenario 1)
# `codex` stubbed on PATH. No Claude/Codex network calls.
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
# Exact whole-line match — needed to tell "gh pr ready 96" (undraft-for-merge)
# apart from "gh pr ready 96 --undo" (fail_review_cycle's re-draft), since
# the former is a textual prefix of the latter and a plain substring grep
# can't distinguish them.
assert_not_line() { if grep -qxF -- "$2" "$3" 2>/dev/null; then echo "  unexpected exact line '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
# Line-number order: fails if either needle is absent, or if "$2" doesn't
# appear on an earlier line of "$4" than "$3" does. Used to prove the merge
# attempt runs BEFORE label removal (PR #107 review cycle 3, BLOCKING) —
# ordering that a plain assert_grep can't distinguish from "both happened,
# in whatever order".
assert_order() {
  local first_line last_line
  first_line=$(grep -nF -- "$2" "$4" 2>/dev/null | head -n1 | cut -d: -f1)
  last_line=$(grep -nF -- "$3" "$4" 2>/dev/null | head -n1 | cut -d: -f1)
  if [ -z "$first_line" ] || [ -z "$last_line" ]; then
    echo "  one or both of '$2' / '$3' missing in $4" >&2; sed 's/^/    /' "$4" >&2; fail "$1"
  elif [ "$first_line" -lt "$last_line" ]; then
    pass "$1"
  else
    echo "  expected '$2' (line $first_line) before '$3' (line $last_line) in $4" >&2; sed 's/^/    /' "$4" >&2; fail "$1"
  fi
}

# Only the review-merge-failed scenarios (1c/1d below) call
# review_merge_failed_recorded_head(), which forwards the script's real `-q`
# jq filter to a real jq binary (see the gh stub below) — everything else in
# this file (scenarios 1, 1b, 2, "no resumable label") never reaches that
# code path and doesn't need jq at all. Gate only those scenarios instead of
# skipping the whole file, so the rest of this harness still runs on a
# machine without jq on PATH (RECOMMENDED, PR #107 review cycle 3).
HAVE_JQ=0
JQ_BIN=""
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
  # Resolve jq's absolute path now, before run_outer_iteration() restricts
  # PATH to "$TMP/bin:/usr/bin:/bin" for the stubbed subshell — a jq
  # installed elsewhere (e.g. Homebrew's /opt/homebrew/bin or
  # /usr/local/bin) would otherwise vanish from the stub's PATH even though
  # this check passed.
  JQ_BIN=$(command -v jq)
fi

mkdir -p "$TMP/bin"

# gh: records every invocation. `pr list --label X` answers with the PR
# number configured for that label via STUB_PR_<LABEL_UPPER>, or empty
# (no match) otherwise — standing in for "this label isn't on any open PR".
#
# `pr view --json comments` forwards the script's real `-q` jq filter to the
# real jq binary against a canned three-comment fixture — a forged marker
# from a non-bot author (a valid-hex "wrong" SHA an attacker could post after
# pushing an unreviewed commit) plus a stale and a fresh marker from the bot
# itself — so this harness actually exercises
# review_merge_failed_recorded_head()'s author filter and its `tail -n1`
# latest-marker selection, rather than a stub that hands back
# STUB_RECORDED_HEAD unconditionally regardless of query (see PR #107
# review, RECOMMENDED). The forged marker is valid-hex and sorted last in
# the fixture (after both bot markers) so that if the author `select()` were
# ever removed, `tail -n1` would surface the forged SHA instead of the real
# one and the assertions below would actually fail — an earlier fixture used
# a non-hex forged value sorted first, which `grep -o
# '[0-9a-f]\{7,40\}'`/`tail -n1` could never select regardless of whether
# author filtering ran, so it passed even with the filter removed (see PR
# #107 review cycle 2, RECOMMENDED).
cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
printf 'CALL=gh %s\n' "\$*" >> "\$RECORD"
case "\$*" in
  "repo view"*) echo main; exit 0 ;;
  "api user"*) printf 'babysit-bot'; exit 0 ;;
  "pr list --state open --label review-codex-outdated"*) printf '%s' "\${STUB_PR_OUTDATED:-}"; exit 0 ;;
  "pr list --state open --label review-mcp-outage"*) printf '%s' "\${STUB_PR_MCP:-}"; exit 0 ;;
  "pr list --state open --label review-codex-no-credits"*) printf '%s' "\${STUB_PR_CREDITS:-}"; exit 0 ;;
  "pr list --state open --label review-merge-failed"*) printf '%s' "\${STUB_PR_MERGE_FAILED:-}"; exit 0 ;;
  "pr list --state open --label review-merge-conflict"*) printf '%s' "\${STUB_PR_MERGE_CONFLICT:-}"; exit 0 ;;
  "pr view "*"--json headRefOid"*) printf '%s' "\${STUB_CURRENT_HEAD:-}"; exit 0 ;;
  "pr view "*"--json mergeable"*) printf '%s' "\${STUB_MERGEABLE:-}"; exit 0 ;;
  "pr view "*"--json state"*) printf '%s' "\${STUB_PR_STATE:-MERGED}"; exit 0 ;;
  "pr merge "*) exit "\${STUB_MERGE_RC:-0}" ;;
esac
if [ "\$1" = "pr" ] && [ "\$2" = "view" ] && [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
  if [ -z "\${STUB_RECORDED_HEAD:-}" ]; then
    exit 0
  fi
  jq_filter="\${7:-}"
  data=\$(cat <<FIXTURE
{"comments":[
  {"author":{"login":"babysit-bot"},"body":"<!-- babysit:merge-failed-head=0000000stale -->"},
  {"author":{"login":"babysit-bot"},"body":"<!-- babysit:merge-failed-head=\$STUB_RECORDED_HEAD -->"},
  {"author":{"login":"attacker"},"body":"<!-- babysit:merge-failed-head=eeeeeee1 -->"}
]}
FIXTURE
)
  printf '%s' "\$data" | "$JQ_BIN" -r "\$jq_filter"
  exit 0
fi
case "\$*" in
  "pr edit "*"--remove-label"*) exit "\${STUB_REMOVE_LABEL_RC:-0}" ;;
  "pr ready "*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# codex: only used in scenario 1 (reviewer available). Fails the
# reviewer_preflight probe generically (not the version/credits telltales),
# which drives run_review_cycle straight to fail_review_cycle() without ever
# reaching gh pr checkout/merge — enough to prove the sweep invoked the real
# run_review_cycle() for the right PR, without needing to fake a full review.
cat > "$TMP/bin/codex.stub" <<'STUB'
#!/bin/bash
printf 'CALL=codex %s\n' "$*" >> "$RECORD"
echo "generic preflight failure (not a version/credits issue)" >&2
exit 1
STUB
chmod +x "$TMP/bin/codex.stub"

# Real git repo satisfying pre-flight: bare origin + a clone with one commit
# on "main", already pushed (clean, not ahead/behind). Real git binary is
# used (only gh/codex are stubbed), matching make_preflight_repo() in
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

# ---------- scenario 1: reviewer CLI available, a PR is stalled behind
# review-codex-outdated ----------
ln -s "$TMP/bin/codex.stub" "$TMP/bin/codex"
r="$TMP/outdated.record"
run_outer_iteration "$r" STUB_PR_OUTDATED=96
assert_grep "stalled retry (reviewer available): sweep removes the label itself" "CALL=gh pr edit 96 --remove-label review-codex-outdated" "$r"
assert_not_line "stalled retry (reviewer available): sweep does not un-draft before the review runs (BLOCKING #2)" "CALL=gh pr ready 96" "$r"
assert_grep "stalled retry (reviewer available): run_review_cycle actually ran for the stalled PR" "=== review handoff: PR #96 @" "$TMP/err"
assert_grep "stalled retry (reviewer available): outer loop logs which PR/label it's retrying" "[outer] retrying review cycle for PR #96 (review-codex-outdated)" "$TMP/err"
assert_not_grep "stalled retry (reviewer available): never merges an unreviewed PR" "CALL=gh pr merge" "$r"
rm -f "$TMP/bin/codex"

# ---------- scenario 1b: reviewer CLI available, but the label-removal call
# itself fails (RECOMMENDED finding, PR #104 review cycle 1) — must not run
# the review cycle with a stale resumable label still on the PR, since a
# review-incomplete bail afterward would leave that stale label for the next
# sweep to wrongly retry a PR meant for manual intervention ----------
ln -s "$TMP/bin/codex.stub" "$TMP/bin/codex"
r="$TMP/remove-label-fails.record"
run_outer_iteration "$r" STUB_PR_OUTDATED=96 STUB_REMOVE_LABEL_RC=1
assert_not_grep "stalled retry (label removal fails): run_review_cycle is not invoked over a stale label" "=== review handoff: PR #96 @" "$TMP/err"
assert_grep "stalled retry (label removal fails): sweep logs the removal failure" "[outer] WARNING: failed to remove review-codex-outdated from PR #96; retrying removal next iteration" "$TMP/err"
rm -f "$TMP/bin/codex"

if [ "$HAVE_JQ" -eq 1 ]; then

# ---------- scenario 1c: a PR is stalled behind review-merge-failed (the #60
# orphan class: review already passed, only the merge itself failed) — unlike
# the other three labels, this must NOT go through a full review cycle: a
# transient reviewer_preflight failure there would draft the PR and label it
# review-incomplete, discarding the already-passed review (PR #107 review,
# BLOCKING). It must retry the merge directly instead. The recorded reviewed
# head and the PR's current head match here (head unchanged since the review
# passed), which is the precondition for taking the merge-only shortcut at
# all (PR #107 review, BLOCKING). No codex stub is installed for this
# scenario — if the sweep ever called run_review_cycle again, `codex` would
# be missing from PATH and the test would still pass incorrectly, so this is
# paired with the explicit assertions below that run_review_cycle/codex never
# ran at all.
#
# The label must stay ON through the merge attempt and only come off after
# `gh pr view --json state` confirms MERGED — removing it up front left an
# interruption between removal and merge with no discoverable record of the
# stalled PR (PR #107 review cycle 3, BLOCKING). assert_order below is the
# regression guard for that ordering, not just assert_grep, since both calls
# happening in either order would satisfy a plain substring check. ----------
r="$TMP/merge-failed.record"
run_outer_iteration "$r" STUB_PR_MERGE_FAILED=60 STUB_CURRENT_HEAD=abc1234 STUB_RECORDED_HEAD=abc1234 STUB_PR_STATE=MERGED
assert_not_grep "stalled retry (merge-failed): does NOT run a full review cycle" "=== review handoff: PR #60 @" "$TMP/err"
assert_not_grep "stalled retry (merge-failed): never invokes the reviewer CLI" "CALL=codex" "$r"
assert_grep "stalled retry (merge-failed): outer loop logs a merge retry, not a review retry" "[outer] retrying merge for PR #60 (review-merge-failed)" "$TMP/err"
assert_grep "stalled retry (merge-failed): merge_reviewed_pr actually attempted a merge" "CALL=gh pr merge 60 --squash --delete-branch --match-head-commit abc1234" "$r"
assert_grep "stalled retry (merge-failed): sweep checks PR state before cleaning up the label" "CALL=gh pr view 60 --json state -q .state" "$r"
assert_grep "stalled retry (merge-failed): label is removed once merge is confirmed" "CALL=gh pr edit 60 --remove-label review-merge-failed" "$r"
assert_order "stalled retry (merge-failed): merge is attempted before the label is removed (BLOCKING)" \
  "CALL=gh pr merge 60 --squash --delete-branch --match-head-commit abc1234" \
  "CALL=gh pr edit 60 --remove-label review-merge-failed" "$r"

# ---------- scenario 1c-2: same as 1c, but `gh pr merge` itself fails (e.g.
# CI still running) — the label must NOT be removed, since the PR is still
# open and this is exactly the retry the label exists to enable. merge_reviewed_pr
# re-adds the label itself (flag_review_cycle_merge_failed, idempotent via
# --add-label), so the sweep must never race that by removing it (PR #107
# review cycle 3, BLOCKING). ----------
r="$TMP/merge-failed-merge-still-fails.record"
run_outer_iteration "$r" STUB_PR_MERGE_FAILED=62 STUB_CURRENT_HEAD=ccc3456 STUB_RECORDED_HEAD=ccc3456 STUB_MERGE_RC=1 STUB_PR_STATE=OPEN
assert_grep "stalled retry (merge still fails): merge is attempted" "CALL=gh pr merge 62 --squash --delete-branch --match-head-commit ccc3456" "$r"
assert_not_grep "stalled retry (merge still fails): label is never removed" "CALL=gh pr edit 62 --remove-label" "$r"
assert_grep "stalled retry (merge still fails): merge_reviewed_pr re-flags the PR for the next retry" "CALL=gh pr edit 62 --add-label review-merge-failed" "$r"
assert_grep "stalled retry (merge still fails): wrapper logs the merge failure" "[review] WARNING: merge failed for PR #62; left open for next iteration" "$TMP/err"

# ---------- scenario 1d: review-merge-failed, but the PR's head has moved
# since the review passed (e.g. new commits pushed during the arbitrarily
# long gap this label allows — it carries no halt/restart requirement).
# Reusing the stale codex-review=success status would merge unreviewed
# commits, so the sweep must fall through to a full review cycle instead of
# retrying the merge directly (PR #107 review, BLOCKING). codex stub is
# installed so the fallthrough path can actually start a review. ----------
ln -s "$TMP/bin/codex.stub" "$TMP/bin/codex"
r="$TMP/merge-failed-stale-head.record"
run_outer_iteration "$r" STUB_PR_MERGE_FAILED=61 STUB_CURRENT_HEAD=1111111 STUB_RECORDED_HEAD=2222222
assert_grep "stalled retry (merge-failed, stale head): sweep logs the head mismatch" "[outer] PR #61 head changed since its review passed (recorded=2222222 current=1111111)" "$TMP/err"
assert_grep "stalled retry (merge-failed, stale head): falls through to a full review cycle" "=== review handoff: PR #61 @" "$TMP/err"
assert_grep "stalled retry (merge-failed, stale head): sweep removes the label before the fallback review" "CALL=gh pr edit 61 --remove-label review-merge-failed" "$r"
assert_not_grep "stalled retry (merge-failed, stale head): never merges the unreviewed head" "CALL=gh pr merge" "$r"
rm -f "$TMP/bin/codex"

else
  echo "SKIP: jq not on PATH; scenarios 1c/1c-2/1d need it to exercise the real gh -q filter used by review_merge_failed_recorded_head" >&2
fi

# ---------- scenario 2: reviewer CLI still unavailable — label stays, no
# review is run, and no new work starts ahead of it ----------
r="$TMP/unavailable.record"
run_outer_iteration "$r" STUB_PR_OUTDATED=96
assert_not_grep "stalled retry (reviewer unavailable): label is left in place for a later retry" "--remove-label" "$r"
assert_not_grep "stalled retry (reviewer unavailable): run_review_cycle is never invoked" "=== review handoff: PR #96 @" "$TMP/err"
assert_grep "stalled retry (reviewer unavailable): sweep logs that it's deferring" "[outer] codex CLI still unavailable; leaving PR #96 labelled review-codex-outdated for a later retry" "$TMP/err"
assert_not_grep "stalled retry (reviewer unavailable): does not fall through to new implementer work" "[outer] worktree:" "$TMP/err"

# ---------- scenario 1e: a PR is stalled behind review-merge-conflict but
# GitHub still reports it CONFLICTING — the fix for the #111 finding that a
# real conflict must never be blindly retried (the whole reason this label
# was kept out of a naive resumable set to begin with). The sweep must defer:
# leave the label in place, never call run_review_cycle, and not fall through
# to new implementer work. ----------
r="$TMP/merge-conflict-still-conflicting.record"
run_outer_iteration "$r" STUB_PR_MERGE_CONFLICT=83 STUB_MERGEABLE=CONFLICTING
assert_not_grep "stalled retry (merge-conflict, still conflicting): label is left in place" "--remove-label" "$r"
assert_not_grep "stalled retry (merge-conflict, still conflicting): run_review_cycle is never invoked" "=== review handoff: PR #83 @" "$TMP/err"
assert_grep "stalled retry (merge-conflict, still conflicting): sweep logs that it's deferring" "[outer] PR #83 still CONFLICTING (or not yet known); leaving it labelled review-merge-conflict for a later retry" "$TMP/err"
assert_not_grep "stalled retry (merge-conflict, still conflicting): does not fall through to new implementer work" "[outer] worktree:" "$TMP/err"

# ---------- scenario 1f: a PR is stalled behind review-merge-conflict and a
# human has since merged the base branch in and pushed — GitHub's mergeable
# computation now reports MERGEABLE. The sweep must detect this (the #111
# fix: this label was previously a dead end, promising a fresh review that
# never actually ran) and route to a real review cycle over the merged-up
# diff, removing the label first like the other resumable labels. ----------
ln -s "$TMP/bin/codex.stub" "$TMP/bin/codex"
r="$TMP/merge-conflict-resolved.record"
run_outer_iteration "$r" STUB_PR_MERGE_CONFLICT=83 STUB_MERGEABLE=MERGEABLE
assert_grep "stalled retry (merge-conflict, resolved): sweep removes the label" "CALL=gh pr edit 83 --remove-label review-merge-conflict" "$r"
assert_grep "stalled retry (merge-conflict, resolved): run_review_cycle actually ran for the stalled PR" "=== review handoff: PR #83 @" "$TMP/err"
assert_grep "stalled retry (merge-conflict, resolved): sweep logs the transition" "[outer] PR #83 no longer CONFLICTING (mergeable=MERGEABLE); routing to a fresh review cycle to re-review the merged-up diff" "$TMP/err"
rm -f "$TMP/bin/codex"

# ---------- no resumable label on any open PR: sweep is a no-op ----------
r="$TMP/none.record"
run_outer_iteration "$r"
assert_not_grep "no stalled PR: sweep never removes a label" "--remove-label" "$r"
assert_not_grep "no stalled PR: sweep never calls gh pr ready" "pr ready" "$r"

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
