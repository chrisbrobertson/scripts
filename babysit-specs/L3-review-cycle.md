---
spec_type: feature
id: ARLO-FEAT-REVIEW-CYCLE
status: review
owners: [Chris Robertson]
depends_on: [ARLO-SYS-AUTONOMOUS-DEV, ARLO-FEAT-MCP-RESILIENCE]
parent_l1: ARLO-PROD-BABYSIT-WITH-REVIEW
parent_l2: ARLO-SYS-AUTONOMOUS-DEV
fit_check: passed
complexity:
  total: 2
  band: trivial
  drivers: [novelty, time_estimate]
  scored_on: 2026-06-28
---

# Frame

## TL;DR
Claude-Codex iterative review cycle that reviews PR code via Codex, feeds findings to Claude for fixes, tracks convergence across cycles, and switches to prescriptive mode after cycle 3 to force concrete fix suggestions.

## Analog
Like a pull request review process with two reviewers: Codex (strict code reviewer) and Claude (implementer), iterating until all blocking issues are resolved or max cycles exhausted.

## Reader & next action
Implementing engineer: understand review cycle state machine, convergence tracking, and prescriptive mode trigger. QA: verify cycle termination conditions and label application.

## API surface fragment
```bash
# Triggered by outer loop when HANDOFF_REVIEW sentinel detected
run_review_cycle <PR_NUMBER>

# Codex review output format (strict markdown)
## BLOCKING
- <issue> — <file:line> — <reason>
  Suggested fix: <concrete code> (prescriptive mode only, cycle 3+)

## RECOMMENDED
- <issue> — <file:line> — <reason>

## INFORMATION
- <issue> — <file:line> — <context>

# Claude review sentinels
DONE_REVIEW                    # addressed findings, ready for next Codex pass
STUCK_REVIEW <reason>          # cannot proceed, bail review cycle

# PR labels applied by cycle
review-incomplete              # human action required (stuck, max cycles, etc.)
review-mcp-outage             # Codex MCP transport failure (auto-retry)

# Cycle state (not exposed, internal to run_review_cycle)
REVIEW_HISTORY=()             # array of prior Codex reviews
review_start_sha              # git SHA at cycle start (for commit tracking)
```

## Consumer
Orchestrator (babysit-with-review.sh outer loop) invoking run_review_cycle() function.

# Substance

## What we know
From implementation (babysit-with-review.sh lines 518-682):
- Cycle limit: MAX_REVIEW_CYCLES (default 6)
- Early exit conditions: BLOCKING=0, STUCK_REVIEW sentinel, HEAD unchanged after Claude pass
- Convergence tracking: cycle 2+ includes prior reviews + git log of Claude commits
- Prescriptive mode: cycle 3+ uses template requiring "Suggested fix:" for BLOCKING
- PR feedback collection: reviews, comments, inline comments (filtered to exclude self-posted)
- Merge behavior: when BLOCKING=0, attempts `gh pr merge --squash --auto`, falls back to immediate merge
- Graceful Codex degradation: if codex CLI not found, skip review cycle (logged)

## What we assume
- [ASSUMPTION] Codex review quality improves with prescriptive mode (cycle 3+). Flips if: prescriptive mode increases false positive rate, requiring mode to be optional or removed.
- [ASSUMPTION] Auto-merge on BLOCKING=0 is safe. Flips if: additional human sign-off is required, needing approval workflow integration.
- [ASSUMPTION] PR feedback filtering (exclude self-posted) is sufficient. Flips if: more sophisticated deduplication is needed (e.g., semantic similarity).
- [ASSUMPTION] Six cycles is adequate convergence budget. Flips if: complex PRs need more cycles, requiring dynamic limit based on PR size.

## Contract

### Request shape (function arguments)
```bash
run_review_cycle <PR_NUMBER>
# PR_NUMBER: integer, must be valid open PR in current repo
```

### Response shape (exit codes)
- **0:** Cycle completed (BLOCKING=0 and merged, or graceful bail with label)
- **2:** Codex MCP transport failure after retries (caller should halt babysitter)

### Invariants
1. **Cycle order:** Codex review → Claude fixes → repeat
2. **Convergence tracking:** Cycle N includes all prior reviews (1..N-1) and commits since cycle start
3. **Prescriptive mode trigger:** Cycle 3+ always uses prescriptive prompt template
4. **BLOCKING counting:** Only bullets under `## BLOCKING` that are not `- (none)` count
5. **PR branch checkout:** Cycle starts by checking out PR branch via `gh pr checkout <PR_NUMBER>`
6. **Label application:** `review-incomplete` for human-action bails, `review-mcp-outage` for Codex transport failures

