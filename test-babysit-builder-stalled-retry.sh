#!/bin/bash
# test-babysit-builder-stalled-retry.sh — recording-stub coverage for
# babysit-builder.sh's stalled-PR sweep (resume_stalled_prs).
#
# Regression this guards against: resume_outage_prs (the pre-fix name) only
# ever searched for PRs labelled build-mcp-outage. build-codex-outdated and
# build-codex-no-credits had no equivalent sweep, so a PR quarantined behind
# either label was never resumed — worse than the sibling bug fixed for
# babysit-with-review.sh in #104, because the ticket's build-ready label is
# also never cleared (only mark_ticket_done does that, and it only runs after
# a resumed PR halts cleanly), so the next run's fetch_github_queue/
# fetch_jira_queue would rebuild the SAME ticket into a second PR alongside
# the stuck one. resume_stalled_prs (this fix) sweeps all three resumable
# labels the same way.
#
# Runs a real babysit-builder.sh invocation (no test-mode hooks exist in that
# script) against a real disposable git repo, with `gh` and `codex` stubbed on
# PATH. No Claude/Codex network calls.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-builder.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }

mkdir -p "$TMP/bin"

# gh: records every invocation. `pr list --label X` answers with the JSON PR
# array configured for that label via STUB_PR_<LABEL_UPPER>, or "[]" (no
# match) otherwise — standing in for "this label isn't on any open PR".
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$*" in
  "auth status"*) exit 0 ;;
  "repo view "*"--json defaultBranchRef"*) echo main; exit 0 ;;
  "pr list --repo "*"--state open --label build-mcp-outage"*) printf '%s' "${STUB_PR_MCP:-[]}"; exit 0 ;;
  "pr list --repo "*"--state open --label build-codex-outdated"*) printf '%s' "${STUB_PR_OUTDATED:-[]}"; exit 0 ;;
  "pr list --repo "*"--state open --label build-codex-no-credits"*) printf '%s' "${STUB_PR_CREDITS:-[]}"; exit 0 ;;
  "issue list --repo "*"--label build-ready"*) printf '%s' "${STUB_QUEUE:-[]}"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# codex: succeeds for the startup reviewer_preflight probe ("Say 'ok'."), then
# fails generically (no compat/credits/transport telltale) for the actual
# per-PR review call inside run_build_cycle — enough to prove resume_stalled_prs
# invoked the real run_build_cycle() for the right PR, without needing to fake
# a full review or wait through the transport-failure retry/sleep path.
cat > "$TMP/bin/codex" <<'STUB'
#!/bin/bash
printf 'CALL=codex %s\n' "$*" >> "$RECORD"
case "$*" in
  *"Say 'ok'."*) echo ok; exit 0 ;;
  *) echo "generic review failure (not a version/credits issue)" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/codex"

# claude: never actually invoked in these scenarios (no new ticket reaches
# build_ticket), but babysit-builder.sh checks both implementer/reviewer
# binaries are on PATH before doing anything else.
cat > "$TMP/bin/claude" <<'STUB'
#!/bin/bash
printf 'CALL=claude %s\n' "$*" >> "$RECORD"
exit 1
STUB
chmod +x "$TMP/bin/claude"

# Real git repo satisfying the builder's default-branch fetch: bare origin +
# a clone with one commit on "main" (pushed), plus a second branch standing
# in for a quarantined PR's head ref.
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
    git checkout -q -b stalled-pr-branch
    echo stalled > tracked.txt
    git add tracked.txt
    git commit -q -m "stalled pr work"
    git push -q -u origin stalled-pr-branch
    git checkout -q main
  )
}

pr_json() {  # <number> <head_ref> <source> <ticket>
  printf '[{"number": %s, "headRefName": "%s", "body": "<!-- babysit-builder source=%s ticket=%s -->"}]' \
    "$1" "$2" "$3" "$4"
}

run_builder() {  # <record> [env assignments...]
  local record="$1"; shift
  : > "$record"
  local repo_dir="$TMP/repo-$$-$RANDOM"
  mkdir -p "$repo_dir"
  make_repo "$repo_dir"
  (
    cd "$repo_dir/work" && env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home-$$-$RANDOM" \
      "$@" "$SCRIPT" --repo owner/repo
  ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- scenario 1: PR stalled behind build-codex-outdated (the label the
# pre-fix sweep never searched for) ----------
r="$TMP/outdated.record"
run_builder "$r" STUB_PR_OUTDATED="$(pr_json 96 stalled-pr-branch github 42)"
assert_grep "stalled retry (build-codex-outdated): sweep removes the label itself" "CALL=gh pr edit 96 --repo owner/repo --remove-label build-codex-outdated" "$r"
assert_grep "stalled retry (build-codex-outdated): run_build_cycle actually ran for the stalled PR" "=== build cycle: PR #96 @" "$TMP/err"
assert_grep "stalled retry (build-codex-outdated): outer sweep logs which PR/label it's retrying" "[build] resuming build cycle for PR #96 (build-codex-outdated)" "$TMP/out"

# ---------- scenario 2: PR stalled behind build-codex-no-credits (also
# unreachable before this fix) ----------
r="$TMP/no-credits.record"
run_builder "$r" STUB_PR_CREDITS="$(pr_json 97 stalled-pr-branch github 43)"
assert_grep "stalled retry (build-codex-no-credits): sweep removes the label itself" "CALL=gh pr edit 97 --repo owner/repo --remove-label build-codex-no-credits" "$r"
assert_grep "stalled retry (build-codex-no-credits): run_build_cycle actually ran for the stalled PR" "=== build cycle: PR #97 @" "$TMP/err"

# ---------- scenario 3 (regression): PR stalled behind build-mcp-outage still
# resumes exactly as before this fix ----------
r="$TMP/mcp-outage.record"
run_builder "$r" STUB_PR_MCP="$(pr_json 98 stalled-pr-branch github 44)"
assert_grep "stalled retry (build-mcp-outage, regression): sweep removes the label itself" "CALL=gh pr edit 98 --repo owner/repo --remove-label build-mcp-outage" "$r"
assert_grep "stalled retry (build-mcp-outage, regression): run_build_cycle actually ran for the stalled PR" "=== build cycle: PR #98 @" "$TMP/err"

# ---------- scenario 4: no PR carries any resumable label — sweep is a no-op,
# no worktree/build-cycle work happens ----------
r="$TMP/none.record"
run_builder "$r"
assert_not_grep "no stalled PR: sweep never removes a label" "--remove-label" "$r"
assert_not_grep "no stalled PR: run_build_cycle never runs" "=== build cycle:" "$TMP/err"

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
