---
spec_type: system
id: ARLO-SYS-AUTONOMOUS-DEV
status: review
owners: [Chris Robertson]
depends_on: [ARLO-PROD-BABYSIT-WITH-REVIEW]
serves_l1: [ARLO-PROD-BABYSIT-WITH-REVIEW]
fit_check: passed
complexity:
  total: 2
  band: trivial
  drivers: [novelty, time_estimate]
  scored_on: 2026-06-28
---

# Frame

## TL;DR

A bash-orchestrated system connecting Claude Code CLI, Codex CLI, GitHub CLI, and git to enable autonomous iterative development with quality-gated review cycles.

## Analog

Like a CI/CD pipeline controller (e.g., GitHub Actions workflow runner), but orchestrating AI agents for development and review instead of running pre-scripted test suites.

## Reader & next action

Engineering leads implementing autonomous development tools — understand component contracts and failure domains before deploying. SRE/platform teams reviewing operational characteristics and failure recovery.

## Component diagram

```
┌─────────────────────────────────────────────────────────────┐
│ babysit-with-review.sh (orchestrator)                       │
│  - Outer loop: state collection → Claude → sentinel detect  │
│  - Review cycle: Codex → Claude → convergence check         │
│  - Pre-flight: working tree validation                      │
│  - Stuck detection: SHA256 hash comparison                   │
└─────────────────┬───────────────────────────────────────────┘
                  │
        ┌─────────┼─────────┬──────────┬──────────┐
        │         │         │          │          │
        ▼         ▼         ▼          ▼          ▼
   ┌────────┐ ┌──────┐ ┌──────┐  ┌────────┐ ┌────────┐
   │ claude │ │codex │ │  gh  │  │  git   │ │ helper │
   │   -p   │ │ exec │ │ CLI  │  │  CLI   │ │scripts │
   └────────┘ └──────┘ └──────┘  └────────┘ └────────┘
        │         │         │          │          │
        ▼         ▼         ▼          ▼          ▼
   Claude API  ChatGPT  GitHub API   local     JSON
   (OAuth)     MCP      (gh auth)    repo      output
```

**Authoritative surface:** Bash orchestrator is the single control plane. All components are stateless; orchestrator maintains iteration state via filesystem (logs, lock files, temp files).

# Substance

## What we know

From the existing implementation:

- Orchestrator: Single bash script (~900 lines) with no external dependencies beyond standard Unix tools
- Components run as subprocesses; orchestrator captures stdout/stderr and exit codes
- Temp files used for inter-component communication (TMP_RESULT, TMP_REVIEW, TMP_CODEX_FULL)
- Logs written to ~/sisyphus-logs/--.log
- Lock file at ~/babysitter-logs/.stop prevents concurrent runs
- No persistent state beyond git commits and GitHub PR metadata

## What we assume

- [ASSUMPTION] Claude Code CLI remains OAuth-based with no API key requirement. Flips if: Claude moves to API-key-only access, requiring secrets management.
- [ASSUMPTION] Codex CLI MCP transport remains the primary failure mode. Flips if: Codex becomes more reliable, allowing removal of retry logic.
- [ASSUMPTION] gh CLI is authenticated and functional. Flips if: auth expires or repo permissions change, requiring pre-flight auth checks.
- [ASSUMPTION] Single bash process is sufficient for orchestration. Flips if: parallelization or job queuing is needed, requiring process management or task queue.

## Cross-component contracts

### Orchestrator → Claude Code CLI

- **Protocol:** Subprocess invocation with stdin prompt, stdout JSON stream
- **Request shape:** 
  ```bash
  claude -p "<prompt>" \
    --model opusplan \
    --dangerously-skip-permissions \
    --output-format stream-json
  ```
