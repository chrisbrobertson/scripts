#!/bin/bash
# babysit-work-prep.sh — turn GitHub/Jira tickets into human-approved TIF specs.
#
# The approval sweep runs first, then up to --max-tickets new spec drafts are
# created. Every draft is isolated in a git worktree and opened as a draft PR.
#
# Every draft is then driven through an adversarial spec review cycle — the same
# convergent reviewer/implementer loop babysit-with-review.sh and
# babysit-builder.sh use — checking the new spec against the existing corpus for
# contradiction, undeclared duplication, dangling references, schema violations
# and unimplementable requirements. The PR stays a DRAFT until the review reaches
# zero BLOCKING findings, and the approval sweep refuses to act on a draft, so a
# human is never asked to approve an unreviewed spec.
#
# An authorized `approved` comment then merges the spec PR and creates the
# `build-ready` sub-ticket consumed by babysit-builder.sh.

set -uo pipefail

VERSION="0.2.0"

usage() {
  cat <<'EOF'
Usage: babysit-work-prep.sh [OPTIONS]

Run from inside the project whose tickets and codebase should be researched.

Options:
  --repo OWNER/REPO          GitHub repository. Default: infer from gh context.
  --source github|jira|both  Ticket source. Default: github.
  --implementer claude|codex
                             Spec-writing harness. Default: claude.
  --implementer-model MODEL  Model passed to the selected harness.
  --implementer-effort LEVEL Effort passed to the selected harness.
  --reviewer claude|codex    Spec review harness. Default: codex.
  --reviewer-model MODEL     Model passed to the review harness.
  --reviewer-effort LEVEL    Effort passed to the review harness.
  --repo-base PATH           Base dir holding cloned repos; spec-guide.md is
                             read from PATH/scripts. Default: auto-detect
                             ~/repos then ~/repo.
  --max-tickets N            Maximum new drafts per run (1-20). Default: 20.
  --dry-run                  Read queues and approvals without making changes.
  -h, --help                 Show help.
  --version                  Show version.

All value options accept both `--name VALUE` and `--name=VALUE`.

Environment:
  MAX_SPEC_REVIEW_CYCLES     Spec review cycles before a draft is quarantined.
                             Default: 4. (Lower than the code loops' 6 — spec
                             revision converges faster and each cycle rewrites
                             prose rather than code.)
  REPO_BASE                  Same as --repo-base (flag wins).
  JIRA_BASE_URL              Required for --source jira|both.
  JIRA_TOKEN                 Jira bearer token (required for Jira sources).
  JIRA_PROJECT               Jira project key (required for Jira sources).
  WORK_PREP_APPROVERS        Comma-separated GitHub logins allowed to approve.
                             Default: the authenticated gh user. Use * to allow
                             any commenter (not recommended for shared repos).
  WORK_PREP_SPEC_DIR         Repo-relative spec directory. Default: ./specs,
                             then the first ./*-specs directory, else ./specs.

Labels applied to spec PRs that do not converge (`spec-*` namespace, disjoint
from the builder's `build-*` and babysit-with-review's `review-*`):
  spec-review-max-cycles     Cycle cap hit with BLOCKING findings open.
  spec-review-incomplete     Review bailed; manual attention needed.
  spec-review-mcp-outage     Reviewer transport failure; retried next run.
  spec-review-codex-outdated Codex CLI too old; upgrade then remove the label.
  spec-review-codex-no-credits  Codex workspace out of credits.
A quarantined PR stays draft, so the approval sweep will not act on it.

Exit codes: 0 completed, 1 fatal/pre-flight failure, 2 invalid arguments.
EOF
}

die_usage() {
  echo "ERROR: $*" >&2
  usage >&2
  exit 2
}

is_option_token() {
  case "${1:-}" in -*) return 0 ;; *) return 1 ;; esac
}

require_value() {
  local option="$1" value="${2:-}"
  [ -n "$value" ] && ! is_option_token "$value" || die_usage "$option requires a value"
}

REPO=""
SOURCE="github"
IMPLEMENTER="claude"
IMPLEMENTER_MODEL=""
IMPLEMENTER_EFFORT=""
REVIEWER="codex"
REVIEWER_MODEL=""
REVIEWER_EFFORT=""
REPO_BASE_OVERRIDE=""
MAX_TICKETS=20
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) echo "babysit-work-prep.sh $VERSION"; exit 0 ;;
    --repo) require_value "$1" "${2:-}"; REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; [ -n "$REPO" ] || die_usage "--repo requires a value"; shift ;;
    --source) require_value "$1" "${2:-}"; SOURCE="$2"; shift 2 ;;
    --source=*) SOURCE="${1#*=}"; [ -n "$SOURCE" ] || die_usage "--source requires a value"; shift ;;
    --implementer) require_value "$1" "${2:-}"; IMPLEMENTER="$2"; shift 2 ;;
    --implementer=*) IMPLEMENTER="${1#*=}"; [ -n "$IMPLEMENTER" ] || die_usage "--implementer requires a value"; shift ;;
    --implementer-model) require_value "$1" "${2:-}"; IMPLEMENTER_MODEL="$2"; shift 2 ;;
    --implementer-model=*) IMPLEMENTER_MODEL="${1#*=}"; [ -n "$IMPLEMENTER_MODEL" ] || die_usage "--implementer-model requires a value"; shift ;;
    --implementer-effort) require_value "$1" "${2:-}"; IMPLEMENTER_EFFORT="$2"; shift 2 ;;
    --implementer-effort=*) IMPLEMENTER_EFFORT="${1#*=}"; [ -n "$IMPLEMENTER_EFFORT" ] || die_usage "--implementer-effort requires a value"; shift ;;
    --reviewer) require_value "$1" "${2:-}"; REVIEWER="$2"; shift 2 ;;
    --reviewer=*) REVIEWER="${1#*=}"; [ -n "$REVIEWER" ] || die_usage "--reviewer requires a value"; shift ;;
    --reviewer-model) require_value "$1" "${2:-}"; REVIEWER_MODEL="$2"; shift 2 ;;
    --reviewer-model=*) REVIEWER_MODEL="${1#*=}"; [ -n "$REVIEWER_MODEL" ] || die_usage "--reviewer-model requires a value"; shift ;;
    --reviewer-effort) require_value "$1" "${2:-}"; REVIEWER_EFFORT="$2"; shift 2 ;;
    --reviewer-effort=*) REVIEWER_EFFORT="${1#*=}"; [ -n "$REVIEWER_EFFORT" ] || die_usage "--reviewer-effort requires a value"; shift ;;
    --repo-base) require_value "$1" "${2:-}"; REPO_BASE_OVERRIDE="$2"; shift 2 ;;
    --repo-base=*) REPO_BASE_OVERRIDE="${1#*=}"; [ -n "$REPO_BASE_OVERRIDE" ] || die_usage "--repo-base requires a value"; shift ;;
    --max-tickets) require_value "$1" "${2:-}"; MAX_TICKETS="$2"; shift 2 ;;
    --max-tickets=*) MAX_TICKETS="${1#*=}"; [ -n "$MAX_TICKETS" ] || die_usage "--max-tickets requires a value"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; [ "$#" -eq 0 ] || die_usage "unexpected positional arguments: $*" ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

case "$SOURCE" in github|jira|both) ;; *) die_usage "invalid source '$SOURCE' (expected github, jira, or both)" ;; esac
case "$IMPLEMENTER" in claude|codex) ;; *) die_usage "invalid implementer '$IMPLEMENTER' (expected claude or codex)" ;; esac
case "$REVIEWER" in claude|codex) ;; *) die_usage "invalid reviewer '$REVIEWER' (expected claude or codex)" ;; esac
case "$MAX_TICKETS" in ''|*[!0-9]*) die_usage "--max-tickets must be an integer from 1 to 20" ;; esac
[ "$MAX_TICKETS" -ge 1 ] && [ "$MAX_TICKETS" -le 20 ] || die_usage "--max-tickets must be an integer from 1 to 20"

for command_name in git gh python3; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "ERROR: required command not found: $command_name" >&2; exit 1; }
done
if [ "$SOURCE" = "jira" ] || [ "$SOURCE" = "both" ]; then
  command -v curl >/dev/null 2>&1 || { echo "ERROR: required command not found: curl" >&2; exit 1; }
  [ -n "${JIRA_BASE_URL:-}" ] && [ -n "${JIRA_TOKEN:-}" ] && [ -n "${JIRA_PROJECT:-}" ] || {
    echo "ERROR: JIRA_BASE_URL, JIRA_TOKEN, and JIRA_PROJECT are required for Jira sources" >&2
    exit 1
  }
fi
if [ "$DRY_RUN" -eq 0 ]; then
  command -v "$IMPLEMENTER" >/dev/null 2>&1 || { echo "ERROR: implementer CLI not found: $IMPLEMENTER" >&2; exit 1; }
  command -v "$REVIEWER" >/dev/null 2>&1 || { echo "ERROR: reviewer CLI not found: $REVIEWER" >&2; exit 1; }
fi

MAX_SPEC_REVIEW_CYCLES="${MAX_SPEC_REVIEW_CYCLES:-4}"
case "$MAX_SPEC_REVIEW_CYCLES" in ''|*[!0-9]*) echo "ERROR: MAX_SPEC_REVIEW_CYCLES must be a positive integer" >&2; exit 1 ;; esac
[ "$MAX_SPEC_REVIEW_CYCLES" -ge 1 ] || { echo "ERROR: MAX_SPEC_REVIEW_CYCLES must be a positive integer" >&2; exit 1; }

# Base directory holding the cloned repos; spec-guide.md lives at $REPO_BASE/scripts.
# Precedence: --repo-base flag > REPO_BASE env var > auto-detect (~/repos then ~/repo).
if [ -n "$REPO_BASE_OVERRIDE" ]; then
  REPO_BASE="$REPO_BASE_OVERRIDE"
elif [ -n "${REPO_BASE:-}" ]; then
  REPO_BASE="${REPO_BASE}"
else
  REPO_BASE="$HOME/repos"
  for _cand in "$HOME/repos" "$HOME/repo"; do
    if [ -d "$_cand/scripts" ]; then REPO_BASE="$_cand"; break; fi
  done
  unset _cand
fi
SCRIPTS_DIR="$REPO_BASE/scripts"
SPEC_GUIDE="$SCRIPTS_DIR/spec-guide.md"

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$PROJECT_ROOT" ] || { echo "ERROR: run from inside a git repository" >&2; exit 1; }
cd "$PROJECT_ROOT" || exit 1
PROJECT=$(basename "$PROJECT_ROOT")

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi
[ -n "$REPO" ] || { echo "ERROR: --repo OWNER/REPO is required (or run in a GitHub repository)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh authentication failed" >&2; exit 1; }

# NB: `gh repo view` takes the repo positionally — it has no --repo flag.
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)
[ -n "$DEFAULT_BRANCH" ] || { echo "ERROR: could not determine the default branch for $REPO" >&2; exit 1; }

if [ -n "${WORK_PREP_SPEC_DIR:-}" ]; then
  SPEC_DIR="${WORK_PREP_SPEC_DIR%/}"
else
  SPEC_DIR=""
  if [ -d specs ]; then
    SPEC_DIR="specs"
  else
    for candidate in *-specs; do
      if [ -d "$candidate" ]; then SPEC_DIR="$candidate"; break; fi
    done
  fi
  [ -n "$SPEC_DIR" ] || SPEC_DIR="specs"
fi
case "$SPEC_DIR" in ''|/*|..|../*|*/../*|*/..) echo "ERROR: WORK_PREP_SPEC_DIR must be a safe repo-relative path" >&2; exit 1 ;; esac

