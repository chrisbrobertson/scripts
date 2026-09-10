#!/bin/bash
# babysit-work-prep.sh — turn GitHub/Jira tickets into human-approved TIF specs.
#
# The approval sweep runs first, then up to --max-tickets new spec drafts are
# created. Every draft is isolated in a git worktree and opened as a PR. An
# authorized `approved` comment merges the spec PR and creates the GitHub
# sub-ticket consumed by babysit-builder.sh.

set -uo pipefail

VERSION="0.1.0"

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
  --max-tickets N            Maximum new drafts per run (1-20). Default: 20.
  --dry-run                  Read queues and approvals without making changes.
  -h, --help                 Show help.
  --version                  Show version.

All value options accept both `--name VALUE` and `--name=VALUE`.

Environment:
  JIRA_BASE_URL              Required for --source jira|both.
  JIRA_TOKEN                 Jira bearer token (required for Jira sources).
  JIRA_PROJECT               Jira project key (required for Jira sources).
  WORK_PREP_APPROVERS        Comma-separated GitHub logins allowed to approve.
                             Default: the authenticated gh user. Use * to allow
                             any commenter (not recommended for shared repos).
  WORK_PREP_SPEC_DIR         Repo-relative spec directory. Default: ./specs,
                             then the first ./*-specs directory, else ./specs.

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
    --max-tickets) require_value "$1" "${2:-}"; MAX_TICKETS="$2"; shift 2 ;;
    --max-tickets=*) MAX_TICKETS="${1#*=}"; [ -n "$MAX_TICKETS" ] || die_usage "--max-tickets requires a value"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; [ "$#" -eq 0 ] || die_usage "unexpected positional arguments: $*" ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

case "$SOURCE" in github|jira|both) ;; *) die_usage "invalid source '$SOURCE' (expected github, jira, or both)" ;; esac
case "$IMPLEMENTER" in claude|codex) ;; *) die_usage "invalid implementer '$IMPLEMENTER' (expected claude or codex)" ;; esac
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
fi

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

b64decode() {
  python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.buffer.read()).decode("utf-8", "replace"))'
}

fetch_pr_records() {
  local output_file="$1" raw_file="$TMP_ROOT/prs.json"
  if ! gh pr list --repo "$REPO" --state all --limit 1000 \
    --json number,state,title,body,url,headRefName,comments > "$raw_file"; then
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
        author_obj = comment.get("author") or {}
        author = (author_obj.get("login") or comment.get("authorLogin") or "").strip()
        if approval.search(comment.get("body") or "") and (allow_any or author.lower() in allowed):
            approved_by = author or "unknown"
            break
    fields = [
        str(pr.get("number") or ""), (pr.get("state") or "").upper(), source,
        ticket, b64(ticket_url), b64(spec_path), b64(pr.get("title")),
        "1" if approved_by else "0", b64(approved_by), b64(pr.get("url")),
    ]
    print("\t".join(fields))
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
        print("\t".join([match.group(1), match.group(2), str(issue.get("number") or ""), issue.get("url") or ""]))
PY
}

existing_subticket() {
  local source="$1" ticket="$2"
  awk -F '\t' -v s="$source" -v t="$ticket" '$1 == s && $2 == t { print $3 "\t" $4; exit }' "$SUBTICKET_RECORDS"
}

ensure_builder_labels() {
  gh label create sub-ticket --repo "$REPO" --color 5319e7 --description "Implementation unit created from an approved spec" --force >/dev/null
  gh label create status:ready-to-build --repo "$REPO" --color 0e8a16 --description "Approved and ready for the builder loop" --force >/dev/null
}

approval_sweep() {
  local pr_num state source ticket ticket_url_b64 spec_path_b64 title_b64 approved approver_b64 pr_url_b64
  local ticket_url spec_path title approver pr_url existing sub_num sub_url issue_url issue_num issue_body
  while IFS=$'\t' read -r pr_num state source ticket ticket_url_b64 spec_path_b64 title_b64 approved approver_b64 pr_url_b64; do
    [ -n "$pr_num" ] || continue
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
      --body-file "$issue_body" --label sub-ticket --label status:ready-to-build 2>> "$LOG") || {
      echo "[approve] PR #$pr_num: sub-ticket creation failed; merged PR will be reconciled next run" >&2
      continue
    }
    issue_num=${issue_url##*/}
    printf '%s\t%s\t%s\t%s\n' "$source" "$ticket" "$issue_num" "$issue_url" >> "$SUBTICKET_RECORDS"
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
    if "sub-ticket" in labels or "status:ready-to-build" in labels:
        continue
    print("\t".join(["github", str(issue.get("number")), b64(issue.get("title")), b64(issue.get("body")), b64(issue.get("url"))]))
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
    print("\t".join(["jira", str(key), b64(fields.get("summary")), b64(text(fields.get("description"))), b64(url)]))
PY
  then
    echo "[jira] Jira returned an invalid response → skipping Jira-sourced tickets this run" >&2
    : > "$output_file"
  fi
}

existing_pr_number() {
  local source="$1" ticket="$2"
  awk -F '\t' -v s="$source" -v t="$ticket" \
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
    try: event = json.loads(line)
    except Exception: continue
    if event.get("type") == "result": final = event.get("result") or ""
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

Review the specification and post an authorized comment whose line starts with **approved** to merge it and create the builder sub-ticket. Authorized approvers: $APPROVERS.
EOF
  pr_url=$(gh pr create --repo "$REPO" --head "$branch" --base "$DEFAULT_BRANCH" \
    --title "[spec] $title" --body-file "$pr_body_file" 2>> "$LOG") || {
    echo "[draft] ticket $ticket: PR creation failed; pushed branch $branch retained" >&2
    return 1
  }
  pr_num=${pr_url##*/}
  echo "[draft] ticket $ticket ($source) → PR #$pr_num opened ($spec_path)"
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

drafts_started=0
# fd 3: draft_ticket invokes the implementer harness, which inherits stdin. Reading
# the queue on fd 0 would let `claude -p` consume the remaining ticket lines as
# prompt input.
while IFS=$'\t' read -r -u 3 ticket_source ticket_key title_b64 body_b64 url_b64; do
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
done 3< "$ALL_TICKETS"

echo "Work prep complete: $drafts_started new ticket(s) considered for drafting."