- **Response shape:** JSON stream with events: `{"type": "assistant", "message": {"content": [...]}}`, final `{"type": "result", "result": "<text>"}`
- **Sentinel contract:** Claude's final text must end with exactly one of: `HANDOFF_REVIEW <PR_NUMBER>`, `STOP`, or (none)
- **Timeout:** No explicit timeout (relies on claude CLI's internal limits)
- **Idempotency:** Non-idempotent; each call advances work state

### Orchestrator → Codex CLI

- **Protocol:** Subprocess invocation with prompt, output file
- **Request shape:**
  ```bash
  codex exec --output-last-message "<file>" -s read-only "<prompt>"
  ```
- **Response shape:** Markdown with three required sections: `## BLOCKING`, `## RECOMMENDED`, `## INFORMATION`
- **Retry policy:** 3 attempts with 0 / 60s / 300s delays on MCP transport failure
- **MCP failure telltales:** Regexes: `Transport send error:`, `tool call failed for \`codex_apps/`,` error sending request for url [https://chatgpt\.com/`](https://chatgpt\.com/`)
- **Idempotency:** Idempotent within a review cycle (same PR state → same review)

### Orchestrator → GitHub CLI

- **Protocol:** Subprocess invocation with gh commands
- **Commands used:**
  - `gh pr list` (with --json for machine-readable output)
  - `gh pr view <number>` (fetch PR details, reviews, comments)
  - `gh pr create` (create new PR)
  - `gh pr checkout <number>` (switch to PR branch)
  - `gh pr edit <number>` (add/remove labels)
  - `gh pr ready <number> [--undo]` (toggle draft status)
  - `gh pr merge <number>` (merge when BLOCKING=0)
  - `gh pr comment <number>` (post review results)
  - `gh label create` (ensure labels exist)
  - `gh repo view` (fetch default branch name)
- **Auth:** Assumes `gh auth status` succeeds
- **Idempotency:** Most commands are idempotent (label add, comment post); merge is not

### Orchestrator → git CLI

- **Protocol:** Subprocess invocation with git commands
- **Pre-flight checks:**
  - `git diff --quiet` (no unstaged changes)
  - `git diff --cached --quiet` (no staged uncommitted changes)
  - `git ls-files --others --exclude-standard` (no untracked files)
  - `git rev-parse --abbrev-ref HEAD` (current branch)
  - `git fetch origin` (sync with remote)
- **Branch operations:**
  - `git checkout <branch>` (switch branches)
  - `git pull --ff-only` (fast-forward default branch)
- **State tracking:**
  - `git rev-parse HEAD` (capture SHA before/after Claude passes)
  - `git log --oneline` (commit history for review context)
- **Idempotency:** Read operations are idempotent; write operations (checkout, pull) are state-changing

### Orchestrator → Helper Scripts

- **Protocol:** Subprocess invocation with --json flag
- **Scripts:**
  - `~/repo/scripts/prs` (PR list with CI rollup)
  - `~/repo/scripts/issues` (issue list sorted by priority)
  - `~/repo/scripts/specs` (spec file list with status)
- **Response shape:** JSON array or table format
- **Auth/deps:** Inherit from gh CLI authentication
- **Idempotency:** Idempotent read-only operations

## SLOs and latency budgets

Formal numeric SLOs are deferred — single-user internal tool with no SLA obligations.

Observed behavior:

- **Outer loop iteration latency:** p50 ~2min, p95 ~10min, p99 ~20min (dominated by Claude inference time)
- **Review cycle iteration latency:** p50 ~4min, p95 ~15min, p99 ~30min (Codex + Claude sequential calls)
- **MCP retry latency:** 0 / 60s / 300s backoff → max 6min additional latency on failure
- **Pre-flight check latency:** p95 <5s (git operations on local repo)
- **Error budget:** No formal error budget; graceful degradation on component failure

Latency budget honors L1 product promise: Tool must complete tasks faster than manual development. Current p50 ~2min per iteration is acceptable for small tasks; p99 ~20min acceptable for complex tasks.

## Failure-domain map

- **Cell scope:** Single developer workstation, single git repository
- **Blast radius per failure class:**
  - **Claude API unavailable:** Outer loop halts at current iteration; no data loss (git state preserved)
  - **Codex MCP transport failure:** Review cycle retries 3×, then labels PR `review-mcp-outage` and halts; PR remains open for manual review
  - **gh CLI auth failure:** Outer loop halts; developer must re-authenticate via `gh auth login`
  - **git CLI failure:** Pre-flight catches most issues; in-flight failures halt iteration
  - **Disk full / log write failure:** Log writes fail silently (stdout to /dev/null behavior); orchestration continues
  - **Process killed / SIGTERM:** Lock file remains; developer must manually remove before next run
- **Degraded modes:**
  - **Codex unavailable:** Review cycle skips automatically (logged message), outer loop continues
  - **Helper scripts unavailable:** State collection returns "(unavailable)" placeholder, Claude continues with degraded context

## arlo-infra.yaml dependencies

N/A — this is a developer workstation tool with no arlo-infra.yaml dependencies.

External dependencies (not arlo-infra.yaml):

- `claude` CLI (Claude Code, installed via `curl` or package manager)
- `codex` CLI (optional, installed via package manager)
- `gh` CLI (GitHub CLI, installed via Homebrew or package manager)
- `git` CLI (standard on macOS/Linux)
- Bash 4.0+ (macOS ships with 3.2; newer versions via Homebrew)

## Compliance posture

- **Data residency:** All data on developer workstation; logs at ~/sisyphus-logs/
- **SOC2 boundary impact:** None (internal tool, no customer data)
- **Retention and deletion:** Logs persist indefinitely unless manually deleted; no automatic cleanup
- **PII / PHI handling:** None (operates on code repositories, not user data)
- **Cross-region data flow:** None (local execution only)

## Verifiers

- Architecture: Chris Robertson
- SRE: N/A (single-user internal tool; no SRE team)
- Security: Chris Robertson (security review completed; see SECURITY-REVIEW-PLAN.md — all findings accepted or resolved)
- Compliance: N/A (internal tool)

## Failure modes & blast radius

- **Vendor outage (Anthropic API):** Outer loop halts; developer waits or cancels run. Blast: single developer blocked for duration of outage.
- **Vendor outage (OpenAI ChatGPT for Codex MCP):** Review cycle retries, then labels PR. Blast: PR review delayed but not lost.
- **Lock file collision:** Second invocation refuses to start. Blast: developer must manually check for running processes and remove stale lock file.
- **Stuck loop (identical iterations):** After STUCK_N iterations, loop halts with log message. Blast: developer must diagnose prompt issue or task complexity.
- **MAX_ITER exhausted:** Loop halts after MAX_ITER iterations. Blast: developer must increase limit or decompose task.
- **Pre-flight check failure:** Script refuses to start with corrective instructions. Blast: developer must manually resolve git state (unstaged changes, diverged branch, etc.).

# Bounds

## Out of scope

- **Surfaces not supported:** Windows (PowerShell, CMD), cloud/CI execution (requires environment portability)
- **Scaling ceiling:** Single repository per invocation; no multi-repo coordination
- **Compliance regimes not covered:** No audit trails, no approval gates, no access control beyond filesystem permissions
- **Non-goals:**
  - Parallelization (multiple PRs in flight simultaneously)
  - Distributed execution (workload splitting across machines)
  - Historical analytics (aggregation across runs)
  - Web UI or API

## Assumptions-that-could-flip

- **Bash orchestration assumption.** If flipped to compiled binary or language-native: requires build pipeline, cross-platform support, and dependency management.
- **Subprocess invocation assumption.** If flipped to library/SDK integration: requires rewrite in Python/Go/etc., loses shell script simplicity.
- **Filesystem-based state assumption.** If flipped to database/API state: requires persistence layer, concurrency control, and remote access.
- **OAuth-based Claude access.** If flipped to API key: requires secrets management, key rotation, and rate limit handling.

## Composes with / replaces

- **Supersedes:** Manual iterative development loop (edit → test → commit → review)
- **Composes with:**
  - CI/CD systems (babysitter creates PRs, CI validates)
  - Code review tools (CodeRabbit, human reviewers add feedback)
  - Monitoring/observability (logs can be ingested by external systems)

# Signals

## SLIs (leading)

Formal SLI definitions are deferred — single-user internal tool. Observable metrics tracked informally:

- **Iteration completion rate:** successful iterations / total iterations
- **Review cycle convergence rate:** PRs reaching BLOCKING=0 / total PRs
- **MCP failure rate:** Codex transport failures / total Codex invocations
- **Pre-flight failure rate:** Runs blocked by pre-flight / total run attempts
- **Stuck loop rate:** Runs halted by stuck detection / total runs

## Error budget burn (lagging)

No formal error budget. Observed failure modes:

- **Claude API 5xx:** <1% of calls (handled by retry in claude CLI)
- **Codex MCP transport failure:** ~5-10% of calls (handled by orchestrator retry)
- **gh CLI auth expiry:** ~1 per month (developer re-authenticates)

## Audit checkpoints

N/A — internal tool, no formal audit requirements.

Optional audit approach:

- Weekly log review: scan ~/sisyphus-logs/ for error patterns
- Monthly metric snapshot: iterations, PRs merged, time saved

## Capacity headroom triggers

N/A — developer workstation tool with no shared capacity.

Potential triggers if usage scales:

- **Log disk usage:** Alert if ~/sisyphus-logs/ exceeds 1GB
- **Concurrent runs per host:** Warn if multiple instances detected (lock file collision rate >10%)

## Kill criteria

- If architectural assumption "Claude OAuth access" flips to API-key-only → requires redesign (secrets management layer)
- If architectural assumption "Codex MCP transport" degrades to >50% failure rate → remove Codex dependency, use alternative review approach
- If bash subprocess model cannot support parallelization (needed for multi-PR workflows) → rewrite in Go/Python with async/await

