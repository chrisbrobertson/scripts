#!/bin/bash
# babysit-with-review.sh — babysit.sh + Claude<->Codex PR-review handoff.
#
# Same outer loop as babysit.sh. When Claude ends an iteration with the
# sentinel `HANDOFF_REVIEW <PR_NUMBER>` on its own line, this wrapper runs
# up to MAX_REVIEW_CYCLES (default 6) of:
#   1. codex exec — produces a strict-markdown review with three sections:
#      ## BLOCKING / ## RECOMMENDED / ## INFORMATION
#   2. claude -p  — addresses BLOCKING (must), RECOMMENDED (should), and
#                   considers INFORMATION findings; commits and pushes.
# The cycle exits early when codex reports zero BLOCKING findings, when
# claude reports STUCK_REVIEW, or when HEAD doesn't advance during a
# claude pass (defensive against "DONE_REVIEW but no commits made").
#
# Env vars:
#   MAX_ITER           default 50   hard cap on outer iterations
#   SLEEP_SEC          default 10   pause between outer iterations (seconds)
#   STUCK_N            default 3    consecutive identical results = stuck
#   MAX_REVIEW_CYCLES  default 6    max codex<->claude cycles per PR
#
# MCP-outage resilience: when codex cannot reach its backend, the wrapper
# retries up to 3 times (0 / 60s / 300s back-off), labels the PR
# `review-mcp-outage`, and halts. On the next babysitter run the pre-iter
# scan retries the labelled PR automatically before running claude.
# `review-incomplete` = human action required; `review-mcp-outage` = auto-retry.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: babysit-with-review.sh [-h|--help]

Run from inside a project root. Outer loop is identical to babysit.sh.
When Claude ends an iteration with `HANDOFF_REVIEW <PR_NUMBER>` on its
own line, runs a Claude<->Codex review cycle on that PR (up to
MAX_REVIEW_CYCLES) before resuming the outer loop.

Env vars:
  MAX_ITER           default 50
  SLEEP_SEC          default 10  (seconds)
  STUCK_N            default 3
  MAX_REVIEW_CYCLES  default 6

PR labels used by the review cycle:
  review-incomplete   Human intervention required; wrapper will NOT retry.
  review-mcp-outage   Codex MCP backend was unreachable; wrapper retries
                      automatically at the top of each outer iteration.

Logs land in ~/sisyphus-logs/<project>-<timestamp>-<pid>.log.

Examples:
  babysit-with-review.sh
  MAX_REVIEW_CYCLES=3 babysit-with-review.sh
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

MAX_ITER="${MAX_ITER:-50}"
SLEEP_SEC="${SLEEP_SEC:-10}"
STUCK_N="${STUCK_N:-3}"
MAX_REVIEW_CYCLES="${MAX_REVIEW_CYCLES:-6}"

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

echo "Babysitting $PROJECT (max=$MAX_ITER, stuck=$STUCK_N, review_cycles=$MAX_REVIEW_CYCLES) → $LOG"
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

   Also SKIP PRs labelled `review-mcp-outage` — these are managed by the wrapper itself, which will retry the codex review cycle automatically at the top of each iteration when the MCP backend recovers. Do not touch them.
2. Open issues you can complete in one iteration. See open issues in the project state above. Pick the highest-priority one that fits the scope discipline below.
3. Approved specs with no implementation. See specs in the project state above — look for rows where IMPL is `no` or `?`. Scaffold the next missing piece — project skeleton, an interface stub, the first integration test, etc.
4. Proto definitions without consumers. Files under ./proto/ that no service implements. Generate stubs or wire a service skeleton that consumes them.
5. Specs needing refinement. Specs with `status: draft` or `status: review` that are actively blocking implementation work. Tighten ambiguous sections, resolve contradictions, expand thin areas.
6. Open questions. Pick one from ./specs/open-questions.md (if it exists), propose a resolution grounded in existing specs, and update the relevant spec(s) to record the decision.

Scope discipline: pick something completable in this iteration — roughly 1–3 hours of work. Prefer landing one small thing fully (code + tests + docs + CHANGELOG entry) over starting several things. Follow every convention in CLAUDE.md.

Per-iteration workflow:
1. State which item you picked and why it is the most valuable next step right now.
2. Implement it fully — code, tests, docs, and a CHANGELOG entry if the project uses one.
3. Run the relevant test suite. If it fails, fix the underlying issue.
4. Commit with a message that explains why the change was made.
5. If the unit of work is shippable on its own, push the branch and open a PR via `gh pr create`.

