#!/usr/bin/env bash
# bazaar-issues.sh — issue controller: intake (any open issue with no bzr-*
# label) → bazaar-issue-worker.sh → spec PR → human approval → bzr-ready.
# Spec: bazaar-builder-specs/L3-controller.md (BZR-FEAT-CONTROLLER),
#       bazaar-builder-specs/L3-issue-worker.md (worker sentinel contract).
#
# Worker → controller sentinel (last line of $BZR_SENTINEL):
#   SPEC_REVIEW <pr>        spec PR non-draft at 0 BLOCKING; issue → bzr-spec-review
#   NEEDS_INFO <n>          questions posted; issue → bzr-needs-info
#   NOT_ACTIONABLE <reason> duplicate / no corpus / question; issue → bzr-blocked
#   BLOCKED <reason>        spec review cap or bail; issue → bzr-blocked
#   STUCK <reason>          transient; attempt counted, claim label removed
#
# Sweeps (issue role): dead-pid release (common), bounce replies, approval,
# rejected spec PR.
set -uo pipefail
BZR_SCRIPT_VERSION="0.1.0"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib/bazaar-common.sh
. "$SCRIPTS_DIR/lib/bazaar-common.sh"
# shellcheck source=lib/bazaar-review.sh
. "$SCRIPTS_DIR/lib/bazaar-review.sh"   # for post_codex_review_status only

ONLY_ISSUE=""; FORCE=0
role_usage_extra() {
  cat <<U
bazaar-issues.sh only:
  --issue N                  Dispatch this issue once and exit; it must carry no bzr-* label unless --force.
  --force                    Dispatch even if the issue carries a bzr-* label (it is replaced by bzr-drafting).
U
}
role_parse_arg() {
  case "$1" in
    --issue) [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+$ ]] || bzr_die_usage "--issue requires a number"; ONLY_ISSUE="$2"; BZR_ROLE_CONSUMED=2 ;;
    --issue=*) ONLY_ISSUE="${1#*=}"; [[ "$ONLY_ISSUE" =~ ^[0-9]+$ ]] || bzr_die_usage "--issue requires a number"; BZR_ROLE_CONSUMED=1 ;;
    --force) FORCE=1; BZR_ROLE_CONSUMED=1 ;;
    *) BZR_ROLE_CONSUMED=0 ;;
  esac
}
role_claim_label() { echo bzr-drafting; }
role_queue_label() { echo ""; }
role_release_label() { echo ""; }
role_worker_cmd() { echo "${BZR_WORKER_OVERRIDE:-$SCRIPTS_DIR/bazaar-issue-worker.sh} $1"; }
# Intake: no bzr-* label, and not a draft-time sub-issue whose parent link has not
# landed yet (gh issue create returns before the sub_issues POST attaches it).
role_candidates() {
  if [ -n "$ONLY_ISSUE" ]; then echo "$ONLY_ISSUE"; return 0; fi   # validated in main, below
  bzr_candidates 'not i["sub_marker"] and not any(l.startswith("bzr-") for l in i["labels"])'
}

# After a merge the head branch may be gone (auto-delete); read the merged files
# from origin/$DEFAULT_BRANCH instead. Writes $BZR_TMP/l4-<issue>.tsv.
collect_l4s_from_default() {  # <issue> <pr>
  local issue="$1" pr="$2" root f
  root=$(bzr_project_root) || return 1
  git -C "$root" fetch --quiet origin "$DEFAULT_BRANCH" >>"$LOG" 2>&1 || return 1
  : > "$BZR_TMP/l4-$issue.tsv"; : > "$BZR_TMP/specs-$issue.txt"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$root" show "origin/$DEFAULT_BRANCH:$f" > "$BZR_TMP/l4src" 2>/dev/null || continue
    grep -q '^spec_type:' "$BZR_TMP/l4src" && echo "$f" >> "$BZR_TMP/specs-$issue.txt"
    bzr_l4_from_file "$BZR_TMP/l4src" "$f" "$BZR_TMP/l4-$issue.tsv"
  done <<< "$(pr_files "$pr")"
}

