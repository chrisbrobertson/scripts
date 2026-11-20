#!/bin/bash
# test-run-retrospective-review.sh — coverage for run-retrospective-review.sh.
#
# run-retrospective-review.sh shipped with no test coverage of its own, despite
# its spec (babysit-specs/L3-retrospective-review.md) listing 10 numbered
# acceptance tests. This harness drives the real script end to end against a
# throwaway local git repo (for worktree-at-merge-SHA), with `gh` and `codex`
# stubbed on PATH — no network, no real Codex/GitHub calls.
#
# Maps to the spec's acceptance tests (AC1-AC10):
#   AC1/AC4  clean review (0 blocking) → PASSED comment + marker
#   AC2      re-run on same PR → idempotent skip, no duplicate comment
#   AC3      2 blocking findings → 2 issues created, correctly labelled
#   AC5      non-merged PR → skipped with state=OPEN
#   AC6      compat_re match → skipped, no comment, no issue
#   AC7      --dry-run → no Codex run, no worktree, no comment, no issue
#   AC8      --no-issues → comment posted, no issues created
#   AC9      worktree EXIT cleanup → no orphaned `git worktree` entries
#   AC10     issue dedup by title prefix, independent of which PR filed it
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/run-retrospective-review.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
assert_file_missing() { if [ -f "$2" ]; then echo "  unexpected file exists: $2" >&2; fail "$1"; else pass "$1"; fi; }
count_lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
# Call-count helpers: the recorded "$*" for a codex/issue-create invocation
# can itself embed newlines (prompt text, issue body), so counting raw lines
# in the record file overcounts. Count only lines carrying the call marker.
count_codex_calls() { grep -c '^CALL=' "$CODEX_RECORD" 2>/dev/null || true; }
count_issue_creates() { grep -c '^ISSUE_CREATE issue create' "$ISSUE_CREATE_LOG" 2>/dev/null || true; }

# ---------- throwaway git repo (worktree-at-merge-SHA target) ----------
REPO_DIR="$TMP/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@test.local
git -C "$REPO_DIR" config user.name test
echo "a" > "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -q -m "initial"
echo "b" >> "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -q -m "feature commit"
export MERGE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

# ---------- stub bin dir ----------
mkdir -p "$TMP/bin"
export GH_RECORD="$TMP/gh-calls.log"
export CODEX_RECORD="$TMP/codex-calls.log"
export ISSUE_CREATE_LOG="$TMP/issue-create.log"
export TMP_COMMENTS_DIR="$TMP/comments"
mkdir -p "$TMP_COMMENTS_DIR"
: > "$GH_RECORD"; : > "$CODEX_RECORD"; : > "$ISSUE_CREATE_LOG"

# gh stub: PR metadata/comments/diff/comment-post/label/issue-list/issue-create.
# $PR_LOOKUP (TSV: pr_num<TAB>state<TAB>mergedAt) controls per-PR metadata;
# a looked-up state of "FAIL" forces a non-zero exit (simulated gh/network error).
# Comment idempotency is tracked dynamically via $TMP_COMMENTS_DIR/pr-<N>.txt —
# whatever was actually posted by a prior invocation, not a static fixture.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=%s\n' "$*" >> "$GH_RECORD"
cmd="$1"; sub="$2"

if [ "$cmd" = "pr" ] && [ "$sub" = "view" ]; then
  pr_num="$3"
  rest="$*"
  if printf '%s' "$rest" | grep -q -- '--json comments'; then
    f="$TMP_COMMENTS_DIR/pr-$pr_num.txt"
    [ -f "$f" ] && cat "$f"
    exit 0
  fi
  state="OPEN"; merged_at="2026-01-01T00:00:00Z"
  if [ -n "${PR_LOOKUP:-}" ] && [ -f "$PR_LOOKUP" ]; then
    line=$(awk -F'\t' -v pr="$pr_num" '$1==pr{print; exit}' "$PR_LOOKUP")
    if [ -n "$line" ]; then
      state=$(echo "$line" | cut -f2)
      merged_at=$(echo "$line" | cut -f3)
    fi
  fi
  if [ "$state" = "FAIL" ]; then
    echo "gh: pull request not found" >&2
    exit 1
  fi
  printf '{"number":%s,"state":"%s","mergedAt":"%s","title":"t","mergeCommit":{"oid":"%s"}}\n' \
    "$pr_num" "$state" "$merged_at" "${MERGE_SHA}"
  exit 0