End-of-iteration sentinels (mutually exclusive — output exactly one as the LAST line of your final message, with no surrounding quotes, code fences, or punctuation):

- HANDOFF_REVIEW <PR_NUMBER>
  Use this if you opened a new PR or pushed new commits to an existing PR during this iteration. The wrapper will run an automated code review (codex) and may invoke you again to address findings before resuming the outer loop. PR_NUMBER must be a bare integer (no leading `#`). Example: `HANDOFF_REVIEW 42`.

- STOP
  Use this ONLY if BOTH are true:
  * Every spec under ./specs/ (recursively) with `status: approved` has a corresponding implementation that compiles and passes its tests, AND
  * There are no open PRs or issues you can act on.

- (no sentinel)
  If neither applies — e.g. you committed work that isn't yet a PR, or you advanced an existing PR without making it review-ready — end your message normally. The outer loop will start the next iteration.

If you hit a transient obstacle (failing test, missing dependency, ambiguous spec section) — DO NOT output STOP. Work around it: pick a different item, scaffold the missing dependency first, file an issue capturing the ambiguity, or commit what you have with a clear note on what is blocked. STOP terminates the entire loop, so reserve it for genuine completion. Do not output STOP or HANDOFF_REVIEW in code, quotes, or as part of a sentence.
PROMPT_EOF

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
- Push commits to PR branch when complete.

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

**CRITICAL: Use plan mode before implementing.**

Step 1: Enter plan mode to create an implementation plan:
  - Analyze all BLOCKING findings and their dependencies
  - Determine the correct order to address them (some fixes may depend on others)
  - Identify any cross-finding interactions or shared root causes
  - Document trade-offs and alternatives for non-obvious decisions
  - Output the plan for review before proceeding

Step 2: Execute the plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to PR branch when complete

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

**CRITICAL: Use plan mode before implementing.**

Step 1: Enter plan mode to create an implementation plan:
  - Analyze all BLOCKING findings and their dependencies
  - Determine the correct order to address them (some fixes may depend on others)
  - Identify any cross-finding interactions or shared root causes
  - Document trade-offs and alternatives for non-obvious decisions
  - Output the plan for review before proceeding

Step 2: Execute the plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to PR branch when complete

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

**CRITICAL: Process the ADJUDICATION section first, then use plan mode for remaining work.**

Step 1: Process Codex adjudication results:
  - For each ACCEPTED item: the finding is resolved. No further action needed.
  - For each DISAGREED item: Codex has provided a reasoned counter-argument with code evidence. You must either:
    (a) Implement a different fix that specifically addresses Codex's counter-argument, OR
    (b) If you believe Codex's counter-argument is itself incorrect, report via STUCK_REVIEW with the specific finding, Codex's argument, and why you disagree (this escalates to human review).

Step 2: Enter plan mode to create an implementation plan for all remaining BLOCKING findings:
  - Include all DISAGREED items that you will re-address (from Step 1a)
  - Include all new BLOCKING findings from the current review
  - Determine the correct order to address them
  - Document trade-offs and alternatives for non-obvious decisions
  - Output the plan for review before proceeding

Step 3: Execute the plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to PR branch when complete

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
  ~/repo/scripts/prs 2>/dev/null || echo "(unavailable)"
  echo ""
  echo "## open issues"
  ~/repo/scripts/issues 2>/dev/null || echo "(unavailable)"
  echo ""
  echo "## specs"
  ~/repo/scripts/specs --check-impl 2>/dev/null || echo "(none found)"
  echo ""
  echo "==="
}

