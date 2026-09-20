#!/usr/bin/env bash
# bazaar-build.sh — build controller: dispatches bzr-ready issues to
# bazaar-build-worker.sh, one worktree and branch per issue, never merges.
# Spec: bazaar-builder-specs/L3-controller.md (BZR-FEAT-CONTROLLER),
#       bazaar-builder-specs/L3-build-worker.md (worker sentinel contract).
#
# Worker → controller sentinel (last line of $BZR_SENTINEL):
#   PR_READY <pr>        converged; parent → bzr-pr-ready
#   SPEC_GAP <reason>    precheck or spec not implementable; parent → bzr-blocked
#   BLOCKED <reason>     every sub-issue skipped or revert conflict; parent → bzr-blocked
#   STUCK <reason>       transient; counts as an attempt (parent → bzr-ready)
# Sub-issue labels (bzr-blocked on a skipped sub-issue) are written by the worker,
# which is the only exception to "controllers own labels": the parent's labels are
# always the controller's.
set -uo pipefail
BZR_SCRIPT_VERSION="0.1.0"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib/bazaar-common.sh
. "$SCRIPTS_DIR/lib/bazaar-common.sh"

ONLY_ISSUE=""; FORCE=0

role_usage_extra() {
  cat <<U
bazaar-build.sh only:
  --issue N                  Dispatch this issue once and exit; requires bzr-ready unless --force.
  --force                    Skip the label check (never the worker's precheck).
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
role_claim_label() { echo bzr-building; }
role_queue_label() { echo bzr-ready; }
role_release_label() { echo bzr-ready; }
role_worker_cmd() { echo "${BZR_WORKER_OVERRIDE:-$SCRIPTS_DIR/bazaar-build-worker.sh} $1"; }

role_candidates() {
  if [ -n "$ONLY_ISSUE" ]; then echo "$ONLY_ISSUE"; return 0; fi   # validated in main, below
  bzr_candidates '"bzr-ready" in i["labels"]'
}

# The PR a build worker opened for a parent: body carries <!-- bzr-build issue=N ... -->
build_pr_for() {  # <issue> → "number state mergedAt" or nothing
  gh pr list --repo "$REPO" --state all --limit 200 --json number,state,mergedAt,body 2>>"$LOG" | python3 -c '
import json, sys, re
n = sys.argv[1]
prs = [p for p in json.load(sys.stdin) if re.search(r"<!-- bzr-build issue=%s(\s|-)" % n, p.get("body") or "")]
prs.sort(key=lambda p: -p["number"])
if prs: print(prs[0]["number"], prs[0]["state"], prs[0].get("mergedAt") or "")' "$1"
}

sub_issues_of() {  # <issue> → lines "number state labels-csv"
  gh api "repos/$REPO/issues/$1/sub_issues" 2>>"$LOG" | python3 -c '
import json, sys
for c in json.load(sys.stdin):
    print(c["number"], c.get("state", "open").upper(), ",".join(l["name"] if isinstance(l, dict) else l for l in c.get("labels", [])))'
}

# Merged-PR sweep: bzr-pr-ready parents whose PR merged either close (all
# sub-issues closed) or go back to bzr-ready for the remaining unblocked
# sub-issues (round 2; the worker picks the -rN branch suffix).
role_sweeps() {
  local issue pr state merged line open_unblocked open_total
  for issue in $(bzr_issues_with_label bzr-pr-ready); do
    read -r pr state merged <<< "$(build_pr_for "$issue")"
    [ "${state:-}" = MERGED ] || continue
    open_unblocked=0; open_total=0
    while read -r n st labels; do
      [ -n "$n" ] || continue
      [ "$st" = OPEN ] || continue
      open_total=$((open_total + 1))
      case ",$labels," in *,bzr-blocked,*) ;; *) open_unblocked=$((open_unblocked + 1)) ;; esac
    done <<< "$(sub_issues_of "$issue")"
    if [ "$open_total" -eq 0 ]; then
      bzr_log "merged-sweep #$issue pr=$pr all sub-issues closed → closing parent"
      bzr_marker_comment "$issue" "<!-- bzr-build-merged pr=$pr ts=$(bzr_now) -->" "bazaar-build: PR #$pr merged and every sub-issue is closed; closing."
      gh issue close "$issue" --repo "$REPO" >>"$LOG" 2>&1 || true
    elif [ "$open_unblocked" -gt 0 ]; then
      bzr_log "merged-sweep #$issue pr=$pr $open_unblocked unblocked sub-issue(s) remain → bzr-ready (next round)"
      bzr_transition "$issue" bzr-ready bzr-pr-ready
      bzr_marker_comment "$issue" "<!-- bzr-build-merged pr=$pr ts=$(bzr_now) -->" "bazaar-build: PR #$pr merged; $open_unblocked sub-issue(s) still open and unblocked, so this issue is queued for another build round."
    else
      bzr_log "merged-sweep #$issue pr=$pr only blocked sub-issues remain; waiting for a human"
    fi
  done
}

role_on_worker_exit() {  # <issue> <rc> <word> <rest>
  local issue="$1" word="$3" rest="$4"
  case "$word" in
    PR_READY)
      [[ "$rest" =~ ^[0-9]+ ]] || { bzr_log "PR_READY without a PR number from #$issue"; return 1; }
      bzr_transition "$issue" bzr-pr-ready bzr-building; return 0 ;;
    SPEC_GAP) bzr_escalate "$issue" "spec gap: $rest"; return 0 ;;
    BLOCKED)  bzr_escalate "$issue" "$rest"; return 0 ;;
    *) return 1 ;;
  esac
}

role_audit() {
  local issue
  for issue in $(bzr_issues_with_label bzr-pr-ready); do
    [ -n "$(build_pr_for "$issue")" ] || echo "AUDIT #$issue is bzr-pr-ready but no build PR references it"
  done
}

bzr_init build "$@"
if [ -n "$ONLY_ISSUE" ]; then
  ONCE=1
  if [ "$FORCE" -eq 1 ]; then
    BZR_SKIP_LABEL_CHECK=1          # dispatch regardless of the issue's current labels
  elif ! bzr_has_label "$ONLY_ISSUE" bzr-ready; then
    echo "ERROR: issue #$ONLY_ISSUE is not bzr-ready (use --force to dispatch anyway)" >&2; exit 2
  fi
fi
bzr_controller_main