fi

if [ "$cmd" = "pr" ] && [ "$sub" = "diff" ]; then
  echo "diff --git a/file.txt b/file.txt"
  exit 0
fi

if [ "$cmd" = "pr" ] && [ "$sub" = "comment" ]; then
  pr_num="$3"
  body=$(cat)
  printf '%s' "$body" >> "$TMP_COMMENTS_DIR/pr-$pr_num.txt"
  exit 0
fi

if [ "$cmd" = "label" ] && [ "$sub" = "create" ]; then
  exit 0
fi

if [ "$cmd" = "issue" ] && [ "$sub" = "list" ]; then
  jqexpr=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--jq" ]; then jqexpr="$arg"; fi
    prev="$arg"
  done
  rest="${jqexpr#*startswith\(\"}"
  prefix="${rest%\"\)\)*}"
  if [ -n "${GH_ISSUE_TITLES:-}" ] && [ -f "$GH_ISSUE_TITLES" ]; then
    while IFS= read -r t; do
      case "$t" in
        "$prefix"*) printf '%s\n' "$t" ;;
      esac
    done < "$GH_ISSUE_TITLES"
  fi
  exit 0
fi

if [ "$cmd" = "issue" ] && [ "$sub" = "create" ]; then
  echo "ISSUE_CREATE $*" >> "$ISSUE_CREATE_LOG"
  exit 0
fi

exit 0
STUB
chmod +x "$TMP/bin/gh"

# codex stub: writes the --output-last-message file per $CODEX_MODE; a
# transport/compat/credits failure is written to stdout+stderr (teed into the
# same transcript the real script greps for telltales).
cat > "$TMP/bin/codex" <<'STUB'
#!/bin/bash
printf 'CALL=%s\n' "$*" >> "$CODEX_RECORD"
out_file=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--output-last-message" ]; then out_file="$arg"; fi
  prev="$arg"
done
mode="${CODEX_MODE:-clean0}"
case "$mode" in
  clean0)
    cat > "$out_file" <<'EOF'
## BLOCKING
- (none)

## RECOMMENDED
- (none)

## INFORMATION
- (none)
EOF
    exit 0
    ;;
  blocking2)
    cat > "$out_file" <<'EOF'
## BLOCKING
- finding one -- file.txt:1 -- needs fix
- finding two -- file.txt:2 -- needs fix

## RECOMMENDED
- (none)

## INFORMATION
- (none)
EOF
    exit 0
    ;;
  compat)
    echo "ERROR: requires a newer version of Codex for this model" >&2
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"

: > "$TMP/empty-lookup.tsv"
export PR_LOOKUP="$TMP/empty-lookup.tsv"

