---
spec_type: feature
id: ARLO-FEAT-MCP-RESILIENCE
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
Retry-with-backoff wrapper for Codex CLI invocations that detects MCP transport failures via telltale strings, retries up to 3 times with increasing delays (0 / 60s / 300s), and returns failure code if all retries exhausted.

## Analog
Like HTTP client retry logic with exponential backoff (e.g., AWS SDK retries), but for CLI subprocess invocations with regex-based failure detection instead of status codes.

## Reader & next action
Implementing engineer: understand telltale regex patterns, retry loop mechanics, and return code contract. QA: verify backoff delays, telltale detection accuracy, and retry count limits.

## API surface fragment
```bash
# Function signature (internal to babysit-with-review.sh)
codex_review_with_retry <codex_prompt>

# Uses global temp files (caller must initialize)
TMP_REVIEW=""           # caller zeros before call, function populates
TMP_CODEX_FULL=""       # function zeros on each attempt, logs full output

# Return codes
0  # success - Codex completed, TMP_REVIEW is non-empty
1  # non-transport failure (prompt issue, crash, etc.)
2  # MCP transport failure - all 3 retries exhausted

# Telltale regex (detects MCP transport failure in stderr/stdout)
mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'
```

## Consumer
Review cycle feature (ARLO-FEAT-REVIEW-CYCLE) invoking codex_review_with_retry() function.

# Substance

## What we know
From implementation (babysit-with-review.sh lines 480-515):
- Fixed retry policy: 3 attempts with delays [0, 60, 300] seconds
- Telltale detection: 3 regex patterns matching known MCP transport errors
- Success criteria: exit code 0 AND non-empty TMP_REVIEW file
- Failure classification: MCP (telltale match) vs. non-MCP (no match)
- Logging: All codex output teed to both LOG and TMP_CODEX_FULL for telltale scanning
- Early success: If attempt N succeeds, no further attempts made

## What we assume
- [ASSUMPTION] MCP transport failures are transient (retry helps). Flips if: failures are persistent (e.g., Codex account suspended), requiring non-retry error path.
- [ASSUMPTION] Three retries with 0/60s/300s delays is optimal. Flips if: empirical data shows different delay schedule is better (e.g., 0/30s/120s).
- [ASSUMPTION] Telltale regex patterns cover all MCP transport failures. Flips if: new error messages appear, requiring regex update or alternative detection.
- [ASSUMPTION] Non-empty TMP_REVIEW indicates success. Flips if: Codex can exit 0 with empty output on valid input, requiring richer success detection.

## Contract

### Request shape (function arguments)
```bash
codex_review_with_retry "<codex_prompt>"
# codex_prompt: string, Codex exec prompt (markdown format expected)
```

### Response shape (return codes + side effects)
```bash
# Return codes
0   # Codex completed successfully; TMP_REVIEW populated with review markdown
1   # Codex failed (non-transport); TMP_REVIEW may be empty or partial
2   # MCP transport failure; all retries exhausted; TMP_REVIEW empty

# Side effects
# - TMP_REVIEW: populated on success (0), empty or partial on failure (1, 2)
# - TMP_CODEX_FULL: last attempt's full output (for telltale scanning)
# - LOG: retry messages logged ("waiting Ns before retry (attempt M of 3)")
```

### Invariants
1. **Retry count:** Exactly 3 attempts (no more, no less)
2. **Delay schedule:** Attempt 1 = 0s, attempt 2 = 60s, attempt 3 = 300s (fixed, not configurable)
3. **Early exit:** If attempt N succeeds (rc=0 and TMP_REVIEW non-empty), return 0 immediately (no further attempts)
4. **Telltale-only return 2:** Return code 2 is reserved for MCP transport failures (telltale match); non-MCP failures return 1
5. **TMP file zeroing:** Each attempt zeros TMP_REVIEW and TMP_CODEX_FULL before invoking codex

### Error model
- **Codex exit code 0, TMP_REVIEW non-empty:** Success, return 0
- **Codex exit code 0, TMP_REVIEW empty:** Treat as failure, check telltale
- **Codex exit code non-zero, telltale match:** MCP transport failure, retry (or return 2 if last attempt)
- **Codex exit code non-zero, no telltale match:** Non-transport failure, return 1 (no retry)
- **All 3 attempts fail with telltale match:** Return 2

### Idempotency
Idempotent on success (same prompt → same review). Non-idempotent on transient failure (retry N may succeed after retry N-1 failed).

### Versioning policy
Function is internal to script; no versioning. Breaking changes (retry count, delay schedule, telltale regex) require in-place edit.

## Performance budget
- **p50 latency (success on attempt 1):** ~1 minute (Codex review time)
- **p95 latency (success on attempt 2):** ~2 minutes (60s delay + Codex retry)
- **p99 latency (success on attempt 3):** ~7 minutes (60s + 300s delays + Codex retries)
- **Worst case (all failures):** ~6 minutes (0 + 60 + 300 = 360s of delays, plus 3× Codex attempts)
- **Throughput envelope:** 1 review per (1-7 minutes) depending on retry count
- **Cost per call:** $0.50-1.50 (Codex inference) × (1-3 attempts) = $0.50-4.50

## Security model
- **AuthN / AuthZ:** Inherits from Codex CLI (Codex MCP auth)
- **Tenant isolation:** N/A (single-user tool)
- **PII handling:** None (Codex prompt contains code diffs, no user data)
- **Rate limits:** No explicit rate limits; bounded by retry count (max 3 Codex calls per function call)

