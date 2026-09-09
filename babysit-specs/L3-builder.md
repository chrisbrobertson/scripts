---
spec_type: feature
id: ASF-FEAT-BUILDER
status: review
owners: [Chris Robertson]
depends_on: [ASF-SYS-AUTONOMOUS-DEV, ASF-FEAT-REVIEW-CYCLE, ASF-FEAT-MCP-RESILIENCE, ASF-FEAT-WORK-PREP]
parent_l1: ASF-PROD-BABYSIT-WITH-REVIEW
parent_l2: ASF-SYS-AUTONOMOUS-DEV
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [novelty, scope, external_integration]
  scored_on: 2026-08-27
---

# Frame

## TL;DR
A build loop (`babysit-builder.sh`) that pulls any ticket carrying a `build-ready`
label — a GitHub issue or a Jira issue, sub-ticket or otherwise — implements the spec
it references in a fresh worktree, and runs the same convergent adversarial review
cycle as `babysit-with-review.sh`. Halts for a human to do the final merge instead of
merging itself. Specs found to have gaps on ingest are kicked back for
clarification/updating rather than built as-is.

## Analog
Like a build engineer who picks up an approved design doc, implements it, and iterates
with a strict code reviewer until the reviewer has no more blocking comments — then
hands the PR to a human lead for the actual merge, rather than merging their own work.
If the design doc itself is incomplete, they kick it back to whoever wrote it instead
of guessing.

## Reader & next action
Implementing engineer: understand how the `build-ready` ticket query maps onto a
per-ticket outer loop across two ticket sources (GitHub, Jira), how `run_build_cycle`
mirrors `run_review_cycle`'s convergence and MCP retry machinery while diverging at
the merge gate, and how the spec-gap kickback path differs from an ordinary retry.
QA: verify no code path in this script ever calls `gh pr merge`, that halted PRs are
left in an unambiguous state for a human to act on, and that a kicked-back ticket is
never silently re-picked-up as `build-ready`.

## API surface fragment
```bash
babysit-builder.sh [--repo OWNER/REPO] [--source github|jira|both]
                    [--implementer claude|codex] [--implementer-model MODEL] [--implementer-effort LEVEL]
                    [--reviewer claude|codex] [--reviewer-model MODEL] [--reviewer-effort LEVEL]
                    [--repo-base PATH] [--max-tickets N] [--dry-run]

# Flags
--repo OWNER/REPO   Repo to open PRs against and (for --source github) pull tickets
                     from; auto-detected via `gh repo view` when omitted
--source SOURCE     Ticket origin: github (default), jira, or both — same semantics as
                     babysit-work-prep.sh's flag
--max-tickets N      Cap on tickets built per invocation (default 5; see scale envelope)
--dry-run            List the build queue and what would be built; no worktree, no
                      implementer/reviewer call, no gh/Jira writes

# Env (required when --source jira|both)
JIRA_BASE_URL   Jira instance base URL
JIRA_TOKEN      Bearer token for Jira REST API — read AND write scope (label transitions)
JIRA_PROJECT    Jira project key to query

# Lock file protocol (own namespace, independent of babysit-with-review.sh;
# PID-checked stop file, matching babysit-work-prep.sh's pattern)
~/sisyphus-logs/<project>-builder.stop

# Sentinels (implementer, same contract as babysit-with-review.sh, plus one addition)
HANDOFF_REVIEW <PR>        # triggers run_build_cycle for PR #<PR>
SPEC_GAP <reason>           # spec has a gap; ticket kicked back, NOT retried as-is
STUCK <reason>              # transient/infra failure; ticket left in queue, retried next run
(no sentinel)                # transient/infra failure; ticket left in queue, retried next run

# Halt outcomes (run_build_cycle; no gh pr merge in any path)
BLOCKING=0 converged        # labels build-ready-for-merge, posts codex-review=success,
                             # posts summary comment, swaps ticket build-ready → build-done
max cycles exhausted        # labels build-max-cycles, posts summary comment (no status),
                             # swaps ticket build-ready → build-done
SPEC_GAP                    # labels build-needs-clarification, posts gap comment, removes build-ready

# Quarantine labels (PR-side, non-terminal; build-* mirrors of the review-* set)
build-incomplete            # cycle bailed for a human-action reason; ticket also swapped
                             # to build-done so it is not rebuilt into a duplicate PR
build-mcp-outage            # reviewer transport failure; ticket KEEPS build-ready, the
                             # run halts, and the next run's outage sweep resumes this PR
build-codex-outdated        # Codex CLI too old; operator upgrades, removes label, re-runs
build-codex-no-credits      # Codex workspace out of credits; operator tops up, re-runs

# Exit codes
0   # Completed normally, including a run that builds zero tickets and a run that
    # halts early on a reviewer-backend outage — a quarantined PR plus an automatic
    # retry next run is a completed run, not a failed one.
1   # Fatal: pre-flight failure (including the startup reviewer probe), gh/git auth
    # failure, lock file collision, or
    # missing/malformed Jira env vars when --source jira|both is requested.
    # A live but unreachable Jira endpoint at query time is NOT fatal — it degrades
    # (skips Jira-sourced tickets, continues with GitHub) and exits 0.
2   # Bad arguments
```