# Stream a claude -p iteration to the log AND a human-readable summary on
# stderr. Captures the final .result into the file passed as $2.
# Returns claude's exit code (PIPESTATUS[0]).
run_claude() {
  local prompt="$1"
  local out_file="$2"
  claude -p "$prompt" \
    --model opusplan \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --verbose 2>>"$LOG" \
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

# Count BLOCKING findings in a strict-markdown codex review on stdin.
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
# (prefixed with "**Codex review —" or "**babysit-with-review:") to avoid
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
          | select(.body | startswith("**babysit-with-review:") | not)
          | "### Review by \(.author.login) [\(.state)]\n\(.body)\n"' \
    2>/dev/null || true)
  [ -n "$reviews" ] && out="${out}${reviews}"$'\n'

  # Top-level issue comments.
  local comments
  comments=$(gh pr view "$pr_num" --json comments \
    --jq '.comments[]
          | select(.body | startswith("**Codex review") | not)
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

# Post a codex review as a PR comment. Best-effort: failures logged, do not abort.
# Args: <pr_num> <cycle> <max_cycles> <review_file>
post_codex_review() {
  local pr_num="$1"
  local cycle="$2"
  local max="$3"
  local review_file="$4"

  [ -s "$review_file" ] || return 0

  local body
  body="**Codex review — PR #${pr_num} cycle ${cycle} of ${max}**

\`\`\`
$(cat "$review_file")
\`\`\`"

  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment (codex review) failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Mark a PR as needing manual review when a review cycle bails for any reason.
# Args: <pr_num> <reason_string>
# Best-effort: gh failures are logged but do not abort the caller.
fail_review_cycle() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] marking PR #$pr_num incomplete: $reason" | tee -a "$LOG" >&2

  # Ensure the label exists (idempotent via --force).
  gh label create review-incomplete \
    --color B60205 \
    --description "Babysit review cycle did not complete cleanly" \
    --force >>"$LOG" 2>&1 || true

  # Convert to draft so the PR cannot be merged without operator action.
  gh pr ready "$pr_num" --undo >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr ready --undo failed for PR #$pr_num" | tee -a "$LOG" >&2

  # Add the label.
  gh pr edit "$pr_num" --add-label review-incomplete >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr edit --add-label failed for PR #$pr_num" | tee -a "$LOG" >&2

  # Post the bail reason. (Codex review content is already on the PR via post_codex_review.)
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
# Best-effort: gh failures are logged but do not abort the caller.
fail_review_cycle_mcp() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] codex MCP outage for PR #$pr_num: $reason" | tee -a "$LOG" >&2

  gh label create review-mcp-outage \
    --color 0075CA \
    --description "Babysit codex review stalled by MCP transport failure; wrapper will retry" \
    --force >>"$LOG" 2>&1 || true

  gh pr ready "$pr_num" --undo >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr ready --undo failed for PR #$pr_num" | tee -a "$LOG" >&2

  gh pr edit "$pr_num" --add-label review-mcp-outage >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr edit --add-label failed for PR #$pr_num" | tee -a "$LOG" >&2

  local body
  body="**babysit-with-review: codex MCP transport failure — review pending**

Reason: ${reason}

The codex MCP backend was unreachable. No code-quality review took place. The babysitter will retry this review cycle automatically on its next run.

Label \`review-mcp-outage\` has been added. Remove it manually if you merge this PR without waiting for an automated review."
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Run codex exec with retry on MCP transport failures.
# Uses $TMP_REVIEW (must be zeroed by caller) for the output-last-message file.
# Uses $TMP_CODEX_FULL for the combined codex output (used for telltale detection).
#
# Returns:
#   0 — codex completed cleanly; $TMP_REVIEW is non-empty.
#   1 — codex failed for a non-transport reason (prompt issue, crash, etc.).
#   2 — codex MCP transport failure; all retries exhausted.
codex_review_with_retry() {
  local codex_prompt="$1"
  local attempt
  local delays=(0 60 300)
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
    codex exec --output-last-message "$TMP_REVIEW" -s read-only "$codex_prompt" 2>&1 \
      | tee -a "$LOG" "$TMP_CODEX_FULL" >&2
    rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ] && [ -s "$TMP_REVIEW" ]; then
      return 0
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

# Run the Claude<->Codex review cycle for a PR number.
run_review_cycle() {
  local pr_num="$1"
  local cycle=0
  local review_start_sha=""
  local -a REVIEW_HISTORY=()
  local justifications=""

  echo "=== review handoff: PR #$pr_num @ $(date -u +%FT%TZ) ===" | tee -a "$LOG" >&2

  # Graceful degradation: if codex isn't installed (e.g. headless mbp16 host
  # where review is handled by an external PM agent), skip the Claude↔Codex
  # review cycle and just return — the outer loop continues normally.
  if ! command -v codex >/dev/null 2>&1; then
    echo "  [review] codex CLI not found; skipping review cycle (PR #$pr_num remains open for external review)" | tee -a "$LOG" >&2
    return 0
  fi

  # Make sure we're on the PR branch.
  if ! gh pr checkout "$pr_num" >>"$LOG" 2>&1; then
    echo "  [review] gh pr checkout $pr_num failed; skipping review cycle" | tee -a "$LOG" >&2
    fail_review_cycle "$pr_num" "gh pr checkout failed before review could run"
    return 0
  fi
  # Capture PR branch tip before any Claude commits so the history git log
  # only surfaces commits Claude makes during this review cycle.
  review_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

  while [ "$cycle" -lt "$MAX_REVIEW_CYCLES" ]; do
    cycle=$((cycle + 1))
    echo "--- review cycle $cycle / $MAX_REVIEW_CYCLES (PR #$pr_num) @ $(date -u +%FT%TZ) ---" | tee -a "$LOG" >&2

    # ---- codex pass ----
    # Build history block for cycle 2+: prior reviews + commits Claude made.
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
      _hb="${_hb}--- commits Claude made since review cycle started ---
${_commits:-"(none)"}
--- end commits ---
"
      history_block="--- prior review cycles (for convergence tracking) ---
${_hb}--- end prior review cycles ---
"
      unset _hb _i _commits
    fi

    # Select Codex template by cycle number.
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
      echo "  [codex] detailed explanations enabled (cycle 3+)" | tee -a "$LOG" >&2
    else
      _tmpl_name="prescriptive-adjudication"
      echo "  [codex] adjudication mode enabled (cycle 5+)" | tee -a "$LOG" >&2
    fi
    echo "  [codex] template=${_tmpl_name} has_history=${_has_history} cycle=${cycle}/${MAX_REVIEW_CYCLES}" | tee -a "$LOG" >&2
    unset _has_history _tmpl_name

    echo "  [codex] reviewing PR #$pr_num..." >&2
    local codex_rc=0
    codex_review_with_retry "$codex_prompt" || codex_rc=$?

    if [ "$codex_rc" -eq 2 ]; then
      fail_review_cycle_mcp "$pr_num" "codex MCP transport failure after 3 retries (cycle $cycle)"
      return 2
    elif [ "$codex_rc" -ne 0 ]; then
      echo "  [codex] non-MCP failure; bailing review cycle" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "codex exec failed (non-transport) during cycle $cycle"
      return 0
    fi

    local review
    review=$(cat "$TMP_REVIEW")
    REVIEW_HISTORY+=("$review")

    post_codex_review "$pr_num" "$cycle" "$MAX_REVIEW_CYCLES" "$TMP_REVIEW"

    {
      echo "--- codex review (cycle $cycle) ---"
      printf '%s\n' "$review"
      echo "--- end codex review ---"
    } >> "$LOG"

    # Parse adjudication results for cycle 5+ telemetry
    if [ "$cycle" -ge 5 ]; then
      local n_accepted n_disagreed
      n_accepted=$(printf '%s\n' "$review" | grep -c '^- BLOCKING.*: ACCEPTED' || echo 0)
      n_disagreed=$(printf '%s\n' "$review" | grep -c '^- BLOCKING.*: DISAGREED' || echo 0)
      echo "  [codex] adjudication: $n_accepted accepted, $n_disagreed disagreed" | tee -a "$LOG" >&2
    fi

    local n_blocking
    n_blocking=$(printf '%s\n' "$review" | count_blocking)
    echo "  [codex] $n_blocking blocking finding(s)" | tee -a "$LOG" >&2

    if [ "$n_blocking" -eq 0 ]; then
      echo "  [review] zero blocking findings; PR #$pr_num cleared after $cycle cycle(s)" | tee -a "$LOG" >&2
      if gh pr merge "$pr_num" --squash --auto >>"$LOG" 2>&1; then
        echo "  [review] PR #$pr_num queued for auto-merge (merges when CI passes)" | tee -a "$LOG" >&2
      elif gh pr merge "$pr_num" --squash >>"$LOG" 2>&1; then
        echo "  [review] PR #$pr_num merged." | tee -a "$LOG" >&2
      else
        echo "  [review] WARNING: merge failed for PR #$pr_num; left open for next iteration. See $LOG." | tee -a "$LOG" >&2
      fi
      return 0
    fi

    # ---- claude pass ----
    local pr_feedback
    pr_feedback=$(collect_pr_feedback "$pr_num" 2>>"$LOG")
    [ -z "$pr_feedback" ] && pr_feedback="(none)"

    # Select Claude template by cycle number
    local _claude_tmpl
    if [ "$cycle" -eq 1 ]; then
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE1"
    elif [ "$cycle" -le 3 ]; then
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE2_3"
      echo "  [claude] entering plan mode for PR #$pr_num cycle $cycle" | tee -a "$LOG" >&2
    elif [ "$cycle" -eq 4 ]; then
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE4"
      echo "  [claude] entering plan mode for PR #$pr_num cycle $cycle" | tee -a "$LOG" >&2
    else
      _claude_tmpl="$CLAUDE_REVIEW_PROMPT_CYCLE5_6"
      echo "  [claude] entering plan mode for PR #$pr_num cycle $cycle" | tee -a "$LOG" >&2
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

    echo "  [claude] addressing findings..." >&2
    if ! run_claude "$claude_prompt" "$TMP_REVIEW_RESULT"; then
      echo "  [claude] non-zero exit during review pass; bailing review cycle" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "claude exited non-zero while addressing review (cycle $cycle)"
      return 0
    fi

    local result trimmed last_line
    result=$(cat "$TMP_REVIEW_RESULT")
    trimmed=$(printf '%s' "$result" | sed -e 's/[[:space:]]*$//')
    last_line=$(printf '%s' "$trimmed" | tail -n 1)

    case "$last_line" in
      "STUCK_REVIEW"*)
        echo "  [claude] $last_line — bailing review cycle" | tee -a "$LOG" >&2
        fail_review_cycle "$pr_num" "claude reported STUCK_REVIEW (cycle $cycle)"
        return 0
        ;;
      "DONE_REVIEW")
        echo "  [claude] DONE_REVIEW — looping for another codex pass" | tee -a "$LOG" >&2
        # Capture resolution justifications for next cycle (cycle 4+)
        if [ "$cycle" -ge 4 ]; then
          justifications=$(gh pr view "$pr_num" --json comments -q '.comments[-1].body' 2>/dev/null || echo "")
          echo "  [claude] resolution justifications posted to PR #$pr_num" | tee -a "$LOG" >&2
        fi
        ;;
      *)
        echo "  [claude] no review-cycle sentinel on last line; treating as DONE_REVIEW" | tee -a "$LOG" >&2
        # Capture resolution justifications for next cycle (cycle 4+)
        if [ "$cycle" -ge 4 ]; then
          justifications=$(gh pr view "$pr_num" --json comments -q '.comments[-1].body' 2>/dev/null || echo "")
          echo "  [claude] resolution justifications posted to PR #$pr_num" | tee -a "$LOG" >&2
        fi
        ;;
    esac

    post_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$pre_sha" ] && [ "$pre_sha" = "$post_sha" ]; then
      echo "  [claude] HEAD unchanged (no commits made) — bailing review cycle to avoid infinite loop" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "claude reported DONE_REVIEW but made no commits (cycle $cycle)"
      return 0
    fi
  done

  echo "  [review] hit MAX_REVIEW_CYCLES=$MAX_REVIEW_CYCLES on PR #$pr_num; resuming outer loop" | tee -a "$LOG" >&2
  fail_review_cycle "$pr_num" "exhausted MAX_REVIEW_CYCLES=$MAX_REVIEW_CYCLES without clearing all blocking findings"
}

# ---------- log header ----------

{
  echo "=== babysit-with-review.sh @ $(date -u +%FT%TZ) ==="
  echo "project:           $PROJECT"
  echo "cwd:               $PWD"
  echo "max_iter:          $MAX_ITER"
  echo "sleep:             ${SLEEP_SEC}s"
  echo "stuck_n:           $STUCK_N"
  echo "max_review_cycles: $MAX_REVIEW_CYCLES"
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

unset _pf_default _pf_current _pf_untracked _pf_n _pf_more _pf_ahead _pf_behind

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
  # The PR is un-drafted and re-reviewed before invoking claude for this iter.
  _mcp_pr=$(gh pr list --state open --label review-mcp-outage --limit 1 --json number -q '.[0].number' 2>/dev/null || echo "")
  if [ -n "$_mcp_pr" ]; then
    echo "[outer] retrying review cycle for PR #$_mcp_pr (review-mcp-outage)" | tee -a "$LOG" >&2
    gh pr edit "$_mcp_pr" --remove-label review-mcp-outage >>"$LOG" 2>&1 || true
    gh pr ready "$_mcp_pr" >>"$LOG" 2>&1 || true
    _rc=0
    run_review_cycle "$_mcp_pr" || _rc=$?
    if [ "$_rc" -eq 2 ]; then
      echo "Halting: codex MCP outage persists for PR #$_mcp_pr. See $LOG" | tee -a "$LOG" >&2
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

  if ! run_claude "$PROMPT" "$TMP_RESULT"; then
    echo "claude exited non-zero on iter $iter; see $LOG" >&2
    break
  fi
  echo "---" >> "$LOG"

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
        if [ "$_rc" -eq 2 ]; then
          echo "Halting: codex MCP transport outage on PR #$pr_num; retries exhausted. See $LOG" | tee -a "$LOG" >&2
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