APPROVERS="${WORK_PREP_APPROVERS:-}"
if [ -z "$APPROVERS" ]; then
  APPROVERS=$(gh api user --jq .login 2>/dev/null || true)
  [ -n "$APPROVERS" ] || { echo "ERROR: could not determine authenticated GitHub login for approval policy" >&2; exit 1; }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/babysit-work-prep.XXXXXX") || exit 1
WORKTREE_LIST="$TMP_ROOT/worktrees"
: > "$WORKTREE_LIST"
TMP_REVIEW="$TMP_ROOT/review"
TMP_REVIEW_RESULT="$TMP_ROOT/review-result"
TMP_CODEX_FULL="$TMP_ROOT/codex-full"
# Set per drafted ticket; the review cycle reads them.
REVIEW_DIR=""
SPEC_BASE_SHA=""
SPEC_REVIEW_HALT=0
LOG_DIR="$HOME/sisyphus-logs"
LOG="$LOG_DIR/${PROJECT}-work-prep-$(date +%Y%m%d-%H%M%S)-$$.log"
STOP_FILE="$LOG_DIR/${PROJECT}-work-prep.stop"
LOCK_HELD=0

cleanup() {
  if [ -f "$WORKTREE_LIST" ]; then
    while IFS= read -r worktree_path; do
      [ -n "$worktree_path" ] || continue
      git worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    done < "$WORKTREE_LIST"
  fi
  if [ "$LOCK_HELD" -eq 1 ] && [ -f "$STOP_FILE" ]; then
    lock_pid=$(sed -n '1p' "$STOP_FILE" 2>/dev/null || true)
    [ "$lock_pid" = "$$" ] && rm -f "$STOP_FILE"
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$LOG_DIR"
  if [ -f "$STOP_FILE" ]; then
    old_pid=$(sed -n '1p' "$STOP_FILE" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      echo "ERROR: work-prep lock held by live PID $old_pid: $STOP_FILE" >&2
      exit 1
    fi
    echo "[lock] clearing stale work-prep lock: $STOP_FILE" >&2
    rm -f "$STOP_FILE"
  fi
  if ! (set -C; printf '%s\n' "$$" > "$STOP_FILE") 2>/dev/null; then
    echo "ERROR: another work-prep process acquired $STOP_FILE" >&2
    exit 1
  fi
  LOCK_HELD=1
  touch "$LOG"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Work prep for $REPO (source=$SOURCE, implementer=$IMPLEMENTER, max=$MAX_TICKETS, spec_dir=$SPEC_DIR, dry-run)"
else
  echo "Work prep for $REPO (source=$SOURCE, implementer=$IMPLEMENTER, max=$MAX_TICKETS, spec_dir=$SPEC_DIR)"
fi
echo "  authorized approvers: $APPROVERS"

# Record separator for the TSV-style intermediate files: ASCII US (0x1f).
# NOT tab: tab is IFS *whitespace*, so bash's `read` collapses runs of it and
# drops empty fields, silently shifting every later field left. A PR with no
# approver (b64("") == "") did exactly that. Non-whitespace IFS characters are
# never collapsed, so empty fields survive. Every field is base64 or digits, so
# 0x1f cannot occur inside one. Do not switch these records back to tab.
RS=$'\x1f'

b64decode() {
  python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.buffer.read()).decode("utf-8", "replace"))'
}

fetch_pr_records() {
  local output_file="$1" raw_file="$TMP_ROOT/prs.json"
  if ! gh pr list --repo "$REPO" --state all --limit 1000 \
    --json number,state,title,body,url,headRefName,comments,isDraft > "$raw_file"; then
    echo "ERROR: could not list PRs for $REPO" >&2
    return 1
  fi
  APPROVERS="$APPROVERS" python3 - "$raw_file" > "$output_file" <<'PY'
import base64, json, os, re, sys

def b64(value):
    return base64.b64encode(str(value or "").encode()).decode()

allowed_raw = os.environ.get("APPROVERS", "")
allow_any = allowed_raw.strip() == "*"
allowed = {x.strip().lower() for x in allowed_raw.split(",") if x.strip()}
# Comments this wrapper posts itself are NOT approvals. The wrapper posts as the
# authenticated user, who is also the default authorized approver, and the
# approval regex is multiline over the whole body — so an indented continuation
# line beginning with "approved" inside a reviewer comment would otherwise
# self-approve the spec and create the build sub-ticket with no human involved.
# Every comment the wrapper posts starts with one of these prefixes; that is an
# invariant, not a convention. Mirrors collect_pr_feedback in
# babysit-with-review.sh.
SELF_PREFIXES = ("**Codex review", "**Claude review", "**babysit-work-prep:")
marker = re.compile(
    r"<!-- babysit-work-prep\s*\n"
    r"source: ([^\n]+)\n"
    r"ticket: ([^\n]+)\n"
    r"ticket-url: ([^\n]*)\n"
    r"spec-path: ([^\n]+)\n-->",
    re.I,
)
# Approval must start a line. This accepts "Approved, let's build this" while
# refusing ambiguous prose such as "this is not approved yet".
approval = re.compile(r"^\s*approved\b", re.I | re.M)

with open(sys.argv[1], encoding="utf-8") as fh:
    prs = json.load(fh)
for pr in prs:
    match = marker.search(pr.get("body") or "")
    if not match:
        continue
    source, ticket, ticket_url, spec_path = (x.strip() for x in match.groups())
    approved_by = ""
    for comment in pr.get("comments") or []:
        body = comment.get("body") or ""
        if body.lstrip().startswith(SELF_PREFIXES):
            continue
        author_obj = comment.get("author") or {}
        author = (author_obj.get("login") or comment.get("authorLogin") or "").strip()
        if approval.search(body) and (allow_any or author.lower() in allowed):
            approved_by = author or "unknown"
            break
    fields = [
        str(pr.get("number") or ""), (pr.get("state") or "").upper(), source,
        ticket, b64(ticket_url), b64(spec_path), b64(pr.get("title")),
        "1" if approved_by else "0", b64(approved_by), b64(pr.get("url")),
        "1" if pr.get("isDraft") else "0",
    ]
    print("\x1f".join(fields))
PY
}

