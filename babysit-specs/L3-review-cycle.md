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
  Root cause: <why this gap exists> (detailed mode, cycle 3+)
  Architectural context: <how this fits into system> (detailed mode, cycle 3+)
  Impact: <what breaks if not fixed> (detailed mode, cycle 3+)

## RECOMMENDED
- <issue> — <file:line> — <reason>

## INFORMATION
- <issue> — <file:line> — <context>

# Claude review sentinels
DONE_REVIEW                    # addressed findings, ready for next Codex pass
STUCK_REVIEW <reason>          # cannot proceed, bail review cycle

# Claude plan mode (cycle 2+)
claude --plan-mode             # invoked before implementation on cycle 2+
# Plan output includes: steps, order, rationale, dependencies

# Claude commit message format (cycle 2+)
fix(<scope>): <what changed>

Why: <rationale explaining trade-offs, alternatives, constraints>
[Impact: <metric or failure mode addressed>]  # cycle 3+ only

# PR labels applied by cycle
review-incomplete              # human action required (stuck, max cycles, etc.)
review-mcp-outage             # Codex MCP transport failure (auto-retry)

# Cycle state (not exposed, internal to run_review_cycle)
REVIEW_HISTORY=()             # array of prior Codex reviews
review_start_sha              # git SHA at cycle start (for commit tracking)
USE_PLAN_MODE=false           # true for cycle 2+ with BLOCKING issues
USE_DETAILED_EXPLANATIONS=false  # true for cycle 3+
REQUIRE_RESOLUTION_JUSTIFICATION=false  # true for cycle 4+
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

**Proposed enhancements (not yet implemented):**
- **Plan-first on cycle 2+:** Claude uses plan mode to create implementation plan before addressing findings when cycle 2+ has BLOCKING issues
- **Detailed Codex explanations on cycle 3+:** Codex provides deeper reasoning about why each gap exists, architectural context, and impact
- **Solution rationale from Claude:** Claude documents why each fix was implemented the way it was (trade-offs, alternatives considered)

## What we assume
- [ASSUMPTION] Codex review quality improves with prescriptive mode (cycle 3+). Flips if: prescriptive mode increases false positive rate, requiring mode to be optional or removed.
- [ASSUMPTION] Auto-merge on BLOCKING=0 is safe. Flips if: additional human sign-off is required, needing approval workflow integration.
- [ASSUMPTION] PR feedback filtering (exclude self-posted) is sufficient. Flips if: more sophisticated deduplication is needed (e.g., semantic similarity).
- [ASSUMPTION] Six cycles is adequate convergence budget. Flips if: complex PRs need more cycles, requiring dynamic limit based on PR size.
- [ASSUMPTION] Plan-first approach on cycle 2+ improves fix quality and reduces trial-and-error. Flips if: planning overhead exceeds benefit, or plan mode introduces latency that slows convergence.
- [ASSUMPTION] Detailed Codex explanations on cycle 3+ help Claude understand root causes better. Flips if: explanation verbosity confuses Claude or increases false positive rate.
- [ASSUMPTION] Solution rationale from Claude aids future review cycles and human understanding. Flips if: rationale in commit messages is sufficient, or Claude over-explains trivial fixes.

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
3. **Prescriptive mode trigger:** Cycle 3+ always uses prescriptive prompt template with "Suggested fix:" requirement
4. **Plan-first trigger (proposed):** Cycle 2+ with BLOCKING issues invokes Claude in plan mode before implementation
5. **Detailed explanation trigger (proposed):** Cycle 3+ Codex reviews include deeper reasoning and architectural context for each finding
6. **Solution rationale (proposed):** Claude documents implementation rationale for each fix (trade-offs, alternatives, constraints)
7. **Explicit resolution justification (proposed):** Cycle 4+ requires Claude to explicitly justify how each BLOCKING finding was resolved or prove it is invalid with supporting references
8. **BLOCKING counting:** Only bullets under `## BLOCKING` that are not `- (none)` count
9. **PR branch checkout:** Cycle starts by checking out PR branch via `gh pr checkout <PR_NUMBER>`
10. **Label application:** `review-incomplete` for human-action bails, `review-mcp-outage` for Codex transport failures

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

### Enhanced cycle behavior (proposed)

**Cycle 1 (baseline):**
- Codex reviews PR with descriptive template (BLOCKING / RECOMMENDED / INFORMATION)
- Claude addresses findings directly (no plan mode)
- Commits include standard messages ("fix(blocking): handle nil session")

**Cycle 2+ with BLOCKING issues (plan-first):**
- Codex reviews PR with descriptive template + convergence history
- **Claude enters plan mode:** Creates implementation plan using `claude --plan-mode` before making changes
  - Plan includes: what to fix, in what order, why each fix is needed, dependencies between fixes
  - Plan is logged and reviewed before execution begins
