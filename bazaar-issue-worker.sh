#!/usr/bin/env bash
# bazaar-issue-worker.sh <issue> — one issue: verify → (questions | normalise +
# classify) → draft specs + draft-time sub-issues → spec review cycle → sentinel.
# Spawned by bazaar-issues.sh; never run by hand except for debugging.
# Spec: bazaar-builder-specs/L3-issue-worker.md (BZR-FEAT-ISSUE-WORKER).
#
# Env from the controller: BZR_ISSUE BZR_REPO BZR_REPO_DIR BZR_HOME BZR_HOST BZR_LOG
#   DEFAULT_BRANCH BZR_SENTINEL SCRIPTS_DIR BZR_APPROVERS IMPLEMENTER* REVIEWER*
#   MAX_SPEC_REVIEW_CYCLES
# Sentinel (last line of $BZR_SENTINEL): SPEC_REVIEW <pr> | NEEDS_INFO <n> |
#   NOT_ACTIONABLE <reason> | BLOCKED <reason> | STUCK <reason>
# The worker never edits labels on the parent issue; the controller does.
set -uo pipefail
BZR_SCRIPT_VERSION="0.1.0"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ISSUE="${1:-${BZR_ISSUE:-}}"; [ -n "$ISSUE" ] || { echo "usage: bazaar-issue-worker.sh <issue>" >&2; exit 2; }
BZR_ROLE=issues; REPO="${BZR_REPO:?}"; LOG="${BZR_LOG:?}"; DRY_RUN=0
BZR_REPO_DIR="${BZR_REPO_DIR:?}"; DEFAULT_BRANCH="${DEFAULT_BRANCH:?}"; BZR_SENTINEL="${BZR_SENTINEL:?}"
IMPLEMENTER="${IMPLEMENTER:-claude}"; REVIEWER="${REVIEWER:-codex}"
MAX_SPEC_REVIEW_CYCLES="${MAX_SPEC_REVIEW_CYCLES:-4}"
# shellcheck source=lib/bazaar-common.sh
. "$SCRIPTS_DIR/lib/bazaar-common.sh"
# shellcheck source=lib/bazaar-review.sh
. "$SCRIPTS_DIR/lib/bazaar-review.sh"

BZR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bzr-issue-worker.XXXXXX") || exit 1
TMP_REVIEW="$BZR_TMP/review"; TMP_CODEX_FULL="$BZR_TMP/codex-full"; TMP_REVIEW_RESULT="$BZR_TMP/review-result"
RUN_DIR="$BZR_TMP/run"; mkdir -p "$RUN_DIR"; export BZR_RUN_DIR="$RUN_DIR"   # exported for test stubs
BRANCH="bzr/spec-$ISSUE"; WT="$BZR_REPO_DIR/wt/spec-$ISSUE"
SENTINEL_WRITTEN=0
ROOT=""