spec_pr_for() {  # <issue> → "number state isDraft mergedAt headRefOid" or nothing
  gh pr list --repo "$REPO" --head "bzr/spec-$1" --state all --limit 20 --json number,state,isDraft,mergedAt,headRefOid,body 2>>"$LOG" | python3 -c '
import json, sys
prs = sorted(json.load(sys.stdin), key=lambda p: -p["number"])
if prs:
    p = prs[0]; print(p["number"], p["state"], str(p["isDraft"]).lower(), p.get("mergedAt") or "", p.get("headRefOid") or "")'
}

# Human approval on a spec PR: a GitHub review in state APPROVED, or a comment
# matching \bapproved\b (case-insensitive, negations excluded, marker comments
# excluded), either from a login in BZR_APPROVERS ("*" = anyone).
pr_is_approved() {  # <pr>
  gh pr view "$1" --repo "$REPO" --json reviews,comments 2>>"$LOG" | python3 -c '
import json, sys, re
approvers = [a.strip() for a in sys.argv[1].split(",") if a.strip()]
ok = lambda login: "*" in approvers or login in approvers
p = json.load(sys.stdin)
for r in p.get("reviews", []):
    if r.get("state") == "APPROVED" and ok((r.get("author") or {}).get("login", "")): sys.exit(0)
neg = re.compile(r"\b(not|isn.t|un|never|before|until)\W{0,3}approved\b|\bunapproved\b", re.I)
pos = re.compile(r"\bapproved\b", re.I)
for c in p.get("comments", []):
    b = c.get("body") or ""
    if "<!-- bzr-" in b or b.lstrip().startswith(("**Codex review", "**Claude review", "**bazaar", "**babysit")): continue
    if not ok((c.get("author") or {}).get("login", "")): continue
    if pos.search(b) and not neg.search(b): sys.exit(0)
sys.exit(1)' "$BZR_APPROVERS"
}

pr_files() { gh pr view "$1" --repo "$REPO" --json files 2>>"$LOG" | python3 -c 'import json,sys; [print(f["path"]) for f in json.load(sys.stdin).get("files", [])]'; }

# Flip status: review → ready in every changed spec file on the PR branch, commit,
# push. Prints the resulting head SHA. Also leaves the L4 list for this issue in
# $BZR_TMP/l4-<issue>.tsv (id<TAB>path<TAB>title) read from the branch.
flip_spec_status() {  # <issue> <pr> → head sha
  local issue="$1" pr="$2" root wt branch="bzr/spec-$1" f changed=0
  root=$(bzr_project_root) || return 1
  wt="$BZR_TMP/approve-$issue"
  git -C "$root" fetch --quiet origin "$branch" >>"$LOG" 2>&1 || return 1
  rm -rf "$wt"; git -C "$root" worktree prune >>"$LOG" 2>&1 || true
  git -C "$root" worktree add --quiet --detach "$wt" FETCH_HEAD >>"$LOG" 2>&1 || return 1
  : > "$BZR_TMP/l4-$issue.tsv"; : > "$BZR_TMP/specs-$issue.txt"
  while IFS= read -r f; do
    [ -f "$wt/$f" ] || continue
    grep -q '^spec_type:' "$wt/$f" && echo "$f" >> "$BZR_TMP/specs-$issue.txt"   # index.md / log.md are not specs
    bzr_l4_from_file "$wt/$f" "$f" "$BZR_TMP/l4-$issue.tsv"
    bzr_flip_status_ready "$wt/$f" && changed=1
  done <<< "$(pr_files "$pr")"
  if [ "$changed" -eq 1 ]; then
    git -C "$wt" -c user.name="bazaar-issues" -c user.email="bazaar@localhost" commit --quiet -am "spec: mark ready per approval on #$issue" >>"$LOG" 2>&1 || return 1
    git -C "$wt" push --quiet origin "HEAD:refs/heads/$branch" >>"$LOG" 2>&1 || return 1
  fi
  git -C "$wt" rev-parse HEAD
  git -C "$root" worktree remove --force "$wt" >>"$LOG" 2>&1 || rm -rf "$wt"
}

