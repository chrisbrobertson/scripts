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

role_claim_label() { echo bzr-drafting; }
role_queue_label() { echo ""; }
role_release_label() { echo ""; }
role_worker_cmd() { echo "${BZR_WORKER_OVERRIDE:-$SCRIPTS_DIR/bazaar-issue-worker.sh} $1"; }
role_candidates() { bzr_candidates 'not any(l.startswith("bzr-") for l in i["labels"])'; }

# ---------- local checkout for the approval sweep ----------
# Prefer the git repo we are running in; otherwise keep a clone under BZR_REPO_DIR.
project_root() {
  local top; top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$top" ]; then echo "$top"; return 0; fi
  local clone="$BZR_REPO_DIR/clone"
  [ -d "$clone/.git" ] || gh repo clone "$REPO" "$clone" -- --quiet >>"$LOG" 2>&1 || return 1
  echo "$clone"
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
  root=$(project_root) || return 1
  wt="$BZR_TMP/approve-$issue"
  git -C "$root" fetch --quiet origin "$branch" >>"$LOG" 2>&1 || return 1
  rm -rf "$wt"; git -C "$root" worktree prune >>"$LOG" 2>&1 || true
  git -C "$root" worktree add --quiet --detach "$wt" FETCH_HEAD >>"$LOG" 2>&1 || return 1
  : > "$BZR_TMP/l4-$issue.tsv"
  while IFS= read -r f; do
    [ -f "$wt/$f" ] || continue
    python3 - "$wt/$f" "$BZR_TMP/l4-$issue.tsv" "$f" <<'PY' && changed=1
import re, sys
path, l4out, rel = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
m = re.match(r"^---\n(.*?)\n---\n", s, re.S)
if not m: sys.exit(1)
fm = m.group(1)
if not re.search(r"^spec_type:", fm, re.M): sys.exit(1)
st = re.search(r"^spec_type:\s*(\S+)", fm, re.M).group(1)
sid = (re.search(r"^id:\s*(\S+)", fm, re.M) or [None, ""])[1]
if st == "task":
    title = ""
    t = re.search(r"^## TL;DR\s*\n+(.+)", s, re.M)
    if t: title = re.split(r"(?<=[.!?])\s", t.group(1).strip())[0][:120]
    open(l4out, "a").write("%s\t%s\t%s\n" % (sid, rel, title or rel))
new = re.sub(r"^status:\s*review\s*$", "status: ready", fm, count=1, flags=re.M)
if new == fm: sys.exit(1)
open(path, "w").write(s[:m.start(1)] + new + s[m.end(1):])
sys.exit(0)
PY
  done <<< "$(pr_files "$pr")"
  if [ "$changed" -eq 1 ]; then
    git -C "$wt" -c user.name="bazaar-issues" -c user.email="bazaar@localhost" commit --quiet -am "spec: mark ready per approval on #$issue" >>"$LOG" 2>&1 || return 1
    git -C "$wt" push --quiet origin "HEAD:refs/heads/$branch" >>"$LOG" 2>&1 || return 1
  fi
  git -C "$wt" rev-parse HEAD
  git -C "$root" worktree remove --force "$wt" >>"$LOG" 2>&1 || rm -rf "$wt"
}

# After a merge the head branch may be gone (auto-delete); read the merged files
# from origin/$DEFAULT_BRANCH instead. Writes $BZR_TMP/l4-<issue>.tsv.
collect_l4s_from_default() {  # <issue> <pr>
  local issue="$1" pr="$2" root f
  root=$(project_root) || return 1
  git -C "$root" fetch --quiet origin "$DEFAULT_BRANCH" >>"$LOG" 2>&1 || return 1
  : > "$BZR_TMP/l4-$issue.tsv"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # (python3 - reads its program from stdin, so the file content goes via a temp file)
    git -C "$root" show "origin/$DEFAULT_BRANCH:$f" > "$BZR_TMP/l4src" 2>/dev/null || continue
    python3 - "$BZR_TMP/l4-$issue.tsv" "$f" "$BZR_TMP/l4src" <<'PY' || true
import re, sys
s = open(sys.argv[3]).read(); l4out, rel = sys.argv[1], sys.argv[2]
m = re.match(r"^---\n(.*?)\n---\n", s, re.S)
if not m: sys.exit(0)
fm = m.group(1)
st = re.search(r"^spec_type:\s*(\S+)", fm, re.M)
if not st or st.group(1) != "task": sys.exit(0)
sid = (re.search(r"^id:\s*(\S+)", fm, re.M) or [None, ""])[1]
t = re.search(r"^## TL;DR\s*\n+(.+)", s, re.M)
title = re.split(r"(?<=[.!?])\s", t.group(1).strip())[0][:120] if t else rel
open(l4out, "a").write("%s\t%s\t%s\n" % (sid, rel, title))
PY
  done <<< "$(pr_files "$pr")"
}