## Consumer
Operator running the build phase of the three-script pipeline
(work-prep → builder → babysit-with-review's review-cycle machinery, mirrored in-process).
The human operator is the direct consumer of `build-ready-for-merge` / `build-max-cycles`
PRs and of `build-needs-clarification` tickets — this script produces review-ready
PRs, never merged PRs, and never silently builds against an incomplete spec.
`babysit-work-prep.sh` is one producer of `build-ready`-labelled tickets, not the only
one — any ticket (GitHub or Jira) carrying that label is eligible work.

# Substance

## What we know
Decisions already recorded in ASF-PROD-BABYSIT-WITH-REVIEW and ASF-SYS-AUTONOMOUS-DEV
(owner-approved 2026-08-27), plus mechanics directly inherited from the shipped
`babysit-with-review.sh` v1.1.0 implementation this script mirrors:

- **`build-ready` label is the work source, ticket type is not constrained.** The
  build queue is any ticket — GitHub issue or Jira issue, sub-ticket or otherwise —
  carrying the `build-ready` label (or its Jira equivalent; see multi-source
  assumption below). There is no freeform `GOAL_DESCRIPTION` argument like
  `babysit-with-review.sh` takes — each outer-loop iteration is scoped to exactly one
  queued ticket. This departs from the shipped `babysit-work-prep.sh`, which currently
  emits `status:ready-to-build` + `sub-ticket` on its GitHub sub-tickets — see the
  coordination note under "Composes with" for what needs to change on the work-prep
  side for its output to be picked up under this contract.
- **Per-ticket worktree, same pattern as the outer loop — verified always-clean.** A
  `git worktree` is created on a fresh, uniquely-named branch off the current default
  branch SHA for every single build attempt; the implementer builds the ticket's spec
  in it, and the worktree is torn down when the ticket reaches a terminal state.
  Unlike `babysit-with-review.sh`, the worktree is **not** torn down before the review
  cycle: that teardown exists there only because `run_review_cycle` calls
  `gh pr checkout`, which errors while the branch is checked out in a worktree.
  `run_build_cycle` has no `gh pr checkout` — it already holds a worktree on the PR
  branch — so it reviews and remediates in place. Two consequences: the operator's own
  checkout is never mutated (no clean-tree pre-flight is needed, and the builder can
  run while a human works in the same clone), and the wrapper pushes the worktree HEAD
  to the PR branch after every remediation pass and again before posting
  `codex-review=success`, so the status can never go green against a SHA the PR does
  not carry. Confirmed against
  the shipped implementation: `babysit-with-review.sh` uses `wip/<project>/iter-<N>`
  off `HEAD` (`git worktree add -b "$_wt_branch" "$_wt_dir" HEAD`, line ~1792);
  `babysit-work-prep.sh` uses `work-prep/<slug>-<pid>` off the default branch's SHA
  (`git worktree add -b "$branch" "$worktree" "$base_sha"`, line ~496). Neither ever
  reuses a branch across attempts, so a rebuilt ticket starts from a genuinely clean
  base every time — no state from a prior crashed or abandoned attempt can leak in.
  Builder follows the same pattern (e.g., `build/<slug>-<pid>`).
- **A spec found to have gaps on ingest is kicked back, never built as-is.** Owner
  decision (2026-08-27): if the implementer determines the referenced spec has a gap
  while starting a build attempt, the ticket is not silently abandoned (`STUCK`) or
  built against a guess — it's kicked back for clarification/updating via a distinct
  `SPEC_GAP` sentinel (see mechanics assumption below), leaving the ticket in an
  explicit `build-needs-clarification` state rather than looping in the queue.
- **A rebuilt ticket discarding prior work is an accepted trade-off, not a defect.**
  Given the always-clean-worktree guarantee above, the owner has confirmed
  (2026-08-27) that re-running a ticket after a crash — which may leave an earlier,
  never-labelled PR open from the discarded attempt — is acceptable: the old PR is
  simply an orphan a human closes, not a correctness risk. No in-progress marker,
  claim/release mechanism, or staleness check is needed to prevent this.
- **Convergent review cycle mirrors the existing implementation.** `run_build_cycle`
  mirrors `run_review_cycle` (`ASF-FEAT-REVIEW-CYCLE`): reviewer → implementer fixes →
  convergence tracking → prescriptive mode at cycle 3+ → same `TMP_RESULT`,
  `TMP_REVIEW`, `TMP_REVIEW_RESULT`, `TMP_CODEX_FULL` temp files and
  `valid_review_structure` validation. Same `MAX_REVIEW_CYCLES` default of 6.
- **MCP resilience is reused unchanged.** The same retry-with-backoff (0/60s/300s) and
  telltale detection from `ASF-FEAT-MCP-RESILIENCE` applies when `--reviewer codex`.
  Two run-level additions follow from the queue shape:
  - **Outage sweep runs before the queue is read.** A PR quarantined
    `build-mcp-outage` by a previous run is resumed first — its head branch is fetched
    into a reconstructed worktree, the label is removed, the PR is un-drafted, and the
    build cycle restarts. Ordering matters: that PR's ticket is still `build-ready`, so
    reading the queue first would rebuild it into the duplicate PR the sweep exists to
    avoid.
  - **Reviewer pre-flight is a run-level fatal, not a per-PR bail.** The Codex
    compatibility/credits probe runs once at startup and exits 1 on failure, before any
    implementer time is spent. `babysit-with-review.sh` probes per review cycle because
    it interleaves with implementation; builder knows its whole queue up front.
- **No auto-merge, ever.** Unlike `babysit-with-review.sh`, no code path calls
  `gh pr merge`. The halt condition (BLOCKING=0 convergence, or max cycles exhausted)
  ends the ticket's processing with a PR comment summarizing the reviewer's final
  findings and a label marking its state; the human does the merge.
- **Parallel label namespace.** Builder uses `build-*` labels exclusively;
  `babysit-with-review.sh`'s `review-*` labels are never read or written by this
  script, and vice versa — no shared state, no collision risk between the two loops
  running concurrently on the same repo.
- **Shared infrastructure, independent process.** Same `REPO_BASE` auto-detection,
  same selectable-implementer/selectable-reviewer plumbing (`ASF-FEAT-SELECTABLE-IMPLEMENTER`,
  `ASF-FEAT-SELECTABLE-REVIEWER`), own stop file
  (`~/sisyphus-logs/<project>-builder.stop`) so it runs concurrently with
  `babysit-with-review.sh` and `babysit-work-prep.sh` without lock contention.
- **Single-process-per-project locking, not per-ticket claiming.** The shipped
  `babysit-work-prep.sh` establishes the actual pattern: the stop file stores the
  holder's PID; a second invocation checks `kill -0 <pid>` and refuses to start
  (`exit 1`) if that PID is live, but auto-clears and proceeds if the PID is dead
  (stale lock from a crashed run). This is stronger than the plain "pre-existing file
  is a collision" lock described for the original outer loop, and builder should use
  the same PID-liveness pattern rather than inventing a separate per-ticket claim.
  Since only one builder process can run per project at a time, no per-ticket
  concurrency mechanism (e.g., a claiming label) is needed to prevent two live
  processes double-building the same ticket.
- **GitHub sub-ticket bodies (from work-prep) carry the spec path.** The shipped
  `babysit-work-prep.sh` sub-ticket body includes `Spec path: \`<path>\`` (plus the
  approved spec PR URL, source ticket URL, and approver) but does not carry the spec's
  `id:` frontmatter value directly — the builder must open the spec file at that path
  and read its frontmatter itself. This only covers GitHub-sourced, work-prep-produced
  tickets; see the multi-source assumption below for how a Jira ticket or a
  hand-labelled GitHub issue conveys the same information.
- **Jira write-back is label-only, per L1's declared scope.** `ASF-PROD-BABYSIT-WITH-REVIEW`
  already scopes Jira integration to "label-based handoff only; Jira/GitHub sync is
  operator-configured" and explicitly excludes Jira status transitions. Builder's
  label transitions on a Jira-sourced ticket (removing `build-ready`, adding
  `build-needs-clarification`, etc.) are therefore Jira label writes, never a Jira
  workflow/status transition.
- **Scale envelope (from L1):** typically 1-5 build tickets per run.

## What we assume
These mechanics are NOT yet confirmed by the owner — they are the author's best
reconstruction from the L1/L2 decisions and the shipped review-cycle implementation,
filled in to make the contract concrete enough to implement. Flag for explicit owner
sign-off before `babysit-builder.sh` is built against this spec:

- [ASSUMPTION] Multi-source `build-ready` query mechanics: for GitHub,
  `gh issue list --label build-ready --json` (any issue, not just ones labelled
  `sub-ticket`). For Jira, JQL `project=$JIRA_PROJECT AND labels=build-ready`,
  mirroring work-prep's Jira query shape but filtering on the label instead of
  `status=Open`. `--source both` merges both queues, tagging each ticket with its
  origin the same way work-prep does. Jira degrades (skip, don't fail the run) on
  API unavailability, per work-prep's established contract.
  Owner should confirm Jira issues actually use the native `labels` field for this
  signal rather than a status/workflow stage — Jira shops often gate on status, not
  labels, and if that's the case here the JQL clause needs to change accordingly.
- [ASSUMPTION] Halt labels: `build-ready-for-merge` (BLOCKING=0, converged),
  `build-max-cycles` (max cycles exhausted, unresolved BLOCKING findings remain), and
  `build-needs-clarification` (spec-gap kickback, see below) are mutually exclusive
  terminal labels, applied to the PR for the first two (no PR exists yet for a
  spec-gap kickback, so that label applies to the ticket itself). Alongside these,
  four non-terminal quarantine labels mirror `babysit-with-review.sh`'s `review-*`
  set one-for-one, because invariant 6 forbids reusing those: `build-incomplete`,
  `build-mcp-outage`, `build-codex-outdated`, `build-codex-no-credits`. A
  `build-incomplete` bail also swaps the ticket to `build-done` (with an explanatory
  ticket comment carrying the real semantics) — leaving it `build-ready` would
  guarantee a duplicate PR on every subsequent run with no progress, which is the one
  case the accepted-duplicate-PR trade-off does not cover. `build-mcp-outage` is the
  deliberate exception: the ticket keeps `build-ready` because the outage sweep at the
  top of the next run resumes that PR before the queue is read.
  Owner should confirm the `build-incomplete` → `build-done` swap reads correctly, or
  whether a distinct ticket-side label is preferred. Critically, the
  queue query filters on `build-ready` presence alone, so `build-done` being *added*
  is not sufficient to stop re-selection — the ticket's terminal transition must
  *swap* `build-ready` for `build-done` (remove one, add the other) in the same
  operation, once its PR reaches either merge-track terminal state. This is the same
  remove-and-add pattern invariant 7 already specifies for the kickback path.
  Owner should confirm the exact label names and whether the ticket should auto-close
  on `build-ready-for-merge` or stay open until the human merges the PR.
- [ASSUMPTION] Branch-protection interaction: `setup-branch-protection.sh` requires the
  `codex-review` status check before *any* merge on protected repos, including a human
  clicking "Merge" in the GitHub UI. Since this script never merges, it must still POST
  `codex-review=success` on `BLOCKING=0` convergence (mirroring
  `run_review_cycle`'s status write, minus the merge call) or the human's manual merge
  is blocked by branch protection with no recourse short of an admin override.
  On `build-max-cycles` halt, no status is posted — the PR is intentionally left
  unmergeable until a human either fixes the remaining findings or force-merges via
  admin override.
  Owner should confirm this status-without-merge behavior is desired, versus leaving
  protected repos requiring an explicit operator step to unblock every builder PR.
- [ASSUMPTION] Spec resolution mechanics: for a GitHub work-prep sub-ticket, the
  implementer prompt is built by parsing `Spec path: \`<path>\`` out of the ticket
  body, then reading that spec file's frontmatter directly out of the target repo. For
  a Jira ticket or a hand-labelled GitHub issue with no work-prep-style body, the spec
  reference must come from somewhere else — proposed: a `Spec: <path or URL>` line
  the operator (or a future work-prep-for-Jira flow) is expected to include, checked
  for before falling back to treating the ticket's own description as the spec.
  Owner should confirm this fallback order, and whether a ticket with genuinely no
  identifiable spec reference should itself count as a "gap" (kicked back) rather than
  a hard `STUCK`.
- [ASSUMPTION] Spec-gap kickback mechanics: the owner confirmed gaps found on ingest
  are kicked back rather than built as-is (see "What we know"), but the following
  remain open: what counts as a "gap" is the implementer's judgment call at the start
  of the build attempt (missing acceptance criteria, contradictory requirements, a
  referenced file/dependency that doesn't exist) — there's no separate lint pass.
  The kickback comment is posted on the ticket (not the already-merged spec PR, which
  may not exist for a Jira-sourced or hand-labelled ticket). Whether
  `babysit-work-prep.sh` should watch for `build-needs-clarification` and
  auto-re-open drafting on the same ticket, or whether that's a purely manual
  hand-off, is undecided.
  Owner should confirm the gap-detection judgment call is acceptable without a
  separate validation pass, and whether work-prep needs a matching auto-pickup for
  `build-needs-clarification` tickets to close the loop.

## Contract

### Request shape
```bash
babysit-builder.sh [--repo OWNER/REPO] [--source github|jira|both]
                    [--implementer claude|codex] [--implementer-model MODEL] [--implementer-effort LEVEL]
                    [--reviewer claude|codex] [--reviewer-model MODEL] [--reviewer-effort LEVEL]
                    [--repo-base PATH] [--max-tickets N] [--dry-run]
# --repo: optional; auto-detected via `gh repo view` when omitted
# --source: defaults to github
# Unknown flags: exit 2 with usage message
```

### Response shape
```
# stdout: per-ticket summary
[build] ticket #103 (github, spec: babysit-specs/L3-example.md) → worktree created, implementing
[build] ticket #103 → PR #150 opened, HANDOFF_REVIEW → entering build cycle
[build] PR #150 → cycle 1: 2 BLOCKING, 1 RECOMMENDED
[build] PR #150 → cycle 2: 0 BLOCKING → converged, labelled build-ready-for-merge,
        codex-review=success posted, summary comment posted, halted for human merge
[build] ticket PROJ-9 (jira) → SPEC_GAP: acceptance criteria missing for the retry path,
        labelled build-needs-clarification, build-ready removed, comment posted
[build] ticket #104 (github) → STUCK: worktree creation failed, left in queue

# exit 0 even when zero tickets are built or all tickets bail this run
```

### Invariants
1. **No self-merge, no exceptions.** `run_build_cycle` never calls `gh pr merge`,
   under any convergence or cycle-exhaustion outcome.
2. **At most one live builder process per project.** Enforced by the PID-checked stop
   file (see "single-process-per-project locking" above), not per-ticket state — a
   ticket is never labelled mid-build, so there is nothing to "release" if a process
   dies; the next invocation simply proceeds once the stale lock clears, and any
   already-open PR from the discarded attempt is left as an orphan for a human to
   close (see "accepted trade-off" in What we know).
3. **Terminal states are mutually exclusive.** A PR carries exactly one of
   `build-ready-for-merge` or `build-max-cycles`; a ticket carries at most one of
   `build-done` or `build-needs-clarification`. Never both, never neither, once the
   ticket reaches a terminal state. The four quarantine labels are a disjoint,
   non-terminal set: a PR carrying one of them carries neither terminal PR label,
   because no review verdict was reached.
4. **Max-tickets cap:** no more than `--max-tickets` (default 5) new tickets are
   started per invocation, regardless of queue size.
5. **Dry-run is read-only:** `--dry-run` performs `gh`/Jira reads only — no worktree,
   no implementer/reviewer invocation, no PR/issue/label/status writes.
6. **Label namespace isolation:** this script never reads or writes a `review-*`
   label, and `babysit-with-review.sh` never reads or writes a `build-*` label.
7. **A terminal ticket is never re-selected.** Every terminal transition (kickback to
   `build-needs-clarification`, or merge-track to `build-done`) removes `build-ready`
   in the same operation that adds the terminal label, since the queue query filters
   on `build-ready` presence alone. A ticket only re-enters the queue when a human (or
   work-prep) explicitly re-adds `build-ready`.

### Idempotency
Idempotent per ticket and per PR: re-running the script against a queue with no new
`build-ready` tickets produces no new PRs, worktrees, or label transitions — with one
accepted exception (see "accepted trade-off" above): a crash after a PR opens but
before `HANDOFF_REVIEW` is reached can produce a duplicate PR on the next run, since a
ticket carries no in-progress marker. This is deliberate, not a defect to fix.

### Versioning policy
Companion script to `babysit-with-review.sh`; no independent version number proposed
yet. Breaking changes to the `build-*` label schema or the spec-resolution contract
require manual migration of any open build PRs.

## Performance budget
- **Per-ticket build+review latency:** comparable to a full `babysit-with-review.sh`
  outer-loop-iteration-plus-review-cycle (p50 ~6min, p95 ~25min) — one implementer
  build pass plus a full convergent review cycle (up to `MAX_REVIEW_CYCLES`).
- **Run of 5 tickets:** on the order of 30min-2hr, dominated by review-cycle
  convergence rate (no formal SLO — internal tool, see `ASF-SYS-AUTONOMOUS-DEV` SLOs
  section).

## Security model
- **AuthN / AuthZ:** Inherits `gh auth status`; Jira access via `JIRA_TOKEN` bearer
  token — unlike work-prep's read-only Jira scope, builder needs write access too
  (label add/remove for kickback and, if the multi-source assumption above is
  confirmed, for build-state transitions on Jira-sourced tickets).
- **Tenant isolation:** Single-user; PRs/issues created and labelled in the
  authenticated account's accessible repos and Jira project.
- **No auto-merge is the core security property of this spec.** Unlike
  `babysit-with-review.sh`'s `codex-review` status gate (which prevents self-merge of
  code that failed review), this script's entire merge surface is human-gated by
  construction — there is no automated path from "ticket labelled build-ready" to "code merged"
  without a human clicking merge. This is a stronger guarantee than the status-gate
  approach, not a weaker one, but only holds if the [ASSUMPTION] above (posting
  `codex-review=success` on convergence) doesn't get reinterpreted as "and then also
  merge" during implementation.
- **PII handling:** Ticket/spec titles and code context only; no user data.

## Telemetry contract
Events emitted to stdout:
- `[build] ticket <id> (<source>, spec: <path>) → worktree created, implementing`
- `[build] ticket <id> (<source>) → PR #M opened, HANDOFF_REVIEW → entering build cycle`
- `[build] PR #M → cycle <k>: <n> BLOCKING, <m> RECOMMENDED`
- `[build] PR #M → cycle <k>: 0 BLOCKING → converged, labelled build-ready-for-merge, codex-review=success posted, summary comment posted, halted for human merge`
- `[build] PR #M → max cycles exhausted, labelled build-max-cycles, summary comment posted, halted for human merge`
- `[build] ticket <id> (<source>) → SPEC_GAP: <reason>, labelled build-needs-clarification, build-ready removed, comment posted`

Events emitted to stderr:
- `[build] ticket <id> (<source>): STUCK: <reason> → left in queue`
- `[build] ticket <id> (<source>): worktree/implementer failure → left in queue`
- `[jira] Jira API unavailable → skipping Jira-sourced tickets this run`

## Verifiers
- Tech lead: Chris Robertson
- Security: verify no code path can reach `gh pr merge` before this spec moves to
  `ready` (see security model above); this is the one invariant this spec cannot
  tolerate drifting
- QA: verify the stop file's PID-liveness check actually prevents a second concurrent
  invocation from processing the same queue, terminal-state mutual exclusivity, that a
  `build-needs-clarification` ticket is never re-selected, and that the [ASSUMPTION]
  branch-protection status write never accompanies a merge call

## Failure modes & blast radius
- **Worktree/implementer failure mid-build (before a PR opens):** ticket logged to
  stderr; it was never relabelled, so it's picked up again next run. Blast: wasted
  implementer inference time, no partial-PR state to clean up.
- **Crash after a PR opens (before or after `HANDOFF_REVIEW`):** the ticket is still
  `build-ready` (no in-progress marker was ever applied — deliberately, per the
  accepted trade-off in "What we know"), so the next run builds it again as a second
  PR. Blast: a stray, unreviewed PR the queue never revisits; mitigated only by an
  operator noticing and closing the orphan. This is accepted behavior, not a defect —
  see the acceptance test and kill criterion below for where it would stop being
  acceptable.
- **Review cycle exhausts max cycles with BLOCKING findings still open:** PR labelled
  `build-max-cycles`, left open and unmerged. Blast: human must manually resolve or
  close; no auto-merge risk regardless.
- **Spec-gap kickback fires on a ticket that actually had enough information:** a
  false-positive gap detection removes `build-ready` and stalls a buildable ticket
  until a human notices the `build-needs-clarification` label and either fixes the
  ticket or manually re-adds `build-ready`. Blast: delayed build, not incorrect code —
  no auto-merge risk, but a source of friction if the implementer's gap judgment is
  miscalibrated (see kill criteria).
- **[ASSUMPTION]-linked: `codex-review=success` posted without merge on a
  protected repo:** if an operator or another automation later merges the PR through a
  different path (e.g., manually via `gh pr merge` outside this pipeline), the status
  gate's only remaining protection is human judgment at merge time — same residual
  risk `babysit-with-review.sh` already accepts for its own status writes.

# Bounds

## Out of scope
- **Merging.** This script's entire reason for existing separately from
  `babysit-with-review.sh` is that it never merges; if auto-merge is later wanted for
  builder PRs, that is a new script or a flag on this one, not a silent addition here.
- **Spec drafting or amendment.** If a ticket's referenced spec has a gap, this script
  kicks it back (`SPEC_GAP` → `build-needs-clarification`) rather than attempting to
  fix the spec itself — actually revising the spec belongs to `babysit-work-prep.sh`
  or a human.
- **Non-GitHub, non-Jira ticket sources.** Linear, Shortcut, etc. are out of scope,
  matching `ASF-PROD-BABYSIT-WITH-REVIEW`'s existing out-of-scope list.

## Assumptions-that-could-flip
- **No-per-ticket-claiming assumption.** If flipped (multi-host builder becomes a
  supported scenario, so the local PID-checked stop file no longer serializes all
  builder activity against a project): a per-ticket claim (label or distributed lock)
  becomes necessary to prevent double-building the same ticket from two hosts.
- **Accepted-duplicate-PR assumption.** If flipped (orphaned PRs from
  crash-and-rebuild prove costly in practice — repo clutter, confusion about which PR
  is live): would need an in-progress marker after all, reintroducing the
  claim/release mechanics this spec currently avoids — trading a self-cleaning
  duplicate-PR nuisance for permanent per-ticket state tracking.
- **Status-without-merge assumption.** If flipped (owner decides branch protection
  should not apply to builder PRs, or a distinct check name should gate builder
  merges): would need its own status context (e.g., `builder-review`) instead of
  reusing `codex-review`, to keep the two loops' merge gates independently tunable.
- **Label-over-status Jira query assumption.** If flipped (Jira gates on workflow
  status, not the `labels` field, for this signal): the JQL clause needs to filter on
  status instead of `labels=build-ready`, and the kickback path needs a status
  transition, not just a label write — which would also break the label-only
  Jira-write-back decision inherited from L1.
- **Implementer-judgment gap-detection assumption.** If flipped (false-positive
  kickbacks prove too frequent): would need a more structured spec-completeness check
  (e.g., a required-sections lint) ahead of the implementer's freeform judgment call.

## Composes with / replaces
- **Composes with:**
  - `babysit-work-prep.sh` — currently the primary (but not exclusive) producer of
    buildable tickets. **Coordination note:** the shipped `babysit-work-prep.sh`
    currently labels its sub-tickets `sub-ticket` + `status:ready-to-build`, not
    `build-ready`. For work-prep output to be picked up under this contract,
    work-prep needs to add `build-ready` to its sub-ticket creation (in addition to
    or instead of `status:ready-to-build`) — this is a required follow-up change to
    `babysit-work-prep.sh` / `ASF-FEAT-WORK-PREP`, not something this spec can
    resolve unilaterally.
  - GitHub Issues and Jira (ticket sources, queried directly by `build-ready` label —
    not exclusively through work-prep's bridging)
  - `babysit-with-review.sh` (mirrors `run_review_cycle`'s convergence/MCP-resilience
    machinery as `run_build_cycle`; shares no runtime state or lock file with it).
    The shared-library-versus-duplication decision is **resolved as duplication**:
    `babysit-builder.sh` carries its own copies of the review prompt templates,
    `count_blocking`, `valid_review_structure`, `codex_review_with_retry`,
    `claude_review`, and the quarantine helpers. This follows the precedent
    `babysit-work-prep.sh` already set by duplicating `run_claude`/`run_codex`, and
    keeps each script a self-contained deployable. The cost is real and should be
    revisited if a third consumer appears: a fix to the review parser or the telltale
    regex now has to land in two files.
  - `setup-branch-protection.sh` / the `codex-review` status check (see
    branch-protection assumption above)
- **Distinct from `babysit-with-review.sh`:** never merges; operates on a labelled
  ticket queue instead of a freeform goal description; own label namespace.

# Signals

## Acceptance tests
1. **Given** a GitHub issue labelled `build-ready` (with or without `sub-ticket`)
   referencing a valid spec file, **when** the script runs, **then** a worktree is
   created, the spec is implemented, a PR is opened, and the build cycle begins.
2. **Given** a build cycle that reaches `BLOCKING=0` on cycle 2, **when** convergence is
   detected, **then** the PR is labelled `build-ready-for-merge`, a
   `codex-review=success` status is posted, a summary comment is posted, and no
   `gh pr merge` call is made.
3. **Given** a build cycle that reaches `MAX_REVIEW_CYCLES` with BLOCKING findings still
   open, **when** the cap is hit, **then** the PR is labelled `build-max-cycles`, a
   summary comment is posted, and no `codex-review` status is posted.
4. **Given** a `babysit-builder.sh` invocation already running for a project (live PID
   in the stop file), **when** a second invocation starts against the same project,
   **then** it exits 1 immediately without reading the build queue or touching any
   ticket.
5. **Given** a ticket whose spec has a genuine gap (e.g., missing acceptance
   criteria), **when** the implementer begins the build attempt, **then** it ends with
   `SPEC_GAP`, the ticket is labelled `build-needs-clarification` with `build-ready`
   removed, a comment explaining the gap is posted, and no PR is opened.
6. **Given** a ticket previously left `build-needs-clarification`, **when** the queue
   is next read (with `build-ready` still absent), **then** the ticket is not
   re-selected.
7. **Given** a ticket whose PR reached `build-ready-for-merge` in a prior run, **when**
   the queue is next read, **then** the ticket is not re-selected — confirming the
   merge-track terminal transition swapped `build-ready` for `build-done` (not just
   added `build-done` alongside a still-present `build-ready`).
8. **Given** `--source jira` and a Jira issue carrying the `build-ready` label with a
   resolvable spec reference, **when** the script runs, **then** it is built through
   the same worktree → PR → build-cycle path as a GitHub-sourced ticket, and its
   telemetry lines are tagged `(jira)`.
9. **Given** `--source both` with one `build-ready` GitHub issue and one `build-ready`
   Jira issue, **when** the script runs, **then** both are built in the same
   invocation.
10. **Given** a builder process that crashes after opening a PR but before
    `HANDOFF_REVIEW`, **when** the script is re-run against the same ticket (still
    `build-ready`), **then** it builds a second PR from a fresh worktree/branch with no
    trace of the discarded attempt's changes — confirming the accepted-duplicate-PR
    trade-off holds in practice, not just in worktree theory.
11. **Given** `--max-tickets 1` and 3 queued `build-ready` tickets, **when** the script
    runs, **then** exactly 1 ticket is built and the other 2 remain queued for the
    next run.
12. **Given** `--dry-run`, **when** the script runs, **then** it prints the build queue
    and what would be built, with no worktree, gh/Jira, or label write calls made.
13. **Given** a `review-*`-labelled PR from a concurrently running
    `babysit-with-review.sh` invocation on the same repo, **when** the builder's build
    queue query runs, **then** it never selects or modifies that PR or its issue.

## Telemetry events tied to L1 KPIs
- **Tickets built per run, by source** → throughput of the build pipeline, downstream
  of work-prep's (or any other producer's) drafting throughput
- **Cycles-to-convergence per build PR** → build-quality signal, comparable to
  `babysit-with-review.sh`'s own review-cycle convergence metric
- **build-max-cycles rate** → fraction of builds that exhaust the cycle cap without
  converging; a leading indicator that implementer prompts or spec quality need work
- **SPEC_GAP kickback rate** → fraction of `build-ready` tickets that turn out to have
  incomplete specs; a leading indicator of work-prep drafting quality or of the
  implementer's gap-detection judgment being miscalibrated

## AEAB cases
N/A — no eval framework yet. Future: record (ticket_id, source, spec_id, pr_number,
cycles_to_halt, halt_reason, time_to_human_merge) to compute end-to-end
ticket-to-merged-code lead time across the full three-script pipeline.

## Kill criteria
- If `build-max-cycles` rate exceeds 50% of built tickets → spec quality from
  `babysit-work-prep.sh` needs tightening, or `MAX_REVIEW_CYCLES` needs raising for
  builder specifically
- If duplicate PRs from crash-and-rebuild (the accepted trade-off) become a measurable
  operational annoyance (e.g., an operator regularly has to hunt for the live PR among
  orphans) → revisit the no-per-ticket-claiming assumption and add an in-progress
  marker
- If `SPEC_GAP` kickback rate exceeds 30% of `build-ready` tickets → either work-prep's
  drafting needs tightening, or the implementer's gap-detection judgment is
  miscalibrated (too trigger-happy) and needs a more structured completeness check
- If human merge latency after `build-ready-for-merge` consistently exceeds the
  drafting+build latency combined → the halt-for-human-merge design is a bottleneck,
  revisit whether limited auto-merge (e.g., only for `RECOMMENDED`-only PRs) is worth
  the security trade-off