sentinel() {  # <word> [rest]
  printf '%s %s\n' "$1" "${2:-}" | sed 's/ $//' > "$BZR_SENTINEL"; SENTINEL_WRITTEN=1
  bzr_log "#$ISSUE sentinel=$1 ${2:-}"
}
finish() {
  local rc=$?
  if [ "$SENTINEL_WRITTEN" -eq 0 ]; then sentinel STUCK "worker exited rc=$rc before reaching a decision"; fi
  # safety push: never lose committed spec work
  if [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; then
    git -C "$WT" push --quiet origin "HEAD:refs/heads/$BRANCH" >>"$LOG" 2>&1 || true
    [ -n "$ROOT" ] && git -C "$ROOT" worktree remove --force "$WT" >>"$LOG" 2>&1 || true
  fi
  rm -rf "$BZR_TMP"
}
trap finish EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

marker() { printf '<!-- bzr-issue-worker phase=%s ts=%s -->' "$1" "$(bzr_now)"; }
comment_issue() {  # <phase> <body-file>  (marker line prepended)
  local f="$BZR_TMP/ci-$RANDOM.md"; { marker "$1"; printf '\n'; cat "$2"; } > "$f"; bzr_comment issue "$ISSUE" "$f"
}

# ---------- gather ----------
ROOT=$(bzr_project_root) || { sentinel STUCK "no local checkout of $REPO"; exit 1; }
git -C "$ROOT" fetch --quiet origin "$DEFAULT_BRANCH" >>"$LOG" 2>&1 || { sentinel STUCK "fetch origin/$DEFAULT_BRANCH failed"; exit 1; }
BASE_SHA=$(git -C "$ROOT" rev-parse "origin/$DEFAULT_BRANCH")
gh issue view "$ISSUE" --repo "$REPO" --json title,body,labels,comments,state > "$BZR_TMP/issue.json" 2>>"$LOG" || { sentinel STUCK "gh issue view failed"; exit 1; }
python3 - "$BZR_TMP/issue.json" "$RUN_DIR" <<'PY'
import json, sys, re, os
i = json.load(open(sys.argv[1])); d = sys.argv[2]
open(os.path.join(d, "title.txt"), "w").write(i.get("title") or "")
body = i.get("body") or ""
open(os.path.join(d, "body.md"), "w").write(body)
m = re.search(r"<details><summary>Original report</summary>\n\n(.*?)\n\n</details>", body, re.S)
open(os.path.join(d, "original.md"), "w").write(m.group(1) if m else body)
open(os.path.join(d, "labels.txt"), "w").write("\n".join(l["name"] for l in i.get("labels", [])))
open(os.path.join(d, "state.txt"), "w").write(i.get("state") or "")
qs = 0
with open(os.path.join(d, "comments.md"), "w") as f:
    for c in i.get("comments", []):
        b = c.get("body") or ""
        if "phase=questions" in b: qs += 1
        f.write("### %s at %s\n%s\n\n" % ((c.get("author") or {}).get("login", "?"), c.get("createdAt", ""), b))
open(os.path.join(d, "question_rounds.txt"), "w").write(str(qs))
PY
TITLE=$(cat "$RUN_DIR/title.txt"); QUESTION_ROUNDS=$(cat "$RUN_DIR/question_rounds.txt")
[ "$(cat "$RUN_DIR/state.txt")" = OPEN ] || { sentinel NOT_ACTIONABLE "issue is not open"; exit 0; }

SPEC_DIR=$(bzr_spec_dir_at "$ROOT" "origin/$DEFAULT_BRANCH") || {
  printf 'bazaar-issues: this repository has no spec corpus (`specs/` or `*-specs/`), so the issue loop cannot draft a spec for it. Bootstrap a corpus from `spec-guide.md` first, then remove `bzr-blocked`.\n' > "$BZR_TMP/nc.md"
  comment_issue verify "$BZR_TMP/nc.md"; sentinel NOT_ACTIONABLE "no spec corpus in $REPO"; exit 0; }
SPEC_GUIDE="$SCRIPTS_DIR/spec-guide.md"

# ---------- worktree (resume if the branch exists on origin) ----------
git -C "$ROOT" worktree prune >>"$LOG" 2>&1 || true
rm -rf "$WT"
RESUMED=0
if git -C "$ROOT" fetch --quiet origin "$BRANCH" >>"$LOG" 2>&1; then
  git -C "$ROOT" worktree add --quiet --detach "$WT" FETCH_HEAD >>"$LOG" 2>&1 || { sentinel STUCK "worktree add (resume) failed"; exit 1; }
  RESUMED=1; bzr_log "#$ISSUE resuming existing branch $BRANCH"
else
  git -C "$ROOT" worktree add --quiet --detach "$WT" "$BASE_SHA" >>"$LOG" 2>&1 || { sentinel STUCK "worktree add failed"; exit 1; }
fi
git -C "$WT" config user.name "bazaar-issue-worker" >/dev/null; git -C "$WT" config user.email "bazaar@localhost" >/dev/null

# ---------- pass A: verify, normalise, classify ----------
cat > "$BZR_TMP/promptA.txt" <<EOP
You are the issue-verification step of Bazaar Builder for GitHub issue #$ISSUE in $REPO. The repository is checked out here (branch $BRANCH, based on $DEFAULT_BRANCH). Spec corpus: ./$SPEC_DIR (schema: $SPEC_GUIDE). Do NOT edit any file in the repository, do NOT run gh, git push, or anything that changes GitHub state. Write your outputs ONLY into the scratch directory $RUN_DIR.

Issue title: $TITLE
Issue labels: $(tr '\n' ' ' < "$RUN_DIR/labels.txt")
Prior question rounds on this issue: $QUESTION_ROUNDS

Issue body (current):
---
$(cat "$RUN_DIR/body.md")
---

All comments so far (agent comments carry <!-- bzr- markers; human replies do not):
---
$(cat "$RUN_DIR/comments.md")
---

Step 1 — verify against the checklist, using the issue, its comments (a human may already have answered earlier questions: never re-ask an answered question), any linked issues, the spec corpus, and the code:
  a. problem statement present   b. desired outcome present   c. acceptance criteria present or derivable
  d. scope bounded   e. no contradiction with the codebase or existing specs   f. not a duplicate of an open issue
Resolve what you can from the repository yourself. Only what you genuinely cannot establish becomes a question.

Step 2 — decide:
  * If it is a duplicate, a pure question, or otherwise not a change to build: write the reason to $RUN_DIR/not_actionable.txt and finish with NOT_ACTIONABLE <one line>.
  * If unresolved gaps remain: write numbered questions to $RUN_DIR/questions.md, each stating which decision it unblocks, and finish with NEEDS_INFO <count>.
  * Otherwise write:
      $RUN_DIR/normalised.md   — the body in this exact template (no details block; the wrapper appends the original):
          ## Problem / ## Desired outcome / ## Acceptance criteria (- [ ] items) / ## Scope (In:/Out:) / ## Type (bug|feature) / ## Links (Specs: none yet; Related: #n)
          Fill only what the issue, comments, linked issues, or the repository establish.
      $RUN_DIR/classification.txt — first line "bug" or "feature" (label wins if present: bug → bug; enhancement/feature → feature), second line the evidence.
    and finish with VERIFY_OK.

End your final message with EXACTLY ONE sentinel on its own last line: VERIFY_OK | NEEDS_INFO <n> | NOT_ACTIONABLE <reason> | STUCK <reason>
EOP
echo "  [$IMPLEMENTER implementer] verifying #$ISSUE..." >&2
if ! run_implementer "$(cat "$BZR_TMP/promptA.txt")" "$BZR_TMP/resultA" "$WT"; then sentinel STUCK "$IMPLEMENTER failed during verification"; exit 1; fi
LAST=$(sed -e 's/[[:space:]]*$//' "$BZR_TMP/resultA" | grep -v '^$' | tail -n 1)
case "$LAST" in
  NOT_ACTIONABLE*)
    reason="${LAST#NOT_ACTIONABLE}"; reason="${reason# }"
    { printf 'bazaar-issues: this issue was judged not actionable as a change: %s\n\n' "${reason:-see below}"; [ -f "$RUN_DIR/not_actionable.txt" ] && cat "$RUN_DIR/not_actionable.txt"; printf '\nIf that is wrong, edit the issue and remove `bzr-blocked`.\n'; } > "$BZR_TMP/na.md"
    comment_issue verify "$BZR_TMP/na.md"; sentinel NOT_ACTIONABLE "${reason:-not a buildable change}"; exit 0 ;;
  NEEDS_INFO*)
    if [ "$QUESTION_ROUNDS" -ge 2 ]; then
      printf 'bazaar-issues: two rounds of questions have not made this issue buildable. It needs a synchronous conversation; rewrite the issue and remove `bzr-blocked` when it is ready.\n' > "$BZR_TMP/b.md"
      comment_issue questions "$BZR_TMP/b.md"; sentinel BLOCKED "needs a synchronous conversation after $QUESTION_ROUNDS question rounds"; exit 0
    fi
    [ -s "$RUN_DIR/questions.md" ] || { sentinel STUCK "implementer said NEEDS_INFO but wrote no questions"; exit 1; }
    n=$(grep -cE '^[0-9]+\.' "$RUN_DIR/questions.md" || true)
    { printf 'bazaar-issues: before this issue can be specified, please answer:\n\n'; cat "$RUN_DIR/questions.md"; printf '\nReply in a comment; the issue is requeued automatically when you do.\n'; } > "$BZR_TMP/q.md"
    comment_issue questions "$BZR_TMP/q.md"; sentinel NEEDS_INFO "${n:-1}"; exit 0 ;;
  VERIFY_OK) ;;
  *) sentinel STUCK "verification ended without a sentinel"; exit 1 ;;
