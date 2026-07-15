#!/bin/bash
# babysit-with-review.sh — autonomous implementation + independent PR-review handoff.
#
# Same outer loop as babysit.sh. When the implementer ends an iteration with the
# sentinel `HANDOFF_REVIEW <PR_NUMBER>` on its own line, this wrapper runs
# up to MAX_REVIEW_CYCLES (default 6) of:
#   1. selected reviewer — produces a strict-markdown review with three sections:
#      ## BLOCKING / ## RECOMMENDED / ## INFORMATION
#   2. selected implementer — addresses BLOCKING (must), RECOMMENDED (should),
#      and considers INFORMATION findings; commits and pushes.
# The cycle exits early when the reviewer reports zero BLOCKING findings, when
# the implementer reports STUCK_REVIEW, or when HEAD doesn't advance during an
# implementation pass (defensive against "DONE_REVIEW but no commits made").
#
# Env vars:
#   MAX_ITER           default 50   hard cap on outer iterations
#   SLEEP_SEC          default 10   pause between outer iterations (seconds)
#   STUCK_N            default 3    consecutive identical results = stuck
#   MAX_REVIEW_CYCLES  default 6    max reviewer/implementer cycles per PR
#
# MCP-outage resilience: when Codex is selected as reviewer and cannot reach
# its backend, the wrapper
# retries up to 3 times (0 / 60s / 300s back-off), labels the PR
# `review-mcp-outage`, and halts. On the next babysitter run the pre-iter
# scan retries the labelled PR automatically before running the implementer.
# `review-incomplete` = human action required; `review-mcp-outage` = auto-retry.
# `review-codex-outdated` = Codex CLI too old for model; upgrade CLI then remove label.
# `review-codex-no-credits` = Codex workspace out of credits; add credits then remove label.

set -uo pipefail

VERSION="1.1.0"