- **Claude executes plan:** Implements each plan step sequentially, committing after each
- **Solution rationale:** Each commit message includes "Why: <rationale>" explaining trade-offs and alternatives
  - Example: `fix(blocking): add null check in auth middleware\n\nWhy: Session can be null during logout flow. Considered moving check to caller, but middleware is the right boundary for this validation (single responsibility).`

**Cycle 3+ with BLOCKING issues (prescriptive + detailed explanations):**
- **Codex reviews with prescriptive template:** Requires "Suggested fix:" with concrete code for each BLOCKING finding
- **Codex adds detailed explanations:** For each finding, includes:
  - **Root cause:** Why this gap exists (e.g., "Missing null check introduced in PR #456 when logout flow was refactored")
  - **Architectural context:** How this fits into the larger system (e.g., "Auth middleware is the trust boundary between public routes and protected resources")
  - **Impact:** What breaks if not fixed (e.g., "500 error on logout when session has already expired; affects ~5% of logout attempts per telemetry")
- **Claude plan-first:** Same as cycle 2+ (plan mode before execution)
- **Claude solution rationale:** Enhanced commit messages with deeper context:
  - Example: `fix(blocking): add null check in auth middleware\n\nWhy: Session can be null during logout flow (gap introduced in PR #456 refactor). Auth middleware is trust boundary, so validation belongs here. Considered:\n- Caller-side check: violates single responsibility\n- Optional session type: increases complexity across 12 callsites\n- Middleware null check: single point of enforcement (chosen)\n\nImpact: Prevents 500 errors on ~5% of logout attempts.`

**Cycle 4+ with BLOCKING issues (explicit resolution justification):**
- **All cycle 3+ behaviors continue** (Codex prescriptive + detailed, Claude plan-first, solution rationale)
- **Claude must explicitly address each BLOCKING finding** at end of cycle with one of:
  - **Resolution:** "BLOCKING <finding-description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how the change addresses the root cause and satisfies the architectural constraints identified by Codex>"
  - **Invalid finding:** "BLOCKING <finding-description> is invalid. Reason: <explanation>. Supporting reference: <link to spec, documentation, or validated source material proving the finding is incorrect>"
- **Format:** Added as comment to PR after Claude completes fixes, before DONE_REVIEW sentinel
- **Purpose:** Forces Claude to demonstrate understanding of each finding and its resolution; prevents false "done" claims

**Benefits:**
- **Plan-first (cycle 2+):** Reduces trial-and-error, ensures fixes are applied in correct order, catches cross-finding dependencies
- **Detailed Codex explanations (cycle 3+):** Helps Claude understand *why* issues exist, not just *what* to fix; improves fix quality by surfacing architectural constraints
- **Solution rationale (cycle 2+):** Aids future reviewers (human or AI) in understanding decisions; creates better commit history
- **Explicit resolution justification (cycle 4+):** Forces Claude to prove understanding of each finding; prevents false convergence claims; creates audit trail of why findings were resolved or rejected

**Costs:**
- **Plan mode latency:** +30-60 seconds per cycle 2+ (plan creation time)
- **Detailed explanations:** +10-20% Codex inference time (more tokens in/out)
- **Rationale overhead:** +10-15% Claude time (composing explanations)
- **Resolution justification overhead:** +15-30 seconds per cycle 4+ (posting PR comment via gh CLI)
- **Total impact:** Cycle 2+ takes ~5-6 minutes (vs. 4 minutes baseline); Cycle 3+ takes ~6-7 minutes; Cycle 4+ takes ~7-8 minutes

## Performance budget

**Current implementation (baseline):**
- **p50 cycle latency:** ~4 minutes (Codex review ~1min + Claude fixes ~3min)
- **p95 cycle latency:** ~15 minutes (complex diffs, many findings)
- **p99 cycle latency:** ~30 minutes (Codex retry delays + large changesets)
- **Throughput envelope:** 1 cycle per (Codex time + Claude time + git operations) = ~15-60 seconds overhead per cycle
- **Cost per cycle:** ~$1-3 (Codex + Claude inference combined)

**Proposed enhanced implementation:**
- **p50 cycle latency:**
  - Cycle 1: ~4 minutes (unchanged)
  - Cycle 2+: ~5-6 minutes (+plan mode: 30-60s)
  - Cycle 3+: ~6-7 minutes (+detailed explanations: 10-20% Codex time)
  - Cycle 4+: ~7-8 minutes (+resolution justification: 15-30s for PR comment)
- **p95 cycle latency:** ~20-22 minutes (plan mode + detailed explanations + resolution justification + complex diffs)
- **p99 cycle latency:** ~40 minutes (retries + plan mode + explanations + justification)
- **Cost per cycle:**
  - Cycle 1: ~$1-3 (unchanged)
  - Cycle 2+: ~$1.50-4 (+plan mode tokens)
  - Cycle 3+: ~$2-5 (+detailed explanation tokens)
  - Cycle 4+: ~$2.50-5.50 (+resolution justification tokens)