fetch_subticket_records() {
  local output_file="$1" raw_file="$TMP_ROOT/issues-all.json"
  if ! gh issue list --repo "$REPO" --state all --limit 1000 \
    --json number,title,body,url,labels > "$raw_file"; then
    echo "ERROR: could not list existing issues for $REPO" >&2
    return 1
  fi
  python3 - "$raw_file" > "$output_file" <<'PY'
import json, re, sys
marker = re.compile(r"<!-- babysit-work-prep-subticket\s+source=([^ ]+)\s+ticket=([^ ]+)\s+-->", re.I)
with open(sys.argv[1], encoding="utf-8") as fh:
    issues = json.load(fh)
for issue in issues:
    match = marker.search(issue.get("body") or "")
    if match:
        print("\x1f".join([match.group(1), match.group(2), str(issue.get("number") or ""), issue.get("url") or ""]))
PY
}

existing_subticket() {
  local source="$1" ticket="$2"
  awk -F "$RS" -v s="$source" -v t="$ticket" '$1 == s && $2 == t { print $3 "\t" $4; exit }' "$SUBTICKET_RECORDS"
}

ensure_builder_labels() {
  gh label create sub-ticket --repo "$REPO" --color 5319e7 --description "Implementation unit created from an approved spec" --force >/dev/null
  # Marks a SOURCE ticket whose spec was approved and whose sub-ticket exists.
  gh label create status:ready-to-build --repo "$REPO" --color 0e8a16 --description "Approved; a builder sub-ticket has been created" --force >/dev/null
  # The builder's queue label. Definition kept byte-identical to the one in
  # babysit-builder.sh's ensure_build_labels so the two --force calls don't
  # flip the colour and description back and forth between runs.
  gh label create build-ready --repo "$REPO" --color 0e8a16 --description "Ticket is ready for the builder loop" --force >/dev/null
}