esac
[ -s "$RUN_DIR/normalised.md" ] && [ -s "$RUN_DIR/classification.txt" ] || { sentinel STUCK "VERIFY_OK without normalised.md/classification.txt"; exit 1; }
CLASS=$(head -n 1 "$RUN_DIR/classification.txt" | tr '[:upper:]' '[:lower:]')

# normalise the body: agent's sections + the original report, verbatim, in a details block (invariant 8)
{ cat "$RUN_DIR/normalised.md"; printf '\n\n<details><summary>Original report</summary>\n\n'; cat "$RUN_DIR/original.md"; printf '\n\n</details>\n'; } > "$BZR_TMP/newbody.md"
gh issue edit "$ISSUE" --repo "$REPO" --body-file "$BZR_TMP/newbody.md" >>"$LOG" 2>&1 || bzr_log "#$ISSUE WARNING: body normalisation edit failed"

# ---------- pass B: draft specs ----------
cat > "$BZR_TMP/promptB.txt" <<EOP
You are the spec-drafting step of Bazaar Builder for GitHub issue #$ISSUE in $REPO, classified as: $CLASS. The repository is checked out on branch $BRANCH (based on $DEFAULT_BRANCH). Spec corpus: ./$SPEC_DIR. Schema: $SPEC_GUIDE — read it first, and read ./CLAUDE.md and the existing specs in ./$SPEC_DIR before writing.
$( [ "$RESUMED" -eq 1 ] && echo "This branch already contains an earlier draft attempt; continue it rather than starting over." )