## Security model
- **AuthN / AuthZ:** Inherits from gh CLI (`gh auth status`) and Codex CLI (Codex MCP auth)
- **Tenant isolation:** N/A (single-user tool)
- **PII handling:** None (operates on code diffs, commit messages, PR metadata)
- **Rate limits:** Bounded by MAX_REVIEW_CYCLES; Codex/Claude rate limits handled by respective CLIs

## Prompt templates (proposed enhancements)

### Codex detailed review template (cycle 3+)
```markdown
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Previous cycles have not yet resolved all BLOCKING issues.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

__HISTORY_BLOCK__

Output your review using EXACTLY this format:

## BLOCKING
- <one-line description> — <file:line> — <why it must be fixed before merge>
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

Format rules:
- Each BLOCKING bullet requires four parts: description, suggested fix, root cause, architectural context, impact.
- If you cannot produce all four parts for a BLOCKING finding, downgrade to RECOMMENDED.
- RECOMMENDED and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
```

### Claude plan-first review template (cycle 2-3)
```markdown
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
  - Commit each fix separately with structured message format:
    ```
    fix(<scope>): <what changed>
    
    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    __IMPACT_BLOCK__
    ```
  - Push commits to PR branch when batch complete

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
```

**Template variable substitutions (cycle 3+):**
- `__IMPACT_BLOCK__` is replaced with:
  ```
  Impact: <failure mode addressed> — <metrics or observability>
  ```

### Claude plan-first review template (cycle 4+)
```markdown
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
  - Commit each fix separately with structured message format:
    ```
    fix(<scope>): <what changed>
    
    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed> — <metrics or observability>
    ```
  - Push commits to PR branch when batch complete

Step 3: Post resolution justification as PR comment:
  For EACH BLOCKING finding in the Codex review, you must post a comment explaining:
  - **If resolved:** "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by Codex and satisfies the architectural constraints>"
  - **If invalid:** "BLOCKING <one-line finding description> is invalid. Reason: <explanation>. Supporting reference: <link to spec/docs/validated source proving the finding is incorrect>"
  
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
```

## Telemetry contract

**Current events:**
- `[review] marking PR #N incomplete: <reason>` (via fail_review_cycle)
- `[review] codex MCP outage for PR #N: <reason>` (via fail_review_cycle_mcp)
- `[codex] N blocking finding(s)` (per cycle)
- `[review] zero blocking findings; PR #N cleared after M cycle(s)` (success)
- `[review] PR #N queued for auto-merge` or `[review] PR #N merged` (merge success)
- `[codex] template=<descriptive|prescriptive> has_history=<yes|no> cycle=M/N` (mode tracking)

**Proposed additional events (for enhanced implementation):**
- `[claude] entering plan mode for PR #N cycle M` (before plan creation)
- `[claude] plan approved, executing N steps` (after plan creation, before implementation)
- `[claude] plan step M/N: <step description>` (during plan execution)
- `[codex] detailed explanations enabled (cycle 3+)` (mode tracking)
- `[claude] commit with rationale: <commit SHA>` (after each commit with Why: block)
- `[claude] posting resolution justifications for N BLOCKING findings (cycle 4+)` (before posting PR comment)
- `[claude] resolution justifications posted to PR #N` (after gh pr comment succeeds)

**Sinks:** Main log file (~/sisyphus-logs/<project>-<timestamp>-<pid>.log)

**Linkage to L1 KPIs:**
- Quality KPI: (PRs merged with BLOCKING=0 / total PRs) = quality gate pass rate
- Productivity KPI: Average cycles-per-PR (lower = better convergence)
- Reliability KPI: (MCP outage failures / total cycles) = Codex availability
- **Proposed:** Plan effectiveness KPI: (PRs converging in cycle 2 with plan / PRs converging in cycle 2 without plan)
- **Proposed:** Explanation value KPI: (cycle 3+ fix accuracy / cycle 1-2 fix accuracy) — measures if detailed explanations improve fixes

**AEAB-eligible eval cases:** N/A (no eval framework yet)

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
- **Plan-first at cycle 2 assumption (proposed).** If flipped to cycle 3+ only or disabled: requires A/B testing to measure plan mode impact on convergence rate.
- **Detailed explanations at cycle 3 assumption (proposed).** If flipped to earlier cycles or all cycles: requires cost/benefit analysis (token usage vs. fix quality improvement).
- **Solution rationale in commits assumption (proposed).** If flipped to separate doc or PR description: requires alternative mechanism for preserving decision context.
- **Resolution justification at cycle 4 assumption (proposed).** If flipped to earlier/later or disabled: requires empirical testing of false convergence rate (Claude claiming DONE_REVIEW without actually resolving findings).