### Error model
- **Codex MCP transport failure:** Retried by ARLO-FEAT-MCP-RESILIENCE (3× with backoff), if all fail → return 2
- **Codex non-transport failure:** Label PR `review-incomplete`, return 0
- **Claude non-zero exit:** Label PR `review-incomplete`, return 0
- **gh pr checkout failure:** Label PR `review-incomplete`, return 0
- **HEAD unchanged after Claude DONE_REVIEW:** Label PR `review-incomplete` (defensive against "done but no commits"), return 0
- **MAX_REVIEW_CYCLES exhausted:** Label PR `review-incomplete`, return 0
- **STUCK_REVIEW sentinel:** Label PR `review-incomplete`, return 0

### Idempotency
Non-idempotent. Each cycle advances PR branch state (commits pushed). Re-running on same PR resumes from current state, not cycle 1.

### Versioning policy
Function is internal to script; no versioning. Breaking changes (sentinel format, label names) require manual migration.

## Performance budget
- **p50 cycle latency:** ~4 minutes (Codex review ~1min + Claude fixes ~3min)
- **p95 cycle latency:** ~15 minutes (complex diffs, many findings)
- **p99 cycle latency:** ~30 minutes (Codex retry delays + large changesets)
- **Throughput envelope:** 1 cycle per (Codex time + Claude time + git operations) = ~15-60 seconds overhead per cycle
- **Cost per cycle:** ~$1-3 (Codex + Claude inference combined)

## Security model
- **AuthN / AuthZ:** Inherits from gh CLI (`gh auth status`) and Codex CLI (Codex MCP auth)
- **Tenant isolation:** N/A (single-user tool)
- **PII handling:** None (operates on code diffs, commit messages, PR metadata)
- **Rate limits:** Bounded by MAX_REVIEW_CYCLES; Codex/Claude rate limits handled by respective CLIs

## Telemetry contract
- **Events emitted:**
  - `[review] marking PR #N incomplete: <reason>` (via fail_review_cycle)
  - `[review] codex MCP outage for PR #N: <reason>` (via fail_review_cycle_mcp)
  - `[codex] N blocking finding(s)` (per cycle)
  - `[review] zero blocking findings; PR #N cleared after M cycle(s)` (success)
  - `[review] PR #N queued for auto-merge` or `[review] PR #N merged` (merge success)
  - `[codex] template=<descriptive|prescriptive> has_history=<yes|no> cycle=M/N` (mode tracking)
- **Sinks:** Main log file (~/sisyphus-logs/<project>-<timestamp>-<pid>.log)
- **Linkage to L1 KPIs:**
  - Quality KPI: (PRs merged with BLOCKING=0 / total PRs) = quality gate pass rate
  - Productivity KPI: Average cycles-per-PR (lower = better convergence)
  - Reliability KPI: (MCP outage failures / total cycles) = Codex availability
- **AEAB-eligible eval cases:** N/A (no eval framework yet)

## Verifiers
- Tech lead: Chris Robertson
- API council / platform review: N/A (internal function)
- Security: [OPEN: review PR label race conditions, merge auto-approve — owner: security-lead]
- QA: [OPEN: test convergence tracking, prescriptive mode, early exit conditions — owner: qa-lead]

## Failure modes & blast radius
- **Contract violation (malformed Codex review):** BLOCKING count fails, cycle bails with label. Blast: PR needs manual review.
- **Perf regression (Codex/Claude latency spike):** Cycle slows, may hit MAX_REVIEW_CYCLES before converging. Blast: PR labeled incomplete, developer reviews manually.
- **Telemetry loss (gh pr comment failure):** Codex review not posted to PR, Claude still receives it. Blast: PR lacks public review history.
- **False positive (BLOCKING for valid code):** Developer wastes time investigating. Mitigated by prescriptive mode requiring concrete fix.
- **False negative (BLOCKING missed):** Bug merges. Mitigated by human review still required post-merge before production.

# Bounds

## Out of scope
- **Out-of-feature behaviors:**
  - Codex retry logic (handled by ARLO-FEAT-MCP-RESILIENCE)
  - PR creation (handled by outer loop / Claude)
  - State collection for Claude prompt (handled by outer loop)
