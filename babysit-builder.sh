#!/bin/bash
# babysit-builder.sh — turn `build-ready` tickets into review-ready PRs.
#
# Implements ASF-FEAT-BUILDER (babysit-specs/L3-builder.md). Every ticket in the
# queue — a GitHub issue or a Jira issue, sub-ticket or otherwise — is built in a
# dedicated git worktree and then driven through the same convergent adversarial
# review cycle as babysit-with-review.sh. This script NEVER merges: it halts with
# the PR labelled for a human to merge.
#
# Divergences from babysit-with-review.sh worth knowing:
#   * The per-ticket worktree is kept alive through the build cycle. There is no
#     `gh pr checkout`, so nothing forces a teardown, and the operator's checkout
#     is never mutated.
#   * No `gh pr merge` call exists anywhere in this file.
#   * Labels live in the `build-*` namespace; `review-*` labels are never read or
#     written.

set -uo pipefail

VERSION="0.1.0"

usage() {
  cat <<'EOF'
Usage: babysit-builder.sh [OPTIONS]

Run from inside the project whose `build-ready` tickets should be built.

Each queued ticket is implemented in its own git worktree, opened as a PR, and
driven through a convergent review cycle. The script halts for a human to merge;
it never merges a PR itself.

Options:
  --repo OWNER/REPO          GitHub repository. Default: infer from gh context.
  --source github|jira|both  Ticket source. Default: github.
  --implementer claude|codex Implementation harness. Default: claude.
  --implementer-model MODEL  Model passed to the implementation harness.
  --implementer-effort LEVEL Effort passed to the implementation harness.
  --reviewer claude|codex    Review harness. Default: codex.
  --reviewer-model MODEL     Model passed to the review harness.
  --reviewer-effort LEVEL    Effort passed to the review harness.
  --repo-base PATH           Base dir holding cloned repos; helper scripts are
                             expected at PATH/scripts. Default: auto-detect
                             ~/repos then ~/repo.
  --max-tickets N            Maximum tickets built per run (1-20). Default: 5.
  --dry-run                  Read the build queue without making any change.
  -h, --help                 Show help.
  --version                  Show version.

All value options accept both `--name VALUE` and `--name=VALUE`.

Environment:
  MAX_REVIEW_CYCLES          Review cycles before halting a PR. Default: 6.
  REPO_BASE                  Same as --repo-base (flag wins).
  JIRA_BASE_URL              Required for --source jira|both.
  JIRA_TOKEN                 Jira bearer token; needs read AND write scope.
  JIRA_PROJECT               Jira project key.

Labels (all in the `build-*` namespace):
  build-ready                Queue label. Any ticket carrying it is eligible work.
  build-done                 Terminal ticket label; swaps out `build-ready`.
  build-needs-clarification  Terminal ticket label: spec gap, kicked back.
  build-ready-for-merge      PR converged with 0 BLOCKING; human merges it.
  build-max-cycles           PR exhausted MAX_REVIEW_CYCLES with findings open.
  build-incomplete           Build cycle bailed; manual review required.
  build-mcp-outage           Reviewer transport failure; retried next run.
  build-codex-outdated       Codex CLI too old; upgrade then remove the label.
  build-codex-no-credits     Codex workspace out of credits; add credits.

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
MAX_TICKETS=5
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) echo "babysit-builder.sh $VERSION"; exit 0 ;;
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

MAX_REVIEW_CYCLES="${MAX_REVIEW_CYCLES:-6}"
case "$MAX_REVIEW_CYCLES" in ''|*[!0-9]*) echo "ERROR: MAX_REVIEW_CYCLES must be a positive integer" >&2; exit 1 ;; esac
[ "$MAX_REVIEW_CYCLES" -ge 1 ] || { echo "ERROR: MAX_REVIEW_CYCLES must be a positive integer" >&2; exit 1; }

# ---------- pre-flight ----------

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

# Base directory holding the cloned repos; helper scripts live at $REPO_BASE/scripts.
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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/babysit-builder.XXXXXX") || exit 1
WORKTREE_LIST="$TMP_ROOT/worktrees"
: > "$WORKTREE_LIST"
TMP_RESULT="$TMP_ROOT/result"
TMP_REVIEW="$TMP_ROOT/review"
TMP_REVIEW_RESULT="$TMP_ROOT/review-result"
TMP_CODEX_FULL="$TMP_ROOT/codex-full"
LOG_DIR="$HOME/sisyphus-logs"
LOG="$LOG_DIR/${PROJECT}-builder-$(date +%Y%m%d-%H%M%S)-$$.log"
STOP_FILE="$LOG_DIR/${PROJECT}-builder.stop"
LOCK_HELD=0