# Rewrite the parent's "Specs:" line (ISSUE-TEMPLATE.md) to the merged spec files
# (only files with spec frontmatter; index.md/log.md changes are not specs).
update_specs_line() {  # <parent> <specs-list-file>
  local parent="$1" list="$2" specs="" f body   # bash expands all words before `local` assigns: no self-reference on one line
  body="$BZR_TMP/body-$parent.md"
  while IFS= read -r f; do [ -n "$f" ] && specs="$specs $f"; done < "$list"
  gh issue view "$parent" --repo "$REPO" --json body 2>>"$LOG" | python3 -c '
import json, sys, re
b = json.load(sys.stdin).get("body") or ""
line = "Specs: " + ", ".join("`%s`" % p for p in sys.argv[1].split())
if re.search(r"^Specs:.*$", b, re.M): b = re.sub(r"^Specs:.*$", line, b, count=1, flags=re.M)
else: b = b.rstrip() + "\n\n## Links\n" + line + "\n"
sys.stdout.write(b)' "$specs" > "$body"
  [ "$DRY_RUN" -eq 1 ] || gh issue edit "$parent" --repo "$REPO" --body-file "$body" >>"$LOG" 2>&1
}

approve_issue() {  # <issue> <pr> <state> <mergedAt>
  local issue="$1" pr="$2" state="$3" merged="$4" sha subs
  if [ "$state" != MERGED ]; then
    sha=$(flip_spec_status "$issue" "$pr") || { bzr_log "approval #$issue: status flip failed"; return 1; }
    post_codex_review_status "$sha" "$pr" "spec approved by a human; bazaar-issues status flip" \
      || bzr_log "approval #$issue: WARNING codex-review status post failed for ${sha:0:8}"
    if ! gh pr merge "$pr" --repo "$REPO" --merge >>"$LOG" 2>&1; then
      printf 'bazaar-issues: approval seen on PR #%s but the merge failed. Fix the PR (conflicts or checks) and the sweep will retry once its head changes.\n' "$pr" > "$BZR_TMP/mf-$issue.md"
      bzr_comment issue "$issue" "$BZR_TMP/mf-$issue.md"; bzr_log "approval #$issue: merge of PR #$pr failed"; return 1
    fi
    bzr_log "approved #$issue pr=$pr merged head=${sha:0:8}"
  else
    bzr_log "approval #$issue: PR #$pr already merged; resuming at sub-issue reconciliation"
    collect_l4s_from_default "$issue" "$pr" || { bzr_log "approval #$issue: could not read merged specs from origin/$DEFAULT_BRANCH; leaving sub-issues untouched"; return 1; }
  fi
  subs=$(bzr_reconcile_sub_issues "$issue" "$BZR_TMP/l4-$issue.tsv" | tr '\n' ' ')
  update_specs_line "$issue" "$BZR_TMP/specs-$issue.txt"
  bzr_transition "$issue" bzr-ready bzr-spec-review
  bzr_marker_comment "$issue" "<!-- bzr-spec-merged pr=$pr ts=$(bzr_now) -->" \
    "bazaar-issues: spec PR #$pr merged. Sub-issues: ${subs:-none}. This issue is now ready for the build loop."
}

reject_issue() {  # <issue> <pr>
  local issue="$1" pr="$2" num st sid
  while read -r num st sid; do
    [ -n "$num" ] && [ "$st" = OPEN ] || continue
    printf 'bazaar-issues: spec PR #%s was closed without merging; closing this draft-time sub-issue.\n' "$pr" > "$BZR_TMP/rj-$num.md"
    bzr_comment issue "$num" "$BZR_TMP/rj-$num.md"; gh issue close "$num" --repo "$REPO" >>"$LOG" 2>&1 || true
  done <<< "$(bzr_sub_issue_markers "$issue")"
  bzr_escalate "$issue" "spec PR #$pr was closed without merging (rejected). Its draft-time sub-issues were closed."
}

