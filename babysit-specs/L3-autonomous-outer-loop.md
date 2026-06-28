---
spec_type: feature
id: ARLO-FEAT-OUTER-LOOP
status: review
owners: [Chris Robertson]
depends_on: [ARLO-SYS-AUTONOMOUS-DEV]
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
Iterative loop that collects project state (PRs, issues, specs), invokes Claude with context, detects sentinels in responses, and sleeps between iterations until work completes or limits are reached.

## Analog
Like a cron job or systemd timer that periodically polls for work, but instead of fixed intervals, runs continuously with configurable sleep between iterations and responds to explicit stop signals.

## Reader & next action
Implementing engineer: understand the iteration lifecycle, sentinel protocol, and stuck detection logic. QA: verify iteration limits, stuck detection, and graceful termination.

## API surface fragment
```bash
# Entry point
MAX_ITER=50 SLEEP_SEC=10 STUCK_N=3 babysit-with-review.sh

# Sentinels (output by Claude in final message)
HANDOFF_REVIEW 123        # triggers review cycle for PR #123
STOP                      # terminates outer loop
(no sentinel)             # continues to next iteration

# Lock file protocol
~/sisyphus-logs/<project>.stop  # presence = allow run, absence = halt

# Log output
~/sisyphus-logs/<project>-<timestamp>-<pid>.log
```

## Consumer
Developer invoking babysit-with-review.sh from project root directory.

# Substance

## What we know
From implementation (babysit-with-review.sh lines 63-906):
- Loop runs from iter=1 to MAX_ITER (default 50)
- Each iteration: collect_state() → run_claude() → detect sentinel → stuck check → sleep
- Lock file check at start of each iteration; loop exits if file removed
- SHA256 hash of Claude's result tracked for stuck detection
- Temp files: TMP_RESULT (Claude output), TMP_REVIEW (Codex review), TMP_REVIEW_RESULT (Claude review response)
- Pre-flight checks (lines 708-803) ensure clean git state before first iteration

## What we assume
- [ASSUMPTION] Developer manually monitors log file during run. Flips if: real-time progress UI needed, requiring terminal display or web dashboard.
- [ASSUMPTION] Single project context per invocation. Flips if: multi-project orchestration needed, requiring workspace management and context switching.
- [ASSUMPTION] Sleep-based iteration pacing is acceptable. Flips if: event-driven (webhook-triggered) iteration is needed, requiring HTTP server or message queue.

## Contract

### Request shape (environment variables)
```bash
MAX_ITER=<int>          # default 50, max iterations before halt
SLEEP_SEC=<int>         # default 10, seconds between iterations
STUCK_N=<int>           # default 3, identical results before declaring stuck
MAX_REVIEW_CYCLES=<int> # default 6, max review cycles per PR (used by review feature)
```

### Response shape (exit codes)
- **0:** Loop completed normally (STOP sentinel or MAX_ITER reached)
- **1:** Pre-flight check failed, lock file collision, or fatal error
- **Exit via SIGTERM:** Graceful - lock file removed by trap

### Invariants
1. **Lock file semantics:** File exists → iteration allowed, file absent → halt at next check
2. **Iteration ordering:** Iterations execute sequentially (i=1, 2, ..., N)
3. **State collection before invocation:** collect_state() always runs before Claude invocation
4. **Sentinel detection after invocation:** Last line of trimmed Claude output determines next action
5. **Stuck detection after N iterations:** If last STUCK_N hashes are identical, halt

### Error model
- **Pre-flight failure:** Exit 1 with corrective instructions (unstaged changes, diverged branch, etc.)
- **Lock file collision:** Exit 1 with instructions to check for running process or remove stale lock
- **Claude non-zero exit:** Log error, break outer loop, exit 0 (iteration reached, not a fatal error)
- **MAX_ITER exhausted:** Log "Hit MAX_ITER", break loop, exit 0
- **Stuck loop detected:** Log "Stuck: last N results identical", break loop, exit 0

### Idempotency
Non-idempotent. Each iteration advances git state (commits, PRs). Re-running after halt resumes from current git state, not from start.

### Versioning policy
Script is unversioned; updates are in-place edits. Breaking changes (env var renames, sentinel format changes) require manual migration by user.

## Performance budget
- **p50 iteration latency:** ~2 minutes (dominated by Claude inference)
- **p95 iteration latency:** ~10 minutes (complex tasks, tool-heavy responses)
- **p99 iteration latency:** ~20 minutes (worst-case: many tool calls, long diffs)
- **Throughput envelope:** 1 iteration per (SLEEP_SEC + latency) = ~3-30 iterations/hour
- **Cost per iteration:** ~$0.50-2.00 (Anthropic API cost via Claude Code CLI OAuth)

## Security model
- **AuthN / AuthZ:** Inherits from gh CLI authentication (`gh auth status`)
- **Tenant isolation:** N/A (single-user tool)
- **PII handling:** None (operates on code, not user data)
- **Rate limits:** No explicit rate limits; bounded by MAX_ITER and developer's Anthropic API quota