- **Capacity limits:**
  - MAX_REVIEW_CYCLES hard cap (no dynamic adjustment)
  - Single PR per cycle (no batch review)
- **Adjacent capabilities deferred:**
  - Parallel review (multiple PRs simultaneously)
  - Human-in-the-loop approval (auto-merge on BLOCKING=0)
  - Cross-PR review (e.g., detecting conflicts with other open PRs)

## Assumptions-that-could-flip
- **Codex-only review assumption.** If flipped to multi-reviewer (Codex + CodeRabbit + human): requires aggregation, prioritization, and conflict resolution.
- **Sequential cycle assumption.** If flipped to parallel: requires parallel Codex invocation, which may conflict with Codex CLI limitations.
- **Prescriptive mode at cycle 3 assumption.** If flipped to earlier/later: requires tuning based on empirical convergence data.
- **Auto-merge assumption.** If flipped to approval-required: requires gh workflow approval API integration or manual merge step.

## Composes with / replaces
- **Replaces:** Manual code review loop (open PR → human reviews → implementer fixes → re-review)
- **Composes with:**
  - ARLO-FEAT-OUTER-LOOP (triggered by HANDOFF_REVIEW sentinel)
  - ARLO-FEAT-MCP-RESILIENCE (provides Codex retry with backoff)
  - CodeRabbit / human reviewers (external feedback collected via collect_pr_feedback)

# Signals

## Acceptance tests
1. **Given** PR #123 with BLOCKING issues, **when** review cycle runs, **then** Codex produces markdown review with `## BLOCKING` section, Claude addresses findings, cycle repeats.
2. **Given** Codex returns 0 BLOCKING findings, **when** cycle completes, **then** PR is merged via `gh pr merge --squash [--auto]` and function returns 0.
3. **Given** cycle 3 starts, **when** Codex prompt is assembled, **then** prescriptive template is used (requires "Suggested fix:" for BLOCKING).
4. **Given** Claude outputs `STUCK_REVIEW cannot fix X`, **when** cycle processes response, **then** PR is labeled `review-incomplete` and function returns 0.
5. **Given** Claude outputs `DONE_REVIEW` but HEAD SHA unchanged, **when** cycle checks, **then** PR is labeled `review-incomplete` (defensive against no-op).
6. **Given** MAX_REVIEW_CYCLES=3 exhausted, **when** cycle limit reached, **then** PR is labeled `review-incomplete` and function returns 0.
7. **Given** cycle 2 starts, **when** Codex prompt is assembled, **then** history block includes cycle 1 review and git log of Claude commits.
8. **Given** Codex MCP transport fails 3 times, **when** retry exhausted, **then** PR is labeled `review-mcp-outage` and function returns 2.
9. **Given** Codex CLI not installed, **when** cycle starts, **then** logged message "codex CLI not found; skipping review cycle" and function returns 0 (graceful degradation).
10. **Given** PR has existing CodeRabbit comments, **when** collect_pr_feedback runs, **then** comments are included in Claude prompt (not filtered out).
11. **Given** PR has self-posted Codex review comment, **when** collect_pr_feedback runs, **then** comment is excluded (filtered by "**Codex review" prefix).

## Telemetry events tied to L1 KPIs
- **Cycles per PR** → Productivity KPI (lower = better prompt quality, faster convergence)
- **BLOCKING=0 rate** → Quality KPI (higher = better code quality at merge)
- **review-incomplete rate** → Reliability KPI (lower = fewer stuck cases)
- **review-mcp-outage rate** → Codex availability KPI (lower = more reliable Codex)

## AEAB cases
N/A — no eval framework integration yet.

Future: Could record (PR_NUMBER, cycle_count, BLOCKING_history, outcome) for offline eval of convergence rate.

## Kill criteria
- If prescriptive mode (cycle 3+) increases false positive rate by >20% vs. descriptive mode → revert to descriptive-only or make mode configurable
- If review cycle convergence rate (BLOCKING=0 / total PRs) drops below 50% → halt feature, improve Codex prompt or switch review approach
- If average cycles-per-PR exceeds 4 for >70% of PRs → halt feature, increase MAX_REVIEW_CYCLES or improve prompt quality
- If Codex MCP outage rate exceeds 30% → remove Codex dependency, use alternative review (e.g., CodeRabbit API, Claude self-review)