# Bounce: a human comment newer than the agent's last marker comment requeues.
sweep_bounce() {
  local issue
  for issue in $(bzr_issues_with_label bzr-needs-info); do
    if bzr_issue_comments "$issue" | python3 -c '
import sys
last_marker = ""; newer = False
rows = [l.rstrip("\n").split("\t", 2) for l in sys.stdin if l.strip()]
for ts, author, body in rows:
    if "<!-- bzr-" in body: last_marker = max(last_marker, ts)
for ts, author, body in rows:
    if "<!-- bzr-" not in body and ts > last_marker: newer = True
sys.exit(0 if newer else 1)'; then
      bzr_log "bounce #$issue human replied → intake"
      bzr_transition "$issue" "" bzr-needs-info
    fi
  done
}

sweep_approvals() {
  local issue pr state draft merged sha
  for issue in $(bzr_issues_with_label bzr-spec-review); do
    read -r pr state draft merged sha <<< "$(spec_pr_for "$issue")"
    [ -n "${pr:-}" ] || { bzr_log "spec-review #$issue has no spec PR on bzr/spec-$issue"; continue; }
    case "$state" in
      MERGED) approve_issue "$issue" "$pr" MERGED "$merged" ;;
      CLOSED) reject_issue "$issue" "$pr" ;;
      OPEN)
        [ "$draft" = true ] && continue
        pr_is_approved "$pr" || continue
        [ "$DRY_RUN" -eq 1 ] && { echo "would approve #$issue via PR #$pr"; continue; }
        approve_issue "$issue" "$pr" OPEN "" ;;
    esac
  done
}

role_sweeps() { sweep_bounce; sweep_approvals; }

# --dry-run: report what the sweeps would do without any write.
role_dry_sweeps() {
  local issue pr state draft merged sha
  for issue in $(bzr_issues_with_label bzr-spec-review); do
    read -r pr state draft merged sha <<< "$(spec_pr_for "$issue")"
    [ -n "${pr:-}" ] || continue
    case "$state" in
      MERGED) echo "would resume approval of #$issue (PR #$pr already merged)" ;;
      CLOSED) echo "would escalate #$issue (spec PR #$pr closed unmerged)" ;;
      OPEN) [ "$draft" = true ] && continue; pr_is_approved "$pr" && echo "would approve #$issue via PR #$pr" ;;
    esac
  done
}

role_on_worker_exit() {  # <issue> <rc> <word> <rest>
  local issue="$1" word="$3" rest="$4"
  case "$word" in
    SPEC_REVIEW) [[ "$rest" =~ ^[0-9]+ ]] || return 1; bzr_transition "$issue" bzr-spec-review bzr-drafting; return 0 ;;
    NEEDS_INFO)  bzr_transition "$issue" bzr-needs-info bzr-drafting; return 0 ;;
    NOT_ACTIONABLE) bzr_escalate "$issue" "not actionable: $rest"; return 0 ;;
    BLOCKED)     bzr_escalate "$issue" "$rest"; return 0 ;;
    *) return 1 ;;
  esac
}

role_audit() {
  local issue
  for issue in $(bzr_issues_with_label bzr-spec-review); do
    [ -n "$(spec_pr_for "$issue")" ] || echo "AUDIT #$issue is bzr-spec-review but has no PR on bzr/spec-$issue"
  done
}

bzr_init issues "$@"
if [ -n "$ONLY_ISSUE" ]; then
  ONCE=1
  if [ "$FORCE" -eq 1 ]; then BZR_SKIP_LABEL_CHECK=1
  elif bzr_issue_labels "$ONLY_ISSUE" | grep -q '^bzr-'; then
    echo "ERROR: issue #$ONLY_ISSUE already carries a bzr-* label ($(bzr_issue_labels "$ONLY_ISSUE" | grep '^bzr-' | tr '\n' ' ')); use --force to redraft" >&2; exit 2
  fi
fi
bzr_controller_main