## Telemetry contract
- **Events emitted:**
  - Log line per iteration: `=== iter N @ <timestamp> ===`
  - Sentinel detection: logged with iteration number
  - Stuck detection: logged with SHA256 hashes
  - Lock file removal: logged before halt
- **Sinks:** File at ~/sisyphus-logs/<project>-<timestamp>-<pid>.log
- **Linkage to L1 KPIs:**
  - Time-to-value: Time from first iteration to first successful PR merge
  - Productivity: (iterations completed / MAX_ITER) = utilization rate
  - Quality: (iterations with STOP sentinel / total iterations) = completion rate
- **AEAB-eligible eval cases:** N/A (no eval framework integration yet)

## Verifiers
- Tech lead: Chris Robertson
- API council / platform review: N/A (internal tool, no public API)
- Security: [OPEN: security review for lock file race conditions — owner: security-lead]
- QA: [OPEN: test cases for pre-flight, stuck detection, sentinel parsing — owner: qa-lead]

## Failure modes & blast radius
- **Contract violation (malformed sentinel):** Sentinel not detected, loop continues to next iteration. Blast: wasted iteration, developer notices in log.
- **Perf regression (iteration latency spike):** Loop slows but does not halt. Blast: developer waits longer for completion.
- **Telemetry loss (log write failure):** Logged output lost, but iteration continues. Blast: debugging harder if issue occurs.
- **Lock file race condition:** Two processes start simultaneously before lock file created. Blast: both run until one detects collision, then both halt. Rare due to PID in log filename.

# Bounds

## Out of scope
- **Out-of-feature behaviors:**
  - Review cycle orchestration (handled by separate L3 feature)
  - Pre-flight validation (handled by orchestrator, not exposed as API)
  - State collection helpers (prs, issues, specs are external)
- **Capacity limits:**
  - MAX_ITER hard cap (no dynamic adjustment)
  - Single project per invocation (no workspace management)
- **Adjacent capabilities deferred:**
  - Parallel iteration (multiple PRs in flight)
  - Event-driven iteration (webhook triggers)
  - Remote execution (CI/cloud deployment)

## Assumptions-that-could-flip
- **Sequential iteration assumption.** If flipped to parallel: requires process pool, shared state management, and conflict resolution.
- **File-based lock assumption.** If flipped to distributed lock: requires lock service (Redis, etcd) for multi-host coordination.
- **Sleep-based pacing assumption.** If flipped to backoff/adaptive: requires latency tracking and dynamic sleep calculation.
- **Bash stdout logging assumption.** If flipped to structured logging: requires log aggregation service and JSON/structured output.

## Composes with / replaces
- **Replaces:** Manual loop of (think about task → write code → commit → review)
- **Composes with:**
  - ARLO-FEAT-REVIEW-CYCLE (triggered by HANDOFF_REVIEW sentinel)
  - ARLO-FEAT-MCP-RESILIENCE (provides Codex retry logic for review cycle)
  - Helper scripts (prs, issues, specs for state collection)

# Signals

## Acceptance tests
1. **Given** a clean git repo on default branch, **when** babysit-with-review.sh runs with MAX_ITER=1, **then** exactly 1 iteration executes and loop exits with code 0.
2. **Given** unstaged changes in working tree, **when** babysit-with-review.sh starts, **then** pre-flight check fails with corrective instructions and exit code 1.
3. **Given** lock file ~/sisyphus-logs/<project>.stop exists, **when** babysit-with-review.sh runs, **then** first iteration executes normally.
4. **Given** lock file is removed mid-run, **when** next iteration checks, **then** loop exits gracefully with log message.
5. **Given** Claude outputs `STOP` sentinel, **when** iteration completes, **then** loop exits with code 0 and log shows "STOP signal received".
6. **Given** Claude outputs `HANDOFF_REVIEW 123`, **when** iteration completes, **then** review cycle runs before next iteration.
7. **Given** Claude outputs identical result for STUCK_N consecutive iterations, **when** stuck detection runs, **then** loop halts with "Stuck" message.
8. **Given** MAX_ITER=5, **when** 5 iterations complete without STOP, **then** loop exits with "Hit MAX_ITER" message.

## Telemetry events tied to L1 KPIs
- **Iteration count** → Time-to-value KPI (fewer iterations = faster value delivery)
- **STOP sentinel rate** → Completion rate KPI (higher STOP rate = more tasks completed)
- **Stuck detection rate** → Quality KPI (lower stuck rate = better prompt quality)
- **Claude non-zero exit rate** → Reliability KPI (lower failure rate = more stable)

## AEAB cases
N/A — no eval framework integration in current implementation.

Future: Could record (prompt, iteration_count, outcome) tuples for offline eval.

## Kill criteria
- If stuck detection rate exceeds 30% of runs → halt feature, improve prompt or add dynamic prompt adaptation
- If iteration latency p95 exceeds 30 minutes → halt feature, optimize prompt length or switch to faster model
- If pre-flight failure rate exceeds 50% of run attempts → improve pre-flight UX or auto-fix common issues
