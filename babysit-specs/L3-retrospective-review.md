---
spec_type: feature
id: ARLO-FEAT-RETROSPECTIVE-REVIEW
status: review
owners: [Chris Robertson]
depends_on: [ARLO-FEAT-REVIEW-CYCLE, ARLO-FEAT-MCP-RESILIENCE]
parent_l1: ARLO-PROD-BABYSIT-WITH-REVIEW
parent_l2: ARLO-SYS-AUTONOMOUS-DEV
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [novelty, scope, external_integration]
  scored_on: 2026-06-28
---

# Frame

## TL;DR
One-shot retrospective Codex review for PRs that merged without automated review (due
to version incompatibility, MCP outages, or other silent failures). Reviews the diff at
the merge commit, posts findings as a closed-PR comment, and opens follow-up GitHub
issues for each blocking finding.

## Analog
Like a post-incident code audit: after a deployment goes wrong, the team reviews what
landed. This feature automates that audit for AI-generated PRs that bypassed the
automated review gate.

## Reader & next action
Implementing engineer: understand the worktree-at-merge-SHA scope, idempotency marker,
and the `find-bailed-merged-prs.sh` integration. QA: verify worktree cleanup, idempotency,
and issue creation deduplication.

## API surface fragment
```bash
# Standalone script
run-retrospective-review.sh [--dry-run] [--repo OWNER/REPO] [--no-issues]
                             [--label LABEL] PR_NUMBER [PR_NUMBER ...]

# Pipeline mode (output of find-bailed-merged-prs.sh piped in)
find-bailed-merged-prs.sh --repo OWNER/REPO \
  | run-retrospective-review.sh --repo OWNER/REPO

# Flags
--repo OWNER/REPO   GitHub repo (required unless piped from find-bailed-merged-prs.sh)
--dry-run           Check PR state/idempotency; print what would happen; skip Codex, worktrees, comments, and issue creation
--no-issues         Post reviews but do not create follow-up issues
--label LABEL       Additional label to add to created issues (repeatable)

# Exit codes
0   # Completed (partial success allowed; per-PR failures are logged, not fatal)
1   # Fatal: bad arguments, gh auth failure, or all PRs failed
```

## Consumer
Operator running one-off audit, or automation triggered after detecting `review-codex-outdated`
or `review-mcp-outage` labels on merged PRs.

# Substance

## What we know
Design decisions:

- **Scope at merge commit, not current HEAD.** `gh pr view --json mergeCommit` gives
  the squash/merge SHA. The script creates a `git worktree` at that SHA and diffs against
  its parent. This captures exactly what landed, not subsequent patches that may have
  silently fixed issues.
- **Worktree isolation.** Each PR is reviewed in a temporary `git worktree`. The main
  checkout is never touched. The trap cleans up the worktree on exit.
- **Codex prompt is Cycle 1 template + `[RETROSPECTIVE]` preamble.** The preamble includes
  the PR number, merge date, and the full `gh pr diff` output so Codex sees the exact
  change set without needing to compute it from the worktree state alone.
- **Idempotency via HTML comment marker.** Before posting, the script checks existing PR
  comments for `<!-- retrospective-review: pr=N -->`. If found, the PR is skipped. This
  makes the script safe to re-run after partial failures.
- **Issues for blocking findings only.** RECOMMENDED and INFORMATION findings are captured
  in the PR comment but do not generate issues. Only BLOCKING findings create issues.
- **One issue per blocking finding** (not one issue per PR). Title format:
  `[retrospective] <one-line finding> (merged PR #N)`. Deduplication: if an issue with
  this exact title already exists (open or closed), it is skipped.
- **Structural validation reused.** The same three-section-header check from
  ARLO-FEAT-MCP-RESILIENCE is applied before treating a Codex response as a valid review.
- **Codex compat failure skips the PR.** If Codex returns the `compat_re` pattern, the
  PR is logged to stderr as skipped. The operator must first upgrade Codex before
  retrospective review can run.
- **`find-bailed-merged-prs.sh` is the source of truth for detection.** The retrospective
  script does not re-scan logs; it accepts PR numbers from stdin (TSV, second column) or
  as CLI arguments.

## What we assume
- [ASSUMPTION] The PR's merge commit is still reachable in the local git history. Flips
  if: the repo was force-pushed or shallow-cloned; requires `git fetch --unshallow` or
  fetching the specific SHA first.
- [ASSUMPTION] The PR diff from `gh pr diff` accurately represents what merged. Flips if:
  the PR was merge-committed (not squashed); the diff may include merge-commit overhead.
  The worktree diff (`git diff $sha^..$sha`) is used as fallback.
