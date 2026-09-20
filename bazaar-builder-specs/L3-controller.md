---
spec_type: feature
id: BZR-FEAT-CONTROLLER
status: review
owners: [Chris Robertson]
depends_on: [BZR-SYS-BAZAAR]
parent_l1: BZR-PROD-BAZAAR-BUILDER
parent_l2: BZR-SYS-BAZAAR
fit_check: passed
complexity:
  total: 2
  band: trivial
  drivers: [novelty, time_estimate]
  scored_on: 2026-09-19
---

# Frame

## TL;DR
Two thin scripts, `bazaar-issues.sh` and `bazaar-build.sh`, share one controller loop from `lib/bazaar-common.sh`. Each tick a controller runs its sweeps, reads its queue, drops anything claimed by a live worker, picks the top candidate, claims it, and spawns its worker in a fresh worktree, up to `--workers` at a time. Nothing is time-bounded: a claim is held by a process, not by a clock, and a failed attempt simply returns the issue to its queue until the third failure escalates it to a human. Controllers never read code, never write specs, and call a model only to break ties.

## Analog
Like a job dispatcher reading a work-queue table, where the table is GitHub labels and the lease is a PID.

## Reader & next action
Implementing agent: build `lib/bazaar-common.sh` and the two scripts per the surface below. Chris Robertson: confirm the attempt-counter mechanics.

## API surface fragment
*Implemented 2026-09-19: `lib/bazaar-common.sh` v0.1.0, `bazaar-issues.sh` v0.1.0, `bazaar-build.sh` v0.1.0. Harnesses `test-bazaar-common.sh` (33), `test-bazaar-build.sh` (16), `test-bazaar-issues.sh` (33), all green over `test-support/fake-gh.py`.*
```bash
bazaar-issues.sh [OPTIONS]        # issue controller: intake → spec → approval
bazaar-build.sh  [OPTIONS]        # build controller: bzr-ready → PR

Common options (lib/bazaar-common.sh):
  --repo OWNER/REPO         Default: gh repo view in cwd.
  --workers N               Concurrent workers (1-8). Default: 1. This is the cost dial.
  --once                    One tick, then exit (cron-friendly). Default: loop every --interval.
  --interval SECONDS        Default: 60.
  --controller-model MODEL  Tie-break model, run with --effort low. Default: claude-haiku-4-5-20251001.
                            'none' disables model calls.
  --implementer claude|codex  --implementer-model  --implementer-effort
  --reviewer    claude|codex  --reviewer-model     --reviewer-effort
                            Passed through to workers (same semantics as babysit-with-review.sh).
  --dry-run                 Print the dispatch decision; no writes.
  --audit                   Print state-machine inconsistencies; no writes.
  --stop                    Touch this script's stop file; running workers finish, no new dispatch.

bazaar-build.sh only:
  --issue N                 Dispatch this issue once and exit; requires bzr-ready unless --force.
  --force                   Skip the label check (never the precheck).

Env: BZR_APPROVERS (default: gh api user login), MAX_ATTEMPTS (3),
     MAX_REVIEW_CYCLES (6), MAX_SPEC_REVIEW_CYCLES (4), BZR_HOME (~/.bazaar)

Exit: 0 clean stop, 1 fatal (incl. reviewer outdated / no credits), 2 usage.

Labels (the whole set):
  bzr-drafting  bzr-needs-info  bzr-spec-review     # issue side
  bzr-ready     bzr-building    bzr-pr-ready        # build side
  bzr-blocked                                       # human escalation, either side
Marker comments (agent-authored, first line):
  <!-- bzr-claim role=issue|build host=H pid=P ts=T -->
  <!-- bzr-attempt role=issue|build n=K reason=... -->
  <!-- bzr-escalated role=issue|build attempts=K -->
```