usage() {
  cat <<'EOF'
Usage: babysit-with-review.sh [-h|--help] [--version] [OPTIONS]

Run from inside a project root. Outer loop is identical to babysit.sh.
When the implementer ends an iteration with `HANDOFF_REVIEW <PR_NUMBER>` on its
own line, runs an implementer/reviewer cycle on that PR (up to
MAX_REVIEW_CYCLES) before resuming the outer loop.

Options:
  --repo-base PATH   Base dir holding the cloned repos; helper scripts
                     (prs, issues, specs) are looked up under PATH/scripts.
                     Overrides the REPO_BASE env var. Default: auto-detect
                     ~/repos then ~/repo.
  --implementer claude|codex
                     Implementation harness. Default: claude.
  --implementer-model MODEL
                     Model for all implementation passes. When omitted, the
                     Claude implementer keeps its stage/cycle defaults.
  --implementer-effort LEVEL
                     Effort for all implementation passes.
  --reviewer claude|codex
                     Review harness. Default: codex.
  --reviewer-model MODEL
                     Model for every review pass and Codex preflight.
  --reviewer-effort LEVEL
                     Effort for every review pass and Codex preflight.

All long options accepting values support both `--name VALUE` and
`--name=VALUE` forms. Model and effort values are passed to the selected CLI.

Env vars:
  REPO_BASE          base dir for helper scripts (see --repo-base)
  MAX_ITER           default 50
  SLEEP_SEC          default 10  (seconds)
  STUCK_N            default 3
  MAX_REVIEW_CYCLES  default 6

PR labels used by the review cycle:
  review-incomplete      Human intervention required; wrapper will NOT retry.
  review-mcp-outage      Codex MCP backend was unreachable; wrapper retries
                         automatically at the top of each outer iteration.
  review-codex-outdated  Codex CLI is too old for the configured model; run
                         \`codex update\`, remove this label, then restart.
  review-codex-no-credits  Codex workspace has no credits; add credits, remove
                           this label, then restart.

Logs land in ~/sisyphus-logs/<project>-<timestamp>-<pid>.log.

Examples:
  babysit-with-review.sh
  babysit-with-review.sh --implementer codex --implementer-effort high
  babysit-with-review.sh --reviewer=claude --reviewer-model=claude-opus-4-8
  babysit-with-review.sh --implementer claude --reviewer claude
  MAX_REVIEW_CYCLES=3 babysit-with-review.sh
EOF
}

REPO_BASE_OVERRIDE=""
IMPLEMENTER="claude"
IMPLEMENTER_MODEL=""
IMPLEMENTER_EFFORT=""
REVIEWER="codex"
REVIEWER_MODEL=""
REVIEWER_EFFORT=""

missing_option_value() {
  echo "Missing value for $1" >&2
  usage >&2
  exit 2
}

is_cli_option_token() {
  case "$1" in
    -h|--help|--version|--repo-base|--repo-base=*|\
    --implementer|--implementer=*|--implementer-model|--implementer-model=*|--implementer-effort|--implementer-effort=*|\
    --reviewer|--reviewer=*|--reviewer-model|--reviewer-model=*|--reviewer-effort|--reviewer-effort=*) return 0 ;;
    *) return 1 ;;
  esac
}

require_option_value() {
  local option="$1"
  local value="${2:-}"
  if [ -z "$value" ] || is_cli_option_token "$value"; then
    missing_option_value "$option"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) echo "babysit-with-review.sh $VERSION"; exit 0 ;;
    --repo-base)
      require_option_value "$1" "${2:-}"
      REPO_BASE_OVERRIDE="$2"; shift 2 ;;
    --repo-base=*)
      REPO_BASE_OVERRIDE="${1#*=}"; [ -n "$REPO_BASE_OVERRIDE" ] || missing_option_value "--repo-base"
      shift ;;
    --implementer)
      require_option_value "$1" "${2:-}"
      IMPLEMENTER="$2"; shift 2 ;;
    --implementer=*)
      IMPLEMENTER="${1#*=}"; [ -n "$IMPLEMENTER" ] || missing_option_value "--implementer"
      shift ;;
    --implementer-model)
      require_option_value "$1" "${2:-}"
      IMPLEMENTER_MODEL="$2"; shift 2 ;;
    --implementer-model=*)
      IMPLEMENTER_MODEL="${1#*=}"; [ -n "$IMPLEMENTER_MODEL" ] || missing_option_value "--implementer-model"
      shift ;;
    --implementer-effort)
      require_option_value "$1" "${2:-}"
      IMPLEMENTER_EFFORT="$2"; shift 2 ;;
    --implementer-effort=*)
      IMPLEMENTER_EFFORT="${1#*=}"; [ -n "$IMPLEMENTER_EFFORT" ] || missing_option_value "--implementer-effort"
      shift ;;
    --reviewer)
      require_option_value "$1" "${2:-}"
      REVIEWER="$2"; shift 2 ;;
    --reviewer=*)
      REVIEWER="${1#*=}"; [ -n "$REVIEWER" ] || missing_option_value "--reviewer"
      shift ;;
    --reviewer-model)
      require_option_value "$1" "${2:-}"
      REVIEWER_MODEL="$2"; shift 2 ;;
    --reviewer-model=*)
      REVIEWER_MODEL="${1#*=}"; [ -n "$REVIEWER_MODEL" ] || missing_option_value "--reviewer-model"
      shift ;;
    --reviewer-effort)
      require_option_value "$1" "${2:-}"
      REVIEWER_EFFORT="$2"; shift 2 ;;
    --reviewer-effort=*)
      REVIEWER_EFFORT="${1#*=}"; [ -n "$REVIEWER_EFFORT" ] || missing_option_value "--reviewer-effort"
      shift ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$IMPLEMENTER" in claude|codex) ;; *) echo "Invalid implementer: $IMPLEMENTER (expected claude or codex)" >&2; exit 2 ;; esac
case "$REVIEWER" in claude|codex) ;; *) echo "Invalid reviewer: $REVIEWER (expected claude or codex)" >&2; exit 2 ;; esac

implementer_startup_model_policy() {
  if [ -n "$IMPLEMENTER_MODEL" ]; then
    printf '%s' "$IMPLEMENTER_MODEL"
  elif [ "$IMPLEMENTER" = "claude" ]; then
    printf '%s' 'stage-default'
  else
    printf '%s' 'configured-default'
  fi
}

resolved_implementer_model() {
  local claude_stage_model="$1"
  if [ -n "$IMPLEMENTER_MODEL" ]; then
    printf '%s' "$IMPLEMENTER_MODEL"
  elif [ "$IMPLEMENTER" = "claude" ]; then
    printf '%s' "$claude_stage_model"
  else
    printf '%s' 'configured-default'
  fi
}

MAX_ITER="${MAX_ITER:-50}"
SLEEP_SEC="${SLEEP_SEC:-10}"
STUCK_N="${STUCK_N:-3}"
MAX_REVIEW_CYCLES="${MAX_REVIEW_CYCLES:-6}"

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

PROJECT=$(basename "$PWD")
LOG_DIR="$HOME/sisyphus-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${PROJECT}-$(date +%Y%m%d-%H%M%S)-$$.log"
STOP_FILE="$LOG_DIR/${PROJECT}.stop"

if [ -f "$STOP_FILE" ]; then
  cat >&2 <<EOF
ERROR: $STOP_FILE already exists.

Another babysit may already be running for '$PROJECT'.

To check:
  pgrep -af babysit

If no other instance is running (e.g. a previous run crashed), remove the
lock file and try again:
  rm $STOP_FILE
EOF
  exit 1
fi

TMP_RESULT=$(mktemp)
TMP_REVIEW=$(mktemp)
TMP_REVIEW_RESULT=$(mktemp)
TMP_CODEX_FULL=$(mktemp)
touch "$LOG" "$STOP_FILE"
trap 'rm -f "$STOP_FILE" "$TMP_RESULT" "$TMP_REVIEW" "$TMP_REVIEW_RESULT" "$TMP_CODEX_FULL"' EXIT

echo "Babysitting $PROJECT v${VERSION} (implementer=$IMPLEMENTER, reviewer=$REVIEWER, max=$MAX_ITER, stuck=$STUCK_N, review_cycles=$MAX_REVIEW_CYCLES) → $LOG"
echo "  roles: implementer model=$(implementer_startup_model_policy) effort=${IMPLEMENTER_EFFORT:-default}; reviewer model=${REVIEWER_MODEL:-configured-default} effort=${REVIEWER_EFFORT:-configured-default}"
echo "  graceful stop: rm $STOP_FILE"

# ---------- prompts ----------

IFS= read -r -d '' BASE_PROMPT <<'PROMPT_EOF' || true
You are working autonomously on this project as one iteration of a long-running babysitter loop. Each invocation should ship ONE well-scoped unit of progress. Over many iterations, the project gets built.

The current project state (PRs, issues, specs) is provided above — use it directly without re-running discovery commands.

Start by reading ./CLAUDE.md and the spec(s) relevant to whatever you decide to work on. Specs live under ./specs/ at the root and recursively under component directories; each has YAML frontmatter with a `status` field (draft|review|approved|deprecated) and a `components` field naming the directories it governs.

Helper scripts (available for targeted mid-iteration queries):
  ~/repo/scripts/prs              — enhanced `gh pr list` with CI check rollup and review state
  ~/repo/scripts/issues           — enhanced `gh issue list` sorted by priority labels
  ~/repo/scripts/specs            — list all specs with status/components (*/specs/**/*.md)
  ~/repo/scripts/specs --status STATUS      — filter by status value (approved|draft|review|deprecated)
  ~/repo/scripts/specs --check-impl         — also show whether component dirs contain source files
  ~/repo/scripts/specs --json / ~/repo/scripts/prs --json / ~/repo/scripts/issues --json  — machine-readable output

Pick the next unit of work in this priority order — stop at the first level that yields an actionable item:

1. Open PRs you can advance. Top priority: PRs in the project state above that are NOT draft and NOT labelled `review-incomplete` (STATE column shows empty). Address all review feedback — including CodeRabbit and other automated reviewer comments and threads — and CI failures on any such PR (yours or a previous iteration's) before considering anything else.

   SKIP any PR whose STATE is `draft` or `BLOCKED` in the prs table (or `isDraft: true` / labels include `review-incomplete` in the JSON). These PRs were marked by a previous review cycle as needing human intervention — re-attempting them wastes iterations. Move on to item 2.

   Also SKIP PRs labelled `review-mcp-outage` or `review-codex-no-credits` — these are managed by the wrapper itself and require operator action before the review cycle can proceed. Do not touch them.
2. Open issues you can complete in one iteration. See open issues in the project state above. Pick the highest-priority one that fits the scope discipline below.
3. Approved specs with no implementation. See specs in the project state above — look for rows where IMPL is `no` or `?`. Scaffold the next missing piece — project skeleton, an interface stub, the first integration test, etc.
4. Proto definitions without consumers. Files under ./proto/ that no service implements. Generate stubs or wire a service skeleton that consumes them.
5. Specs needing refinement. Specs with `status: draft` or `status: review` that are actively blocking implementation work. Tighten ambiguous sections, resolve contradictions, expand thin areas.
6. Open questions. Pick one from ./specs/open-questions.md (if it exists), propose a resolution grounded in existing specs, and update the relevant spec(s) to record the decision.

Scope discipline: pick something completable in this iteration — roughly 1–3 hours of work. Prefer landing one small thing fully (code + tests + docs + CHANGELOG entry) over starting several things. Follow every convention in CLAUDE.md.

Per-iteration workflow:
0. You are in a dedicated git worktree on a placeholder branch. As your FIRST action —
   before reading files or writing code — rename this branch to reflect the work item you
   are about to pick:
     git branch -m <type>/<slug>-<issue-number>
   Use `feat/` for new features, `fix/` for bug fixes, `docs/` for docs-only changes,
   `chore/` for maintenance. Include the issue or PR number when working from a tracked
   item (e.g., `feat/close-goals-124`, `fix/auth-header-87`). This branch name becomes the
   PR branch name — choose descriptively; changing it after `git push` breaks the PR link.
1. State which item you picked and why it is the most valuable next step right now.
2. Implement it fully — code, tests, docs, and a CHANGELOG entry if the project uses one.
3. Run the relevant test suite. If it fails, fix the underlying issue.
4. Commit with a message that explains why the change was made.
5. If the unit of work is shippable on its own, push the branch and open a PR via `gh pr create`. Do NOT merge it — see merge policy below.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — opening or advancing a PR means leaving it open and ending your turn with `HANDOFF_REVIEW <PR>` so the wrapper's Codex review runs.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

End-of-iteration sentinels (mutually exclusive — output exactly one as the LAST line of your final message, with no surrounding quotes, code fences, or punctuation):

- HANDOFF_REVIEW <PR_NUMBER>
  Use this if you opened a new PR or pushed new commits to an existing PR during this iteration. Leave the PR open — the wrapper runs the Codex review and performs the merge once it passes. PR_NUMBER must be a bare integer (no leading `#`). Example: `HANDOFF_REVIEW 42`.

- STOP
  Use this ONLY if BOTH are true:
  * Every spec under ./specs/ (recursively) with `status: approved` has a corresponding implementation that compiles and passes its tests, AND
  * There are no open PRs or issues you can act on.

- (no sentinel)
  If neither applies — e.g. you committed work that isn't yet a PR, or you advanced an existing PR without making it review-ready — end your message normally. The outer loop will start the next iteration.

If you hit a transient obstacle (failing test, missing dependency, ambiguous spec section) — DO NOT output STOP. Work around it: pick a different item, scaffold the missing dependency first, file an issue capturing the ambiguity, or commit what you have with a clear note on what is blocked. STOP terminates the entire loop, so reserve it for genuine completion. Do not output STOP or HANDOFF_REVIEW in code, quotes, or as part of a sentence.
PROMPT_EOF

# The heredoc above is single-quoted (no expansion); point the helper-script
# references at the resolved base path so the agent sees real, runnable paths.
BASE_PROMPT="${BASE_PROMPT//\~\/repo\/scripts/$SCRIPTS_DIR}"

IFS= read -r -d '' CODEX_REVIEW_PROMPT_CYCLE1 <<'PROMPT_EOF' || true
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

IFS= read -r -d '' CODEX_REVIEW_PROMPT_CYCLE2 <<'PROMPT_EOF' || true
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

IFS= read -r -d '' CODEX_REVIEW_PROMPT_CYCLE3_4 <<'PROMPT_EOF' || true
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

IFS= read -r -d '' CODEX_REVIEW_PROMPT_CYCLE5_6 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. Claude posted resolution justifications for the previous cycle's findings. You must adjudicate those justifications AND review the current code state.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

--- Claude's resolution justifications (from previous cycle) begin ---
__JUSTIFICATIONS__
--- Claude's resolution justifications end ---

You have two responsibilities this cycle:

RESPONSIBILITY 1: Adjudicate Claude's resolution justifications.
For each justification Claude posted, you must respond:
- If Claude claimed a finding is "resolved": examine the referenced commit and the current code. Either the fix genuinely addresses the root cause and architectural constraints, or it does not.
- If Claude claimed a finding is "invalid": evaluate the reasoning and the cited supporting reference. Either the reference proves the finding incorrect, or it does not.

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
- You MUST adjudicate every justification Claude posted. No justification may be silently ignored.
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

IFS= read -r -d '' CLAUDE_REVIEW_PROMPT_CYCLE1 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 1 of __MAX_CYCLES__. This is the first review of this PR.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

Implementation:
- Address all BLOCKING findings with minimal, targeted changes.
- Run relevant tests after each fix.
- Commit each fix separately using standard format: fix(<scope>): <what changed>
- Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next Codex review cycle and performs the merge once it passes.
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

--- codex review begin ---
__REVIEW__
--- codex review end ---
PROMPT_EOF

IFS= read -r -d '' CLAUDE_REVIEW_PROMPT_CYCLE2_3 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. The previous cycle(s) did not fully resolve BLOCKING issues.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

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
  - Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next Codex review cycle and performs the merge once it passes.
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

--- codex review begin ---
__REVIEW__
--- codex review end ---
PROMPT_EOF

IFS= read -r -d '' CLAUDE_REVIEW_PROMPT_CYCLE4 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 4 of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

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
  - Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next Codex review cycle and performs the merge once it passes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Step 3: Post resolution justification as PR comment:
  For EACH BLOCKING finding in the Codex review, you must post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by Codex and satisfies the architectural constraints>"
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

--- codex review begin ---
__REVIEW__
--- codex review end ---
PROMPT_EOF

IFS= read -r -d '' CLAUDE_REVIEW_PROMPT_CYCLE5_6 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. Codex has adjudicated your previous resolution justifications.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Process the ADJUDICATION section first, then plan your approach inline.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit.

Step 1: Process Codex adjudication results:
  - For each ACCEPTED item: the finding is resolved. No further action needed.
  - For each DISAGREED item: Codex has provided a reasoned counter-argument with code evidence. You must either:
    (a) Implement a different fix that specifically addresses Codex's counter-argument, OR
    (b) If you believe Codex's counter-argument is itself incorrect, report via STUCK_REVIEW with the specific finding, Codex's argument, and why you disagree (this escalates to human review).

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
  - Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next Codex review cycle and performs the merge once it passes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Step 4: Post resolution justification as PR comment:
  For EACH BLOCKING finding (including DISAGREED items you re-addressed), post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by Codex and satisfies the architectural constraints>"
  - If invalid: "BLOCKING <one-line finding description> is invalid. Reason: <explanation>. Supporting reference: <link to spec/docs/validated source proving the finding is incorrect>"
  - If re-addressed after disagreement: "BLOCKING <one-line finding description> re-addressed after Codex disagreement. Previous fix was insufficient because: <acknowledge Codex's point>. New fix in commit <SHA>: <explanation of how new approach resolves Codex's concern>"

  Use `gh pr comment __PR_NUMBER__ --body "<text>"` to post the justification.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before Step 4, run the full test suite and verify no new surface introduced.
- Step 4 is MANDATORY before DONE_REVIEW.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address AND posted resolution justifications)
- STUCK_REVIEW <one-line reason> (you cannot proceed — use this if Codex's disagreement is itself incorrect and needs human review)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- codex review begin ---
__REVIEW__
--- codex review end ---
PROMPT_EOF

# ---------- helpers ----------

collect_state() {
  echo "=== project state @ $(date -u +%FT%TZ) ==="
  echo ""
  echo "## open PRs"
  "$SCRIPTS_DIR/prs" 2>/dev/null || echo "(unavailable)"
  echo ""
  echo "## open issues"
  "$SCRIPTS_DIR/issues" 2>/dev/null || echo "(unavailable)"
  echo ""
  echo "## specs"
  "$SCRIPTS_DIR/specs" --check-impl 2>/dev/null || echo "(none found)"
  echo ""
  echo "==="
}

# Stream a claude -p iteration to the log AND a human-readable summary on
# stderr. Captures the final .result into the file passed as $2.
# Returns claude's exit code (PIPESTATUS[0]).
run_claude() {
  local prompt="$1"
  local out_file="$2"
  local run_dir="${3:-$PWD}"
  local stage_model="${4:-claude-sonnet-5}"
  local model="${IMPLEMENTER_MODEL:-$stage_model}"
  local -a args=(-p "$prompt" --model "$model")
  [ -n "$IMPLEMENTER_EFFORT" ] && args+=(--effort "$IMPLEMENTER_EFFORT")
  args+=(--dangerously-skip-permissions --output-format stream-json --verbose)
  (cd "$run_dir" && claude "${args[@]}" 2>>"$LOG") \
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

# Run a Codex implementation pass with the same autonomous/full-access policy
# as Claude's permission bypass. Codex writes its final response directly to
# out_file; diagnostic stdout/stderr is logged separately so it cannot corrupt
# sentinel capture.
run_codex_implementer() {
  local prompt="$1"
  local out_file="$2"
  local run_dir="${3:-$PWD}"
  local -a args=(exec --output-last-message "$out_file" --dangerously-bypass-approvals-and-sandbox)
  [ -n "$IMPLEMENTER_MODEL" ] && args+=(--model "$IMPLEMENTER_MODEL")
  [ -n "$IMPLEMENTER_EFFORT" ] && args+=(-c "model_reasoning_effort=\"$IMPLEMENTER_EFFORT\"")
  : > "$out_file"
  (cd "$run_dir" && codex "${args[@]}" "$prompt" 2>&1) \
    | tee -a "$LOG" >&2
  return ${PIPESTATUS[0]}
}

# Provider-neutral implementation dispatcher. stage_model is used only for
# backward-compatible Claude defaults; an explicit implementer model overrides it.
run_implementer() {
  local prompt="$1"
  local out_file="$2"
  local run_dir="${3:-$PWD}"
  local stage_model="${4:-claude-sonnet-5}"
  case "$IMPLEMENTER" in
    claude) run_claude "$prompt" "$out_file" "$run_dir" "$stage_model" ;;
    codex) run_codex_implementer "$prompt" "$out_file" "$run_dir" ;;
  esac
}

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