## Composes with / replaces
- **Replaces:** Manual code review loop (open PR → human reviews → implementer fixes → re-review)
- **Composes with:**
  - ARLO-FEAT-OUTER-LOOP (triggered by HANDOFF_REVIEW sentinel)
  - ARLO-FEAT-MCP-RESILIENCE (provides Codex retry with backoff)
  - CodeRabbit / human reviewers (external feedback collected via collect_pr_feedback)

# Signals

## Acceptance tests

**Current implementation (baseline):**
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

**Proposed enhancement tests:**
12. **Given** cycle 2 starts with BLOCKING issues, **when** Claude is invoked, **then** log shows "[claude] entering plan mode for PR #N cycle 2" before implementation begins.
13. **Given** cycle 2+ plan mode completes, **when** Claude executes plan, **then** log shows "[claude] plan approved, executing N steps" and each step is logged.
14. **Given** cycle 2+ with plan execution, **when** Claude commits a fix, **then** commit message includes "Why: <rationale>" explaining trade-offs and alternatives.
15. **Given** cycle 3 starts, **when** Codex prompt is assembled, **then** prescriptive template includes "Root cause:", "Architectural context:", and "Impact:" fields for each BLOCKING finding.
16. **Given** cycle 3+ Codex review with detailed explanations, **when** Claude reads review, **then** Claude can reference root cause and architectural context in its fix rationale.
17. **Given** cycle 3+ with detailed explanations, **when** Claude commits a fix, **then** commit message includes "Impact: <failure mode addressed>" in addition to "Why:" rationale.
18. **Given** cycle 2+ plan identifies fix dependencies, **when** plan is executed, **then** fixes are applied in the order specified by plan (not Codex review order).
19. **Given** cycle 3+ with prescriptive mode and detailed explanations, **when** Codex cannot provide all required fields for a finding, **then** finding is downgraded to RECOMMENDED (per template rules).
20. **Given** cycle 4 completes with BLOCKING findings addressed, **when** Claude finishes Step 3, **then** PR has comment with resolution justification for each BLOCKING finding (format: "BLOCKING <desc> resolved in commit <SHA>. Why this resolves it: <explanation>").
21. **Given** cycle 4+ with invalid BLOCKING finding, **when** Claude justifies findings, **then** PR comment includes "BLOCKING <desc> is invalid. Reason: <explanation>. Supporting reference: <link>" with valid external reference.
22. **Given** cycle 4+ completes, **when** DONE_REVIEW sentinel is output, **then** all BLOCKING findings from Codex review have corresponding resolution justifications posted to PR (verified via `gh pr view`).

## Telemetry events tied to L1 KPIs
- **Cycles per PR** → Productivity KPI (lower = better prompt quality, faster convergence)
- **BLOCKING=0 rate** → Quality KPI (higher = better code quality at merge)
- **review-incomplete rate** → Reliability KPI (lower = fewer stuck cases)
- **review-mcp-outage rate** → Codex availability KPI (lower = more reliable Codex)

## AEAB cases
N/A — no eval framework integration yet.

Future: Could record (PR_NUMBER, cycle_count, BLOCKING_history, outcome) for offline eval of convergence rate.

## Kill criteria

**Current implementation:**
- If prescriptive mode (cycle 3+) increases false positive rate by >20% vs. descriptive mode → revert to descriptive-only or make mode configurable
- If review cycle convergence rate (BLOCKING=0 / total PRs) drops below 50% → halt feature, improve Codex prompt or switch review approach
- If average cycles-per-PR exceeds 4 for >70% of PRs → halt feature, increase MAX_REVIEW_CYCLES or improve prompt quality
- If Codex MCP outage rate exceeds 30% → remove Codex dependency, use alternative review (e.g., CodeRabbit API, Claude self-review)

**Proposed enhancements:**
- If plan-first mode (cycle 2+) does NOT reduce cycles-per-PR by >15% vs. baseline → disable plan mode, too much overhead for insufficient benefit
- If plan mode latency exceeds 2 minutes on >50% of cycles → optimize plan prompt or make plan mode optional
- If detailed explanations (cycle 3+) do NOT improve fix accuracy by >10% vs. cycle 1-2 → disable detailed mode, explanation verbosity not helping
- If solution rationale bloats commit messages by >3× average length with no measurable review benefit → shorten rationale template or move to PR description
- If resolution justifications (cycle 4+) do NOT reduce false convergence rate (PRs re-opened due to unresolved BLOCKING) by >20% → remove Step 3, justification overhead not worth benefit
- If cycle 4+ with all enhancements takes >12 minutes on >70% of PRs → reduce enhancement scope or make enhancements opt-in per PR