cleanup() {
  if [ -f "$WORKTREE_LIST" ]; then
    while IFS= read -r worktree_path; do
      [ -n "$worktree_path" ] || continue
      git worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
      rm -rf "$worktree_path" >/dev/null 2>&1 || true
    done < "$WORKTREE_LIST"
  fi
  git worktree prune >/dev/null 2>&1 || true
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
      echo "ERROR: builder lock held by live PID $old_pid: $STOP_FILE" >&2
      exit 1
    fi
    echo "[lock] clearing stale builder lock: $STOP_FILE" >&2
    rm -f "$STOP_FILE"
  fi
  if ! (set -C; printf '%s\n' "$$" > "$STOP_FILE") 2>/dev/null; then
    echo "ERROR: another builder process acquired $STOP_FILE" >&2
    exit 1
  fi
  LOCK_HELD=1
  touch "$LOG"
else
  LOG="$TMP_ROOT/dry-run.log"
  touch "$LOG"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Builder for $REPO (source=$SOURCE, implementer=$IMPLEMENTER, reviewer=$REVIEWER, max=$MAX_TICKETS, cycles=$MAX_REVIEW_CYCLES, dry-run)"
else
  echo "Builder for $REPO (source=$SOURCE, implementer=$IMPLEMENTER, reviewer=$REVIEWER, max=$MAX_TICKETS, cycles=$MAX_REVIEW_CYCLES) → $LOG"
  echo "  graceful stop: rm $STOP_FILE"
fi

# ---------- review prompts (mirrored from babysit-with-review.sh) ----------

IFS= read -r -d '' REVIEW_PROMPT_CYCLE1 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle 1 of __MAX_CYCLES__. This is the first review of this PR.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

Output your review using EXACTLY this format:

## BLOCKING
- <one-line description> — <file:line> — <why it must be fixed before merge>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Format rules:
- BLOCKING, RECOMMENDED, and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
PROMPT_EOF

IFS= read -r -d '' REVIEW_PROMPT_CYCLE2 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle 2 of __MAX_CYCLES__. The previous cycle did not fully resolve BLOCKING issues.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line> — <why it must be fixed before merge>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Convergence tracking:
- Mark each BLOCKING finding with [NEW] if it was not flagged in previous cycles, or [RECURRENCE] if it was flagged before but remains unresolved.

Format rules:
- BLOCKING bullets start with [NEW|RECURRENCE] tag, followed by single-line description.
- RECOMMENDED and INFORMATION are single-line bullets only (no tags).
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
PROMPT_EOF

IFS= read -r -d '' REVIEW_PROMPT_CYCLE3_4 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. This cycle uses prescriptive mode with detailed explanations.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line> — <why it must be fixed before merge>
  Suggested fix: <concrete code change — show the exact replacement or patch sketch>
  Root cause: <why this gap exists — when/how introduced, what changed>
  Architectural context: <how this component fits into the system, what boundaries it enforces>
  Impact: <what breaks if not fixed — user-facing symptoms, error rates, affected flows>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Prescriptive mode requirements:
- Each BLOCKING finding MUST include all four parts: suggested fix, root cause, architectural context, impact.
- If you cannot produce all four parts for a finding, downgrade it to RECOMMENDED.
- Suggested fix must be concrete code showing the exact change needed.

Convergence tracking:
- Mark each BLOCKING finding with [NEW] if it was not flagged in previous cycles, or [RECURRENCE] if it was flagged before but remains unresolved.

Format rules:
- BLOCKING bullets are multi-line with four required sub-bullets (suggested fix, root cause, architectural context, impact).
- RECOMMENDED and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
PROMPT_EOF

IFS= read -r -d '' REVIEW_PROMPT_CYCLE5_6 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. The implementer posted resolution justifications for the previous cycle's findings. You must adjudicate those justifications AND review the current code state.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

--- implementer resolution justifications (from previous cycle) begin ---
__JUSTIFICATIONS__
--- implementer resolution justifications end ---

You have two responsibilities this cycle:

RESPONSIBILITY 1: Adjudicate the implementer's resolution justifications.
For each justification posted, you must respond:
- If a finding was claimed "resolved": examine the referenced commit and the current code. Either the fix genuinely addresses the root cause and architectural constraints, or it does not.
- If a finding was claimed "invalid": evaluate the reasoning and the cited supporting reference. Either the reference proves the finding incorrect, or it does not.

RESPONSIBILITY 2: Review the current code state for any remaining or new issues (same as previous cycles).

Output your review using EXACTLY this format:

## ADJUDICATION
- BLOCKING <one-line finding from previous cycle>: ACCEPTED — <one-line confirmation that the fix/invalidity argument is sound>
- BLOCKING <one-line finding from previous cycle>: DISAGREED — <reasoned explanation with code-level evidence of why the fix does not resolve the issue or why the finding remains valid>

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line> — <why it must be fixed before merge>
  Suggested fix: <concrete code change — show the exact replacement or patch sketch>
  Root cause: <why this gap exists — when/how introduced, what changed>
  Architectural context: <how this component fits into the system, what boundaries it enforces>
  Impact: <what breaks if not fixed — user-facing symptoms, error rates, affected flows>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Adjudication rules:
- You MUST adjudicate every justification the implementer posted. No justification may be silently ignored.
- ACCEPTED means you agree the finding is resolved or invalid — it will not recur in future reviews.
- DISAGREED means the finding remains unresolved — it MUST appear in your BLOCKING section as [RECURRENCE] with an updated suggested fix that addresses your counter-argument.
- Your disagreement must include specific code-level evidence (file:line references, logic traces, or behavioral analysis). Generic disagreements ("this doesn't look right") are not acceptable.

Prescriptive mode requirements:
- Each BLOCKING finding MUST include all four parts: suggested fix, root cause, architectural context, impact.
- If you cannot produce all four parts for a finding, downgrade it to RECOMMENDED.
- Suggested fix must be concrete code showing the exact change needed.

Convergence tracking:
- Mark each BLOCKING finding with [NEW] if it was not flagged in previous cycles, or [RECURRENCE] if it was flagged before but remains unresolved.

Format rules:
- ADJUDICATION section comes first, before BLOCKING/RECOMMENDED/INFORMATION.
- BLOCKING bullets are multi-line with four required sub-bullets (suggested fix, root cause, architectural context, impact).
- RECOMMENDED and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT make code changes. This is review only.
PROMPT_EOF

IFS= read -r -d '' REMEDIATION_PROMPT_CYCLE1 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 1 of __MAX_CYCLES__. This is the first review of this PR.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

Implementation:
- Address all BLOCKING findings with minimal, targeted changes.
- Run relevant tests after each fix.
- Commit each fix separately using standard format: fix(<scope>): <what changed>
- Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before outputting DONE_REVIEW, run the full test suite and verify no new surface introduced.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

IFS= read -r -d '' REMEDIATION_PROMPT_CYCLE2_3 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. The previous cycle(s) did not fully resolve BLOCKING issues.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Plan your approach BEFORE implementing.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit. Instead, plan inline:

Step 1: Analyze and outline your approach (as text output):
  - List all BLOCKING findings and their dependencies
  - Determine the correct order to address them (some fixes may depend on others)
  - Identify any cross-finding interactions or shared root causes
  - Note trade-offs and alternatives for non-obvious decisions

Step 2: Execute your plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before outputting DONE_REVIEW, run the full test suite and verify no new surface introduced.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

IFS= read -r -d '' REMEDIATION_PROMPT_CYCLE4 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 4 of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Plan your approach BEFORE implementing.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit. Instead, plan inline:

Step 1: Analyze and outline your approach (as text output):
  - List all BLOCKING findings and their dependencies
  - Determine the correct order to address them (some fixes may depend on others)
  - Identify any cross-finding interactions or shared root causes
  - Note trade-offs and alternatives for non-obvious decisions

Step 2: Execute your plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Step 3: Post resolution justification as PR comment:
  For EACH BLOCKING finding in the review, you must post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by the reviewer and satisfies the architectural constraints>"
  - If invalid: "BLOCKING <one-line finding description> is invalid. Reason: <explanation>. Supporting reference: <link to spec/docs/validated source proving the finding is incorrect>"

  Use `gh pr comment __PR_NUMBER__ --body "<text>"` to post the justification.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before Step 3, run the full test suite and verify no new surface introduced.
- Step 3 is MANDATORY before DONE_REVIEW.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address AND posted resolution justifications)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

IFS= read -r -d '' REMEDIATION_PROMPT_CYCLE5_6 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. The reviewer has adjudicated your previous resolution justifications.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Process the ADJUDICATION section first, then plan your approach inline.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit.

Step 1: Process the reviewer's adjudication results:
  - For each ACCEPTED item: the finding is resolved. No further action needed.
  - For each DISAGREED item: the reviewer has provided a reasoned counter-argument with code evidence. You must either:
    (a) Implement a different fix that specifically addresses the counter-argument, OR
    (b) If you believe the counter-argument is itself incorrect, report via STUCK_REVIEW with the specific finding, the reviewer's argument, and why you disagree (this escalates to human review).

Step 2: Outline your implementation plan (as text output) for all remaining BLOCKING findings:
  - Include all DISAGREED items that you will re-address (from Step 1a)
  - Include all new BLOCKING findings from the current review
  - Determine the correct order to address them
  - Note trade-offs and alternatives for non-obvious decisions

Step 3: Execute your plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Step 4: Post resolution justification as PR comment:
  For EACH BLOCKING finding (including DISAGREED items you re-addressed), post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by the reviewer and satisfies the architectural constraints>"
  - If invalid: "BLOCKING <one-line finding description> is invalid. Reason: <explanation>. Supporting reference: <link to spec/docs/validated source proving the finding is incorrect>"
  - If re-addressed after disagreement: "BLOCKING <one-line finding description> re-addressed after reviewer disagreement. Previous fix was insufficient because: <acknowledge the reviewer's point>. New fix in commit <SHA>: <explanation of how the new approach resolves the concern>"

  Use `gh pr comment __PR_NUMBER__ --body "<text>"` to post the justification.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before Step 4, run the full test suite and verify no new surface introduced.
- Step 4 is MANDATORY before DONE_REVIEW.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address AND posted resolution justifications)
- STUCK_REVIEW <one-line reason> (you cannot proceed — use this if the reviewer's disagreement is itself incorrect and needs human review)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

# ---------- generic helpers ----------

b64decode() {
  python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.buffer.read()).decode("utf-8", "replace"))'
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40
}

# ---------- implementer harness ----------

run_claude() {
  local prompt="$1" out_file="$2" run_dir="$3" stage_model="${4:-claude-sonnet-5}"
  local model="${IMPLEMENTER_MODEL:-$stage_model}"
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
        event = json.loads(line)
    except Exception:
        continue
    kind = event.get("type")
    if kind == "assistant":
        for block in event.get("message", {}).get("content", []):
            if block.get("type") == "tool_use":
                inp = block.get("input") or {}
                summary = inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                summary = str(summary).splitlines()[0][:120] if summary else ""
                name = block.get("name") or "?"
                print(("  [tool] %s %s" % (name, summary)).rstrip(), file=sys.stderr, flush=True)
    elif kind == "result":
        final = event.get("result") or ""
sys.stdout.write(final)
' > "$out_file"
  return ${PIPESTATUS[0]}
}

run_codex_implementer() {
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
    claude) run_claude "$1" "$2" "$3" "${4:-claude-sonnet-5}" ;;
    codex) run_codex_implementer "$1" "$2" "$3" ;;
  esac
}

# ---------- reviewer harness ----------

# Count BLOCKING findings in a strict-markdown review on stdin.
# Treats a single `- (none)` bullet as zero findings.
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