# Fetch all existing PR feedback: formal review bodies, top-level comments, and
# inline review comments. Filters out comments posted by the babysitter itself
# (prefixed with "**Codex review —", "**Claude review —", or
# "**babysit-with-review:") to avoid
# feeding its own output back as external feedback.
# Args: <pr_num>
collect_pr_feedback() {
  local pr_num="$1"
  local owner_repo
  owner_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  [ -z "$owner_repo" ] && return 0

  local out=""

  # Formal review summaries (CodeRabbit posts its main summary here).
  local reviews
  reviews=$(gh pr view "$pr_num" --json reviews \
    --jq '.reviews[]
          | select(.body != "")
          | select(.body | startswith("**Codex review") | not)
          | select(.body | startswith("**Claude review") | not)
          | select(.body | startswith("**babysit-with-review:") | not)
          | "### Review by \(.author.login) [\(.state)]\n\(.body)\n"' \
    2>/dev/null || true)
  [ -n "$reviews" ] && out="${out}${reviews}"$'\n'

  # Top-level issue comments.
  local comments
  comments=$(gh pr view "$pr_num" --json comments \
    --jq '.comments[]
          | select(.body | startswith("**Codex review") | not)
          | select(.body | startswith("**Claude review") | not)
          | select(.body | startswith("**babysit-with-review:") | not)
          | "### Comment by \(.author.login)\n\(.body)\n"' \
    2>/dev/null || true)
  [ -n "$comments" ] && out="${out}${comments}"$'\n'

  # Inline review comments (line-level diff annotations).
  local inline
  inline=$(gh api "repos/${owner_repo}/pulls/${pr_num}/comments" \
    --jq '.[] | "### Inline comment by \(.user.login) on \(.path):\(.line // .original_line // "?")\n\(.body)\n"' \
    2>/dev/null || true)
  [ -n "$inline" ] && out="${out}${inline}"$'\n'

  [ -z "$out" ] && out="(none)"
  printf '%s' "$out"
}

# Post the selected harness review as a PR comment. Best-effort: failures logged.
# Args: <pr_num> <cycle> <max_cycles> <review_file>
post_codex_review() {
  local pr_num="$1"
  local cycle="$2"
  local max="$3"
  local review_file="$4"

  [ -s "$review_file" ] || return 0

  local body reviewer_name
  case "$REVIEWER" in codex) reviewer_name="Codex" ;; claude) reviewer_name="Claude" ;; esac
  body="**${reviewer_name} review — PR #${pr_num} cycle ${cycle} of ${max}**

\`\`\`
$(cat "$review_file")
\`\`\`"

  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment ($REVIEWER review) failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Mark a PR as needing manual review when a review cycle bails for any reason.
# Args: <pr_num> <reason_string>
# Safety commands (ready --undo, edit --add-label) are fail-closed: gh failure → exit 1.
# Notification commands (label create, pr comment) are best-effort.
fail_review_cycle() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] marking PR #$pr_num incomplete: $reason" | tee -a "$LOG" >&2

  # Ensure the label exists (idempotent via --force). Best-effort.
  gh label create review-incomplete \
    --color B60205 \
    --description "Babysit review cycle did not complete cleanly" \
    --force >>"$LOG" 2>&1 || true

  # Fail-closed: if we can't draft the PR, halt — it must not remain mergeable.
  if ! gh pr ready "$pr_num" --undo >>"$LOG" 2>&1; then
    echo "ERROR: gh pr ready --undo failed for PR #$pr_num — PR may still be mergeable; manually quarantine before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  # Fail-closed: if we can't label the PR, halt — it must not remain unlabelled.
  if ! gh pr edit "$pr_num" --add-label review-incomplete >>"$LOG" 2>&1; then
    echo "ERROR: gh pr edit --add-label failed for PR #$pr_num — PR may be unlabelled; manually add 'review-incomplete' before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  # Post the bail reason. (Reviewer content is already on the PR.)
  local body
  body="**babysit-with-review: review cycle bailed — manual review required**

Reason: ${reason}"
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Mark a PR as stalled by a codex MCP transport failure.
# The babysitter will retry the review cycle on its next run.
# Args: <pr_num> <reason_string>
# Safety commands (ready --undo, edit --add-label) are fail-closed: gh failure → exit 1.
# Notification commands (label create, pr comment) are best-effort.
fail_review_cycle_mcp() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] codex MCP outage for PR #$pr_num: $reason" | tee -a "$LOG" >&2

  gh label create review-mcp-outage \
    --color 0075CA \
    --description "Babysit codex review stalled by MCP transport failure; wrapper will retry" \
    --force >>"$LOG" 2>&1 || true

  # Fail-closed: if we can't draft the PR, halt — it must not remain mergeable.
  if ! gh pr ready "$pr_num" --undo >>"$LOG" 2>&1; then
    echo "ERROR: gh pr ready --undo failed for PR #$pr_num — PR may still be mergeable; manually quarantine before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  # Fail-closed: if we can't label the PR, halt — it must not remain unlabelled.
  if ! gh pr edit "$pr_num" --add-label review-mcp-outage >>"$LOG" 2>&1; then
    echo "ERROR: gh pr edit --add-label failed for PR #$pr_num — PR may be unlabelled; manually add 'review-mcp-outage' before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  local body
  body="**babysit-with-review: codex MCP transport failure — review pending**

Reason: ${reason}

The codex MCP backend was unreachable. No code-quality review took place. The babysitter will retry this review cycle automatically on its next run.

Label \`review-mcp-outage\` has been added. Remove it manually if you merge this PR without waiting for an automated review."
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Mark a PR as stalled by a Codex backend compatibility failure.
# The Codex CLI must be upgraded before the review cycle can proceed.
# Args: <pr_num> <reason_string>
# Safety commands (ready --undo, edit --add-label) are fail-closed: gh failure → exit 1.
# Notification commands (label create, pr comment) are best-effort.
fail_review_cycle_codex_outdated() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] Codex version incompatibility for PR #$pr_num: $reason" | tee -a "$LOG" >&2

  gh label create review-codex-outdated \
    --color e4e669 \
    --description "Babysit codex review stalled by CLI version incompatibility; upgrade Codex then remove label" \
    --force >>"$LOG" 2>&1 || true

  # Fail-closed: if we can't draft the PR, halt — it must not remain mergeable.
  if ! gh pr ready "$pr_num" --undo >>"$LOG" 2>&1; then
    echo "ERROR: gh pr ready --undo failed for PR #$pr_num — PR may still be mergeable; manually quarantine before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  # Fail-closed: if we can't label the PR, halt — it must not remain unlabelled.
  if ! gh pr edit "$pr_num" --add-label review-codex-outdated >>"$LOG" 2>&1; then
    echo "ERROR: gh pr edit --add-label failed for PR #$pr_num — PR may be unlabelled; manually add 'review-codex-outdated' before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  local body
  body="**babysit-with-review: Codex version incompatibility — review blocked**

Reason: ${reason}

The Codex CLI is too old for the configured model. No code-quality review took place.

To resume: upgrade the Codex CLI (\`codex update\`), then remove the \`review-codex-outdated\` label and restart the babysitter."
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Mark a PR as stalled by Codex workspace credit exhaustion.
# Operator must add credits to the Codex workspace, remove the label, and restart.
# Args: <pr_num> <reason_string>
# Safety commands (ready --undo, edit --add-label) are fail-closed: gh failure → exit 1.
# Notification commands (label create, pr comment) are best-effort.
fail_review_cycle_codex_no_credits() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] Codex workspace out of credits for PR #$pr_num: $reason" | tee -a "$LOG" >&2

  gh label create review-codex-no-credits \
    --color d93f0b \
    --description "Babysit codex review stalled: workspace out of credits; add credits then remove label" \
    --force >>"$LOG" 2>&1 || true

  # Fail-closed: if we can't draft the PR, halt — it must not remain mergeable.
  if ! gh pr ready "$pr_num" --undo >>"$LOG" 2>&1; then
    echo "ERROR: gh pr ready --undo failed for PR #$pr_num — PR may still be mergeable; manually quarantine before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  # Fail-closed: if we can't label the PR, halt — it must not remain unlabelled.
  if ! gh pr edit "$pr_num" --add-label review-codex-no-credits >>"$LOG" 2>&1; then
    echo "ERROR: gh pr edit --add-label failed for PR #$pr_num — PR may be unlabelled; manually add 'review-codex-no-credits' before restarting" | tee -a "$LOG" >&2
    exit 1
  fi

  local body
  body="**babysit-with-review: Codex workspace out of credits — review blocked**

Reason: ${reason}

The Codex workspace has no credits remaining. No code-quality review took place.

To resume: add credits to the Codex workspace, then remove the \`review-codex-no-credits\` label and restart the babysitter."
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Validate the strict review parser contract shared by all reviewer harnesses.
valid_review_structure() {
  local review_file="$1"
  [ -s "$review_file" ] || return 1
  awk '
    BEGIN { current = 0; valid = 1 }
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
    /^## / { current = 0; next }
    /^- / {
      if (current == 1) blocking_bullets++
      else if (current == 2) recommended_bullets++
      else if (current == 3) information_bullets++
    }
    END {
      if (blocking_headings != 1 || recommended_headings != 1 || information_headings != 1) valid = 0
      if (blocking_bullets < 1 || recommended_bullets < 1 || information_bullets < 1) valid = 0
      exit(valid ? 0 : 1)
    }
  ' "$review_file" 2>/dev/null
}

# Run codex exec with retry on MCP transport failures.
# Uses $TMP_REVIEW (must be zeroed by caller) for the output-last-message file.
# Uses $TMP_CODEX_FULL for the combined codex output (used for telltale detection).
#
# Invariant: a non-zero return never leaves a PR mergeable-and-unreviewed.
# The caller is responsible for calling fail_review_cycle* on any non-zero return.
#
# Returns:
#   0 — codex completed cleanly; $TMP_REVIEW is non-empty and structurally valid
#         (all three section headers present: ## BLOCKING / ## RECOMMENDED / ## INFORMATION).
#   1 — codex failed for a non-transport reason (prompt issue, crash, structurally
#         invalid output, etc.).
#   2 — codex MCP transport failure; all retries exhausted.
#   3 — backend compatibility failure; Codex CLI too old for configured model (no retry).
#   4 — Codex workspace out of credits; no retry.
codex_review_with_retry() {
  local codex_prompt="$1"
  local attempt
  local delays=(0 60 300)
  local compat_re='requires a newer version of Codex'
  local credits_re='Your workspace is out of credits'
  # Telltale patterns for MCP transport failures. Update if Codex changes its error format.
  # Monitored via the MCP outage rate KPI (see L3-mcp-resilience.md kill criteria: >30% → find alternative reviewer).
  local mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'

  for attempt in 1 2 3; do
    if [ "${delays[$((attempt - 1))]}" -gt 0 ]; then
      echo "  [codex] waiting ${delays[$((attempt - 1))]}s before retry (attempt $attempt of 3)..." | tee -a "$LOG" >&2
      sleep "${delays[$((attempt - 1))]}"
    fi
    : > "$TMP_REVIEW"
    : > "$TMP_CODEX_FULL"

    local rc=0
    set +e
    local -a codex_args=(exec --output-last-message "$TMP_REVIEW" -s read-only)
    [ -n "$REVIEWER_MODEL" ] && codex_args+=(--model "$REVIEWER_MODEL")
    [ -n "$REVIEWER_EFFORT" ] && codex_args+=(-c "model_reasoning_effort=\"$REVIEWER_EFFORT\"")
    codex "${codex_args[@]}" "$codex_prompt" 2>&1 \
      | tee -a "$LOG" "$TMP_CODEX_FULL" >&2
    rc=${PIPESTATUS[0]}
    set -e

    # Compat check first (before mcp_re): version mismatch → return 3, no retry.
    if grep -qE "$compat_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      echo "  [codex] FATAL: backend compatibility failure on attempt $attempt (rc=$rc); Codex CLI is too old for the configured model" | tee -a "$LOG" >&2
      return 3
    fi

    # Credits check: workspace exhausted → return 4, no retry.
    if grep -qE "$credits_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      echo "  [codex] FATAL: Codex workspace out of credits on attempt $attempt (rc=$rc); add credits and restart" | tee -a "$LOG" >&2
      return 4
    fi

    # Structural validation: require all three section headers before treating as success.
    # This closes the exit-0-garbage hole (e.g. a deprecation warning in place of a review).
    if [ "$rc" -eq 0 ] && [ -s "$TMP_REVIEW" ]; then
      if valid_review_structure "$TMP_REVIEW"; then return 0; fi
      echo "  [codex] exit 0 but review missing required section headers (## BLOCKING / ## RECOMMENDED / ## INFORMATION); treating as failure" | tee -a "$LOG" >&2
      # fall through to return 1
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

# Run a Claude review with non-mutating plan permissions. Claude's stream-json
# result is reduced to the final response in TMP_REVIEW and validated against
# the same strict section contract as Codex.
claude_review() {
  local review_prompt="$1"
  local -a args=(-p "$review_prompt" --permission-mode plan)
  [ -n "$REVIEWER_MODEL" ] && args+=(--model "$REVIEWER_MODEL")
  [ -n "$REVIEWER_EFFORT" ] && args+=(--effort "$REVIEWER_EFFORT")
  args+=(--output-format stream-json --verbose)
  : > "$TMP_REVIEW"
  set +e
  claude "${args[@]}" 2>&1 \
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
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  [claude reviewer] non-zero exit (rc=$rc); treating review as incomplete" | tee -a "$LOG" >&2
    return 1
  fi
  if ! valid_review_structure "$TMP_REVIEW"; then
    echo "  [claude reviewer] review missing required section headers (## BLOCKING / ## RECOMMENDED / ## INFORMATION); treating as failure" | tee -a "$LOG" >&2
    return 1
  fi
}

review_with_retry() {
  local review_prompt="$1"
  case "$REVIEWER" in
    codex) codex_review_with_retry "$review_prompt" ;;
    claude) claude_review "$review_prompt" ;;
  esac
}

# Codex-only preflight preserves compatibility and credit detection. Claude has
# no equivalent provider-specific probe and fails closed when its review runs.
reviewer_preflight() {
  [ "$REVIEWER" = "codex" ] || return 0
  local compat_re='requires a newer version of Codex'
  local credits_re='Your workspace is out of credits'
  local probe_full
  probe_full=$(mktemp)
  local -a args=(exec -s read-only)
  [ -n "$REVIEWER_MODEL" ] && args+=(--model "$REVIEWER_MODEL")
  [ -n "$REVIEWER_EFFORT" ] && args+=(-c "model_reasoning_effort=\"$REVIEWER_EFFORT\"")
  local rc=0
  set +e
  codex "${args[@]}" "Say 'ok'." 2>&1 | tee -a "$LOG" "$probe_full" >/dev/null
  rc=${PIPESTATUS[0]}
  set -e
  if grep -qE "$compat_re" "$probe_full" 2>/dev/null; then rm -f "$probe_full"; return 3; fi
  if grep -qE "$credits_re" "$probe_full" 2>/dev/null; then rm -f "$probe_full"; return 4; fi
  rm -f "$probe_full"
  [ "$rc" -eq 0 ] || return 1
}

reviewer_binary_available() {
  command -v "$REVIEWER" >/dev/null 2>&1
}

# Run the selected implementer/reviewer cycle for a PR number.
run_review_cycle() {
  local pr_num="$1"
  local cycle=0
  local review_start_sha=""
  local -a REVIEW_HISTORY=()
  local justifications=""

  echo "=== review handoff: PR #$pr_num @ $(date -u +%FT%TZ) ===" | tee -a "$LOG" >&2

  # Graceful degradation checks the selected reviewer binary.
  if ! reviewer_binary_available; then
    echo "  [review] $REVIEWER CLI not found; skipping review cycle (PR #$pr_num remains open for external review)" | tee -a "$LOG" >&2
    return 0
  fi

  # Codex preflight is provider-specific; Claude failures take the generic
  # review-incomplete path after the real review invocation.
  local _probe_rc=0
  reviewer_preflight || _probe_rc=$?
  if [ "$_probe_rc" -eq 3 ]; then
    echo "  [review] FATAL: Codex version incompatibility detected in pre-flight probe (PR #$pr_num); upgrade CLI before retrying" | tee -a "$LOG" >&2
    fail_review_cycle_codex_outdated "$pr_num" "Codex pre-flight probe: CLI too old for configured model"
    return 3
  elif [ "$_probe_rc" -eq 4 ]; then
    echo "  [review] FATAL: Codex workspace out of credits (pre-flight probe for PR #$pr_num); add credits before restarting" | tee -a "$LOG" >&2
    fail_review_cycle_codex_no_credits "$pr_num" "Codex pre-flight probe: workspace out of credits"
    return 4
  elif [ "$_probe_rc" -ne 0 ]; then
    echo "  [review] FATAL: $REVIEWER pre-flight probe returned rc=$_probe_rc; bailing review cycle for PR #$pr_num" | tee -a "$LOG" >&2
    fail_review_cycle "$pr_num" "$REVIEWER pre-flight probe failed (rc=$_probe_rc) before checkout"
    return 0
  fi
  unset _probe_rc

  # Make sure we're on the PR branch.
  if ! gh pr checkout "$pr_num" >>"$LOG" 2>&1; then
    echo "  [review] gh pr checkout $pr_num failed; skipping review cycle" | tee -a "$LOG" >&2
    fail_review_cycle "$pr_num" "gh pr checkout failed before review could run"
    return 0
  fi
  # Capture PR branch tip before remediation commits so cycle history only
  # surfaces changes made by the selected implementer during this review cycle.
  review_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

  while [ "$cycle" -lt "$MAX_REVIEW_CYCLES" ]; do
    cycle=$((cycle + 1))
    echo "--- review cycle $cycle / $MAX_REVIEW_CYCLES (PR #$pr_num) @ $(date -u +%FT%TZ) ---" | tee -a "$LOG" >&2

    # ---- reviewer pass ----
    # Build history block for cycle 2+: prior reviews + remediation commits.
    local history_block=""
    if [ "$cycle" -ge 2 ] && [ "${#REVIEW_HISTORY[@]}" -gt 0 ]; then
      local _hb=""
      local _i
      for _i in "${!REVIEW_HISTORY[@]}"; do
        _hb="${_hb}### cycle $(( _i + 1 )) review
${REVIEW_HISTORY[$_i]}
"
      done
      local _commits
      _commits=$(git log --oneline "${review_start_sha}..HEAD" 2>/dev/null || true)
      _hb="${_hb}--- commits the implementer made since review cycle started ---
${_commits:-"(none)"}
--- end commits ---
"
      history_block="--- prior review cycles (for convergence tracking) ---
${_hb}--- end prior review cycles ---
"
      unset _hb _i _commits
    fi

    # Select the existing review template by cycle number.
    local _tmpl
    if [ "$cycle" -eq 1 ]; then
      _tmpl="$CODEX_REVIEW_PROMPT_CYCLE1"
    elif [ "$cycle" -eq 2 ]; then
      _tmpl="$CODEX_REVIEW_PROMPT_CYCLE2"
    elif [ "$cycle" -le 4 ]; then
      _tmpl="$CODEX_REVIEW_PROMPT_CYCLE3_4"
    else
      _tmpl="$CODEX_REVIEW_PROMPT_CYCLE5_6"
    fi
    local codex_prompt
    codex_prompt="${_tmpl//__PR_NUMBER__/$pr_num}"
    codex_prompt="${codex_prompt//__CYCLE__/$cycle}"
    codex_prompt="${codex_prompt//__MAX_CYCLES__/$MAX_REVIEW_CYCLES}"
    codex_prompt="${codex_prompt//__HISTORY_BLOCK__/$history_block}"
    codex_prompt="${codex_prompt//__JUSTIFICATIONS__/$justifications}"
    unset _tmpl

    local _has_history="no"
    [ -n "$history_block" ] && _has_history="yes"
    local _tmpl_name
    if [ "$cycle" -eq 1 ]; then
      _tmpl_name="descriptive-baseline"
    elif [ "$cycle" -eq 2 ]; then
      _tmpl_name="descriptive-convergence"
    elif [ "$cycle" -le 4 ]; then
      _tmpl_name="prescriptive-detailed"
      echo "  [$REVIEWER reviewer] detailed explanations enabled (cycle 3+)" | tee -a "$LOG" >&2
    else
      _tmpl_name="prescriptive-adjudication"
      echo "  [$REVIEWER reviewer] adjudication mode enabled (cycle 5+)" | tee -a "$LOG" >&2
    fi
    echo "  [$REVIEWER reviewer] template=${_tmpl_name} has_history=${_has_history} cycle=${cycle}/${MAX_REVIEW_CYCLES}" | tee -a "$LOG" >&2
    unset _has_history _tmpl_name

    echo "  [$REVIEWER reviewer] reviewing PR #$pr_num..." >&2
    local reviewer_rc=0
    review_with_retry "$codex_prompt" || reviewer_rc=$?

    if [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 3 ]; then
      fail_review_cycle_codex_outdated "$pr_num" "Codex CLI version incompatibility during review (cycle $cycle)"
      return 3
    elif [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 4 ]; then
      fail_review_cycle_codex_no_credits "$pr_num" "Codex workspace out of credits during review (cycle $cycle)"
      return 4
    elif [ "$REVIEWER" = "codex" ] && [ "$reviewer_rc" -eq 2 ]; then
      fail_review_cycle_mcp "$pr_num" "codex MCP transport failure after 3 retries (cycle $cycle)"
      return 2
    elif [ "$reviewer_rc" -ne 0 ]; then
      echo "  [$REVIEWER reviewer] review failed; bailing review cycle" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "$REVIEWER review failed during cycle $cycle"
      return 0
    fi

    local review
    review=$(cat "$TMP_REVIEW")
    REVIEW_HISTORY+=("$review")

    post_codex_review "$pr_num" "$cycle" "$MAX_REVIEW_CYCLES" "$TMP_REVIEW"

    {
      echo "--- $REVIEWER review (cycle $cycle) ---"
      printf '%s\n' "$review"
      echo "--- end $REVIEWER review ---"
    } >> "$LOG"

    # Parse adjudication results for cycle 5+ telemetry
    if [ "$cycle" -ge 5 ]; then
      local n_accepted n_disagreed
      n_accepted=$(printf '%s\n' "$review" | grep -c '^- BLOCKING.*: ACCEPTED' || echo 0)
      n_disagreed=$(printf '%s\n' "$review" | grep -c '^- BLOCKING.*: DISAGREED' || echo 0)
      echo "  [$REVIEWER reviewer] adjudication: $n_accepted accepted, $n_disagreed disagreed" | tee -a "$LOG" >&2
    fi

    local n_blocking
    n_blocking=$(printf '%s\n' "$review" | count_blocking)
    echo "  [$REVIEWER reviewer] $n_blocking blocking finding(s)" | tee -a "$LOG" >&2

    # Guard: if count_blocking returned non-integer, bail — never merge on a parse error.
    if ! [[ "$n_blocking" =~ ^[0-9]+$ ]]; then
      echo "  [review] FATAL: count_blocking produced non-integer ('$n_blocking'); bailing to prevent spurious merge" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "count_blocking produced non-integer output (parse error in cycle $cycle)"
      return 0
    fi

    if [ "$n_blocking" -eq 0 ]; then
      echo "  [review] zero blocking findings; PR #$pr_num cleared after $cycle cycle(s)" | tee -a "$LOG" >&2

      # Set codex-review=success commit status so branch protection allows the merge.
      # This is the ONLY place this status is set green — the implementation agent never sets it.
      local _owner_repo _head_sha
      _owner_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
      _head_sha=$(gh pr view "$pr_num" --json headRefOid -q .headRefOid 2>/dev/null || echo "")
      if [ -n "$_owner_repo" ] && [ -n "$_head_sha" ]; then
        if gh api -X POST "repos/${_owner_repo}/statuses/${_head_sha}" \
            -f state=success \
            -f context=codex-review \
            -f description="$REVIEWER review passed (cycle ${cycle} of ${MAX_REVIEW_CYCLES})" \
            -f target_url="https://github.com/${_owner_repo}/pull/${pr_num}" \
            >>"$LOG" 2>&1; then
          echo "  [review] codex-review status set to success for ${_head_sha:0:8}" | tee -a "$LOG" >&2
        else
          echo "  [review] WARNING: failed to set codex-review status for PR #$pr_num; leaving PR open rather than merging without the status check" | tee -a "$LOG" >&2
          return 0
        fi
      else
        echo "  [review] WARNING: could not resolve repo or head SHA for PR #$pr_num; leaving PR open rather than merging without the status check" | tee -a "$LOG" >&2
        return 0
      fi

      if gh pr merge "$pr_num" --squash --delete-branch --auto >>"$LOG" 2>&1; then
        echo "  [review] PR #$pr_num queued for auto-merge (merges when CI passes)" | tee -a "$LOG" >&2
      elif gh pr merge "$pr_num" --squash --delete-branch >>"$LOG" 2>&1; then
        echo "  [review] PR #$pr_num merged." | tee -a "$LOG" >&2
      else
        echo "  [review] WARNING: merge failed for PR #$pr_num; left open for next iteration. See $LOG." | tee -a "$LOG" >&2
        return 0
      fi

      # Clean up: switch back to default branch so the next outer-loop iteration
      # starts from the right base, and delete the local PR branch.
      local _pr_branch
      _pr_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      git checkout "$DEFAULT_BRANCH" >>"$LOG" 2>&1 || true
      git pull --ff-only origin "$DEFAULT_BRANCH" >>"$LOG" 2>&1 || true
      if [ -n "$_pr_branch" ] && [ "$_pr_branch" != "$DEFAULT_BRANCH" ]; then
        git branch -D "$_pr_branch" >>"$LOG" 2>&1 || true
      fi
      return 0
    fi

    # ---- implementer remediation pass ----
    local pr_feedback
    pr_feedback=$(collect_pr_feedback "$pr_num" 2>>"$LOG")
    [ -z "$pr_feedback" ] && pr_feedback="(none)"

    # Select Claude template and model by cycle number.
    # Cycles 1-3: Sonnet (fast, sufficient for straightforward fixes).
    # Cycles 4+: Opus (harder problems need stronger reasoning).
    local _claude_tmpl _claude_model
    if [ "$cycle" -eq 1 ]; then
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE1"
      _claude_model="claude-sonnet-5"
    elif [ "$cycle" -le 3 ]; then
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE2_3"
      _claude_model="claude-sonnet-5"
      echo "  [$IMPLEMENTER implementer] structured remediation pass for PR #$pr_num cycle $cycle" | tee -a "$LOG" >&2
    elif [ "$cycle" -eq 4 ]; then
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE4"
      _claude_model="claude-opus-4-8"
      echo "  [$IMPLEMENTER implementer] structured remediation pass for PR #$pr_num cycle $cycle (with justifications)" | tee -a "$LOG" >&2
    else
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE5_6"
      _claude_model="claude-opus-4-8"
      echo "  [$IMPLEMENTER implementer] adjudication remediation pass for PR #$pr_num cycle $cycle" | tee -a "$LOG" >&2
    fi

    local claude_prompt
    claude_prompt="${_claude_tmpl//__PR_NUMBER__/$pr_num}"
    claude_prompt="${claude_prompt//__CYCLE__/$cycle}"
    claude_prompt="${claude_prompt//__MAX_CYCLES__/$MAX_REVIEW_CYCLES}"
    claude_prompt="${claude_prompt//__REVIEW__/$review}"
    claude_prompt="${claude_prompt//__PR_FEEDBACK__/$pr_feedback}"
    unset _claude_tmpl

    local pre_sha post_sha
    pre_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

    local _resolved_implementer_model
    _resolved_implementer_model=$(resolved_implementer_model "$_claude_model")
    echo "  [$IMPLEMENTER implementer] addressing findings (model: $_resolved_implementer_model)..." >&2
    if ! run_implementer "$claude_prompt" "$TMP_REVIEW_RESULT" "$PWD" "$_claude_model"; then
      echo "  [$IMPLEMENTER implementer] non-zero exit during review pass; bailing review cycle" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "$IMPLEMENTER exited non-zero while addressing review (cycle $cycle)"
      return 0
    fi

    local result trimmed last_line
    result=$(cat "$TMP_REVIEW_RESULT")
    trimmed=$(printf '%s' "$result" | sed -e 's/[[:space:]]*$//')
    last_line=$(printf '%s' "$trimmed" | tail -n 1)

    case "$last_line" in
      "STUCK_REVIEW"*)
        echo "  [$IMPLEMENTER implementer] $last_line — bailing review cycle" | tee -a "$LOG" >&2
        fail_review_cycle "$pr_num" "$IMPLEMENTER reported STUCK_REVIEW (cycle $cycle)"
        return 0
        ;;
      "DONE_REVIEW")
        echo "  [$IMPLEMENTER implementer] DONE_REVIEW — looping for another reviewer pass" | tee -a "$LOG" >&2
        # Capture resolution justifications for next cycle (cycle 4+)
        if [ "$cycle" -ge 4 ]; then
          justifications=$(gh pr view "$pr_num" --json comments -q '.comments[-1].body' 2>/dev/null || echo "")
          echo "  [$IMPLEMENTER implementer] resolution justifications posted to PR #$pr_num" | tee -a "$LOG" >&2
        fi
        ;;
      *)
        echo "  [$IMPLEMENTER implementer] no review-cycle sentinel on last line; treating as DONE_REVIEW" | tee -a "$LOG" >&2
        # Capture resolution justifications for next cycle (cycle 4+)
        if [ "$cycle" -ge 4 ]; then
          justifications=$(gh pr view "$pr_num" --json comments -q '.comments[-1].body' 2>/dev/null || echo "")
          echo "  [$IMPLEMENTER implementer] resolution justifications posted to PR #$pr_num" | tee -a "$LOG" >&2
        fi
        ;;
    esac

    post_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$pre_sha" ] && [ "$pre_sha" = "$post_sha" ]; then
      echo "  [$IMPLEMENTER implementer] HEAD unchanged (no commits made) — bailing review cycle to avoid infinite loop" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "$IMPLEMENTER reported DONE_REVIEW but made no commits (cycle $cycle)"
      return 0
    fi
  done

  echo "  [review] hit MAX_REVIEW_CYCLES=$MAX_REVIEW_CYCLES on PR #$pr_num; resuming outer loop" | tee -a "$LOG" >&2
  fail_review_cycle "$pr_num" "exhausted MAX_REVIEW_CYCLES=$MAX_REVIEW_CYCLES without clearing all blocking findings"
}

# Narrow deterministic test hook for argument and provider-command regression
# coverage. Normal execution is unchanged when BABYSIT_TEST_MODE is unset.
if [ -n "${BABYSIT_TEST_MODE:-}" ]; then
  case "$BABYSIT_TEST_MODE" in
    config)
      printf 'implementer=%s\nimplementer_model=%s\nimplementer_effort=%s\n' \
        "$IMPLEMENTER" "$IMPLEMENTER_MODEL" "$IMPLEMENTER_EFFORT"
      printf 'reviewer=%s\nreviewer_model=%s\nreviewer_effort=%s\n' \
        "$REVIEWER" "$REVIEWER_MODEL" "$REVIEWER_EFFORT"
      ;;
    implementer-outer)
      run_implementer "test implementation prompt" "$TMP_RESULT" "$PWD" "claude-sonnet-5" || exit $?
      cat "$TMP_RESULT"
      ;;
    implementer-remediation)
      run_implementer "test remediation prompt" "$TMP_REVIEW_RESULT" "$PWD" "${BABYSIT_TEST_STAGE_MODEL:-claude-sonnet-5}" || exit $?
      cat "$TMP_REVIEW_RESULT"
      ;;
    reviewer)
      review_with_retry "test review prompt" || exit $?
      cat "$TMP_REVIEW"
      ;;
    reviewer-preflight)
      reviewer_preflight
      ;;
    reviewer-availability)
      if reviewer_binary_available; then
        printf 'available_reviewer=%s\n' "$REVIEWER"
      else
        printf 'missing_reviewer=%s\n' "$REVIEWER"
      fi
      ;;
    model-policy)
      printf 'startup_model=%s\n' "$(implementer_startup_model_policy)"
      printf 'remediation_model=%s\n' "$(resolved_implementer_model 'claude-opus-4-8')"
      ;;
    *)
      echo "Unknown BABYSIT_TEST_MODE: $BABYSIT_TEST_MODE" >&2
      exit 2
      ;;
  esac
  exit 0
fi

# ---------- log header ----------

{
  echo "=== babysit-with-review.sh v${VERSION} @ $(date -u +%FT%TZ) ==="
  echo "project:           $PROJECT"
  echo "cwd:               $PWD"
  echo "max_iter:          $MAX_ITER"
  echo "sleep:             ${SLEEP_SEC}s"
  echo "stuck_n:           $STUCK_N"
  echo "max_review_cycles: $MAX_REVIEW_CYCLES"
  echo "implementer:       $IMPLEMENTER"
  echo "implementer_model: $(implementer_startup_model_policy)"
  echo "implementer_effort:${IMPLEMENTER_EFFORT:+ $IMPLEMENTER_EFFORT}"
  echo "reviewer:          $REVIEWER"
  echo "reviewer_model:    ${REVIEWER_MODEL:-configured-default}"
  echo "reviewer_effort:   ${REVIEWER_EFFORT:+ $REVIEWER_EFFORT}"
  echo "--- base prompt ---"
  printf '%s\n' "$BASE_PROMPT"
  echo "--- end base prompt ---"
  echo "--- codex review prompt: cycle 1 (descriptive baseline) ---"
  printf '%s\n' "$CODEX_REVIEW_PROMPT_CYCLE1"
  echo "--- end codex review prompt (cycle 1) ---"
  echo "--- codex review prompt: cycle 2 (descriptive + convergence) ---"
  printf '%s\n' "$CODEX_REVIEW_PROMPT_CYCLE2"
  echo "--- end codex review prompt (cycle 2) ---"
  echo "--- codex review prompt: cycles 3-4 (prescriptive + detailed) ---"
  printf '%s\n' "$CODEX_REVIEW_PROMPT_CYCLE3_4"
  echo "--- end codex review prompt (cycles 3-4) ---"
  echo "--- codex review prompt: cycles 5-6 (prescriptive + adjudication) ---"
  printf '%s\n' "$CODEX_REVIEW_PROMPT_CYCLE5_6"
  echo "--- end codex review prompt (cycles 5-6) ---"
  echo "--- claude review prompt: cycle 1 (standard) ---"
  printf '%s\n' "$CLAUDE_REVIEW_PROMPT_CYCLE1"
  echo "--- end claude review prompt (cycle 1) ---"
  echo "--- claude review prompt: cycles 2-3 (plan-first) ---"
  printf '%s\n' "$CLAUDE_REVIEW_PROMPT_CYCLE2_3"
  echo "--- end claude review prompt (cycles 2-3) ---"
  echo "--- claude review prompt: cycle 4 (plan-first + resolution justification) ---"
  printf '%s\n' "$CLAUDE_REVIEW_PROMPT_CYCLE4"
  echo "--- end claude review prompt (cycle 4) ---"
  echo "--- claude review prompt: cycles 5-6 (plan-first + adjudication processing) ---"
  printf '%s\n' "$CLAUDE_REVIEW_PROMPT_CYCLE5_6"
  echo "--- end claude review prompt (cycles 5-6) ---"
} >> "$LOG"

# ---------- pre-flight checks ----------

# Ensures the working tree is clean and on the default branch before the outer
# loop starts. Auto-cleans when safe (switches branch, fast-forwards); refuses
# with corrective instructions when it could clobber WIP.
_pf_default=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
git fetch origin >>"$LOG" 2>&1 \
  || echo "[preflight] WARN: git fetch origin failed; continuing without remote state" >&2

# 1. Refuse if tracked files have unstaged modifications.
if ! git diff --quiet 2>/dev/null; then
  cat >&2 <<EOF
ERROR: working tree has unstaged modifications. Inspect: git status
Resolve before starting:
  git stash push -u -m "pre-babysit"   # save them
  # or commit them on a feature branch and push
EOF
  exit 1
fi

# 2. Refuse if tracked files have staged-but-uncommitted changes.
if ! git diff --cached --quiet 2>/dev/null; then
  cat >&2 <<EOF
ERROR: working tree has staged but uncommitted changes. Inspect: git status
Resolve before starting:
  git commit -m "wip"
  # or
  git restore --staged .
EOF
  exit 1
fi

# 3. Refuse if untracked non-ignored files exist.
_pf_untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
if [ -n "$_pf_untracked" ]; then
  _pf_n=$(printf '%s\n' "$_pf_untracked" | wc -l | tr -d ' ')
  _pf_more=""
  [ "$_pf_n" -gt 5 ] && _pf_more="  ...and $(( _pf_n - 5 )) more"
  cat >&2 <<EOF
ERROR: working tree has $_pf_n untracked non-ignored file(s):
$(printf '%s\n' "$_pf_untracked" | head -5 | sed 's/^/  /')
$_pf_more
Add them to .gitignore, commit them, or remove them. Inspect: git status
EOF
  exit 1
fi

# 4. Auto-clean: switch to default branch if HEAD is elsewhere (tree clean by here).
_pf_current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ "$_pf_current" != "$_pf_default" ]; then
  echo "[preflight] switching from '$_pf_current' to default branch '$_pf_default'..." >&2
  if ! git checkout "$_pf_default" >>"$LOG" 2>&1; then
    echo "ERROR: failed to checkout default branch '$_pf_default'. See $LOG." >&2
    exit 1
  fi
fi

# 5. Check ahead/behind vs origin.
_pf_ahead=$(git rev-list --count "origin/${_pf_default}..${_pf_default}" 2>/dev/null || echo 0)
_pf_behind=$(git rev-list --count "${_pf_default}..origin/${_pf_default}" 2>/dev/null || echo 0)

if [ "$_pf_ahead" -gt 0 ] && [ "$_pf_behind" -gt 0 ]; then
  cat >&2 <<EOF
ERROR: local '$_pf_default' has diverged from origin/$_pf_default ($_pf_ahead ahead, $_pf_behind behind).
Reconcile manually:
  git log --oneline --left-right origin/$_pf_default...$_pf_default
EOF
  exit 1
fi

if [ "$_pf_ahead" -gt 0 ]; then
  cat >&2 <<EOF
ERROR: local '$_pf_default' is $_pf_ahead commit(s) ahead of origin/$_pf_default.
This causes review tools to compute the wrong diff (incident 2026-04-30).

Inspect the local commits:
  git log --oneline origin/$_pf_default..$_pf_default

If sound, push them:
  git push origin $_pf_default

Then re-run the babysitter.
EOF
  exit 1
fi

if [ "$_pf_behind" -gt 0 ]; then
  echo "[preflight] '$_pf_default' is $_pf_behind commit(s) behind origin; fast-forwarding..." >&2
  if ! git pull --ff-only origin "$_pf_default" >>"$LOG" 2>&1; then
    echo "ERROR: failed to fast-forward '$_pf_default' from origin. See $LOG." >&2
    exit 1
  fi
fi

DEFAULT_BRANCH="$_pf_default"
unset _pf_default _pf_current _pf_untracked _pf_n _pf_more _pf_ahead _pf_behind

# Prune stale worktree metadata from previous crashed runs.
git worktree prune >>"$LOG" 2>&1 || true

# ---------- outer loop ----------

declare -a HASHES=()

iter=0
while [ "$iter" -lt "$MAX_ITER" ]; do
  iter=$((iter + 1))
  HEADER="=== iter $iter @ $(date -u +%FT%TZ) ==="
  echo "$HEADER" | tee -a "$LOG" >&2
  echo "  [stop file: $STOP_FILE]" >&2
  if [ ! -f "$STOP_FILE" ]; then
    echo "Stop file removed; exiting before iter $iter." | tee -a "$LOG"
    break
  fi

  # Retry any PR stalled by a previous codex MCP transport failure.
  # The PR is un-drafted and re-reviewed before invoking the implementer.
  _mcp_pr=$(gh pr list --state open --label review-mcp-outage --limit 1 --json number -q '.[0].number' 2>/dev/null || echo "")
  if [ -n "$_mcp_pr" ]; then
    echo "[outer] retrying review cycle for PR #$_mcp_pr (review-mcp-outage)" | tee -a "$LOG" >&2
    gh pr edit "$_mcp_pr" --remove-label review-mcp-outage >>"$LOG" 2>&1 || true
    gh pr ready "$_mcp_pr" >>"$LOG" 2>&1 || true
    _rc=0
    run_review_cycle "$_mcp_pr" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
      case "$_rc" in
        2) echo "Halting: codex MCP outage persists for PR #$_mcp_pr; retries exhausted. See $LOG" | tee -a "$LOG" >&2 ;;
        3) echo "Halting: Codex version incompatibility for PR #$_mcp_pr; upgrade CLI before restarting. See $LOG" | tee -a "$LOG" >&2 ;;
        4) echo "Halting: Codex workspace out of credits for PR #$_mcp_pr; add credits then remove label and restart. See $LOG" | tee -a "$LOG" >&2 ;;
        *) echo "Halting: review cycle returned unexpected rc=$_rc for PR #$_mcp_pr. See $LOG" | tee -a "$LOG" >&2 ;;
      esac
      break
    fi
    unset _mcp_pr _rc
    continue
  fi
  unset _mcp_pr

  STATE=$(collect_state)
  PROMPT="${STATE}

${BASE_PROMPT}"

  {
    echo "--- state ---"
    printf '%s\n' "$STATE"
    echo "--- end state ---"
  } >> "$LOG"

  # --- per-iteration worktree ---
  _wt_branch="wip/${PROJECT}/iter-${iter}"
  _wt_dir="/tmp/babysit-${PROJECT}-iter${iter}-$$"
  if ! git worktree add -b "$_wt_branch" "$_wt_dir" HEAD >>"$LOG" 2>&1; then
    echo "  [outer] WARNING: worktree creation failed for iter $iter; $IMPLEMENTER will run in $PWD" | tee -a "$LOG" >&2
    _wt_dir=""
    _wt_branch=""
  else
    echo "  [outer] worktree: $_wt_dir (branch: $_wt_branch)" | tee -a "$LOG" >&2
  fi

  if ! run_implementer "$PROMPT" "$TMP_RESULT" "$_wt_dir"; then
    echo "ERROR: implementation $IMPLEMENTER exited non-zero on iter $iter; quarantining unreviewed open PRs" | tee -a "$LOG" >&2
    # Push any WIP commits before removing the worktree, so work is not silently lost.
    if [ -n "$_wt_dir" ]; then
      _wt_actual=$(git -C "$_wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      _wt_ahead=$(git -C "$_wt_dir" rev-list "${DEFAULT_BRANCH}..HEAD" --count 2>/dev/null || echo 0)
      if [ "${_wt_ahead:-0}" -gt 0 ] && [ -n "${_wt_actual:-}" ]; then
        echo "  [outer] pushing ${_wt_ahead} WIP commit(s) from ${_wt_actual} after crash" | tee -a "$LOG" >&2
        git -C "$_wt_dir" push -u origin "HEAD:${_wt_actual}" >>"$LOG" 2>&1 || \
          echo "  [outer] WARNING: WIP push failed for ${_wt_actual}" | tee -a "$LOG" >&2
      fi
      git worktree remove --force "$_wt_dir" >>"$LOG" 2>&1 || true
      rm -rf "$_wt_dir"
      if [ -n "$_wt_actual" ] && [ "$_wt_actual" != "$DEFAULT_BRANCH" ]; then
        git branch -D "$_wt_actual" >>"$LOG" 2>&1 || true
      fi
    fi
    _wt_dir=""
    _wt_branch=""
    # Sweep open, non-draft PRs authored by @me that carry no review-* label.
    # A crashed implementation pass may have left such a PR mergeable-and-unreviewed,
    # which is the same silent-merge hole this script is designed to prevent.
    _quarantine_prs=$(gh pr list \
      --state open --draft=false --author "@me" \
      --json number,labels \
      --jq '[.[] | select(.labels | map(.name) | map(startswith("review-")) | any | not) | .number] | .[]' \
      2>/dev/null || echo "")
    if [ -n "$_quarantine_prs" ]; then
      while IFS= read -r _qpr; do
        echo "  [outer] quarantining unreviewed open PR #$_qpr (implementation crash on iter $iter)" | tee -a "$LOG" >&2
        fail_review_cycle "$_qpr" "implementation $IMPLEMENTER crashed before review handoff (iter $iter)"
      done <<< "$_quarantine_prs"
    fi
    unset _quarantine_prs _qpr
    break
  fi
  echo "---" >> "$LOG"

  # Remove the worktree BEFORE sentinel handling: run_review_cycle calls
  # gh pr checkout, which fails if the PR branch is still checked out in the
  # worktree ("fatal: ... is already used by worktree at ...").
  # The implementer has already pushed the branch to origin, so removing the local
  # worktree is safe.
  if [ -n "$_wt_dir" ]; then
    _wt_actual=$(git -C "$_wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$_wt_branch")
    echo "  [outer] iter $iter branch: $_wt_actual" | tee -a "$LOG" >&2
    _wt_ahead=$(git -C "$_wt_dir" rev-list "${DEFAULT_BRANCH}..HEAD" --count 2>/dev/null || echo 0)
    if [ "${_wt_ahead:-0}" -gt 0 ]; then
      echo "  [outer] safety-push: ${_wt_ahead} unpushed commit(s) on ${_wt_actual}" | tee -a "$LOG" >&2
      git -C "$_wt_dir" push -u origin "HEAD:${_wt_actual}" >>"$LOG" 2>&1 || \
        echo "  [outer] WARNING: safety-push failed for ${_wt_actual}" | tee -a "$LOG" >&2
    fi
    git worktree remove --force "$_wt_dir" >>"$LOG" 2>&1 || true
    rm -rf "$_wt_dir"
    # Delete the actual branch (the implementer renames the placeholder during execution).
    # gh pr checkout will re-create from remote if run_review_cycle needs it.
    if [ -n "$_wt_actual" ] && [ "$_wt_actual" != "$DEFAULT_BRANCH" ]; then
      git branch -D "$_wt_actual" >>"$LOG" 2>&1 || true
    fi
    _wt_dir=""
    _wt_branch=""
  fi

  RESULT=$(cat "$TMP_RESULT")
  TRIMMED=$(printf '%s' "$RESULT" | sed -e 's/[[:space:]]*$//')
  LAST_LINE=$(printf '%s' "$TRIMMED" | tail -n 1)

  # Sentinel detection. HANDOFF_REVIEW triggers a review cycle and falls
  # through to the next outer iteration; STOP terminates the loop.
  case "$LAST_LINE" in
    "HANDOFF_REVIEW "*)
      pr_num="${LAST_LINE#HANDOFF_REVIEW }"
      pr_num="${pr_num%% *}"
      if [[ "$pr_num" =~ ^[0-9]+$ ]]; then
        _rc=0
        run_review_cycle "$pr_num" || _rc=$?
        if [ "$_rc" -ne 0 ]; then
          case "$_rc" in
            2) echo "Halting: codex MCP transport outage on PR #$pr_num; retries exhausted. See $LOG" | tee -a "$LOG" >&2 ;;
            3) echo "Halting: Codex version incompatibility on PR #$pr_num; upgrade CLI before restarting. See $LOG" | tee -a "$LOG" >&2 ;;
            4) echo "Halting: Codex workspace out of credits on PR #$pr_num; add credits then remove label and restart. See $LOG" | tee -a "$LOG" >&2 ;;
            *) echo "Halting: review cycle returned unexpected rc=$_rc for PR #$pr_num. See $LOG" | tee -a "$LOG" >&2 ;;
          esac
          break
        fi
      else
        echo "  [outer] HANDOFF_REVIEW with non-numeric PR '$pr_num'; ignoring" | tee -a "$LOG" >&2
      fi
      ;;
    "STOP")
      echo "STOP signal received on iter $iter."
      break
      ;;
  esac

  # Stuck-loop guard.
  HASH=$(printf '%s' "$RESULT" | shasum -a 256 | awk '{print $1}')
  HASHES+=("$HASH")
  if [ "${#HASHES[@]}" -gt "$STUCK_N" ]; then
    HASHES=("${HASHES[@]: -$STUCK_N}")
  fi
  if [ "${#HASHES[@]}" -eq "$STUCK_N" ]; then
    STUCK=1
    for h in "${HASHES[@]}"; do
      [ "$h" = "${HASHES[0]}" ] || { STUCK=0; break; }
    done
    if [ "$STUCK" -eq 1 ]; then
      echo "Stuck: last $STUCK_N results identical. Bailing on iter $iter." | tee -a "$LOG"
      break
    fi
  fi

  sleep "$SLEEP_SEC"
done

if [ "$iter" -ge "$MAX_ITER" ]; then
  echo "Hit MAX_ITER=$MAX_ITER. Bailing." | tee -a "$LOG"
fi

echo "Done after $iter iterations. See $LOG"