- [ASSUMPTION] One Codex run per PR is sufficient for retrospective purposes. Flips if:
  the PR is too large for a single Codex context window, requiring chunked review.
- [ASSUMPTION] Blocking findings from a retrospective review represent real risk. Flips if:
  subsequent commits have already fixed the issues; the issue creation flow instructs
  operators to verify against current HEAD before acting.

## Contract

### Request shape
```bash
run-retrospective-review.sh --repo OWNER/REPO PR_NUMBER [PR_NUMBER ...]
# repo: OWNER/REPO string (e.g., chrisbrobertson/secondbrain)
# PR_NUMBER: merged PR number (open PRs are skipped with a note)
```

### Response shape
```
# stdout: per-PR summary
PR #133: 2 blocking finding(s) → review posted, 2 issue(s) created
PR #134: 0 blocking finding(s) → review posted (PASSED)
PR #135: Codex failure (compat) → skipped (see stderr)
PR #136: already reviewed → skipped (idempotent)

# exit 0 even with skipped PRs; exit 1 only on fatal errors
```

### Invariants
1. **Merge-commit scope:** Always reviews the diff at `mergeCommit.oid`, not `HEAD`.
2. **Idempotency:** A PR with an existing `<!-- retrospective-review: pr=N -->` marker
   is never reviewed twice.
3. **Worktree cleanup:** Temporary worktrees are removed in an `EXIT` trap even on error.
4. **Structural validation:** Codex output must contain all three section headers before
   being treated as a review. Invalid output → PR skipped, logged to stderr.
5. **Issue deduplication:** Issues are not created if an issue with the same title prefix
   already exists.
6. **Non-fatal per-PR errors:** A failure on one PR (worktree error, Codex failure, gh
   comment failure) logs to stderr and continues to the next PR. Exit 0 if at least one
   PR was successfully reviewed.
7. **Dry-run preview:** `--dry-run` checks PR state and idempotency (via `gh pr view` and
   the comments API), then prints `[dry-run] would review at SHA <sha>` instead of running
   Codex. No Codex execution, no worktree creation, no comment posting, no issue creation.
   PRs that are already reviewed or not merged are still reported as skipped (no change from
   live mode).

### Idempotency
Idempotent per PR. Re-running on the same PR set produces the same output (skipped) for
already-reviewed PRs.

### Versioning policy
Standalone script; no versioning. Breaking changes (prompt format, issue title format,
idempotency marker) require manual migration of existing markers/issues.

## Performance budget
- **Per-PR latency:** ~1–2 minutes (worktree setup + Codex review; same as forward-path cycle 1)
- **Issue creation overhead:** ~1–2s per issue via `gh issue create`
- **Cost per PR:** ~$0.50–1.50 (Codex inference, cycle 1 depth)
- **Batch of 10 PRs:** ~15–20 minutes end-to-end

## Security model
- **AuthN / AuthZ:** Inherits from `gh` CLI (`gh auth status`) and Codex CLI
- **Tenant isolation:** Single-user; reviews are posted to PRs in the authenticated account
- **PII handling:** Code diffs and commit messages only; no user data
- **Worktree isolation:** Temporary directory; cleaned up on exit

## Telemetry contract
Events emitted to stdout:
- `PR #N: K blocking finding(s) → review posted, K issue(s) created`
- `PR #N: 0 blocking finding(s) → review posted (PASSED)`
- `PR #N: already reviewed → skipped (idempotent)`
- `PR #N: not merged → skipped (state=OPEN)`

Events emitted to stderr:
- `PR #N: Codex failure (compat) → skipped`
- `PR #N: worktree creation failed → skipped`
- `PR #N: gh pr view failed → skipped`

## Verifiers
- Tech lead: Chris Robertson
- Security: ensure worktree paths don't leak sensitive data; Codex prompt contains diff
- QA: verify idempotency marker, worktree cleanup, issue deduplication

## Failure modes & blast radius
- **Codex compat failure (compat_re match):** PR skipped. Blast: no review for that PR;
  operator must upgrade Codex first.
- **Merge commit not reachable locally:** Worktree creation fails; PR skipped. Blast:
  limited; operator can `git fetch origin <sha>` and retry.
- **`gh issue create` failure:** Warning logged; review comment already posted. Blast:
  no tracking issue, but the review comment on the PR is the primary artefact.
- **Partial run (script interrupted mid-batch):** Already-reviewed PRs have idempotency
  marker; resume by re-running on the full list.