## Telemetry contract
- **Events emitted:**
  - `[codex] waiting Ns before retry (attempt M of 3)...` (on retry, N = delay in seconds)
  - `[codex] MCP transport failure on attempt M of 3 (rc=N, review=<present|empty>)` (on telltale match)
  - `[codex] reviewing PR #N...` (on each attempt, logged by caller before invoking function)
- **Sinks:** Main log file (~/sisyphus-logs/<project>-<timestamp>-<pid>.log)
- **Linkage to L1 KPIs:**
  - Reliability KPI: (MCP transport failures / total Codex calls) = Codex availability
  - Productivity KPI: Average retries-per-call (lower = better Codex reliability)
- **AEAB-eligible eval cases:** N/A (no eval framework yet)

## Verifiers
- Tech lead: Chris Robertson
- API council / platform review: N/A (internal function)
- Security: [OPEN: review telltale regex for injection risk — owner: security-lead]
- QA: [OPEN: test retry count, backoff delays, telltale detection — owner: qa-lead]

## Failure modes & blast radius
- **Contract violation (telltale regex mismatch):** MCP failure misclassified as non-transport, returns 1 instead of 2. Blast: caller does not retry at outer loop level, PR stalls.
- **Perf regression (Codex latency spike):** Retry delays compound latency. Blast: review cycle slows, may exhaust MAX_REVIEW_CYCLES.
- **Telemetry loss (log write failure):** Retry messages not logged. Blast: debugging harder if issue occurs.
- **False positive (non-MCP error matches telltale):** Non-transport failure retried unnecessarily. Blast: wasted time and API cost.
- **False negative (MCP error missed by telltale):** MCP failure returns 1, not retried. Blast: PR labeled `review-incomplete` instead of `review-mcp-outage`.

# Bounds

## Out of scope
- **Out-of-feature behaviors:**
  - Codex prompt assembly (handled by review cycle caller)
  - PR labeling (review-mcp-outage applied by caller, not this function)
  - Dynamic retry policy (no adaptive backoff, no jitter)
- **Capacity limits:**
  - Fixed 3 retries (no configuration)
  - Fixed delay schedule (no exponential backoff)
- **Adjacent capabilities deferred:**
  - Circuit breaker (no "stop trying after N consecutive failures across calls")
  - Retry budget (no global limit on retries per run)
  - Alternative backends (no fallback to non-Codex reviewer)

## Assumptions-that-could-flip
- **Fixed retry policy assumption.** If flipped to configurable: requires env var (MAX_CODEX_RETRIES, CODEX_RETRY_DELAYS) and parsing logic.
- **Telltale regex assumption.** If flipped to structured error codes: requires Codex CLI to output machine-readable error format (JSON).
- **Codex-only assumption.** If flipped to multi-backend (Codex + fallback): requires backend selection logic and contract abstraction.
- **Synchronous retry assumption.** If flipped to async retry (queue failed calls): requires job queue and background worker.

## Composes with / replaces
- **Replaces:** Bare Codex invocation with no error handling
- **Composes with:**
  - ARLO-FEAT-REVIEW-CYCLE (caller, uses this for Codex resilience)
  - Codex CLI (subprocess invoked by this function)

# Signals

## Acceptance tests
1. **Given** Codex succeeds on attempt 1 (exit 0, non-empty TMP_REVIEW), **when** function is called, **then** return 0 with no retries.
2. **Given** Codex fails on attempt 1 with telltale match, succeeds on attempt 2, **when** function is called, **then** return 0 after 60s delay.
3. **Given** Codex fails on attempts 1 and 2 with telltale match, succeeds on attempt 3, **when** function is called, **then** return 0 after 60s + 300s delays.
4. **Given** Codex fails on all 3 attempts with telltale match, **when** function is called, **then** return 2 (MCP transport failure).
5. **Given** Codex fails on attempt 1 with no telltale match, **when** function is called, **then** return 1 (non-transport failure) with no retries.
6. **Given** Codex exit 0 but TMP_REVIEW empty on attempt 1, **when** function is called, **then** treat as failure, check telltale, potentially retry.
7. **Given** attempt 2 starts, **when** function sleeps, **then** log message "waiting 60s before retry (attempt 2 of 3)" appears.
8. **Given** attempt 3 fails with telltale match, **when** function returns, **then** log message "MCP transport failure on attempt 3 of 3 (rc=N, review=empty)" appears.

## Telemetry events tied to L1 KPIs
- **Retry count distribution** → Reliability KPI (most calls should succeed on attempt 1)
- **Return code 2 rate** → Codex availability KPI (lower = better Codex uptime)
- **Average latency per call** → Productivity KPI (lower = less time waiting for retries)

## AEAB cases
N/A — no eval framework integration yet.

Future: Could record (attempt_count, delays_applied, outcome) for retry policy tuning.

## Kill criteria
- If MCP transport failure rate (return 2 / total calls) exceeds 30% over 7 days → halt feature, escalate to Codex support or remove Codex dependency
- If retry latency p95 exceeds 10 minutes → reduce MAX_REVIEW_CYCLES or shorten delay schedule
- If telltale false positive rate (non-MCP errors matching regex) exceeds 10% → refine regex or switch to structured error parsing
- If telltale false negative rate (MCP errors missed by regex) exceeds 10% → expand regex or switch to alternative detection method
