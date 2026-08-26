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
Iterative loop that collects project state (PRs, issues, specs), creates a git worktree for each iteration, invokes the selected implementer with context, detects sentinels in responses, and sleeps between iterations until work completes or limits are reached. Uses `run_implementer` as the provider-neutral dispatch point (Claude or Codex).

## Analog
Like a cron job or systemd timer that periodically polls for work, but instead of fixed intervals, runs continuously with configurable sleep between iterations and responds to explicit stop signals.

## Reader & next action
Implementing engineer: understand the iteration lifecycle, sentinel protocol, and stuck detection logic. QA: verify iteration limits, stuck detection, and graceful termination.

## API surface fragment
```bash
# Entry point (with selectable implementer/reviewer harnesses)
MAX_ITER=50 SLEEP_SEC=10 STUCK_N=3 babysit-with-review.sh \
  [--implementer claude|codex] [--implementer-model MODEL] [--implementer-effort LEVEL] \
  [--reviewer claude|codex] [--reviewer-model MODEL] [--reviewer-effort LEVEL] \
  [--repo-base PATH] [--version] PROJECT [GOAL_DESCRIPTION]

# Also accepts REPO_BASE env var; autodetects ~/repos then ~/repo if neither set.
# All switches accept both --name value and --name=value forms.
# Invalid harness value or missing option value: exit 2 before any side effects.

# Sentinels (output by implementer in final message — trimmed last line)
HANDOFF_REVIEW 123        # triggers review cycle for PR #123
STOP                      # terminates outer loop
(no sentinel)             # continues to next iteration

# Lock file protocol
~/sisyphus-logs/<project>.stop  # absent = allow run, creation = halt next iteration
# A pre-existing stop file is a collision: exit 1. Script creates the file itself.
# Removing the file mid-run is the graceful stop mechanism.

# Per-iteration git worktree
git worktree add -b wip/<project>/iter-N <path>  # created before implementer
# Implementer's first action: git branch -m <type>/<slug>-<issue>
# Worktree is removed (git worktree remove --force + git branch -D) BEFORE sentinel handling

# Log output
~/sisyphus-logs/<project>-<timestamp>-<pid>.log
```

## Consumer
Developer invoking babysit-with-review.sh from project root directory.

# Substance