approval_sweep() {
  local pr_num state source ticket ticket_url_b64 spec_path_b64 title_b64 approved approver_b64 pr_url_b64 is_draft
  local ticket_url spec_path title approver pr_url existing sub_num sub_url issue_url issue_num issue_body
  while IFS="$RS" read -r pr_num state source ticket ticket_url_b64 spec_path_b64 title_b64 approved approver_b64 pr_url_b64 is_draft; do
    [ -n "$pr_num" ] || continue

    # A draft spec PR has not converged in spec review. gh reports drafts as
    # state=OPEN, so without this check the sweep would approve and merge an
    # unreviewed spec. MERGED PRs are still reconciled (sub-ticket may be missing).
    if [ "$state" = "OPEN" ] && [ "$is_draft" = "1" ]; then
      echo "[approve] PR #$pr_num → still draft (spec review not converged), skipped"
      continue
    fi
    ticket_url=$(printf '%s' "$ticket_url_b64" | b64decode)
    spec_path=$(printf '%s' "$spec_path_b64" | b64decode)
    title=$(printf '%s' "$title_b64" | b64decode)
    approver=$(printf '%s' "$approver_b64" | b64decode)
    pr_url=$(printf '%s' "$pr_url_b64" | b64decode)

    if [ "$approved" != "1" ]; then
      [ "$state" = "OPEN" ] && echo "[approve] PR #$pr_num → no authorized approval comment yet, skipped"
      continue
    fi

    existing=$(existing_subticket "$source" "$ticket")
    if [ -n "$existing" ]; then
      sub_num=${existing%%$'\t'*}
      echo "[approve] PR #$pr_num → sub-ticket #$sub_num already exists, skipped (idempotent)"
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[approve] PR #$pr_num → [dry-run] approved by $approver; would merge/reconcile and create sub-ticket"
      continue
    fi

    if [ "$state" = "OPEN" ]; then
      if ! gh pr merge "$pr_num" --repo "$REPO" --merge >> "$LOG" 2>&1; then
        echo "[approve] PR #$pr_num: merge failed; no ticket state changed" >&2
        continue
      fi
    elif [ "$state" != "MERGED" ]; then
      echo "[approve] PR #$pr_num: approved but state=$state; skipped" >&2
      continue
    fi

    if [ "$source" = "github" ]; then
      if ! gh issue edit "$ticket" --repo "$REPO" --add-label status:ready-to-build >> "$LOG" 2>&1; then
        echo "[approve] PR #$pr_num: could not label source issue #$ticket; will retry next run" >&2
        continue
      fi
    fi

    issue_body="$TMP_ROOT/subticket-$pr_num.md"
    cat > "$issue_body" <<EOF
<!-- babysit-work-prep-subticket source=$source ticket=$ticket -->
Approved implementation unit produced by babysit-work-prep.

- Approved spec PR: $pr_url
- Spec path: \`$spec_path\`
- Source ticket: $ticket_url
- Approved by: @$approver

Implement the merged spec and open a PR for human review. Do not merge automatically.
EOF
    issue_url=$(gh issue create --repo "$REPO" --title "[build] ${title#\[spec\] }" \
      --body-file "$issue_body" --label sub-ticket --label build-ready 2>> "$LOG") || {
      echo "[approve] PR #$pr_num: sub-ticket creation failed; merged PR will be reconciled next run" >&2
      continue
    }
    issue_num=${issue_url##*/}
    printf '%s%s%s%s%s%s%s\n' "$source" "$RS" "$ticket" "$RS" "$issue_num" "$RS" "$issue_url" >> "$SUBTICKET_RECORDS"
    echo "[approve] PR #$pr_num → approved by $approver, merged/reconciled, sub-ticket #$issue_num created"
  done < "$PR_RECORDS"
}

fetch_github_tickets() {
  local output_file="$1" raw_file="$TMP_ROOT/issues-open.json"
  if ! gh issue list --repo "$REPO" --state open --limit 1000 \
    --json number,title,body,url,labels > "$raw_file"; then
    echo "ERROR: could not list GitHub tickets for $REPO" >&2
    return 1
  fi
  python3 - "$raw_file" > "$output_file" <<'PY'
import base64, json, sys
def b64(value): return base64.b64encode(str(value or "").encode()).decode()
with open(sys.argv[1], encoding="utf-8") as fh: issues = json.load(fh)
for issue in issues:
    labels = {((x.get("name") if isinstance(x, dict) else x) or "").lower() for x in issue.get("labels") or []}
    # Skip anything already downstream of drafting: our own sub-tickets, source
    # tickets whose spec is approved, and any ticket already in the builder's
    # pipeline (hand-labelled build-ready included — it has a spec already, and
    # drafting a second one while the builder works on it would collide).
    if labels & {"sub-ticket", "status:ready-to-build", "build-ready",
                 "build-done", "build-needs-clarification"}:
        continue
    print("\x1f".join(["github", str(issue.get("number")), b64(issue.get("title")), b64(issue.get("body")), b64(issue.get("url"))]))
PY
}

fetch_jira_tickets() {
  local output_file="$1" raw_file="$TMP_ROOT/jira.json"
  local jira_url="${JIRA_BASE_URL%/}/rest/api/3/search"
  if ! curl -fsS -G "$jira_url" \
    -H "Authorization: Bearer $JIRA_TOKEN" -H "Accept: application/json" \
    --data-urlencode "jql=project=$JIRA_PROJECT AND status=Open" \
    --data-urlencode "fields=summary,description" --data-urlencode "maxResults=$MAX_TICKETS" \
    > "$raw_file"; then
    echo "[jira] Jira API unavailable → skipping Jira-sourced tickets this run" >&2
    : > "$output_file"
    return 0
  fi
  if ! python3 - "$raw_file" > "$output_file" <<'PY'
import base64, json, os, sys
def b64(value): return base64.b64encode(str(value or "").encode()).decode()
def text(value):
    if isinstance(value, str): return value
    if isinstance(value, list): return "\n".join(filter(None, (text(x) for x in value)))
    if isinstance(value, dict):
        own = value.get("text") or ""
        children = text(value.get("content") or [])
        return "\n".join(filter(None, [own, children]))
    return ""
with open(sys.argv[1], encoding="utf-8") as fh: data = json.load(fh)
issues = data if isinstance(data, list) else data.get("issues", [])
base = os.environ.get("JIRA_BASE_URL", "").rstrip("/")
for issue in issues:
    fields = issue.get("fields") or issue
    key = issue.get("key") or issue.get("id") or ""
    if not key: continue
    url = f"{base}/browse/{key}"
    print("\x1f".join(["jira", str(key), b64(fields.get("summary")), b64(text(fields.get("description"))), b64(url)]))
PY
  then
    echo "[jira] Jira returned an invalid response → skipping Jira-sourced tickets this run" >&2
    : > "$output_file"
  fi
}

existing_pr_number() {
  local source="$1" ticket="$2"
  awk -F "$RS" -v s="$source" -v t="$ticket" \
    '$3 == s && $4 == t && ($2 == "OPEN" || $2 == "MERGED") { print $1; exit }' "$PR_RECORDS"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40
}

run_claude() {
  local prompt="$1" out_file="$2" run_dir="$3" model="${IMPLEMENTER_MODEL:-claude-sonnet-5}"
  local -a args=(-p "$prompt" --model "$model")
  [ -n "$IMPLEMENTER_EFFORT" ] && args+=(--effort "$IMPLEMENTER_EFFORT")
  args+=(--dangerously-skip-permissions --output-format stream-json --verbose)
  (cd "$run_dir" && claude "${args[@]}" 2>> "$LOG" < /dev/null) \
    | tee -a "$LOG" \
    | python3 -c '
import json, sys
final = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    t = ev.get("type")
    if t == "system" and ev.get("subtype") == "init":
        sid = (ev.get("session_id") or "?")[:8]
        print(f"  [init] session {sid}", file=sys.stderr, flush=True)
    elif t == "assistant":
        for block in ev.get("message", {}).get("content", []):
            bt = block.get("type")
            if bt == "text":
                txt = (block.get("text") or "").strip()
                if txt:
                    print(f"  [text] {txt.splitlines()[0][:200]}", file=sys.stderr, flush=True)
            elif bt == "tool_use":
                name = block.get("name", "?")
                inp = block.get("input") or {}
                summary = (
                    inp.get("command") or inp.get("file_path")
                    or inp.get("pattern") or inp.get("path") or ""
                )
                summary = str(summary).splitlines()[0][:120] if summary else ""
                print(f"  [tool] {name} {summary}".rstrip(), file=sys.stderr, flush=True)
    elif t == "result":
        final = ev.get("result") or ""
sys.stdout.write(final)
' > "$out_file"
  return ${PIPESTATUS[0]}
}

run_codex() {
  local prompt="$1" out_file="$2" run_dir="$3"
  local -a args=(exec --output-last-message "$out_file" --dangerously-bypass-approvals-and-sandbox)
  [ -n "$IMPLEMENTER_MODEL" ] && args+=(--model "$IMPLEMENTER_MODEL")
  [ -n "$IMPLEMENTER_EFFORT" ] && args+=(-c "model_reasoning_effort=\"$IMPLEMENTER_EFFORT\"")
  : > "$out_file"
  (cd "$run_dir" && codex "${args[@]}" "$prompt" 2>&1 < /dev/null) | tee -a "$LOG" >&2
  return ${PIPESTATUS[0]}
}

run_implementer() {
  case "$IMPLEMENTER" in
    claude) run_claude "$1" "$2" "$3" ;;
    codex) run_codex "$1" "$2" "$3" ;;
  esac
}

# ---------- spec review machinery ----------
# Copies of babysit-with-review.sh / babysit-builder.sh helpers. Kept textually
# close to those so a parser or telltale-regex fix can be diffed across all three
# (the deliberate cost of the no-shared-library decision recorded in
# babysit-specs/L3-builder.md). Reviews run inside $REVIEW_DIR, the drafting
# worktree, which stays alive for the whole review cycle.

count_blocking() {
  awk '
    BEGIN { in_block = 0; n = 0 }
    /^## BLOCKING[[:space:]]*$/ { in_block = 1; next }
    /^## /                      { in_block = 0; next }
    in_block && /^-[[:space:]]/ {
      line = $0
      sub(/^-[[:space:]]+/, "", line)
      if (line == "(none)") next
      n++
    }
    END { print n }
  '
}

valid_review_structure() {
  local review_file="$1"
  [ -s "$review_file" ] || return 1
  awk '
    BEGIN { current = 0; valid = 1 }
    /^[[:space:]]*$/ { next }
    /^## ADJUDICATION[[:space:]]*$/ {
      adjudication_headings++
      if (adjudication_headings != 1 || blocking_headings || recommended_headings || information_headings) valid = 0
      current = 4
      next
    }
    /^## BLOCKING[[:space:]]*$/ {
      blocking_headings++
      if (blocking_headings != 1 || recommended_headings || information_headings) valid = 0
      current = 1
      next
    }
    /^## RECOMMENDED[[:space:]]*$/ {
      recommended_headings++
      if (blocking_headings != 1 || recommended_headings != 1 || information_headings) valid = 0
      current = 2
      next
    }
    /^## INFORMATION[[:space:]]*$/ {
      information_headings++
      if (blocking_headings != 1 || recommended_headings != 1 || information_headings != 1) valid = 0
      current = 3
      next
    }
    /^## / { valid = 0; current = 0; next }
    /^- / {
      if (current < 1 || current > 4) {
        valid = 0
        next
      }
      is_none = ($0 == "- (none)")
      if (none[current] || (is_none && bullets[current] > 0)) valid = 0
      bullets[current]++
      if (is_none) none[current] = 1
      next
    }
    /^[[:space:]]+/ {
      if (current >= 1 && current <= 4 && bullets[current] > 0 && !none[current]) next
      valid = 0
      next
    }
    { valid = 0 }
    END {
      if (blocking_headings != 1 || recommended_headings != 1 || information_headings != 1) valid = 0
      if (bullets[1] < 1 || bullets[2] < 1 || bullets[3] < 1) valid = 0
      if (adjudication_headings == 1 && bullets[4] < 1) valid = 0
      exit(valid ? 0 : 1)
    }
  ' "$review_file" 2>/dev/null
}

codex_review_with_retry() {
  local codex_prompt="$1"
  local attempt rc
  local delays=(0 60 300)
  local compat_re='requires a newer version of Codex'
  local credits_re='Your workspace is out of credits'
  # Telltale patterns for MCP transport failures. Update if Codex changes its error format.
  local mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'

  for attempt in 1 2 3; do
    if [ "${delays[$((attempt - 1))]}" -gt 0 ]; then
      echo "  [codex] waiting ${delays[$((attempt - 1))]}s before retry (attempt $attempt of 3)..." | tee -a "$LOG" >&2
      sleep "${delays[$((attempt - 1))]}"
    fi
    : > "$TMP_REVIEW"
    : > "$TMP_CODEX_FULL"

    local -a codex_args=(exec --output-last-message "$TMP_REVIEW" -s read-only)
    [ -n "$REVIEWER_MODEL" ] && codex_args+=(--model "$REVIEWER_MODEL")
    [ -n "$REVIEWER_EFFORT" ] && codex_args+=(-c "model_reasoning_effort=\"$REVIEWER_EFFORT\"")
    (cd "$REVIEW_DIR" && codex "${codex_args[@]}" "$codex_prompt" 2>&1 < /dev/null) \
      | tee -a "$LOG" "$TMP_CODEX_FULL" >&2
    rc=${PIPESTATUS[0]}

    if grep -qE "$compat_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      echo "  [codex] FATAL: backend compatibility failure on attempt $attempt (rc=$rc); Codex CLI is too old for the configured model" | tee -a "$LOG" >&2
      return 3
    fi
    if grep -qE "$credits_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      echo "  [codex] FATAL: Codex workspace out of credits on attempt $attempt (rc=$rc); add credits and restart" | tee -a "$LOG" >&2
      return 4
    fi

    if [ "$rc" -eq 0 ] && [ -s "$TMP_REVIEW" ]; then
      if valid_review_structure "$TMP_REVIEW"; then return 0; fi
      echo "  [codex] exit 0 but review missing required section headers; treating as failure" | tee -a "$LOG" >&2
    fi

    if grep -qE "$mcp_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      local review_state
      review_state=$([ -s "$TMP_REVIEW" ] && echo "present" || echo "empty")
      echo "  [codex] MCP transport failure on attempt $attempt of 3 (rc=$rc, review=$review_state)" | tee -a "$LOG" >&2
      [ "$attempt" -lt 3 ] && continue
      return 2
    fi

    return 1
  done
}

claude_review() {
  local review_prompt="$1" rc
  local -a args=(-p "$review_prompt" --permission-mode plan)
  [ -n "$REVIEWER_MODEL" ] && args+=(--model "$REVIEWER_MODEL")
  [ -n "$REVIEWER_EFFORT" ] && args+=(--effort "$REVIEWER_EFFORT")
  args+=(--output-format stream-json --verbose)
  : > "$TMP_REVIEW"
  (cd "$REVIEW_DIR" && claude "${args[@]}" 2>&1 < /dev/null) \
    | tee -a "$LOG" \
    | python3 -c '
import json, sys
final = ""
for line in sys.stdin:
    try:
        event = json.loads(line)
    except Exception:
        continue
    if event.get("type") == "result":
        final = event.get("result") or ""
sys.stdout.write(final)
' > "$TMP_REVIEW"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "  [claude reviewer] non-zero exit (rc=$rc); treating review as incomplete" | tee -a "$LOG" >&2
    return 1
  fi
  if ! valid_review_structure "$TMP_REVIEW"; then
    echo "  [claude reviewer] review missing required section headers; treating as failure" | tee -a "$LOG" >&2
    return 1
  fi
}

review_with_retry() {
  case "$REVIEWER" in
    codex) codex_review_with_retry "$1" ;;
    claude) claude_review "$1" ;;
  esac
}

reviewer_preflight() {
  [ "$REVIEWER" = "codex" ] || return 0
  local compat_re='requires a newer version of Codex'
  local credits_re='Your workspace is out of credits'
  local probe_full rc
  probe_full="$TMP_ROOT/reviewer-probe"
  local -a args=(exec -s read-only)
  [ -n "$REVIEWER_MODEL" ] && args+=(--model "$REVIEWER_MODEL")
  [ -n "$REVIEWER_EFFORT" ] && args+=(-c "model_reasoning_effort=\"$REVIEWER_EFFORT\"")
  codex "${args[@]}" "Say 'ok'." 2>&1 < /dev/null | tee -a "$LOG" "$probe_full" >/dev/null
  rc=${PIPESTATUS[0]}
  grep -qE "$compat_re" "$probe_full" 2>/dev/null && return 3
  grep -qE "$credits_re" "$probe_full" 2>/dev/null && return 4
  [ "$rc" -eq 0 ] || return 1
}

# Post a reviewer pass as a PR comment. MUST start with "**<Name> review" — the
# approval scan in fetch_pr_records skips comments with this pipeline's prefixes,
# and that filter is what stops a review body containing a line beginning with
# "approved" from self-approving the spec.
post_reviewer_review() {
  local pr_num="$1" cycle="$2" max="$3" review_file="$4"
  [ -s "$review_file" ] || return 0
  local reviewer_name body
  case "$REVIEWER" in codex) reviewer_name="Codex" ;; claude) reviewer_name="Claude" ;; esac
  body="**${reviewer_name} review — spec PR #${pr_num} cycle ${cycle} of ${max}**

\`\`\`
$(cat "$review_file")
\`\`\`"
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --repo "$REPO" --body-file - >> "$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment ($REVIEWER review) failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Label a non-converged spec PR and explain why. The PR is already a draft and
# stays one, and the approval sweep skips drafts — so unlike the builder there is
# no `gh pr ready --undo` to make fail-closed here; the PR is un-approvable by
# construction.
# Args: <pr_num> <label> <heading> <reason> <extra>
quarantine_spec_pr() {
  local pr_num="$1" label="$2" heading="$3" reason="$4" extra="${5:-}"
  echo "  [review] marking spec PR #$pr_num $label: $reason" | tee -a "$LOG" >&2
  gh label create "$label" --repo "$REPO" --color B60205 \
    --description "Work-prep spec review did not converge" --force >> "$LOG" 2>&1 || true
  if ! gh pr edit "$pr_num" --repo "$REPO" --add-label "$label" >> "$LOG" 2>&1; then
    echo "ERROR: could not label spec PR #$pr_num '$label'; add it manually" | tee -a "$LOG" >&2
  fi
  local body_file="$TMP_ROOT/quarantine-$pr_num.md"
  {
    printf '**babysit-work-prep: %s**\n\n' "$heading"
    printf 'Reason: %s\n' "$reason"
    [ -n "$extra" ] && printf '\n%s\n' "$extra"
    printf '\nThis PR stays a draft. The approval sweep skips drafts, so it cannot be merged by an `approved` comment until a human resolves the findings and marks it ready.\n'
  } > "$body_file"
  gh pr comment "$pr_num" --repo "$REPO" --body-file "$body_file" >> "$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

validate_spec_change() {
  local worktree="$1" base_sha="$2" changed_file="$3" paths_file="$TMP_ROOT/changed-paths"
  {
    git -C "$worktree" diff --name-only "$base_sha"
    git -C "$worktree" ls-files --others --exclude-standard
  } | sort -u > "$paths_file"
  [ "$(wc -l < "$paths_file" | tr -d ' ')" -eq 1 ] || return 1
  spec_path=$(sed -n '1p' "$paths_file")
  case "$spec_path" in "$SPEC_DIR"/*.md) ;; *) return 1 ;; esac
  [ -f "$worktree/$spec_path" ] && [ ! -L "$worktree/$spec_path" ] || return 1
  # Work-prep drafts a new spec; editing an existing contract is a separate flow.
  git -C "$worktree" cat-file -e "$base_sha:$spec_path" 2>/dev/null && return 1
  python3 - "$worktree/$spec_path" <<'PY' || return 1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
if not text.startswith("---\n"):
    raise SystemExit(1)
end = text.find("\n---", 4)
if end < 0:
    raise SystemExit(1)
front = text[4:end]
required = [r"(?m)^spec_type:\s*\S+", r"(?m)^id:\s*\S+", r"(?m)^status:\s*review\s*$"]
if not all(re.search(pattern, front) for pattern in required):
    raise SystemExit(1)
PY
  printf '%s' "$spec_path" > "$changed_file"
}

# ---------- spec review prompts ----------

IFS= read -r -d '' SPEC_REVIEW_PROMPT_CYCLE1 <<'PROMPT_EOF' || true
You are adversarially reviewing a NEWLY DRAFTED specification before a human is asked to approve it. Be a skeptic: your job is to find every reason this spec should not be approved as written.

The spec under review: __SPEC_PATH__
It was drafted from this ticket:
  Ticket: __TICKET__ (__TICKET_URL__)
  Title: __TICKET_TITLE__
  Description:
  ---
  __TICKET_BODY__
  ---

This is review cycle __CYCLE__ of __MAX_CYCLES__. This is the first review of this spec.

Before judging, READ:
1. The spec under review, in full.
2. EVERY OTHER SPEC in ./__SPEC_DIR__/ — you cannot assess consistency or duplication without knowing what the corpus already says. This is the most important step and the one most easily skipped.
3. ./CLAUDE.md for project conventions.
4. The schema this corpus follows: __SPEC_GUIDE__ (read it if the path exists and is readable; if it is not, apply the criteria below on their own).
5. The actual code the spec describes, enough to tell whether its claims about current behavior are true.

Judge the spec on these criteria. A finding is BLOCKING if it would make the spec wrong to approve:

- **Contradiction with an existing spec.** The spec asserts something another spec in the corpus contradicts, without acknowledging or superseding it. Cite both files.
- **Undeclared duplication.** The spec covers work an existing spec already covers, without saying so or explaining the relationship. Cite the overlapping spec.
- **Dangling references.** Any `depends_on`, `parent_l1`, `parent_l2`, `parent_feature` or in-body spec ID that does not resolve to a real file in the corpus; broken relative links.
- **Schema violation.** Missing or malformed frontmatter keys for its layer, wrong ID scheme, missing required sections, wrong layer for what it actually describes.
- **Not implementable.** No acceptance criteria or equivalent definition of done; requirements too vague to build against; contract (inputs, outputs, error cases) left undefined.
- **Invented design decisions.** The spec states a design decision as settled that the ticket, the code, and the corpus do not establish — the author inferred it. This is the single most damaging failure mode in a spec corpus and it is easy to miss because invented decisions read as confident prose. An unconfirmed decision must be flagged `[ASSUMPTION]` with what would flip it, not asserted.
- **Claims about current behavior that are false.** The spec describes the code as doing something it does not do. Verify against the code, do not trust the prose.

Output your review using EXACTLY this format:

## BLOCKING
- <one-line description> — <file:line or spec section> — <why it must be fixed before a human approves this spec>

## RECOMMENDED
- <one-line description> — <file:line or spec section> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line or spec section> — <context, suggestion, or fyi>

Format rules:
- BLOCKING, RECOMMENDED, and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT edit any file. This is review only.
PROMPT_EOF

IFS= read -r -d '' SPEC_REVIEW_PROMPT_CYCLE2 <<'PROMPT_EOF' || true
You are adversarially reviewing a NEWLY DRAFTED specification before a human is asked to approve it. Be a skeptic: your job is to find every reason this spec should not be approved as written.

The spec under review: __SPEC_PATH__
It was drafted from this ticket:
  Ticket: __TICKET__ (__TICKET_URL__)
  Title: __TICKET_TITLE__
  Description:
  ---
  __TICKET_BODY__
  ---

This is review cycle __CYCLE__ of __MAX_CYCLES__. The previous cycle did not resolve every BLOCKING finding.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

Re-read the spec as it stands now, plus EVERY OTHER SPEC in ./__SPEC_DIR__/, ./CLAUDE.md, and __SPEC_GUIDE__ if readable. Do not rely on the previous cycle's reading of the corpus — the spec has changed.

Judge the spec on the same criteria as before. A finding is BLOCKING if it would make the spec wrong to approve:
- Contradiction with an existing spec (cite both files)
- Undeclared duplication of an existing spec's scope
- Dangling `depends_on` / `parent_*` / in-body spec IDs, or broken links
- Schema violation for its layer (frontmatter, ID scheme, required sections)
- Not implementable: no acceptance criteria, undefined contract, requirements too vague
- Invented design decisions asserted as settled rather than flagged `[ASSUMPTION]`
- False claims about what the code currently does

Watch specifically for regressions: a fix for one finding that introduced a new contradiction, or a requirement quietly deleted rather than resolved.

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line or spec section> — <why it must be fixed before a human approves this spec>

## RECOMMENDED
- <one-line description> — <file:line or spec section> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line or spec section> — <context, suggestion, or fyi>

Convergence tracking:
- Mark each BLOCKING finding [NEW] if it was not flagged in a previous cycle, or [RECURRENCE] if it was flagged before and remains unresolved.

Format rules:
- BLOCKING bullets start with the [NEW|RECURRENCE] tag, then a single-line description.
- RECOMMENDED and INFORMATION are single-line bullets only (no tags).
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT edit any file. This is review only.
PROMPT_EOF

IFS= read -r -d '' SPEC_REVIEW_PROMPT_CYCLE3 <<'PROMPT_EOF' || true
You are adversarially reviewing a NEWLY DRAFTED specification before a human is asked to approve it. Be a skeptic, but this cycle you must also be constructive.

The spec under review: __SPEC_PATH__
It was drafted from this ticket:
  Ticket: __TICKET__ (__TICKET_URL__)
  Title: __TICKET_TITLE__
  Description:
  ---
  __TICKET_BODY__
  ---

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple cycles have not resolved every BLOCKING finding. This cycle uses prescriptive mode.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

Re-read the spec as it stands now, plus EVERY OTHER SPEC in ./__SPEC_DIR__/, ./CLAUDE.md, and __SPEC_GUIDE__ if readable.

Same criteria as previous cycles (contradiction, undeclared duplication, dangling references, schema violation, not implementable, invented design decisions, false claims about the code).

**Prescriptive requirement:** every BLOCKING finding MUST carry a concrete `Suggested wording:` line — the actual replacement text or frontmatter change the spec should carry. If you cannot write the replacement yourself, you do not understand the finding well enough to block on it: downgrade it to RECOMMENDED.

**A note on convergence:** if a finding recurs because the underlying question is a design decision nobody has made, the correct resolution is NOT to keep demanding a different answer. It is to require the spec to flag it `[ASSUMPTION]` with a "Flips if:" clause and move on. Specs are allowed to have open questions; they are not allowed to hide them.

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line or spec section> — <why it must be fixed before a human approves this spec>
  Suggested wording: <the concrete replacement text or frontmatter change>

## RECOMMENDED
- <one-line description> — <file:line or spec section> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line or spec section> — <context, suggestion, or fyi>

Format rules:
- BLOCKING bullets are the tagged description line plus the required `Suggested wording:` line, indented two spaces.
- RECOMMENDED and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT edit any file. This is review only.
PROMPT_EOF

IFS= read -r -d '' SPEC_REVISION_PROMPT <<'PROMPT_EOF' || true
An adversarial review of the specification you drafted has produced the findings below. This is cycle __CYCLE__ of __MAX_CYCLES__.

The spec under review: __SPEC_PATH__

You MUST resolve every BLOCKING finding before this spec can go to a human for approval.

How to resolve each kind of finding:
- **Contradiction / undeclared duplication with an existing spec:** read the spec named in the finding. Either reconcile the wording, or state the relationship explicitly (supersedes, extends, narrows). Do not silently delete the conflicting requirement.
- **Dangling reference:** fix the ID or the link. If the referenced spec genuinely does not exist yet, say so in the body rather than pointing at a file that isn't there.
- **Schema violation:** fix the frontmatter, ID, or section layout to match the corpus convention.
- **Not implementable:** add the missing acceptance criteria or contract detail. If you cannot, that is itself the finding — flag it.
- **Invented design decision:** you asserted something the ticket, the code, and the corpus do not establish. Do NOT invent a better-sounding answer. Convert it to an `[ASSUMPTION]` with a "Flips if:" clause so the owner can confirm or correct it. Getting an open question flagged is a success, not a failure.
- **False claim about current behavior:** verify against the code and correct the spec to describe what the code actually does.

Constraints — these are hard:
- Edit ONLY the spec file __SPEC_PATH__. Do NOT change code, tests, configuration, or any other file. The wrapper verifies this after every cycle and will bail the review if you touch anything else.
- Commit your revisions with a message explaining what the review flagged and what you changed.
- Do NOT push, do NOT open or edit a PR, do NOT comment on GitHub, do NOT edit issues or labels. The wrapper owns every lifecycle action.
- Do NOT mark the spec `status: ready`. Only the owner does that.

If you believe a BLOCKING finding is wrong, you may leave it unresolved — but you must add a short note in the spec explaining why the reviewer's reading is incorrect, with a citation. Silent refusal is not acceptable; the next review cycle will simply flag it again.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

# ---------- spec review cycle ----------

# Reviewer -> implementer convergence loop for one drafted spec PR. Mirrors
# run_review_cycle / run_build_cycle, adapted for prose: the reviewer judges the
# spec against the existing corpus rather than judging code against tests.
#
# The PR is created as a DRAFT and only marked ready on convergence, so the
# approval sweep (which skips drafts) can never offer a human an unreviewed spec.
#
# Globals: REVIEW_DIR (the drafting worktree, still checked out on $branch).
# Args: <pr_num> <branch> <spec_path> <source> <ticket> <ticket_url> <title> <body>
# Returns: 0 the PR reached a terminal state (ready, or quarantined);
#          2 reviewer MCP outage; 3 Codex too old; 4 Codex out of credits.
run_spec_review_cycle() {
  local pr_num="$1" branch="$2" spec_path="$3" source="$4" ticket="$5"
  local ticket_url="$6" title="$7" body="$8"
  local cycle=0 review_start_sha=""
  local -a REVIEW_HISTORY=()

  echo "=== spec review: PR #$pr_num ($spec_path) @ $(date -u +%FT%TZ) ===" | tee -a "$LOG" >&2
  review_start_sha=$(git -C "$REVIEW_DIR" rev-parse HEAD 2>/dev/null || echo "")

  while [ "$cycle" -lt "$MAX_SPEC_REVIEW_CYCLES" ]; do
    cycle=$((cycle + 1))
    echo "--- spec review cycle $cycle / $MAX_SPEC_REVIEW_CYCLES (PR #$pr_num) ---" | tee -a "$LOG" >&2

    local history_block=""
    if [ "$cycle" -ge 2 ] && [ "${#REVIEW_HISTORY[@]}" -gt 0 ]; then
      local _hb="" _i _commits
      for _i in "${!REVIEW_HISTORY[@]}"; do
        _hb="${_hb}### cycle $(( _i + 1 )) review
${REVIEW_HISTORY[$_i]}
"
      done
      _commits=$(git -C "$REVIEW_DIR" log --oneline "${review_start_sha}..HEAD" 2>/dev/null || true)
      _hb="${_hb}--- revisions made since the review started ---
${_commits:-"(none)"}
--- end revisions ---
"
      history_block="--- prior review cycles (for convergence tracking) ---
${_hb}--- end prior review cycles ---
"
      unset _hb _i _commits
    fi

    local _tmpl
    if [ "$cycle" -eq 1 ]; then
      _tmpl="$SPEC_REVIEW_PROMPT_CYCLE1"
    elif [ "$cycle" -eq 2 ]; then
      _tmpl="$SPEC_REVIEW_PROMPT_CYCLE2"
    else
      _tmpl="$SPEC_REVIEW_PROMPT_CYCLE3"
      echo "  [$REVIEWER reviewer] prescriptive mode (cycle 3+)" | tee -a "$LOG" >&2
    fi
    local review_prompt
    review_prompt="${_tmpl//__PR_NUMBER__/$pr_num}"
    review_prompt="${review_prompt//__CYCLE__/$cycle}"
    review_prompt="${review_prompt//__MAX_CYCLES__/$MAX_SPEC_REVIEW_CYCLES}"
    review_prompt="${review_prompt//__SPEC_PATH__/$spec_path}"
    review_prompt="${review_prompt//__SPEC_DIR__/$SPEC_DIR}"
    review_prompt="${review_prompt//__SPEC_GUIDE__/$SPEC_GUIDE}"
    review_prompt="${review_prompt//__TICKET__/$ticket}"
    review_prompt="${review_prompt//__TICKET_URL__/$ticket_url}"
    review_prompt="${review_prompt//__TICKET_TITLE__/$title}"
    review_prompt="${review_prompt//__TICKET_BODY__/$body}"
    review_prompt="${review_prompt//__HISTORY_BLOCK__/$history_block}"
    unset _tmpl

    echo "  [$REVIEWER reviewer] reviewing spec for PR #$pr_num..." >&2
    local reviewer_rc=0
    review_with_retry "$review_prompt" || reviewer_rc=$?

    if [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 3 ]; then
      quarantine_spec_pr "$pr_num" spec-review-codex-outdated \
        "Codex version incompatibility — spec review blocked" \
        "Codex CLI too old for the configured model (cycle $cycle)" \
        "To resume: upgrade the Codex CLI (\`codex update\`), remove the label, and re-run work-prep."
      return 3
    elif [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 4 ]; then
      quarantine_spec_pr "$pr_num" spec-review-codex-no-credits \
        "Codex workspace out of credits — spec review blocked" \
        "Codex workspace has no credits remaining (cycle $cycle)" \
        "To resume: add credits to the Codex workspace, remove the label, and re-run work-prep."
      return 4
    elif [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 2 ]; then
      quarantine_spec_pr "$pr_num" spec-review-mcp-outage \
        "reviewer MCP transport failure — spec review pending" \
        "codex MCP transport failure after 3 retries (cycle $cycle)" \
        "No spec review took place. Re-run work-prep to retry; remove the label if you review this spec by hand."
      return 2
    elif [ "$reviewer_rc" -ne 0 ]; then
      quarantine_spec_pr "$pr_num" spec-review-incomplete \
        "spec review bailed — manual attention required" \
        "$REVIEWER review failed during cycle $cycle"
      return 0
    fi

    local review
    review=$(cat "$TMP_REVIEW")
    REVIEW_HISTORY+=("$review")
    post_reviewer_review "$pr_num" "$cycle" "$MAX_SPEC_REVIEW_CYCLES" "$TMP_REVIEW"
    {
      echo "--- $REVIEWER spec review (cycle $cycle) ---"
      printf '%s\n' "$review"
      echo "--- end $REVIEWER spec review ---"
    } >> "$LOG"

    local n_blocking
    n_blocking=$(printf '%s\n' "$review" | count_blocking)
    if ! [[ "$n_blocking" =~ ^[0-9]+$ ]]; then
      quarantine_spec_pr "$pr_num" spec-review-incomplete \
        "spec review bailed — parse error" \
        "count_blocking produced non-integer output ('$n_blocking') in cycle $cycle"
      return 0
    fi
    echo "[review] spec PR #$pr_num → cycle $cycle: $n_blocking BLOCKING"

    if [ "$n_blocking" -eq 0 ]; then
      echo "  [review] spec converged after $cycle cycle(s); marking PR #$pr_num ready" | tee -a "$LOG" >&2
      if ! git -C "$REVIEW_DIR" push origin "HEAD:refs/heads/$branch" >> "$LOG" 2>&1; then
        quarantine_spec_pr "$pr_num" spec-review-incomplete \
          "spec converged but the final push failed" \
          "could not push revisions to origin/$branch"
        return 0
      fi
      if ! gh pr ready "$pr_num" --repo "$REPO" >> "$LOG" 2>&1; then
        echo "  [review] WARNING: gh pr ready failed for PR #$pr_num; it stays draft and will not be approved" | tee -a "$LOG" >&2
        return 0
      fi
      local summary_file="$TMP_ROOT/spec-summary-$pr_num.md"
      {
        printf '**babysit-work-prep: spec review converged — ready for your approval**\n\n'
        printf 'The %s reviewer reported 0 BLOCKING findings after %s cycle(s) of %s, judging this spec against the rest of `%s/`, the project conventions, and the code it describes.\n\n' \
          "$REVIEWER" "$cycle" "$MAX_SPEC_REVIEW_CYCLES" "$SPEC_DIR"
        printf 'This PR is now out of draft. To accept the spec, post a comment whose line starts with **approved** — that merges it, labels the source ticket, and creates the `build-ready` sub-ticket for the builder.\n\n'
        printf 'Final review:\n\n```\n%s\n```\n' "$review"
      } > "$summary_file"
      gh pr comment "$pr_num" --repo "$REPO" --body-file "$summary_file" >> "$LOG" 2>&1 \
        || echo "  [review] WARNING: summary comment failed for PR #$pr_num" | tee -a "$LOG" >&2
      return 0
    fi

    # ---- implementer revision pass ----
    local rev_prompt pre_sha post_sha
    rev_prompt="${SPEC_REVISION_PROMPT//__PR_NUMBER__/$pr_num}"
    rev_prompt="${rev_prompt//__CYCLE__/$cycle}"
    rev_prompt="${rev_prompt//__MAX_CYCLES__/$MAX_SPEC_REVIEW_CYCLES}"
    rev_prompt="${rev_prompt//__SPEC_PATH__/$spec_path}"
    rev_prompt="${rev_prompt//__REVIEW__/$review}"

    pre_sha=$(git -C "$REVIEW_DIR" rev-parse HEAD 2>/dev/null || echo "")
    echo "  [$IMPLEMENTER implementer] revising spec (cycle $cycle)..." >&2
    if ! run_implementer "$rev_prompt" "$TMP_REVIEW_RESULT" "$REVIEW_DIR"; then
      quarantine_spec_pr "$pr_num" spec-review-incomplete \
        "spec review bailed — implementer failure" \
        "$IMPLEMENTER exited non-zero while revising the spec (cycle $cycle)"
      return 0
    fi

    local rev_last_line
    rev_last_line=$(sed -e 's/[[:space:]]*$//' "$TMP_REVIEW_RESULT" | grep -v '^$' | tail -n 1)
    case "$rev_last_line" in
      "STUCK_REVIEW"*)
        quarantine_spec_pr "$pr_num" spec-review-incomplete \
          "spec review bailed — implementer stuck" \
          "$IMPLEMENTER reported ${rev_last_line} (cycle $cycle)"
        return 0
        ;;
    esac

    # The revision pass must not have escaped the one spec file. This is the same
    # gate the initial draft passes, re-run every cycle so a review-driven edit
    # cannot sprawl into code under cover of "fixing a finding".
    local recheck_file="$TMP_ROOT/recheck-$pr_num"
    if ! validate_spec_change "$REVIEW_DIR" "$SPEC_BASE_SHA" "$recheck_file"; then
      quarantine_spec_pr "$pr_num" spec-review-incomplete \
        "spec review bailed — revision touched more than the spec" \
        "after cycle $cycle the branch no longer contains exactly one new spec under $SPEC_DIR" \
        "work-prep drafts specs only. A revision that adds or edits code, tests, or a second file is out of contract, so the review stopped rather than push it."
      return 0
    fi

    post_sha=$(git -C "$REVIEW_DIR" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$pre_sha" ] && [ "$pre_sha" = "$post_sha" ]; then
      quarantine_spec_pr "$pr_num" spec-review-incomplete \
        "spec review bailed — no progress" \
        "$IMPLEMENTER reported DONE_REVIEW but committed nothing in cycle $cycle"
      return 0
    fi

    git -C "$REVIEW_DIR" push origin "HEAD:refs/heads/$branch" >> "$LOG" 2>&1 \
      || echo "  [review] WARNING: push to origin/$branch failed after cycle $cycle" | tee -a "$LOG" >&2
  done

  git -C "$REVIEW_DIR" push origin "HEAD:refs/heads/$branch" >> "$LOG" 2>&1 || true
  quarantine_spec_pr "$pr_num" spec-review-max-cycles \
    "max spec review cycles reached — human review required" \
    "$MAX_SPEC_REVIEW_CYCLES cycles did not clear every BLOCKING finding" \
    "Read the review comments above. Either resolve the findings and mark the PR ready yourself, or close it and re-run work-prep after clarifying the ticket."
  return 0
}

draft_ticket() {
  local source="$1" ticket="$2" title="$3" body="$4" ticket_url="$5"
  local branch_slug branch worktree base_ref base_sha prompt result changed_path_file spec_path
  local prompt_file pr_body_file pr_url pr_num current_branch

  branch_slug=$(slugify "$source-$ticket")
  [ -n "$branch_slug" ] || branch_slug="ticket"
  branch="work-prep/${branch_slug}-$$"
  worktree="$TMP_ROOT/wt-${branch_slug}"
  base_ref="$DEFAULT_BRANCH"
  git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" && base_ref="origin/$DEFAULT_BRANCH"
  base_sha=$(git rev-parse "$base_ref" 2>/dev/null || true)
  [ -n "$base_sha" ] || { echo "[draft] ticket $ticket: default branch '$DEFAULT_BRANCH' is unavailable locally" >&2; return 1; }

  if ! git worktree add -b "$branch" "$worktree" "$base_sha" >> "$LOG" 2>&1; then
    echo "[draft] ticket $ticket: worktree creation failed" >&2
    return 1
  fi
  printf '%s\n' "$worktree" >> "$WORKTREE_LIST"
  # The worktree stays alive through the review cycle: the reviewer reads the
  # spec in place and the implementer revises it there.
  REVIEW_DIR="$worktree"
  SPEC_BASE_SHA="$base_sha"

  prompt_file="$TMP_ROOT/prompt-${branch_slug}.txt"
  result="$TMP_ROOT/result-${branch_slug}.txt"
  cat > "$prompt_file" <<EOF
You are the spec-writing implementer in babysit-work-prep. Research the ticket below against this checkout and draft exactly ONE implementation-ready TIF specification.

Ticket source: $source
Ticket ID: $ticket
Ticket URL: $ticket_url
Ticket title: $title

Ticket description:
---
$body
---

Requirements:
1. Read CLAUDE.md and relevant existing specs/code before writing.
2. Create exactly one Markdown file beneath ./$SPEC_DIR. Create the directory if needed.
3. Use YAML frontmatter with spec_type, a stable id, status: review, owners, dependencies, fit_check, and complexity.
4. Make the spec implementation-ready: frame, known facts vs assumptions, API/CLI contract, invariants, idempotency, error model, security, telemetry, bounds, failure modes, and acceptance tests.
5. Cite the source ticket URL in the document.
6. Do not change code, tests, configuration, or any existing file. Do not push, open a PR, edit issues, or call gh/Jira APIs; the wrapper owns lifecycle changes.
7. You may commit the new spec, but do not rename the current branch.

End your final response with: WORK_PREP_DONE <repo-relative-spec-path>
EOF

  if ! run_implementer "$(cat "$prompt_file")" "$result" "$worktree"; then
    echo "[draft] ticket $ticket: implementer failed; any committed work remains on local branch $branch" >&2
    return 1
  fi

  changed_path_file="$TMP_ROOT/changed-${branch_slug}"
  if ! validate_spec_change "$worktree" "$base_sha" "$changed_path_file"; then
    echo "[draft] ticket $ticket: implementer must add exactly one new review-status Markdown spec under $SPEC_DIR" >&2
    return 1
  fi
  spec_path=$(cat "$changed_path_file")

  current_branch=$(git -C "$worktree" branch --show-current)
  if [ "$current_branch" != "$branch" ]; then
    echo "[draft] ticket $ticket: implementer renamed branch unexpectedly; skipped" >&2
    return 1
  fi

  git -C "$worktree" add -- "$spec_path" || return 1
  if ! git -C "$worktree" diff --cached --quiet; then
    git -C "$worktree" commit -m "docs(spec): draft $source ticket $ticket" >> "$LOG" 2>&1 || {
      echo "[draft] ticket $ticket: commit failed; local branch $branch retained" >&2
      return 1
    }
  fi
  if [ "$(git -C "$worktree" rev-parse HEAD)" = "$base_sha" ]; then
    echo "[draft] ticket $ticket: no committed spec change found" >&2
    return 1
  fi
  if ! git -C "$worktree" push -u origin "HEAD:refs/heads/$branch" >> "$LOG" 2>&1; then
    echo "[draft] ticket $ticket: push failed; local branch $branch retained" >&2
    return 1
  fi

  pr_body_file="$TMP_ROOT/pr-${branch_slug}.md"
  cat > "$pr_body_file" <<EOF
<!-- babysit-work-prep
source: $source
ticket: $ticket
ticket-url: $ticket_url
spec-path: $spec_path
-->
## Work-prep spec draft

Drafted from [$source ticket $ticket]($ticket_url).

This PR opens as a draft and is held there until an adversarial spec review reports zero BLOCKING findings, checking the draft against the rest of \`$SPEC_DIR/\`, the project conventions, and the code it describes. The review runs as comments below.

Once it is out of draft, review the specification yourself and post a comment whose line starts with **approved** to merge it and create the \`build-ready\` sub-ticket. Authorized approvers: $APPROVERS.
EOF
  # Opened as a DRAFT. The approval sweep skips drafts, so no human is asked to
  # approve this spec until the review cycle below clears it.
  pr_url=$(gh pr create --repo "$REPO" --head "$branch" --base "$DEFAULT_BRANCH" --draft \
    --title "[spec] $title" --body-file "$pr_body_file" 2>> "$LOG") || {
    echo "[draft] ticket $ticket: PR creation failed; pushed branch $branch retained" >&2
    return 1
  }
  pr_num=${pr_url##*/}
  echo "[draft] ticket $ticket ($source) → draft PR #$pr_num opened ($spec_path), entering spec review"

  local cycle_rc=0
  run_spec_review_cycle "$pr_num" "$branch" "$spec_path" "$source" "$ticket" \
    "$ticket_url" "$title" "$body" || cycle_rc=$?
  if [ "$cycle_rc" -ne 0 ]; then
    SPEC_REVIEW_HALT="$cycle_rc"
  fi
  return 0
}

PR_RECORDS="$TMP_ROOT/pr-records"
SUBTICKET_RECORDS="$TMP_ROOT/subticket-records"
GITHUB_TICKETS="$TMP_ROOT/github-tickets"
JIRA_TICKETS="$TMP_ROOT/jira-tickets"
ALL_TICKETS="$TMP_ROOT/all-tickets"

fetch_pr_records "$PR_RECORDS" || exit 1
fetch_subticket_records "$SUBTICKET_RECORDS" || exit 1
if [ "$DRY_RUN" -eq 0 ]; then
  git fetch origin "$DEFAULT_BRANCH" >> "$LOG" 2>&1 || { echo "ERROR: could not fetch origin/$DEFAULT_BRANCH" >&2; exit 1; }
  ensure_builder_labels || { echo "ERROR: could not ensure builder labels" >&2; exit 1; }
fi

# Approval/recovery always precedes new drafting.
approval_sweep

: > "$ALL_TICKETS"
if [ "$SOURCE" = "github" ] || [ "$SOURCE" = "both" ]; then
  fetch_github_tickets "$GITHUB_TICKETS" || exit 1
  cat "$GITHUB_TICKETS" >> "$ALL_TICKETS"
fi
if [ "$SOURCE" = "jira" ] || [ "$SOURCE" = "both" ]; then
  fetch_jira_tickets "$JIRA_TICKETS"
  cat "$JIRA_TICKETS" >> "$ALL_TICKETS"
fi

if [ "$DRY_RUN" -eq 0 ] && [ -s "$ALL_TICKETS" ]; then
  _probe_rc=0
  reviewer_preflight || _probe_rc=$?
  case "$_probe_rc" in
    0) ;;
    3) echo "ERROR: Codex CLI is too old for the configured model; run 'codex update' before drafting" >&2; exit 1 ;;
    4) echo "ERROR: Codex workspace is out of credits; add credits before drafting" >&2; exit 1 ;;
    *) echo "ERROR: $REVIEWER pre-flight probe failed (rc=$_probe_rc); no specs drafted" >&2; exit 1 ;;
  esac
  unset _probe_rc
fi

drafts_started=0
# fd 3: draft_ticket invokes the implementer harness, which inherits stdin. Reading
# the queue on fd 0 would let `claude -p` consume the remaining ticket lines as
# prompt input.
while IFS="$RS" read -r -u 3 ticket_source ticket_key title_b64 body_b64 url_b64; do
  [ -n "$ticket_key" ] || continue
  existing_pr=$(existing_pr_number "$ticket_source" "$ticket_key")
  if [ -n "$existing_pr" ]; then
    echo "[draft] ticket $ticket_key ($ticket_source) → already has open/merged spec PR #$existing_pr, skipped"
    continue
  fi
  [ "$drafts_started" -lt "$MAX_TICKETS" ] || break
  title=$(printf '%s' "$title_b64" | b64decode)
  body=$(printf '%s' "$body_b64" | b64decode)
  ticket_url=$(printf '%s' "$url_b64" | b64decode)
  drafts_started=$((drafts_started + 1))
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[draft] ticket $ticket_key ($ticket_source) → [dry-run] would draft spec and open PR"
    continue
  fi
  draft_ticket "$ticket_source" "$ticket_key" "$title" "$body" "$ticket_url" || true
  if [ "$SPEC_REVIEW_HALT" -ne 0 ]; then
    case "$SPEC_REVIEW_HALT" in
      2) echo "Halting: reviewer MCP outage; the spec PR is labelled spec-review-mcp-outage and stays draft. Re-run to retry. See $LOG" >&2 ;;
      3) echo "Halting: Codex version incompatibility; upgrade the CLI, remove spec-review-codex-outdated, then re-run. See $LOG" >&2 ;;
      4) echo "Halting: Codex workspace out of credits; add credits, remove spec-review-codex-no-credits, then re-run. See $LOG" >&2 ;;
    esac
    break
  fi
done 3< "$ALL_TICKETS"

echo "Work prep complete: $drafts_started new ticket(s) considered for drafting."