- **False-clean review (Codex misses real bug):** Issue not created. Blast: same as a
  missed finding in the forward-path review; mitigated by this being a defence-in-depth
  layer, not the only quality gate.

# Bounds

## Out of scope
- **Re-running on the same PR with new findings:** The idempotency marker prevents
  duplicate reviews. If a re-review is needed (e.g., Codex quality improved), the
  operator must manually delete the marker comment and re-run.
- **Automated fix PRs:** Retrospective review creates issues, not fix PRs. Fix PRs
  require the live babysitter running against the default branch.
- **Review of open (non-merged) PRs:** The script skips non-merged PRs with a note.
  Use the forward-path review cycle for open PRs.
- **Multi-round retrospective cycles:** One Codex pass per PR. Convergence cycles are
  for the live forward-path only.

## Assumptions-that-could-flip
- **Single-pass-sufficient assumption.** If flipped (PR too complex for one pass):
  chunk the diff by file or directory and aggregate findings.
- **Merge-commit-reachable assumption.** If flipped (shallow clone): add `git fetch
  --unshallow` or `git fetch origin <sha>` before worktree creation.
- **gh-pr-diff-accurate assumption.** If flipped (merge commit): fall back to
  `git diff $sha^..$sha` in worktree, which is the default already.

## Composes with / replaces
- **Composes with:**
  - `find-bailed-merged-prs.sh` (detection — pipes PR list)
  - `backfill-codex-reviews.py` (log-based backfill — different use case: posts reviews
    that WERE captured in logs but never posted to GitHub; retrospective runs NEW reviews)
  - ARLO-FEAT-MCP-RESILIENCE (structural validation reused)
- **Distinct from `backfill-codex-reviews.py`:** That script posts review content already
  captured in sisyphus logs. This script runs a new Codex review for PRs where no valid
  review was ever captured.

# Signals

## Acceptance tests
1. **Given** a merged PR with no `<!-- retrospective-review: pr=N -->` marker, **when**
   script runs, **then** Codex review is posted as a PR comment with the `[RETROSPECTIVE]`
   header and the marker.
2. **Given** the script is run twice on the same PR, **then** the second run outputs
   `already reviewed → skipped` and no duplicate comment is posted.
3. **Given** Codex returns 2 blocking findings, **when** review completes, **then** 2
   GitHub issues are created with titles prefixed `[retrospective]` and labelled
   `kind:bug,retrospective`.
4. **Given** Codex returns 0 blocking findings, **when** review completes, **then** the
   PR receives a `[RETROSPECTIVE REVIEW — PASSED]` comment and no issues are created.
5. **Given** a non-merged (OPEN) PR number is passed, **when** script runs, **then** PR
   is skipped with `not merged → skipped (state=OPEN)`.
6. **Given** Codex output matches `compat_re`, **when** script runs, **then** PR is
   logged to stderr as skipped; no comment, no issue.
7. **Given** `--dry-run` flag, **when** script runs, **then** each eligible PR outputs
   `[dry-run] would review at SHA <sha> (merged <date>)` and no Codex run, worktree,
   comment, or issue is created. PRs that are not merged or already reviewed are still
   reported as skipped.
8. **Given** `--no-issues` flag and 3 blocking findings, **when** script runs, **then**
   review comment is posted but no issues are created.
9. **Given** the worktree EXIT trap triggers (script killed mid-run), **when** inspection
   runs after, **then** `git worktree list` shows no orphaned entries.
10. **Given** an issue with title `[retrospective] <same finding> (merged PR #N)` already
    exists, **when** `gh issue create` would be called, **then** it is skipped (dedup).

## Telemetry events tied to L1 KPIs
- **Retrospective findings per PR** → unreviewed-PR quality signal (lower = code was fine)
- **Issue-to-fix rate** → follow-through rate on retrospective findings
- **Codex compat skip rate** → signals how often retrospective is blocked by outdated CLI

## AEAB cases
N/A — no eval framework yet. Future: record (pr_number, blocking_count, issues_created,
resolved_within_N_iterations) for audit completeness tracking.

## Kill criteria
- If retrospective review creates issues that are consistently closed as "already fixed
  by subsequent commits" (>80% of issues) → add current-HEAD check before creating issue
- If Codex compat failure prevents retrospective on >50% of target PRs → prioritise
  Codex upgrade path; add version pre-check to the script
- If worktree creation fails for >20% of PRs (shallow clone or git issues) → add
  auto-fetch fallback