sub_issue_markers() {  # <parent> → lines "number state spec-id"
  gh api "repos/$REPO/issues/$1/sub_issues" 2>>"$LOG" | python3 -c '
import json, sys, re
for c in json.load(sys.stdin):
    m = re.search(r"<!-- bzr-sub-issue parent=\d+ spec=(\S+) -->", c.get("body") or "")
    print(c["number"], c.get("state", "open").upper(), m.group(1) if m else "-")'
}

create_sub_issue() {  # <parent> <spec-id> <path> <title>
  local parent="$1" sid="$2" path="$3" title="$4" url num id body
  body="$BZR_TMP/sub-$parent-$RANDOM.md"
  printf '<!-- bzr-sub-issue parent=%s spec=%s -->\nImplements %s (`%s`), part of #%s.\n\nRefs #%s\n' "$parent" "$sid" "$sid" "$path" "$parent" "$parent" > "$body"
  url=$(gh issue create --repo "$REPO" --title "$title" --body-file "$body" 2>>"$LOG") || return 1
  num="${url##*/}"
  id=$(gh issue view "$num" --repo "$REPO" --json id 2>>"$LOG" | bzr_json id)
  gh api -X POST "repos/$REPO/issues/$parent/sub_issues" -F "sub_issue_id=$id" >>"$LOG" 2>&1 \
    || bzr_log "WARNING: created #$num but could not attach it as a sub-issue of #$parent"
  echo "$num"
}

# Reconcile draft-time sub-issues with the merged L4 list: create missing, close dropped.
reconcile_sub_issues() {  # <parent> ; reads $BZR_TMP/l4-<parent>.tsv ; prints created/kept numbers
  local parent="$1" sid path title num st have want=""
  [ -f "$BZR_TMP/l4-$parent.tsv" ] || { bzr_log "reconcile #$parent: no L4 list available; leaving sub-issues untouched"; return 0; }
  while IFS=$'\t' read -r sid path title; do [ -n "$sid" ] && want="$want $sid"; done < "$BZR_TMP/l4-$parent.tsv"
  local n_l4; n_l4=$(grep -c . "$BZR_TMP/l4-$parent.tsv" || true)
  [ "$n_l4" -ge 2 ] || want=""                      # zero or one L4 → no sub-issues
  local existing; existing=$(sub_issue_markers "$parent")
  while IFS=$'\t' read -r sid path title; do
    [ -n "$sid" ] || continue; [ -n "$want" ] || break
    if printf '%s\n' "$existing" | awk -v s="$sid" '$2=="OPEN" && $3==s {f=1} END{exit !f}'; then
      printf '%s\n' "$existing" | awk -v s="$sid" '$2=="OPEN" && $3==s {print $1}'
    else
      num=$(create_sub_issue "$parent" "$sid" "$path" "$title") && { bzr_log "sub-issue #$num created for $sid"; echo "$num"; }
    fi
  done < "$BZR_TMP/l4-$parent.tsv"
  while read -r num st sid; do
    [ -n "$num" ] && [ "$st" = OPEN ] || continue
    case " $want " in *" $sid "*) ;; *)
      bzr_log "sub-issue #$num ($sid) no longer in the approved spec set → closing"
      printf 'bazaar-issues: the approved spec no longer contains %s; closing this sub-issue.\n' "$sid" > "$BZR_TMP/close-$num.md"
      bzr_comment issue "$num" "$BZR_TMP/close-$num.md"; gh issue close "$num" --repo "$REPO" >>"$LOG" 2>&1 || true ;;
    esac
  done <<< "$existing"
}

# Rewrite the parent's "Specs:" line (ISSUE-TEMPLATE.md) to the merged spec set.
update_specs_line() {  # <parent> <pr>
  local parent="$1" pr="$2" specs="" f body   # bash expands all words before `local` assigns: no self-reference on one line
  body="$BZR_TMP/body-$parent.md"
  while IFS= read -r f; do specs="$specs $f"; done <<< "$(pr_files "$pr")"
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
  subs=$(reconcile_sub_issues "$issue" | tr '\n' ' ')
  update_specs_line "$issue" "$pr"
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
  done <<< "$(sub_issue_markers "$issue")"
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
bzr_controller_main