### Implementation notes (2026-09-19)
- **Controllers own every parent-issue label transition.** Workers write only sentinels (last line of `$BZR_SENTINEL`), comments, PRs, and `bzr-blocked` on skipped sub-issues. The worker L3s' "wrapper moves the label" wording is superseded by this: the wrapper is the controller's `role_on_worker_exit`.
- **Role hooks** a controller script defines over the common lib: `role_parse_arg` (runs in the caller's shell, sets `BZR_ROLE_CONSUMED`), `role_claim_label`, `role_queue_label`, `role_release_label`, `role_candidates`, `role_worker_cmd`, `role_sweeps`, `role_on_worker_exit`, optional `role_dry_sweeps` and `role_audit`.
- **No jq, bash 3.2.** All JSON goes through python3; `gh --jq` is avoided so the test stub can serve plain JSON; the child registry is a directory of pid files; the worker subshell gets its pid from `bash -c 'echo $PPID'` (no `BASHPID`).
- **Dry-run** runs no sweeps with side effects; `role_dry_sweeps` reports would-approve / would-escalate.
- **`--force`** on `bazaar-build.sh --issue N` bypasses the pre-claim label check (`BZR_SKIP_LABEL_CHECK`) but never the worker's precheck.
- **Escalation** replaces every `bzr-*` state label with `bzr-blocked`, so a rejected `bzr-spec-review` issue ends with exactly one label.
- **Approval marker** is `<!-- bzr-spec-merged pr=N -->`; the comment guard refuses any agent body containing the approval word, including marker names.
- **Local checkout for the approval sweep:** the git repo the controller runs in, else a clone under `~/.bazaar/<owner>-<repo>/clone`.

## Consumer
Operator shell, cron, or the staff-fleet dispatcher. Spawns [BZR-FEAT-ISSUE-WORKER](L3-issue-worker.md) or [BZR-FEAT-BUILD-WORKER](L3-build-worker.md).

# Substance

## What we know
- Owner decisions 2026-09-19: controllers only queue the next item, model as tie-breaker; concurrency is `--workers`; every open issue without a `bzr-*` label is intake (no opt-in label); no time-based lease, everything asynchronous; no outage labels, a failed step is retried on the next run and `bzr-blocked` is only for human escalation or after three automatic attempts; two scripts, not one.
- `gh issue list --json` returns `labels`, `createdAt`; `gh api graphql` exposes `Issue.parent` (probed 2026-09-19) for excluding sub-issues.
- `claude --help` (2026-09-19) offers `--effort low|medium|high|xhigh|max` and no thinking switch; `--effort low` is the controller setting.
- Stop-file pattern: PID-checked stop file as in the babysit family.

## What we assume
- [ASSUMPTION] Liveness is by process. A claim marker names `host`, `pid`, and the process start time (`ps -o lstart=`), so a recycled pid is not mistaken for the worker. A controller releases a claim when the host is its own and the pid is dead, and releases all of its own host's claims for its role at startup (no worker can have survived it). Claims naming another host are never touched. Flips if: controllers run on several hosts for one repo, in which case the home-lab-monitor lock becomes the lease.
- [ASSUMPTION] The attempt counter is the number of `bzr-attempt` markers for this role posted after the newest `bzr-escalated` marker (or ever, if none). Reaching `MAX_ATTEMPTS` escalates: `bzr-blocked` plus a `bzr-escalated` marker. A human clears `bzr-blocked`; the next failures count from zero because they follow the escalation marker. Flips if: comment volume becomes a nuisance, then the counter moves into the claim marker.
- [ASSUMPTION] Tie-break by model only when two or more candidates share the top priority label. Flips if: the owner wants the model to weigh content.
- [ASSUMPTION] The approval and bounce sweeps live in `bazaar-issues.sh`; the merged-PR sweep lives in `bazaar-build.sh`. Flips if: the owner wants approvals to land while the issue controller is off.

## Contract

### Request shape
One tick = `(role, repo, free_slots)`.

### Response shape
Per tick, zero or more `dispatch <issue>` and `skip <issue> <reason>` log lines; one claim written per dispatch.

### Queue definition per role
| Script | Queue (in order) | Sweeps before reading |
|---|---|---|
| `bazaar-issues.sh` | open issues that are not sub-issues, not PRs, and carry no `bzr-*` label | (a) dead-pid release: `bzr-drafting` → no label; (b) bounce: `bzr-needs-info` with a human comment newer than the last marker → no label; (c) approval sweep (below); (d) rejected spec: `bzr-spec-review` whose spec PR was closed unmerged → `bzr-blocked`, close its draft-time sub-issues |
| `bazaar-build.sh` | `bzr-ready` | (a) dead-pid release: `bzr-building` → `bzr-ready`; (b) merged sweep: `bzr-pr-ready` whose PR merged → close parent if every sub-issue is closed, else `bzr-ready` for the remaining unblocked sub-issues |

Excluded from every queue: sub-issues (built through their parent), closed issues, issues carrying `bzr-blocked`, issues whose newest claim names a live process.

### Approval sweep (`bazaar-issues.sh`)
For each open issue in `bzr-spec-review` whose spec PR (branch `bzr/spec-<issue>`, body `Refs #<issue>`) is non-draft and approved per the L2 "Human → system" contract. Each step idempotent:
1. In a scratch worktree on the PR branch, rewrite `status: review` → `status: ready` in every changed file with a `spec_type:` frontmatter; commit `spec: mark ready per approval on #<issue>`; push. This is the only content edit a controller makes, authorised by the approval.
2. Post commit status `codex-review=success` on the new head (same `gh api` call as `babysit-builder.sh`), since `setup-branch-protection.sh` requires it on main. `babysit-work-prep.sh` merges bare today (line 416) and would fail on a protected repo.
3. `gh pr merge --merge`. On failure: comment on the issue, stay in `bzr-spec-review`, retry only when the PR head changes.
4. Reconcile sub-issues: the worker created them at draft time (see [BZR-FEAT-ISSUE-WORKER](L3-issue-worker.md)); the sweep verifies one open sub-issue with a `bzr-sub-issue … spec=<L4 ID>` marker exists per merged `spec_type: task` file, creates any missing, and closes any whose L4 was dropped from the final PR.
5. Rewrite the parent's `Specs:` line to the merged spec IDs and paths (the build precheck reads this).
6. `bzr-spec-review` → `bzr-ready`; comment with the merged spec list and sub-issue numbers.

Interrupted after step 3: detected as "PR merged, issue still `bzr-spec-review`", resumes at step 4.

### Attempt handling (both scripts)
A worker exit that is transient (`STUCK`, reviewer transport failure after the lib's own retries, crash without sentinel) makes the controller: post `bzr-attempt n=K`, return the issue to its queue state (issue side: remove the claim label so it has no `bzr-*` label; build side: `bzr-building` → `bzr-ready`), and, if `K ≥ MAX_ATTEMPTS`, add `bzr-blocked` and post `bzr-escalated`. Reviewer-outdated and no-credits are not attempts: the controller comments on the PR, leaves the issue in its queue state, and exits 1 for the operator.

### Invariants
1. A controller never edits code or PR contents, and never edits spec text except the approval-authorised status flip.
2. At most `--workers` worker processes per controller.
3. Claim order: add claim label, remove prior state label if any, post claim marker. Spawn only after all three succeed; on partial failure revert and log.
4. Labels are re-read immediately before claiming; a candidate claimed since the queue read is skipped.
5. No claim is ever released on elapsed time.
6. The model may only return an issue number from the candidate list; anything else falls back to sort order.
7. `--dry-run` and `--audit` perform no writes.
8. The stop file stops new dispatch only; workers are never killed by a controller.
9. Every transition is add-then-remove.
10. `bzr-blocked` is added only by escalation (attempts, `NOT_ACTIONABLE`, rejected spec, skipped sub-issues) and removed only by a human.

### Error model
- `gh` read failure: skip tick; halt after 3 consecutive.
- Claim write fails midway: revert, log `claim-failed`, continue.
- Worker exits without a sentinel: treated as a transient attempt.
- Model call fails or returns garbage: sort order.
- Approval merge fails: see sweep step 3.

### Idempotency
A tick is safe to repeat. Claims are checked against live labels and live pids. Sweeps detect partial completion and finish the missing steps.

### Versioning policy
Semver per script and for the lib, starting 0.1.0.

## Performance budget
Tick under 10s with an empty queue; at most one model call per tick.

## Security model
Inherits `gh` auth. Approval accepted only from `BZR_APPROVERS`. The word "approved" is forbidden in every agent-authored comment (grep guard in the shared comment helper).

## Telemetry contract
Log lines `[ctl:<role>]`: `tick`, `dispatch <issue> worker=<pid>`, `skip <issue> <reason>`, `claim-failed`, `dead-pid-release <issue>`, `attempt <issue> n=<K>`, `escalate <issue>`, `bounce <issue>`, `approved <issue> pr=<n>`, `merged-sweep <issue> …`, `worker-exit <issue> rc=<n> sentinel=<word>`. Sink: `$BZR_HOME/<repo>/logs/ctl-<role>-<date>.log`.

## Verifiers
- Tech lead: Chris Robertson
- QA: recording-stub harness, `IMPLEMENTATION-PLAN.md` phase 2.

## Failure modes & blast radius
- **Double dispatch:** covered by invariants 3-4 and pid liveness; blast one issue.
- **Controller on host A dies while worker on host A still runs; controller restarts:** startup release would free a live claim. Mitigation: startup release checks each pid before releasing; only dead pids are freed.
- **Approval regex false positive** ("not approved yet"): a spec merges early. Mitigation: negative-phrase guard and GitHub review state preferred. [ASSUMPTION] the guard is enough. Flips if: it misfires once, then approval moves to GitHub reviews only.
- **Attempt markers drown the thread:** three per escalation at most; acceptable.

# Bounds

## Out of scope
Priority inference, planning, cross-host leases, killing workers, any code or spec edit beyond the status flip.

## Assumptions-that-could-flip
- **Model tie-break.** Flip to `none` by default if it never changes an outcome in the first month.

## Composes with / replaces
Composes with both workers, `lib/bazaar-common.sh`, and [BZR-FEAT-REVIEW-LIB](L3-review-lib.md). Replaces the queue logic of `babysit-work-prep.sh` and `babysit-builder.sh`, both of which are deleted in plan phase 5. Consumed by [BZR-FEAT-BUILD-WORKER](L3-build-worker.md)'s precheck via the `Specs:` line and sub-issue markers.

# Signals

## Acceptance tests
1. **Given** two unlabelled open issues, one `P1`, **when** `bazaar-issues.sh` ticks with 1 free slot, **then** the `P1` issue is claimed and the other logged `skip no-slot`.
2. **Given** an issue in `bzr-drafting` whose claim names this host and a dead pid, **when** a tick runs, **then** the label is removed and `dead-pid-release` logged.
3. **Given** the same but the pid is alive, **when** a tick runs, **then** nothing changes even after hours.
4. **Given** a claim naming another host, **when** a tick runs, **then** it is skipped, never released.
5. **Given** an issue in `bzr-needs-info` with a human comment newer than the last marker, **when** a tick runs, **then** the label is removed and the issue is intake again.
6. **Given** an approved spec PR with two L4s and two draft-time sub-issues, **when** a tick runs, **then** the PR merges with `codex-review=success` on its head, every merged spec is `status: ready`, sub-issues are unchanged, the parent's `Specs:` line lists the IDs, and the issue is `bzr-ready`.
7. **Given** the sweep crashed after merging, **when** the next tick runs, **then** it resumes at reconciliation and creates no duplicates.
8. **Given** "not approved yet", **when** a tick runs, **then** nothing changes.
9. **Given** a worker exits `STUCK` for the third time since the last escalation, **when** the controller handles it, **then** `bzr-blocked` is added, `bzr-escalated` posted, and the issue leaves every queue.
10. **Given** a human removes `bzr-blocked`, **when** the next failure occurs, **then** the attempt count is 1.
11. **Given** `--workers 2` and three `bzr-ready` issues, **when** `bazaar-build.sh` ticks, **then** exactly two are claimed.
12. **Given** a sub-issue with no labels, **when** `bazaar-issues.sh` ticks, **then** it is skipped with `is-sub-issue`.
13. **Given** a `bzr-pr-ready` parent whose PR merged with one sub-issue skipped and later unblocked, **when** the merged sweep runs, **then** the parent becomes `bzr-ready`.
14. **Given** the stop file exists, **when** a tick runs, **then** no dispatch and exit 0 after workers finish.

## Telemetry events tied to L1 KPIs
`dispatch`/`worker-exit` pairs give wall-clock per stage; `attempt` and `escalate` counts feed the reliability indicator.

## AEAB cases
N/A.

## Kill criteria
Double dispatch observed more than once after release; escalations above 20% of issues over 30 days.