## What we know
From implementation (babysit-with-review.sh):
- Script version: `VERSION="1.1.0"` (accessible via `--version`)
- Loop runs from iter=1 to MAX_ITER (default 50)
- Each iteration: MCP-outage retry check → `git worktree add` → collect_state() → `run_implementer` → worktree teardown → detect sentinel → stuck check → sleep
- `run_implementer` dispatches to `run_claude` (default) or `run_codex_implementer` based on `$IMPLEMENTER`
- Lock file check at start of each iteration; loop exits if file absent
- SHA256 hash of implementer's result tracked for stuck detection
- Temp files: `TMP_RESULT` (implementer output), `TMP_REVIEW` (reviewer output), `TMP_REVIEW_RESULT` (implementer review response), `TMP_CODEX_FULL` (full codex output for telltale scanning)
- Pre-flight checks (`reviewer_binary_available`, `reviewer_preflight`, git state) ensure clean state before first iteration; `git worktree prune` runs at pre-flight
- **Per-iteration worktree:** `git worktree add -b wip/<project>/iter-N` before each implementer invocation. The implementer's first instruction is `git branch -m <type>/<slug>-<issue>` to rename the branch. Any unpushed commits are pushed to origin as a safety net before the worktree is discarded. Worktree is removed (`worktree remove --force` + `branch -D`) *before* sentinel handling so `gh pr checkout` in `run_review_cycle` does not conflict.
- **MCP-outage pre-iteration retry:** At the top of each outer-loop iteration, if the current PR is labelled `review-mcp-outage`, `run_review_cycle` is retried immediately (up to the outer loop's normal iteration budget). This is distinct from the intra-retry in ARLO-FEAT-MCP-RESILIENCE.
- **Crash-quarantine sweep:** On implementer non-zero exit, any WIP commits are pushed to origin, the worktree is torn down, then every open non-draft PR assigned to `@me` that lacks a `review-*` label is quarantined via `fail_review_cycle` (labeled `review-incomplete`, marked draft).
- Helper scripts resolve via `SCRIPTS_DIR="$REPO_BASE/scripts"`. `REPO_BASE` precedence: `--repo-base` flag > `REPO_BASE` env var > autodetect `~/repos` (if exists) then `~/repo`.

## What we assume
- [ASSUMPTION] Developer manually monitors log file during run. Flips if: real-time progress UI needed, requiring terminal display or web dashboard.
- [ASSUMPTION] Single project context per invocation. Flips if: multi-project orchestration needed, requiring workspace management and context switching.
- [ASSUMPTION] Sleep-based iteration pacing is acceptable. Flips if: event-driven (webhook-triggered) iteration is needed, requiring HTTP server or message queue.

## Contract

### Request shape (environment variables + CLI flags)
```bash
# Environment variables
MAX_ITER=<int>          # default 50, max iterations before halt
SLEEP_SEC=<int>         # default 10, seconds between iterations
STUCK_N=<int>           # default 3, identical results before declaring stuck
MAX_REVIEW_CYCLES=<int> # default 6, max review cycles per PR (used by review feature)
REPO_BASE=<path>        # override helper-script base path (also via --repo-base)

# CLI flags (all accept --flag value and --flag=value)
--implementer claude|codex    # default: claude
--implementer-model MODEL     # pass to implementer CLI (omit = use CLI default)
--implementer-effort LEVEL    # pass to implementer CLI
--reviewer claude|codex       # default: codex
--reviewer-model MODEL        # pass to reviewer CLI
--reviewer-effort LEVEL       # pass to reviewer CLI
--repo-base PATH              # override REPO_BASE
--version                     # print version and exit 0
```

### Response shape (exit codes)
- **0:** Loop completed normally (STOP sentinel, MAX_ITER reached, stuck, or implementer non-zero exit)
- **1:** Pre-flight check failed, lock file collision, or `fail_review_cycle*` gh command failed
- **2:** Invalid CLI argument (unknown flag, missing option value, invalid harness value) — exits before any side effects
- **Exit via stop file removal:** Graceful — lock file absent at next iteration check

### Invariants
1. **Lock file semantics:** Stop file *absent* (or just deleted) → halt at next iteration check. A *pre-existing* stop file at start-up is a collision → `exit 1`. The script creates the file itself on startup and removes it via EXIT trap.
2. **Iteration ordering:** Iterations execute sequentially (i=1, 2, ..., N)
3. **Worktree-before-collect:** `git worktree add` runs before `collect_state()`, which in turn runs before the implementer invocation
4. **Worktree-before-sentinel:** Worktree teardown completes *before* sentinel handling (so `gh pr checkout` in `run_review_cycle` finds no conflicting checkout)
5. **Sentinel detection after invocation:** Last line of trimmed implementer output determines next action
6. **Stuck detection after N iterations:** If last STUCK_N hashes are identical, halt

### Error model
- **Invalid CLI argument:** Exit 2 with usage message (before lock file created, before log opened)
- **Pre-flight failure:** Exit 1 with corrective instructions (unstaged changes, diverged branch, etc.)
- **Lock file collision (pre-existing stop file):** Exit 1 with instructions to check for running process
- **Stop file removed mid-run:** Log message, break loop, exit 0
- **Implementer non-zero exit:** Push any WIP commits, tear down worktree, run crash-quarantine sweep, break outer loop, exit 0
- **MAX_ITER exhausted:** Log "Hit MAX_ITER", break loop, exit 0
- **Stuck loop detected:** Log "Stuck: last N results identical", break loop, exit 0
- **MCP-outage PR at top of iteration:** Retry `run_review_cycle` immediately; if it returns non-zero again, fall through to sentinel/stuck handling as normal

### Idempotency
Non-idempotent. Each iteration advances git state (commits, PRs). Re-running after halt resumes from current git state, not from start.

### Versioning policy
Script version: `1.1.0` (semver, `--version` flag). Breaking changes (env var renames, sentinel format changes) require manual migration by user.

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
- Security: lock file race condition accepted for single-user scenario (TOCTOU window negligible; blast radius: both processes halt gracefully). See SECURITY-REVIEW-PLAN.md §1.
- QA: Test cases documented in QA-TEST-PLAN.md (TC-1.*). Test harness exists: `BABYSIT_TEST_MODE` + `test-babysit-with-review-cli.sh`.

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
3. **Given** a pre-existing stop file `~/sisyphus-logs/<project>.stop` exists before start-up, **when** babysit-with-review.sh runs, **then** exit 1 (collision — the script requires creating the lock file itself).
3b. **Given** no pre-existing stop file, **when** babysit-with-review.sh starts, **then** the script creates the stop file and the first iteration executes normally.
4. **Given** stop file is removed mid-run, **when** next iteration checks, **then** loop exits gracefully with log message.
5. **Given** implementer outputs `STOP` sentinel, **when** iteration completes, **then** loop exits with code 0 and log shows "STOP signal received".
6. **Given** implementer outputs `HANDOFF_REVIEW 123`, **when** iteration completes, **then** review cycle runs before next iteration.
7. **Given** implementer outputs identical result for STUCK_N consecutive iterations, **when** stuck detection runs, **then** loop halts with "Stuck" message.
8. **Given** MAX_ITER=5, **when** 5 iterations complete without STOP, **then** loop exits with "Hit MAX_ITER" message.
9. **Given** each outer iteration runs, **when** implementer is invoked, **then** a `wip/<project>/iter-N` worktree was created before the invocation and is removed (along with its branch) before sentinel handling.
10. **Given** `--unknown-flag` is passed, **when** babysit-with-review.sh starts, **then** exit 2 with usage message (before lock file created).
11. **Given** implementer exits non-zero, **when** crash-quarantine sweep runs, **then** all open non-draft `@me` PRs lacking a `review-*` label are labeled `review-incomplete` and marked draft.

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