Issue title: $TITLE
Issue body (normalised):
---
$(cat "$RUN_DIR/normalised.md")
---

Requirements:
1. bug → one L4 task spec whose parent_feature is the existing L3 that owns the behaviour (create that L3 too only if none exists). feature → a new or amended L3 plus one L4 per PR-sized unit of work. Two or more L4s become GitHub sub-issues automatically; keep each L4 genuinely PR-sized.
2. Every file you add or change must be under ./$SPEC_DIR (specs, index.md, log.md). Do not change code, tests, or configuration. Do not run gh, push, open a PR, or edit issues; the wrapper owns lifecycle.
3. Frontmatter per the schema, status: review, ids per the corpus prefix. Cite the issue URL https://github.com/$REPO/issues/$ISSUE in each new spec.
4. Never infer a design decision: unknowns become [ASSUMPTION] with "Flips if:" or [OPEN: … — owner: …]. Do not mark anything status: ready.
5. Update ./$SPEC_DIR/index.md and append to ./$SPEC_DIR/log.md if they exist.
6. Commit your work on this branch (do not rename the branch).

End your final message with EXACTLY ONE sentinel on its own last line: DRAFT_DONE | STUCK <reason>
EOP
echo "  [$IMPLEMENTER implementer] drafting specs for #$ISSUE..." >&2
if ! run_implementer "$(cat "$BZR_TMP/promptB.txt")" "$BZR_TMP/resultB" "$WT"; then sentinel STUCK "$IMPLEMENTER failed during drafting"; exit 1; fi
LAST=$(sed -e 's/[[:space:]]*$//' "$BZR_TMP/resultB" | grep -v '^$' | tail -n 1)
case "$LAST" in DRAFT_DONE) ;; STUCK*) sentinel STUCK "drafting: ${LAST#STUCK }"; exit 1 ;; *) sentinel STUCK "drafting ended without a sentinel"; exit 1 ;; esac

# Only spec-dir Markdown may change (invariant 6); at least one spec with frontmatter.
validate_spec_paths() {  # <worktree> <base-sha>
  local wt="$1" base="$2" p n=0
  { git -C "$wt" diff --name-only "$base"; git -C "$wt" ls-files --others --exclude-standard; } | sort -u > "$BZR_TMP/paths"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in "$SPEC_DIR"/*.md) ;; *) echo "out-of-scope change: $p" >&2; return 1 ;; esac
    [ -f "$wt/$p" ] && grep -q '^spec_type:' "$wt/$p" && n=$((n+1))
  done < "$BZR_TMP/paths"
  [ "$n" -ge 1 ] || { echo "no spec file with frontmatter changed" >&2; return 1; }
}
git -C "$WT" add -A -- "$SPEC_DIR" >>"$LOG" 2>&1 || true
git -C "$WT" diff --cached --quiet || git -C "$WT" commit --quiet -m "docs(spec): draft for #$ISSUE" >>"$LOG" 2>&1
if ! validate_spec_paths "$WT" "$BASE_SHA" 2>"$BZR_TMP/verr"; then
  sentinel BLOCKED "draft violated the spec-only contract: $(tr '\n' ' ' < "$BZR_TMP/verr")"; exit 0
fi
[ "$(git -C "$WT" rev-parse HEAD)" != "$BASE_SHA" ] || { sentinel STUCK "no committed spec change"; exit 1; }
git -C "$WT" push --quiet -u origin "HEAD:refs/heads/$BRANCH" >>"$LOG" 2>&1 || { sentinel STUCK "push of $BRANCH failed"; exit 1; }

# ---------- PR (reuse an open one on this branch) ----------
PR=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number 2>>"$LOG" | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p[0]["number"] if p else "")')
SPEC_PATHS=$(grep -v 'index\.md$\|log\.md$' "$BZR_TMP/paths" | tr '\n' ' ')
if [ -z "$PR" ]; then
  cat > "$BZR_TMP/prbody.md" <<EOP
<!-- bzr-spec issue=$ISSUE class=$CLASS -->
## Spec draft for #$ISSUE ($CLASS)

Refs #$ISSUE

Specs: $(for p in $SPEC_PATHS; do printf '`%s` ' "$p"; done)

This PR opens as a draft and stays there until the adversarial spec review reports zero BLOCKING findings against the rest of \`$SPEC_DIR/\`, the schema, and the code. Once it is out of draft, review it yourself; a comment containing the word approved (or a GitHub approval) from $BZR_APPROVERS merges it, marks the specs ready, and queues the issue for the build loop.
EOP
  PR_URL=$(gh pr create --repo "$REPO" --head "$BRANCH" --base "$DEFAULT_BRANCH" --draft --title "[spec] #$ISSUE $TITLE" --body-file "$BZR_TMP/prbody.md" 2>>"$LOG") || { sentinel STUCK "gh pr create failed"; exit 1; }
  PR="${PR_URL##*/}"; bzr_log "#$ISSUE draft PR #$PR opened"