run() {  # run [script args...] — stdin always /dev/null unless caller overrides
  : > "$GH_RECORD"; : > "$CODEX_RECORD"; : > "$ISSUE_CREATE_LOG"
  (cd "$REPO_DIR" && "$SCRIPT" --repo o/r "$@") < /dev/null >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

run_stdin() {  # run_stdin <stdin-content> [script args...]
  local input="$1"; shift
  : > "$GH_RECORD"; : > "$CODEX_RECORD"; : > "$ISSUE_CREATE_LOG"
  (cd "$REPO_DIR" && printf '%s\n' "$input" | "$SCRIPT" --repo o/r "$@") >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- AC1/AC4: clean review, 0 blocking → PASSED comment + marker ----------
printf '101\tMERGED\t2026-03-01T00:00:00Z\n' > "$TMP/lookup1.tsv"
PR_LOOKUP="$TMP/lookup1.tsv" CODEX_MODE=clean0 run 101
assert_eq "AC1: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "AC1: PASSED summary on stdout" "PR #101: 0 blocking finding(s) → review posted (PASSED)" "$TMP/out"
assert_grep "AC1: comment carries the idempotency marker" "<!-- retrospective-review: pr=101 -->" "$TMP_COMMENTS_DIR/pr-101.txt"
assert_grep "AC1: comment header is PASSED" "RETROSPECTIVE REVIEW — PASSED" "$TMP_COMMENTS_DIR/pr-101.txt"

# ---------- AC2: re-run on same PR → idempotent skip, no duplicate comment ----------
comment_lines_before=$(count_lines "$TMP_COMMENTS_DIR/pr-101.txt")
PR_LOOKUP="$TMP/lookup1.tsv" CODEX_MODE=clean0 run 101
assert_eq "AC2: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "AC2: idempotent-skip summary" "PR #101: already reviewed → skipped (idempotent)" "$TMP/out"
assert_eq "AC2: codex is never invoked on the idempotent path" "$(count_codex_calls)" "0"
comment_lines_after=$(count_lines "$TMP_COMMENTS_DIR/pr-101.txt")
assert_eq "AC2: no duplicate comment posted" "$comment_lines_before" "$comment_lines_after"

# ---------- AC3: 2 blocking findings → 2 issues created, correctly labelled ----------
printf '103\tMERGED\t2026-03-02T00:00:00Z\n' > "$TMP/lookup3.tsv"
PR_LOOKUP="$TMP/lookup3.tsv" CODEX_MODE=blocking2 run 103
assert_eq "AC3: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "AC3: 2-blocking summary on stdout" "PR #103: 2 blocking finding(s) → review posted, 2 issue(s) created" "$TMP/out"
assert_eq "AC3: exactly 2 issues created" "$(count_issue_creates)" "2"
assert_grep "AC3: issue title prefixed [retrospective]" "[retrospective] finding one" "$ISSUE_CREATE_LOG"
assert_grep "AC3: issue carries merged-PR suffix" "(merged PR #103)" "$ISSUE_CREATE_LOG"
assert_grep "AC3: issue labelled retrospective,priority:high" "retrospective,priority:high" "$ISSUE_CREATE_LOG"

# ---------- AC5: non-merged (OPEN) PR → skipped with state=OPEN ----------
printf '105\tOPEN\t\n' > "$TMP/lookup5.tsv"
PR_LOOKUP="$TMP/lookup5.tsv" CODEX_MODE=clean0 run 105
assert_eq "AC5: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "AC5: not-merged summary" "PR #105: not merged → skipped (state=OPEN)" "$TMP/out"
assert_eq "AC5: codex never invoked for an open PR" "$(count_codex_calls)" "0"
assert_file_missing "AC5: no comment posted for an open PR" "$TMP_COMMENTS_DIR/pr-105.txt"

# ---------- AC6: compat_re match → skipped; no comment, no issue ----------
printf '106\tMERGED\t2026-03-03T00:00:00Z\n' > "$TMP/lookup6.tsv"
PR_LOOKUP="$TMP/lookup6.tsv" CODEX_MODE=compat run 106
assert_eq "AC6: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "AC6: compat-skip message on stderr" "PR #106: Codex failure (compat) → skipped (upgrade Codex CLI before retrying)" "$TMP/err"
assert_eq "AC6: codex invoked exactly once (no retry on compat)" "$(count_codex_calls)" "1"
assert_file_missing "AC6: no comment posted" "$TMP_COMMENTS_DIR/pr-106.txt"
assert_eq "AC6: no issue created" "$(count_issue_creates)" "0"

# ---------- AC7: --dry-run → no codex, no worktree-driven comment/issue ----------
printf '107\tMERGED\t2026-03-04T00:00:00Z\n' > "$TMP/lookup7.tsv"
PR_LOOKUP="$TMP/lookup7.tsv" CODEX_MODE=clean0 run --dry-run 107
assert_eq "AC7: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "AC7: dry-run preview message" "PR #107: [dry-run] would review at SHA ${MERGE_SHA} (merged 2026-03-04T00:00:00Z)" "$TMP/out"
assert_eq "AC7: codex never invoked under --dry-run" "$(count_codex_calls)" "0"
assert_file_missing "AC7: no comment posted under --dry-run" "$TMP_COMMENTS_DIR/pr-107.txt"
assert_eq "AC7: no issue created under --dry-run" "$(count_issue_creates)" "0"

# ---------- AC8: --no-issues with blocking findings → comment posted, no issues ----------
printf '108\tMERGED\t2026-03-05T00:00:00Z\n' > "$TMP/lookup8.tsv"
PR_LOOKUP="$TMP/lookup8.tsv" CODEX_MODE=blocking2 run --no-issues 108
assert_eq "AC8: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "AC8: comment still posted" "<!-- retrospective-review: pr=108 -->" "$TMP_COMMENTS_DIR/pr-108.txt"
assert_eq "AC8: no issues created under --no-issues" "$(count_issue_creates)" "0"

# ---------- AC9: worktree EXIT cleanup → no orphaned `git worktree` entries ----------
printf '109\tMERGED\t2026-03-06T00:00:00Z\n110\tMERGED\t2026-03-06T00:00:00Z\n' > "$TMP/lookup9.tsv"
PR_LOOKUP="$TMP/lookup9.tsv" CODEX_MODE=clean0 run 109 110
assert_eq "AC9: exit 0" "$(cat "$TMP/rc")" "0"
assert_eq "AC9: no leftover worktrees after a 2-PR run" "$(git -C "$REPO_DIR" worktree list | wc -l | tr -d ' ')" "1"

# ---------- AC10: issue dedup by title prefix, independent of filing PR ----------
printf '111\tMERGED\t2026-03-07T00:00:00Z\n' > "$TMP/lookup10.tsv"
printf '[retrospective] finding one -- file.txt:1 -- needs fix (merged PR #999)\n' > "$TMP/existing-issues.txt"
GH_ISSUE_TITLES="$TMP/existing-issues.txt" PR_LOOKUP="$TMP/lookup10.tsv" CODEX_MODE=blocking2 run 111
assert_eq "AC10: exit 0" "$(cat "$TMP/rc")" "0"
assert_eq "AC10: only the non-duplicate finding creates an issue" "$(count_issue_creates)" "1"
assert_grep "AC10: the new issue is for 'finding two'" "finding two" "$ISSUE_CREATE_LOG"
assert_not_grep "AC10: the deduped 'finding one' is not re-created" "finding one" "$ISSUE_CREATE_LOG"

# ---------- stdin TSV pipeline mode (find-bailed-merged-prs.sh integration) ----------
printf '112\tMERGED\t2026-03-08T00:00:00Z\n' > "$TMP/lookup-stdin.tsv"
PR_LOOKUP="$TMP/lookup-stdin.tsv" CODEX_MODE=clean0 run_stdin "proj	112	BAILED"
assert_eq "stdin: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "stdin: PR number from TSV column 2 is picked up" "PR #112: 0 blocking finding(s) → review posted (PASSED)" "$TMP/out"

# ---------- gh pr view failure → logged, not fatal ----------
printf '199\tFAIL\t\n' > "$TMP/lookup-fail.tsv"
PR_LOOKUP="$TMP/lookup-fail.tsv" CODEX_MODE=clean0 run 199
# Single-PR batch where the only PR fails == "all PRs failed" per the
# script's own exit-code contract, so this is exit 1, not 0.
assert_eq "gh-fail: exit 1 (the only PR in the batch failed)" "$(cat "$TMP/rc")" "1"
assert_grep "gh-fail: logs the gh pr view failure" "PR #199: gh pr view failed → skipped" "$TMP/err"

# ---------- gh pr view failure alongside a success → non-fatal, overall exit 0 ----------
printf '198\tMERGED\t2026-03-09T00:00:00Z\n199\tFAIL\t\n' > "$TMP/lookup-mixed.tsv"
PR_LOOKUP="$TMP/lookup-mixed.tsv" CODEX_MODE=clean0 run 198 199
assert_eq "gh-fail-mixed: exit 0 (one success offsets the failure)" "$(cat "$TMP/rc")" "0"
assert_grep "gh-fail-mixed: the failing PR is still logged" "PR #199: gh pr view failed → skipped" "$TMP/err"
assert_grep "gh-fail-mixed: the other PR still succeeds" "PR #198: 0 blocking finding(s) → review posted (PASSED)" "$TMP/out"

# ---------- --help ----------
run --help
assert_eq "help: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "help: documents usage" "Usage:" "$TMP/out"
assert_grep "help: documents --dry-run" "--dry-run" "$TMP/out"

# ---------- unknown argument ----------
run --bogus 1
assert_eq "unknown-arg: exit 2" "$(cat "$TMP/rc")" "2"
assert_grep "unknown-arg: reports the unrecognized flag" "Unknown argument: --bogus" "$TMP/err"

# ---------- no PR numbers at all → fatal ----------
(cd "$REPO_DIR" && "$SCRIPT" --repo o/r < /dev/null >"$TMP/out" 2>"$TMP/err"); echo "$?" > "$TMP/rc"
assert_eq "no-prs: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "no-prs: reports no PR numbers provided" "no PR numbers provided" "$TMP/err"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