# Validate the strict review parser contract shared by all reviewer harnesses.
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

# Run codex exec with retry on MCP transport failures. Runs inside $BUILD_DIR.
# Returns: 0 clean, 1 non-transport failure, 2 MCP outage (retries exhausted),
#          3 Codex CLI too old, 4 workspace out of credits.
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
    (cd "$BUILD_DIR" && codex "${codex_args[@]}" "$codex_prompt" 2>&1 < /dev/null) \
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

# Run a Claude review with non-mutating plan permissions, inside $BUILD_DIR.
claude_review() {
  local review_prompt="$1" rc
  local -a args=(-p "$review_prompt" --permission-mode plan)
  [ -n "$REVIEWER_MODEL" ] && args+=(--model "$REVIEWER_MODEL")
  [ -n "$REVIEWER_EFFORT" ] && args+=(--effort "$REVIEWER_EFFORT")
  args+=(--output-format stream-json --verbose)
  : > "$TMP_REVIEW"
  (cd "$BUILD_DIR" && claude "${args[@]}" 2>&1 < /dev/null) \
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

# Codex-only preflight preserves compatibility and credit detection. Run once per
# invocation, before any implementer time is spent.
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

# ---------- GitHub / Jira lifecycle ----------

ensure_build_labels() {
  gh label create build-ready --repo "$REPO" --color 0e8a16 \
    --description "Ticket is ready for the builder loop" --force >/dev/null 2>&1 || return 1
  gh label create build-done --repo "$REPO" --color c5def5 \
    --description "Builder has produced a PR for this ticket; no longer queued" --force >/dev/null 2>&1 || return 1
  gh label create build-needs-clarification --repo "$REPO" --color fbca04 \
    --description "Builder found a gap in the referenced spec; kicked back for clarification" --force >/dev/null 2>&1 || return 1
  gh label create build-ready-for-merge --repo "$REPO" --color 1d76db \
    --description "Build cycle converged with 0 BLOCKING findings; awaiting human merge" --force >/dev/null 2>&1 || return 1
  gh label create build-max-cycles --repo "$REPO" --color d93f0b \
    --description "Build cycle exhausted MAX_REVIEW_CYCLES with BLOCKING findings open" --force >/dev/null 2>&1 || return 1
  gh label create build-incomplete --repo "$REPO" --color B60205 \
    --description "Build cycle bailed; manual review required" --force >/dev/null 2>&1 || return 1
  gh label create build-mcp-outage --repo "$REPO" --color 0075CA \
    --description "Builder review stalled by MCP transport failure; retried next run" --force >/dev/null 2>&1 || return 1
  gh label create build-codex-outdated --repo "$REPO" --color e4e669 \
    --description "Builder review blocked: Codex CLI too old; upgrade then remove label" --force >/dev/null 2>&1 || return 1
  gh label create build-codex-no-credits --repo "$REPO" --color d93f0b \
    --description "Builder review blocked: Codex workspace out of credits" --force >/dev/null 2>&1 || return 1
}

jira_api() {
  local method="$1" path="$2" body_file="${3:-}"
  local url="${JIRA_BASE_URL%/}$path"
  local -a args=(-fsS -X "$method" -H "Authorization: Bearer $JIRA_TOKEN" -H "Accept: application/json")
  if [ -n "$body_file" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "@$body_file")
  fi
  curl "${args[@]}" "$url" >> "$LOG" 2>&1
}

# Swap the queue label for a terminal label in a single operation (invariant 7).
# Args: <source> <ticket> <terminal-label>
ticket_swap_to_terminal() {
  local source="$1" ticket="$2" terminal="$3"
  if [ "$source" = "github" ]; then
    gh issue edit "$ticket" --repo "$REPO" \
      --remove-label build-ready --add-label "$terminal" >> "$LOG" 2>&1
    return $?
  fi
  local body_file="$TMP_ROOT/jira-labels-$$.json"
  python3 - "$terminal" > "$body_file" <<'PY'
import json, sys
print(json.dumps({"update": {"labels": [{"remove": "build-ready"}, {"add": sys.argv[1]}]}}))
PY
  jira_api PUT "/rest/api/3/issue/$ticket" "$body_file"
}

# Args: <source> <ticket> <text-file>
ticket_comment() {
  local source="$1" ticket="$2" text_file="$3"
  if [ "$source" = "github" ]; then
    gh issue comment "$ticket" --repo "$REPO" --body-file "$text_file" >> "$LOG" 2>&1
    return $?
  fi
  local body_file="$TMP_ROOT/jira-comment-$$.json"
  python3 - "$text_file" > "$body_file" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
content = [
    {"type": "paragraph", "content": [{"type": "text", "text": line}]} if line else {"type": "paragraph"}
    for line in text.splitlines()
]
print(json.dumps({"body": {"type": "doc", "version": 1, "content": content or [{"type": "paragraph"}]}}))
PY
  jira_api POST "/rest/api/3/issue/$ticket/comment" "$body_file"
}

# Fetch all existing PR feedback, filtering out this pipeline's own comments.
collect_pr_feedback() {
  local pr_num="$1" out=""
  local reviews comments inline
  reviews=$(gh pr view "$pr_num" --repo "$REPO" --json reviews \
    --jq '.reviews[]
          | select(.body != "")
          | select(.body | startswith("**Codex review") | not)
          | select(.body | startswith("**Claude review") | not)
          | select(.body | startswith("**babysit-builder:") | not)
          | "### Review by \(.author.login) [\(.state)]\n\(.body)\n"' \
    2>/dev/null || true)
  [ -n "$reviews" ] && out="${out}${reviews}"$'\n'

  comments=$(gh pr view "$pr_num" --repo "$REPO" --json comments \
    --jq '.comments[]
          | select(.body | startswith("**Codex review") | not)
          | select(.body | startswith("**Claude review") | not)
          | select(.body | startswith("**babysit-builder:") | not)
          | "### Comment by \(.author.login)\n\(.body)\n"' \
    2>/dev/null || true)
  [ -n "$comments" ] && out="${out}${comments}"$'\n'

  inline=$(gh api "repos/${REPO}/pulls/${pr_num}/comments" \
    --jq '.[] | "### Inline comment by \(.user.login) on \(.path):\(.line // .original_line // "?")\n\(.body)\n"' \
    2>/dev/null || true)
  [ -n "$inline" ] && out="${out}${inline}"$'\n'

  [ -z "$out" ] && out="(none)"
  printf '%s' "$out"
}

post_reviewer_review() {
  local pr_num="$1" cycle="$2" max="$3" review_file="$4"
  [ -s "$review_file" ] || return 0
  local reviewer_name body
  case "$REVIEWER" in codex) reviewer_name="Codex" ;; claude) reviewer_name="Claude" ;; esac
  body="**${reviewer_name} review — PR #${pr_num} cycle ${cycle} of ${max}**

\`\`\`
$(cat "$review_file")
\`\`\`"
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --repo "$REPO" --body-file - >> "$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment ($REVIEWER review) failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Quarantine a PR whose build cycle could not complete. Safety commands are
# fail-closed; notification commands are best-effort.
# Args: <pr_num> <label> <heading> <reason> <extra-body>
quarantine_pr() {
  local pr_num="$1" label="$2" heading="$3" reason="$4" extra="${5:-}"

  echo "  [build] marking PR #$pr_num $label: $reason" | tee -a "$LOG" >&2

  if ! gh pr ready "$pr_num" --repo "$REPO" --undo >> "$LOG" 2>&1; then
    echo "ERROR: gh pr ready --undo failed for PR #$pr_num — draft it manually before restarting" | tee -a "$LOG" >&2
    exit 1
  fi
  if ! gh pr edit "$pr_num" --repo "$REPO" --add-label "$label" >> "$LOG" 2>&1; then
    echo "ERROR: gh pr edit --add-label failed for PR #$pr_num — add '$label' manually before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  local body_file="$TMP_ROOT/quarantine-$pr_num.md"
  {
    printf '**babysit-builder: %s**\n\n' "$heading"
    printf 'Reason: %s\n' "$reason"
    [ -n "$extra" ] && printf '\n%s\n' "$extra"
  } > "$body_file"
  gh pr comment "$pr_num" --repo "$REPO" --body-file "$body_file" >> "$LOG" 2>&1 \
    || echo "  [build] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

fail_build_cycle() {
  quarantine_pr "$1" build-incomplete "build cycle bailed — manual review required" "$2" \
    "This PR was NOT merged and no \`codex-review\` status was posted. Resolve the outstanding findings by hand, or close the PR."
}

fail_build_cycle_mcp() {
  quarantine_pr "$1" build-mcp-outage "reviewer MCP transport failure — review pending" "$2" \
    "The codex MCP backend was unreachable. No code-quality review took place. The builder retries this PR automatically at the start of its next run.

Remove the \`build-mcp-outage\` label manually if you merge this PR without waiting for an automated review."
}

fail_build_cycle_codex_outdated() {
  quarantine_pr "$1" build-codex-outdated "Codex version incompatibility — review blocked" "$2" \
    "The Codex CLI is too old for the configured model. No code-quality review took place.

To resume: upgrade the Codex CLI (\`codex update\`), then remove the \`build-codex-outdated\` label and re-run the builder."
}

fail_build_cycle_codex_no_credits() {
  quarantine_pr "$1" build-codex-no-credits "Codex workspace out of credits — review blocked" "$2" \
    "The Codex workspace has no credits remaining. No code-quality review took place.

To resume: add credits to the Codex workspace, then remove the \`build-codex-no-credits\` label and re-run the builder."
}

# Stamp the builder marker into a PR body so a later run can map the PR back to
# its ticket. Idempotent.
ensure_pr_marker() {
  local pr_num="$1" source="$2" ticket="$3"
  local marker="<!-- babysit-builder source=$source ticket=$ticket -->"
  local body
  body=$(gh pr view "$pr_num" --repo "$REPO" --json body -q .body 2>/dev/null || echo "")
  case "$body" in *"$marker"*) return 0 ;; esac
  local body_file="$TMP_ROOT/pr-body-$pr_num.md"
  printf '%s\n\n%s\n' "$marker" "$body" > "$body_file"
  gh pr edit "$pr_num" --repo "$REPO" --body-file "$body_file" >> "$LOG" 2>&1 \
    || echo "  [build] WARNING: could not stamp builder marker on PR #$pr_num" | tee -a "$LOG" >&2
}

# ---------- build cycle ----------

# Reviewer → implementer convergence loop for one PR. Mirrors run_review_cycle in
# babysit-with-review.sh, minus every merge path.
#
# Globals: BUILD_DIR (worktree checked out on the PR branch), BUILD_BRANCH.
# Returns: 0 the PR reached a terminal state (converged, max cycles, or bail);
#          2 reviewer MCP outage; 3 Codex too old; 4 Codex out of credits.
run_build_cycle() {
  local pr_num="$1"
  local cycle=0 review_start_sha="" justifications=""
  local -a REVIEW_HISTORY=()

  echo "=== build cycle: PR #$pr_num @ $(date -u +%FT%TZ) ===" | tee -a "$LOG" >&2
  review_start_sha=$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || echo "")

  while [ "$cycle" -lt "$MAX_REVIEW_CYCLES" ]; do
    cycle=$((cycle + 1))
    echo "--- build cycle $cycle / $MAX_REVIEW_CYCLES (PR #$pr_num) @ $(date -u +%FT%TZ) ---" | tee -a "$LOG" >&2

    local history_block=""
    if [ "$cycle" -ge 2 ] && [ "${#REVIEW_HISTORY[@]}" -gt 0 ]; then
      local _hb="" _i _commits
      for _i in "${!REVIEW_HISTORY[@]}"; do
        _hb="${_hb}### cycle $(( _i + 1 )) review
${REVIEW_HISTORY[$_i]}
"
      done
      _commits=$(git -C "$BUILD_DIR" log --oneline "${review_start_sha}..HEAD" 2>/dev/null || true)
      _hb="${_hb}--- commits the implementer made since the build cycle started ---
${_commits:-"(none)"}
--- end commits ---
"
      history_block="--- prior review cycles (for convergence tracking) ---
${_hb}--- end prior review cycles ---
"
      unset _hb _i _commits
    fi

    local _tmpl _tmpl_name
    if [ "$cycle" -eq 1 ]; then
      _tmpl="$REVIEW_PROMPT_CYCLE1"; _tmpl_name="descriptive-baseline"
    elif [ "$cycle" -eq 2 ]; then
      _tmpl="$REVIEW_PROMPT_CYCLE2"; _tmpl_name="descriptive-convergence"
    elif [ "$cycle" -le 4 ]; then
      _tmpl="$REVIEW_PROMPT_CYCLE3_4"; _tmpl_name="prescriptive-detailed"
    else
      _tmpl="$REVIEW_PROMPT_CYCLE5_6"; _tmpl_name="prescriptive-adjudication"
    fi
    local review_prompt
    review_prompt="${_tmpl//__PR_NUMBER__/$pr_num}"
    review_prompt="${review_prompt//__CYCLE__/$cycle}"
    review_prompt="${review_prompt//__MAX_CYCLES__/$MAX_REVIEW_CYCLES}"
    review_prompt="${review_prompt//__HISTORY_BLOCK__/$history_block}"
    review_prompt="${review_prompt//__JUSTIFICATIONS__/$justifications}"
    echo "  [$REVIEWER reviewer] template=${_tmpl_name} cycle=${cycle}/${MAX_REVIEW_CYCLES}" | tee -a "$LOG" >&2
    unset _tmpl _tmpl_name

    local reviewer_rc=0
    review_with_retry "$review_prompt" || reviewer_rc=$?

    if [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 3 ]; then
      fail_build_cycle_codex_outdated "$pr_num" "Codex CLI version incompatibility during review (cycle $cycle)"
      return 3
    elif [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 4 ]; then
      fail_build_cycle_codex_no_credits "$pr_num" "Codex workspace out of credits during review (cycle $cycle)"
      return 4
    elif [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 2 ]; then
      fail_build_cycle_mcp "$pr_num" "codex MCP transport failure after 3 retries (cycle $cycle)"
      return 2
    elif [ "$reviewer_rc" -ne 0 ]; then
      fail_build_cycle "$pr_num" "$REVIEWER review failed during cycle $cycle"
      return 0
    fi

    local review
    review=$(cat "$TMP_REVIEW")
    REVIEW_HISTORY+=("$review")
    post_reviewer_review "$pr_num" "$cycle" "$MAX_REVIEW_CYCLES" "$TMP_REVIEW"
    {
      echo "--- $REVIEWER review (cycle $cycle) ---"
      printf '%s\n' "$review"
      echo "--- end $REVIEWER review ---"
    } >> "$LOG"

    local n_blocking
    n_blocking=$(printf '%s\n' "$review" | count_blocking)
    if ! [[ "$n_blocking" =~ ^[0-9]+$ ]]; then
      echo "  [build] FATAL: count_blocking produced non-integer ('$n_blocking')" | tee -a "$LOG" >&2
      fail_build_cycle "$pr_num" "count_blocking produced non-integer output (parse error in cycle $cycle)"
      return 0
    fi
    local n_recommended
    n_recommended=$(printf '%s\n' "$review" | awk '
      /^## RECOMMENDED[[:space:]]*$/ { s = 1; next }
      /^## / { s = 0; next }
      s && /^-[[:space:]]/ { line = $0; sub(/^-[[:space:]]+/, "", line); if (line != "(none)") n++ }
      END { print n + 0 }')
    echo "[build] PR #$pr_num → cycle $cycle: $n_blocking BLOCKING, $n_recommended RECOMMENDED"

    if [ "$n_blocking" -eq 0 ]; then
      echo "  [build] zero blocking findings; PR #$pr_num converged after $cycle cycle(s)" | tee -a "$LOG" >&2

      # The codex-review status is posted against the branch tip, so the remote
      # must match the reviewed tree before the status goes green.
      if ! git -C "$BUILD_DIR" push origin "HEAD:refs/heads/$BUILD_BRANCH" >> "$LOG" 2>&1; then
        fail_build_cycle "$pr_num" "converged but the final push to origin/$BUILD_BRANCH failed"
        return 0
      fi

      local head_sha status_ok=0
      head_sha=$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || echo "")
      if [ -n "$head_sha" ]; then
        # Mirrors run_review_cycle's status write, minus the merge call: branch
        # protection requires this check even for a human clicking Merge.
        if gh api -X POST "repos/${REPO}/statuses/${head_sha}" \
            -f state=success \
            -f context=codex-review \
            -f description="$REVIEWER review passed (cycle ${cycle} of ${MAX_REVIEW_CYCLES})" \
            -f target_url="https://github.com/${REPO}/pull/${pr_num}" \
            >> "$LOG" 2>&1; then
          status_ok=1
          echo "  [build] codex-review status set to success for ${head_sha:0:8}" | tee -a "$LOG" >&2
        else
          echo "  [build] WARNING: failed to set codex-review status for PR #$pr_num" | tee -a "$LOG" >&2
        fi
      fi

      if ! gh pr edit "$pr_num" --repo "$REPO" --add-label build-ready-for-merge >> "$LOG" 2>&1; then
        echo "ERROR: could not label PR #$pr_num build-ready-for-merge; add it manually" | tee -a "$LOG" >&2
        exit 1
      fi

      local summary_file="$TMP_ROOT/summary-$pr_num.md"
      {
        printf '**babysit-builder: build cycle converged — ready for human merge**\n\n'
        printf 'The %s reviewer reported 0 BLOCKING findings after %s cycle(s) of %s.\n\n' \
          "$REVIEWER" "$cycle" "$MAX_REVIEW_CYCLES"
        if [ "$status_ok" -eq 1 ]; then
          printf 'A `codex-review=success` status was posted for `%s` so branch protection permits the merge.\n' "${head_sha:0:8}"
        else
          printf 'WARNING: the `codex-review` status could not be posted. On a protected branch the merge stays blocked until an operator posts it or overrides protection.\n'
        fi
        printf '\nThis pipeline never merges. A human performs the merge.\n\n'
        printf 'Final review:\n\n```\n%s\n```\n' "$review"
      } > "$summary_file"
      gh pr comment "$pr_num" --repo "$REPO" --body-file "$summary_file" >> "$LOG" 2>&1 \
        || echo "  [build] WARNING: summary comment failed for PR #$pr_num" | tee -a "$LOG" >&2

      echo "[build] PR #$pr_num → cycle $cycle: 0 BLOCKING → converged, labelled build-ready-for-merge, halted for human merge"
      return 0
    fi

    # ---- implementer remediation pass ----
    local pr_feedback
    pr_feedback=$(collect_pr_feedback "$pr_num" 2>> "$LOG")
    [ -z "$pr_feedback" ] && pr_feedback="(none)"

    local _rem_tmpl _rem_model
    if [ "$cycle" -eq 1 ]; then
      _rem_tmpl="$REMEDIATION_PROMPT_CYCLE1"; _rem_model="claude-sonnet-5"
    elif [ "$cycle" -le 3 ]; then
      _rem_tmpl="$REMEDIATION_PROMPT_CYCLE2_3"; _rem_model="claude-sonnet-5"
    elif [ "$cycle" -eq 4 ]; then
      _rem_tmpl="$REMEDIATION_PROMPT_CYCLE4"; _rem_model="claude-opus-4-8"
    else
      _rem_tmpl="$REMEDIATION_PROMPT_CYCLE5_6"; _rem_model="claude-opus-4-8"
    fi
    local rem_prompt
    rem_prompt="${_rem_tmpl//__PR_NUMBER__/$pr_num}"
    rem_prompt="${rem_prompt//__CYCLE__/$cycle}"
    rem_prompt="${rem_prompt//__MAX_CYCLES__/$MAX_REVIEW_CYCLES}"
    rem_prompt="${rem_prompt//__REVIEW__/$review}"
    rem_prompt="${rem_prompt//__PR_FEEDBACK__/$pr_feedback}"
    unset _rem_tmpl

    local pre_sha post_sha
    pre_sha=$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || echo "")

    echo "  [$IMPLEMENTER implementer] addressing findings for PR #$pr_num (cycle $cycle)..." >&2
    if ! run_implementer "$rem_prompt" "$TMP_REVIEW_RESULT" "$BUILD_DIR" "$_rem_model"; then
      fail_build_cycle "$pr_num" "$IMPLEMENTER exited non-zero while addressing review (cycle $cycle)"
      return 0
    fi

    local result trimmed last_line
    result=$(cat "$TMP_REVIEW_RESULT")
    trimmed=$(printf '%s' "$result" | sed -e 's/[[:space:]]*$//')
    last_line=$(printf '%s' "$trimmed" | tail -n 1)

    case "$last_line" in
      "STUCK_REVIEW"*)
        echo "  [$IMPLEMENTER implementer] $last_line — bailing build cycle" | tee -a "$LOG" >&2
        fail_build_cycle "$pr_num" "$IMPLEMENTER reported STUCK_REVIEW (cycle $cycle)"
        return 0
        ;;
    esac

    post_sha=$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$pre_sha" ] && [ "$pre_sha" = "$post_sha" ]; then
      fail_build_cycle "$pr_num" "$IMPLEMENTER made no commits while addressing review (cycle $cycle)"
      return 0
    fi

    # Keep the PR in sync with the reviewed worktree even if the implementer
    # forgot to push; the reviewer reads the worktree, humans read the PR.
    git -C "$BUILD_DIR" push origin "HEAD:refs/heads/$BUILD_BRANCH" >> "$LOG" 2>&1 \
      || echo "  [build] WARNING: push to origin/$BUILD_BRANCH failed after cycle $cycle" | tee -a "$LOG" >&2

    if [ "$cycle" -ge 4 ]; then
      justifications=$(gh pr view "$pr_num" --repo "$REPO" --json comments -q '.comments[-1].body' 2>/dev/null || echo "")
    fi
  done

  # Cycle cap reached with BLOCKING findings still open. No codex-review status
  # is posted — the PR is intentionally left unmergeable on protected branches.
  git -C "$BUILD_DIR" push origin "HEAD:refs/heads/$BUILD_BRANCH" >> "$LOG" 2>&1 || true
  if ! gh pr edit "$pr_num" --repo "$REPO" --add-label build-max-cycles >> "$LOG" 2>&1; then
    echo "ERROR: could not label PR #$pr_num build-max-cycles; add it manually" | tee -a "$LOG" >&2
    exit 1
  fi
  local summary_file="$TMP_ROOT/summary-$pr_num.md" final_review="(no review captured)"
  [ "${#REVIEW_HISTORY[@]}" -gt 0 ] && final_review="${REVIEW_HISTORY[${#REVIEW_HISTORY[@]}-1]}"
  {
    printf '**babysit-builder: max review cycles reached — human review required**\n\n'
    printf 'The %s reviewer still reported BLOCKING findings after %s cycles. No `codex-review` status was posted, so on a protected branch this PR is intentionally unmergeable until a human resolves the findings or overrides protection.\n\n' \
      "$REVIEWER" "$MAX_REVIEW_CYCLES"
    printf 'Final review:\n\n```\n%s\n```\n' "$final_review"
  } > "$summary_file"
  gh pr comment "$pr_num" --repo "$REPO" --body-file "$summary_file" >> "$LOG" 2>&1 \
    || echo "  [build] WARNING: summary comment failed for PR #$pr_num" | tee -a "$LOG" >&2
  echo "[build] PR #$pr_num → max cycles exhausted, labelled build-max-cycles, halted for human merge"
  return 0
}

# ---------- queue ----------

fetch_github_queue() {
  local output_file="$1" raw_file="$TMP_ROOT/gh-queue.json"
  if ! gh issue list --repo "$REPO" --state open --label build-ready --limit 1000 \
    --json number,title,body,url,labels > "$raw_file"; then
    echo "ERROR: could not list build-ready tickets for $REPO" >&2
    return 1
  fi
  python3 - "$raw_file" > "$output_file" <<'PY'
import base64, json, sys
def b64(value): return base64.b64encode(str(value or "").encode()).decode()
with open(sys.argv[1], encoding="utf-8") as fh:
    issues = json.load(fh)
for issue in issues:
    labels = {((x.get("name") if isinstance(x, dict) else x) or "").lower() for x in issue.get("labels") or []}
    # A terminal label alongside build-ready means a previous swap half-failed.
    if "build-done" in labels or "build-needs-clarification" in labels:
        continue
    print("\t".join(["github", str(issue.get("number")), b64(issue.get("title")),
                     b64(issue.get("body")), b64(issue.get("url"))]))
PY
}

fetch_jira_queue() {
  local output_file="$1" raw_file="$TMP_ROOT/jira-queue.json"
  local jira_url="${JIRA_BASE_URL%/}/rest/api/3/search"
  : > "$output_file"
  if ! curl -fsS -G "$jira_url" \
    -H "Authorization: Bearer $JIRA_TOKEN" -H "Accept: application/json" \
    --data-urlencode "jql=project=$JIRA_PROJECT AND labels=build-ready" \
    --data-urlencode "fields=summary,description,labels" \
    --data-urlencode "maxResults=$MAX_TICKETS" > "$raw_file"; then
    echo "[jira] Jira API unavailable → skipping Jira-sourced tickets this run" >&2
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
        return "\n".join(filter(None, [own, text(value.get("content") or [])]))
    return ""
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
issues = data if isinstance(data, list) else data.get("issues", [])
base = os.environ.get("JIRA_BASE_URL", "").rstrip("/")
for issue in issues:
    fields = issue.get("fields") or issue
    key = issue.get("key") or issue.get("id") or ""
    if not key: continue
    labels = {str(x).lower() for x in (fields.get("labels") or [])}
    if "build-done" in labels or "build-needs-clarification" in labels:
        continue
    print("\t".join(["jira", str(key), b64(fields.get("summary")),
                     b64(text(fields.get("description"))), b64(f"{base}/browse/{key}")]))
PY
  then
    echo "[jira] Jira returned an invalid response → skipping Jira-sourced tickets this run" >&2
    : > "$output_file"
  fi
}

# Extract the spec reference from a ticket body. Prints the path, or nothing.
extract_spec_path() {
  printf '%s' "$1" | python3 -c '
import re, sys
body = sys.stdin.read()
patterns = [
    r"^[ \t]*[-*]?[ \t]*Spec path:[ \t]*`([^`\n]+)`",
    r"^[ \t]*[-*]?[ \t]*Spec path:[ \t]*(\S+)",
    r"^[ \t]*[-*]?[ \t]*Spec:[ \t]*`([^`\n]+)`",
    r"^[ \t]*[-*]?[ \t]*Spec:[ \t]*(\S+)",
]
for pattern in patterns:
    match = re.search(pattern, body, re.I | re.M)
    if match:
        sys.stdout.write(match.group(1).strip())
        break
'
}

safe_repo_relative_path() {
  case "${1:-}" in
    ''|/*|..|../*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}

# The ref every build worktree is cut from. Prefer the fetched remote tip; fall
# back to the local branch when origin/ is absent (fresh clone, or --dry-run,
# which never fetches).
build_base_ref() {
  if git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
    printf '%s' "origin/$DEFAULT_BRANCH"
  else
    printf '%s' "$DEFAULT_BRANCH"
  fi
}

# Does <path> exist in the tree the build will actually start from? The operator's
# working checkout is NOT the right thing to test — it can sit on any branch, and
# a false negative here strands the ticket in build-needs-clarification.
spec_exists_on_base() {
  git cat-file -e "$(build_base_ref):${1}" 2>/dev/null
}

# ---------- ticket handling ----------

# Kick a ticket back for spec clarification. Never opens or touches a PR.
# Args: <source> <ticket> <ticket_url> <reason> <orphan_pr_or_empty>
kickback_ticket() {
  local source="$1" ticket="$2" ticket_url="$3" reason="$4" orphan_pr="${5:-}"
  local comment_file="$TMP_ROOT/kickback-$(slugify "$source-$ticket").md"
  {
    printf 'babysit-builder: spec gap — kicked back for clarification\n\n'
    printf 'The builder did not implement this ticket. Reason:\n\n%s\n\n' "$reason"
    printf 'The `build-ready` label has been removed and `build-needs-clarification` added, so the builder will not pick this ticket up again. Update or clarify the specification, then re-add `build-ready`.\n'
    if [ -n "$orphan_pr" ]; then
      printf '\nNote: PR #%s was opened before the gap was reported. It is an orphan — review and close it.\n' "$orphan_pr"
    fi
  } > "$comment_file"

  ticket_comment "$source" "$ticket" "$comment_file" \
    || echo "[build] WARNING: could not comment on ticket $ticket ($source)" >&2
  if ! ticket_swap_to_terminal "$source" "$ticket" build-needs-clarification; then
    echo "[build] ERROR: could not swap labels on ticket $ticket ($source); it may be re-selected next run" >&2
    return 1
  fi
  echo "[build] ticket $ticket ($source) → SPEC_GAP: $reason, labelled build-needs-clarification, build-ready removed, comment posted"
}

# Mark a ticket as no longer queued once its PR reached a terminal state.
mark_ticket_done() {
  local source="$1" ticket="$2" pr_num="$3" outcome="$4"
  local comment_file="$TMP_ROOT/done-$(slugify "$source-$ticket").md"
  {
    printf 'babysit-builder: build complete — %s\n\n' "$outcome"
    printf 'PR #%s carries the implementation. This pipeline never merges; a human performs the merge.\n\n' "$pr_num"
    printf 'The `build-ready` label has been removed and `build-done` added, so this ticket will not be rebuilt. Re-add `build-ready` to build it again.\n'
  } > "$comment_file"
  ticket_comment "$source" "$ticket" "$comment_file" \
    || echo "[build] WARNING: could not comment on ticket $ticket ($source)" >&2
  ticket_swap_to_terminal "$source" "$ticket" build-done \
    || echo "[build] ERROR: could not swap labels on ticket $ticket ($source); it may be rebuilt next run" >&2
}

# Create a fresh worktree on a new branch off the default branch tip.
# Sets BUILD_DIR and BUILD_BRANCH. Returns non-zero on failure.
create_build_worktree() {
  local slug="$1" base_ref base_sha
  BUILD_BRANCH="build/${slug}-$$"
  BUILD_DIR="$TMP_ROOT/wt-${slug}"
  base_ref=$(build_base_ref)
  base_sha=$(git rev-parse "$base_ref" 2>/dev/null || true)
  [ -n "$base_sha" ] || { echo "[build] default branch '$DEFAULT_BRANCH' is unavailable locally" >&2; return 1; }
  if ! git worktree add -b "$BUILD_BRANCH" "$BUILD_DIR" "$base_sha" >> "$LOG" 2>&1; then
    echo "[build] worktree creation failed for branch $BUILD_BRANCH" >&2
    return 1
  fi
  printf '%s\n' "$BUILD_DIR" >> "$WORKTREE_LIST"
}

discard_build_worktree() {
  [ -n "${BUILD_DIR:-}" ] || return 0
  git worktree remove --force "$BUILD_DIR" >> "$LOG" 2>&1 || true
  rm -rf "$BUILD_DIR"
  if [ -n "${BUILD_BRANCH:-}" ]; then
    git branch -D "$BUILD_BRANCH" >> "$LOG" 2>&1 || true
  fi
  BUILD_DIR=""
  BUILD_BRANCH=""
}

BUILD_DIR=""
BUILD_BRANCH=""
HALT_RC=0

# Build one queued ticket end to end. Sets HALT_RC non-zero when the reviewer
# backend forced the run to stop.
build_ticket() {
  local source="$1" ticket="$2" title="$3" body="$4" ticket_url="$5"
  local slug spec_path prompt_file spec_note
  local last_line pr_num cycle_rc

  slug=$(slugify "$source-$ticket")
  [ -n "$slug" ] || slug="ticket"

  spec_path=$(extract_spec_path "$body")
  if [ -n "$spec_path" ]; then
    if ! safe_repo_relative_path "$spec_path"; then
      kickback_ticket "$source" "$ticket" "$ticket_url" \
        "the referenced spec path '$spec_path' is not a safe repo-relative path"
      return 0
    fi
    if ! spec_exists_on_base "$spec_path"; then
      kickback_ticket "$source" "$ticket" "$ticket_url" \
        "the referenced spec '$spec_path' does not exist in $REPO at $(build_base_ref)"
      return 0
    fi
    spec_note="Specification: ./$spec_path (read it in full before doing anything else)"
    echo "[build] ticket $ticket ($source, spec: $spec_path) → worktree created, implementing"
  else
    spec_note="Specification: none referenced by the ticket. Treat the ticket description below as the specification; if it is not implementation-ready, report SPEC_GAP."
    echo "[build] ticket $ticket ($source, spec: none referenced) → worktree created, implementing"
  fi

  if ! create_build_worktree "$slug"; then
    echo "[build] ticket $ticket ($source): worktree creation failed → left in queue" >&2
    return 0
  fi

  prompt_file="$TMP_ROOT/prompt-${slug}.txt"
  cat > "$prompt_file" <<EOF
You are the implementation engineer in babysit-builder. Implement the approved specification for the ticket below, in this dedicated git worktree, and open a pull request for human review.

Repository: $REPO
Base branch: $DEFAULT_BRANCH
Branch: $BUILD_BRANCH (already checked out — do NOT rename it; the wrapper owns the branch name)
Ticket source: $source
Ticket ID: $ticket
Ticket URL: $ticket_url
Ticket title: $title
$spec_note

Ticket description:
---
$body
---

Helper scripts available for targeted queries:
  $SCRIPTS_DIR/prs      — enhanced \`gh pr list\` with CI rollup and review state
  $SCRIPTS_DIR/issues   — enhanced \`gh issue list\` sorted by priority labels
  $SCRIPTS_DIR/specs    — list specs with status and components

STEP 0 — spec gap check. Do this FIRST, before writing any code.
Read ./CLAUDE.md, the specification named above, and the code it touches. Decide whether the spec is complete enough to implement:
  - acceptance criteria or an equivalent definition of done are present
  - requirements are internally consistent (no contradictions)
  - every referenced file, dependency, interface, or upstream contract actually exists
If the spec has a gap, make NO code changes and end your final message with:
  SPEC_GAP <one-line description of exactly what is missing or contradictory>
Do not guess at missing requirements and do not implement a partial interpretation. A kicked-back ticket is a normal, useful outcome — it is not a failure.

STEP 1 — implement. Follow every convention in CLAUDE.md. Write the code, the tests, and the docs the spec calls for. Stay within the spec's scope; do not refactor adjacent code that the spec does not require you to touch.

STEP 2 — test. Run the relevant test suite. If it fails, fix the underlying issue.

STEP 3 — commit. Use conventional-commit messages that explain why the change was made.

STEP 4 — push and open the PR:
  git push -u origin HEAD:refs/heads/$BUILD_BRANCH
  gh pr create --repo $REPO --head $BUILD_BRANCH --base $DEFAULT_BRANCH --title "<concise title>" --body-file <file>
The PR body MUST begin with this exact line:
  <!-- babysit-builder source=$source ticket=$ticket -->
followed by a summary of the change and a reference to $ticket_url.

**Merge policy (non-negotiable):**
- NEVER run \`gh pr merge\`. This pipeline has no automated merge path at all. The wrapper runs a review cycle on your PR and then halts so a human can merge it.
- Do not edit issues, labels, or commit statuses. The wrapper owns every ticket and PR lifecycle change.
- Do not rename the branch, and do not touch other branches or other PRs.

End your final message with EXACTLY ONE of these sentinels as the LAST line, bare (no quotes, code fences, or trailing punctuation):
- HANDOFF_REVIEW <PR_NUMBER>   — you opened the PR; PR_NUMBER is a bare integer.
- SPEC_GAP <one-line reason>   — the spec is not implementable as written.
- STUCK <one-line reason>      — a transient or environmental obstacle stopped you.
EOF

  if ! run_implementer "$(cat "$prompt_file")" "$TMP_RESULT" "$BUILD_DIR" "claude-sonnet-5"; then
    echo "[build] ticket $ticket ($source): implementer exited non-zero → left in queue" >&2
    safety_push_worktree
    discard_build_worktree
    return 0
  fi

  last_line=$(sed -e 's/[[:space:]]*$//' "$TMP_RESULT" | grep -v '^$' | tail -n 1)

  case "$last_line" in
    "HANDOFF_REVIEW "*)
      pr_num="${last_line#HANDOFF_REVIEW }"
      pr_num="${pr_num%% *}"
      pr_num="${pr_num#\#}"
      if ! [[ "$pr_num" =~ ^[0-9]+$ ]]; then
        echo "[build] ticket $ticket ($source): HANDOFF_REVIEW with non-numeric PR '$pr_num' → left in queue" >&2
        safety_push_worktree
        discard_build_worktree
        return 0
      fi
      echo "[build] ticket $ticket ($source) → PR #$pr_num opened, HANDOFF_REVIEW → entering build cycle"

      # The build cycle pushes to BUILD_BRANCH and posts the codex-review status
      # against the worktree's HEAD, so the worktree branch and the PR head must
      # be the same ref. Adopt whatever the worktree is actually on, then verify.
      local wt_branch pr_head
      wt_branch=$(git -C "$BUILD_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      [ -n "$wt_branch" ] && [ "$wt_branch" != "HEAD" ] && BUILD_BRANCH="$wt_branch"
      pr_head=$(gh pr view "$pr_num" --repo "$REPO" --json headRefName -q .headRefName 2>/dev/null || echo "")
      if [ -z "$pr_head" ] || [ "$pr_head" != "$BUILD_BRANCH" ]; then
        fail_build_cycle "$pr_num" "PR head '$pr_head' does not match the build worktree branch '$BUILD_BRANCH'; the implementer renamed or re-targeted the branch"
        mark_ticket_done "$source" "$ticket" "$pr_num" "PR quarantined — branch mismatch"
        discard_build_worktree
        return 0
      fi

      ensure_pr_marker "$pr_num" "$source" "$ticket"
      cycle_rc=0
      run_build_cycle "$pr_num" || cycle_rc=$?
      if [ "$cycle_rc" -eq 0 ]; then
        mark_ticket_done "$source" "$ticket" "$pr_num" "PR halted for human merge"
      else
        HALT_RC="$cycle_rc"
      fi
      discard_build_worktree
      return 0
      ;;
    "SPEC_GAP "*|"SPEC_GAP")
      local reason orphan
      reason="${last_line#SPEC_GAP}"
      reason="${reason# }"
      [ -n "$reason" ] || reason="the implementer reported a spec gap without a reason"
      # The sentinel is authoritative even if a PR was opened first.
      orphan=$(gh pr list --repo "$REPO" --state open --head "$BUILD_BRANCH" \
        --json number -q '.[0].number' 2>/dev/null || echo "")
      kickback_ticket "$source" "$ticket" "$ticket_url" "$reason" "$orphan"
      discard_build_worktree
      return 0
      ;;
    "STUCK "*|"STUCK")
      echo "[build] ticket $ticket ($source): STUCK: ${last_line#STUCK } → left in queue" >&2
      safety_push_worktree
      discard_build_worktree
      return 0
      ;;
    *)
      echo "[build] ticket $ticket ($source): no sentinel on last line → left in queue" >&2
      safety_push_worktree
      discard_build_worktree
      return 0
      ;;
  esac
}

# Push any commits the implementer made but never pushed, so work is not lost
# when the worktree is discarded.
safety_push_worktree() {
  [ -n "${BUILD_DIR:-}" ] && [ -n "${BUILD_BRANCH:-}" ] || return 0
  local ahead
  ahead=$(git -C "$BUILD_DIR" rev-list "origin/${DEFAULT_BRANCH}..HEAD" --count 2>/dev/null || echo 0)
  [ "${ahead:-0}" -gt 0 ] || return 0
  echo "[build] safety-push: ${ahead} unpushed commit(s) on $BUILD_BRANCH" >&2
  git -C "$BUILD_DIR" push -u origin "HEAD:refs/heads/$BUILD_BRANCH" >> "$LOG" 2>&1 \
    || echo "[build] WARNING: safety-push failed for $BUILD_BRANCH" >&2
}

# ---------- outage sweep ----------

# Re-run the build cycle for PRs a previous run quarantined as build-mcp-outage.
# Runs BEFORE the queue is read: those tickets are still build-ready, and reading
# the queue first would rebuild them into duplicate PRs.
resume_outage_prs() {
  local raw_file="$TMP_ROOT/outage-prs.json" records="$TMP_ROOT/outage-records"
  if ! gh pr list --repo "$REPO" --state open --label build-mcp-outage --limit 20 \
    --json number,headRefName,body > "$raw_file" 2>> "$LOG"; then
    echo "[build] WARNING: could not list build-mcp-outage PRs" >&2
    return 0
  fi
  python3 - "$raw_file" > "$records" <<'PY'
import json, re, sys
marker = re.compile(r"<!-- babysit-builder\s+source=(\S+)\s+ticket=(\S+)\s+-->", re.I)
with open(sys.argv[1], encoding="utf-8") as fh:
    prs = json.load(fh)
for pr in prs:
    match = marker.search(pr.get("body") or "")
    source, ticket = (match.group(1), match.group(2)) if match else ("", "")
    print("\t".join([str(pr.get("number") or ""), pr.get("headRefName") or "", source, ticket]))
PY

  local pr_num head_ref source ticket cycle_rc
  # fd 3: the harnesses inherit stdin, and would otherwise consume this file.
  while IFS=$'\t' read -r -u 3 pr_num head_ref source ticket; do
    [ -n "$pr_num" ] && [ -n "$head_ref" ] || continue
    echo "[build] resuming build cycle for PR #$pr_num (build-mcp-outage)"
    if ! git fetch origin "$head_ref" >> "$LOG" 2>&1; then
      echo "[build] WARNING: could not fetch origin/$head_ref for PR #$pr_num; skipped" >&2
      continue
    fi
    BUILD_BRANCH="$head_ref"
    BUILD_DIR="$TMP_ROOT/wt-resume-$pr_num"
    if ! git worktree add -f -B "$head_ref" "$BUILD_DIR" FETCH_HEAD >> "$LOG" 2>&1; then
      echo "[build] WARNING: could not create worktree for PR #$pr_num; skipped" >&2
      BUILD_DIR=""; BUILD_BRANCH=""
      continue
    fi
    printf '%s\n' "$BUILD_DIR" >> "$WORKTREE_LIST"

    gh pr edit "$pr_num" --repo "$REPO" --remove-label build-mcp-outage >> "$LOG" 2>&1 || true
    gh pr ready "$pr_num" --repo "$REPO" >> "$LOG" 2>&1 || true

    cycle_rc=0
    run_build_cycle "$pr_num" || cycle_rc=$?
    if [ "$cycle_rc" -eq 0 ]; then
      if [ -n "$source" ] && [ -n "$ticket" ]; then
        mark_ticket_done "$source" "$ticket" "$pr_num" "PR halted for human merge"
      else
        echo "[build] WARNING: PR #$pr_num carries no builder marker; its ticket keeps build-ready and may be rebuilt" >&2
      fi
    else
      HALT_RC="$cycle_rc"
    fi
    discard_build_worktree
    [ "$HALT_RC" -eq 0 ] || return 0
  done 3< "$records"
}

# ---------- main ----------

if [ "$DRY_RUN" -eq 0 ]; then
  {
    echo "=== babysit-builder.sh v${VERSION} @ $(date -u +%FT%TZ) ==="
    echo "project:           $PROJECT"
    echo "repo:              $REPO"
    echo "default_branch:    $DEFAULT_BRANCH"
    echo "source:            $SOURCE"
    echo "implementer:       $IMPLEMENTER (model=${IMPLEMENTER_MODEL:-stage-default} effort=${IMPLEMENTER_EFFORT:-default})"
    echo "reviewer:          $REVIEWER (model=${REVIEWER_MODEL:-configured-default} effort=${REVIEWER_EFFORT:-configured-default})"
    echo "max_tickets:       $MAX_TICKETS"
    echo "max_review_cycles: $MAX_REVIEW_CYCLES"
  } >> "$LOG"

  git fetch origin "$DEFAULT_BRANCH" >> "$LOG" 2>&1 \
    || { echo "ERROR: could not fetch origin/$DEFAULT_BRANCH" >&2; exit 1; }
  git worktree prune >> "$LOG" 2>&1 || true

  ensure_build_labels || { echo "ERROR: could not ensure build-* labels on $REPO" >&2; exit 1; }

  _probe_rc=0
  reviewer_preflight || _probe_rc=$?
  case "$_probe_rc" in
    0) ;;
    3) echo "ERROR: Codex CLI is too old for the configured model; run 'codex update' before starting the builder" >&2; exit 1 ;;
    4) echo "ERROR: Codex workspace is out of credits; add credits before starting the builder" >&2; exit 1 ;;
    *) echo "ERROR: $REVIEWER pre-flight probe failed (rc=$_probe_rc)" >&2; exit 1 ;;
  esac
  unset _probe_rc

  resume_outage_prs
  if [ "$HALT_RC" -ne 0 ]; then
    case "$HALT_RC" in
      2) echo "Halting: reviewer MCP outage persists; the PR is labelled build-mcp-outage and will be retried next run. See $LOG" >&2 ;;
      3) echo "Halting: Codex version incompatibility; upgrade the CLI, remove build-codex-outdated, then re-run. See $LOG" >&2 ;;
      4) echo "Halting: Codex workspace out of credits; add credits, remove build-codex-no-credits, then re-run. See $LOG" >&2 ;;
    esac
    echo "Builder halted during outage sweep."
    exit 0
  fi
fi

GITHUB_QUEUE="$TMP_ROOT/github-queue"
JIRA_QUEUE="$TMP_ROOT/jira-queue"
ALL_TICKETS="$TMP_ROOT/all-tickets"
: > "$ALL_TICKETS"

if [ "$SOURCE" = "github" ] || [ "$SOURCE" = "both" ]; then
  fetch_github_queue "$GITHUB_QUEUE" || exit 1
  cat "$GITHUB_QUEUE" >> "$ALL_TICKETS"
fi
if [ "$SOURCE" = "jira" ] || [ "$SOURCE" = "both" ]; then
  fetch_jira_queue "$JIRA_QUEUE"
  cat "$JIRA_QUEUE" >> "$ALL_TICKETS"
fi

builds_started=0
# fd 3: the implementer/reviewer harnesses inherit stdin, and reading the queue on
# fd 0 would let the first harness invocation swallow the remaining tickets.
while IFS=$'\t' read -r -u 3 ticket_source ticket_key title_b64 body_b64 url_b64; do
  [ -n "$ticket_key" ] || continue
  [ "$builds_started" -lt "$MAX_TICKETS" ] || break
  title=$(printf '%s' "$title_b64" | b64decode)
  body=$(printf '%s' "$body_b64" | b64decode)
  ticket_url=$(printf '%s' "$url_b64" | b64decode)
  builds_started=$((builds_started + 1))

  if [ "$DRY_RUN" -eq 1 ]; then
    spec_path=$(extract_spec_path "$body")
    echo "[build] ticket $ticket_key ($ticket_source, spec: ${spec_path:-none referenced}) → [dry-run] would build and open a PR"
    continue
  fi

  build_ticket "$ticket_source" "$ticket_key" "$title" "$body" "$ticket_url"
  if [ "$HALT_RC" -ne 0 ]; then
    case "$HALT_RC" in
      2) echo "Halting: reviewer MCP outage; the PR is labelled build-mcp-outage and will be retried next run. See $LOG" >&2 ;;
      3) echo "Halting: Codex version incompatibility; upgrade the CLI, remove build-codex-outdated, then re-run. See $LOG" >&2 ;;
      4) echo "Halting: Codex workspace out of credits; add credits, remove build-codex-no-credits, then re-run. See $LOG" >&2 ;;
    esac
    break
  fi
done 3< "$ALL_TICKETS"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run complete: $builds_started ticket(s) in the build queue."
else
  echo "Builder complete: $builds_started ticket(s) considered. See $LOG"
fi
exit 0