else
  bzr_log "#$ISSUE reusing open PR #$PR"
fi

# ---------- draft-time sub-issues ----------
collect_l4s() {  # → $BZR_TMP/l4.tsv from the worktree's changed spec files
  : > "$BZR_TMP/l4.tsv"; local p
  { git -C "$WT" diff --name-only "$BASE_SHA"; } | sort -u | while IFS= read -r p; do
    [ -f "$WT/$p" ] && bzr_l4_from_file "$WT/$p" "$p" "$BZR_TMP/l4.tsv"
  done
}
collect_l4s; SUBS=$(bzr_reconcile_sub_issues "$ISSUE" "$BZR_TMP/l4.tsv" | tr '\n' ' ')

# ---------- spec review cycle ----------
PRIMARY=$(printf '%s\n' $SPEC_PATHS | grep '/L3-' | head -n 1); [ -n "$PRIMARY" ] || PRIMARY=$(printf '%s\n' $SPEC_PATHS | head -n 1)
rc=0
run_review_cycle --mode spec --pr "$PR" --worktree "$WT" --branch "$BRANCH" --max-cycles "$MAX_SPEC_REVIEW_CYCLES" \
  --spec-path "${SPEC_PATHS% }" --spec-dir "$SPEC_DIR" --spec-guide "$SPEC_GUIDE" \
  --ticket "#$ISSUE" --ticket-url "https://github.com/$REPO/issues/$ISSUE" --ticket-title "$TITLE" --ticket-body "$(cat "$RUN_DIR/normalised.md")" \
  --validate-cmd "validate_spec_paths '$WT' '$BASE_SHA'" || rc=$?
collect_l4s; SUBS=$(bzr_reconcile_sub_issues "$ISSUE" "$BZR_TMP/l4.tsv" | tr '\n' ' ')   # the review may have changed the L4 set
case "$rc" in
  0)
    gh pr ready "$PR" --repo "$REPO" >>"$LOG" 2>&1 || bzr_log "#$ISSUE WARNING: gh pr ready failed; PR stays draft"
    cat > "$BZR_TMP/done.md" <<EOP
bazaar-issues: the spec draft for this issue converged after $REVIEW_CYCLES_RUN review cycle(s) and is ready for your review: https://github.com/$REPO/pull/$PR

Specs: $(for p in $SPEC_PATHS; do printf '`%s` ' "$p"; done)
Sub-issues (one per L4): ${SUBS:-none}

To accept, comment on the PR with a line containing the word approved, or approve it as a GitHub review. That merges the specs, marks them ready, and queues this issue for the build loop.
EOP
    comment_issue review "$BZR_TMP/done.md"; sentinel SPEC_REVIEW "$PR" ;;
  10|20)
    printf 'bazaar-issues: spec review stopped: %s\n\nFinal review is in the comments above. Fix the draft by hand and comment approved, or close this PR to reject it; either way remove `bzr-blocked` from #%s afterwards.\n' "$REVIEW_FAIL_REASON" "$ISSUE" > "$BZR_TMP/fail.md"
    { marker review; printf '\n'; cat "$BZR_TMP/fail.md"; } > "$BZR_TMP/failm.md"; bzr_comment pr "$PR" "$BZR_TMP/failm.md"
    sentinel BLOCKED "spec review: $REVIEW_FAIL_REASON" ;;
  2|3|4) sentinel STUCK "reviewer unavailable: $REVIEW_FAIL_REASON" ;;
  *) sentinel STUCK "review cycle rc=$rc" ;;
esac
exit 0
