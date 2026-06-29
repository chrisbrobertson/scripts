#!/bin/bash
# setup-branch-protection.sh — require the codex-review status check on the default branch.
#
# This is the operator-side companion to the babysit-with-review.sh wrapper.
# The wrapper POSTs a codex-review=success commit status immediately before
# merging a PR that has passed the Codex review cycle.  When branch protection
# is enabled with this required check, any merge attempt that bypasses the
# wrapper (e.g. implementation Claude running `gh pr merge` directly) is
# rejected by GitHub because the status was never set.
#
# DEPLOY ORDER:
#   1. Ship and deploy the updated babysit-with-review.sh (the wrapper must be
#      able to set the status before protection is active, or its own merges
#      will be blocked too).
#   2. Run this script per repo that the babysitter manages.
#
# Usage:
#   setup-branch-protection.sh [--repo OWNER/REPO] [--branch BRANCH]
#                               [--check CHECK_CONTEXT] [--dry-run]
#
#   --repo OWNER/REPO     GitHub repo to protect (default: detected via gh repo view)
#   --branch BRANCH       Branch to protect (default: repo default branch)
#   --check CHECK_CONTEXT Required status check context (default: codex-review)
#   --dry-run             Print the API payload without making any gh API calls
#
# Exit codes:
#   0   Protection applied (or dry-run completed)
#   1   Fatal: missing args, gh auth failure, API error

set -uo pipefail

REPO=""
BRANCH=""
CHECK_CONTEXT="codex-review"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    REPO="$2";           shift 2 ;;
    --branch)  BRANCH="$2";         shift 2 ;;
    --check)   CHECK_CONTEXT="$2";  shift 2 ;;
    --dry-run) DRY_RUN=1;           shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- resolve repo ----
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
  if [ -z "$REPO" ]; then
    echo "ERROR: --repo OWNER/REPO is required (or run from inside a git repo with a GitHub remote)" >&2
    exit 1
  fi
fi

# ---- resolve branch ----
if [ -z "$BRANCH" ]; then
  BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "")
  if [ -z "$BRANCH" ]; then
    echo "ERROR: could not detect default branch for $REPO; use --branch to specify" >&2
    exit 1
  fi
fi

echo "repo:    $REPO"
echo "branch:  $BRANCH"
echo "check:   $CHECK_CONTEXT"
echo ""

# ---- build payload ----
# PUT /repos/{owner}/{repo}/branches/{branch}/protection
# required_status_checks.strict=false: do not require branch to be up to date
#   before merging (strict mode would force rebases and is too disruptive for
#   the babysitter workflow; the status on the exact head SHA is what matters).
# enforce_admins=true: protection applies to admins too — critical so that
#   the authenticated account (which owns the token the babysitter uses) cannot
#   bypass it.
# required_pull_request_reviews: require at least 0 human approvals but, more
#   importantly, BLOCK DIRECT PUSHES — all changes must arrive via a PR. This
#   prevents `git push origin main` by the implementation agent entirely.
#   dismiss_stale_reviews=false: don't invalidate the codex-review status on
#   new commits (the status is per-SHA; a force-push would need a new status).
#   require_code_owner_reviews=false: no CODEOWNERS file needed.
#   required_approving_review_count=0: we use the codex-review status check as
#   the gate, not human approval. The PR requirement alone (count=0) blocks
#   direct pushes while letting gh pr merge --squash proceed normally.
# restrictions=null: any authenticated user can push branches and open PRs;
#   only direct pushes to the protected branch are blocked.

PAYLOAD=$(cat <<PAYLOAD_EOF
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["${CHECK_CONTEXT}"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null
}
PAYLOAD_EOF
)

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would PUT repos/${REPO}/branches/${BRANCH}/protection with payload:"
  echo "$PAYLOAD"
  echo ""
  echo "[dry-run] no changes made."
  exit 0
fi

# ---- apply protection ----
echo "Applying branch protection to ${REPO}:${BRANCH} ..."
if response=$(gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" \
    --input - <<< "$PAYLOAD" 2>&1); then
  echo "Branch protection applied successfully."
  echo ""
  echo "Required status checks now active:"
  printf '%s\n' "$response" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rsc = d.get("required_status_checks") or {}
for ctx in rsc.get("contexts", []):
    print(f"  - {ctx}")
' 2>/dev/null || true
  echo ""
  echo "enforce_admins: $(printf '%s\n' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("enforce_admins",{}).get("enabled","?"))' 2>/dev/null || echo "?")"
else
  echo "ERROR: gh api PUT failed:" >&2
  echo "$response" >&2
  exit 1
fi

echo ""
echo "Next steps:"
echo "  1. Verify: gh api repos/${REPO}/branches/${BRANCH}/protection"
echo "  2. Start the babysitter — it will set codex-review=success before each merge."
echo "  3. To remove protection later: gh api -X DELETE repos/${REPO}/branches/${BRANCH}/protection"
