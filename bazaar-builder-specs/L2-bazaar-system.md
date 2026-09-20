---
spec_type: system
id: BZR-SYS-BAZAAR
status: review
owners: [Chris Robertson]
depends_on: [BZR-PROD-BAZAAR-BUILDER]
serves_l1: [BZR-PROD-BAZAAR-BUILDER]
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [surface_span, external_integration, scope]
  scored_on: 2026-09-19
---

# Frame

## TL;DR
Two long-running bash controllers (`bazaar-issues.sh`, `bazaar-build.sh`, sharing `lib/bazaar-common.sh`) read a GitHub label queue, claim one issue each per free worker slot, and run a worker agent inside a per-issue git worktree. Claims are held by live processes, never by a clock. Workers talk to GitHub only through `gh`, run Claude or Codex through a shared library, and report back with a sentinel line. All durable state lives in GitHub labels and comments; nothing on disk survives a run except logs and worktrees.

## Analog
Like a systemd timer plus a job runner: the timer is dumb, the job knows the work, and the queue is the ticket system itself.

## Reader & next action
Chris Robertson, before implementation: confirm the label state machine and the claim protocol, then approve the extraction plan in `IMPLEMENTATION-PLAN.md`. Implementing agent: read this page, then the L3 for the component being built.

## Component diagram

```
              GitHub (labels + comments + sub-issues = the only durable state)
   ┌──────────────────────────────────────────────────────────────────────────┐
   │ (no bzr label) → bzr-drafting → bzr-needs-info ⇄ … → bzr-spec-review     │
   │           → bzr-ready → bzr-building → bzr-pr-ready → (closed by merge)  │
   │ side state: bzr-blocked (human escalation only)                          │
   └───────────▲────────────────────────────────▲────────────────────────────┘
               │ gh                              │ gh
   ┌───────────┴───────────┐          ┌──────────┴────────────┐
   │ bazaar-issues.sh      │          │ bazaar-build.sh       │   controllers
   │  queue: no bzr label  │          │  queue: bzr-ready     │   (lib/bazaar-common.sh
   │  sweeps: dead-pid,    │          │  sweeps: dead-pid,    │    + optional Haiku
   │   bounce, approval,   │          │   merged-PR           │    tie-break)
   │   rejected spec       │          │                       │
   │   approval sweep      │          │   or --issue N        │
   │  --workers N          │          │  --workers N          │
   └───────────┬───────────┘          └──────────┬────────────┘
               │ spawn per issue                  │ spawn per issue
   ┌───────────▼───────────┐          ┌──────────▼────────────┐
   │ issue worker          │          │ build worker          │   workers
   │  worktree bzr/spec-N  │          │  worktree bzr/N-slug  │   (implementer +
   │  verify → classify →  │          │  precheck → plan →    │    reviewer via lib)
   │  draft specs → spec   │          │  per sub-issue:       │
   │  review cycle → PR    │          │   implement → review  │
   └───────────┬───────────┘          └──────────┬────────────┘
               └──────────────┬───────────────────┘
                              ▼
                  lib/bazaar-review.sh  (BZR-FEAT-REVIEW-LIB)
                  run_implementer | review_with_retry | run_review_cycle --mode code|spec
                              │
               ┌──────────────┼──────────────┬───────────┐
               ▼              ▼              ▼           ▼
           claude -p      codex exec        gh          git worktree
```

**Authoritative surface:** the label on the issue. A worker that crashes leaves the claim label in place; the controller on that host releases it when it sees the pid is dead.

# Substance

## What we know
- Owner decisions 1-12 recorded in [BZR-PROD-BAZAAR-BUILDER](L1-bazaar-builder.md) "What we know".
- The review cycle to be extracted exists in `babysit-builder.sh` (`run_build_cycle`, line 1093) and `babysit-work-prep.sh` (`run_spec_review_cycle`, line 1040). The builder copy already keeps the worktree alive through the review cycle and never calls `gh pr checkout`, which is the behaviour this system needs for concurrent workers.
- `gh api repos/{owner}/{repo}/issues/{n}/sub_issues` (GET) and GraphQL `subIssues` / `subIssuesSummary` / `parent` work for this account (probed 2026-09-19, read only).
- Agent and human share one GitHub login here, so comment authorship carries no information.
- `babysit-builder.sh` posts a `codex-review=success` commit status at convergence; `setup-branch-protection.sh` makes that status required on main. Both are reused unchanged.

## What we assume
- [ASSUMPTION] Creating a sub-issue relationship is `POST /repos/{owner}/{repo}/issues/{parent}/sub_issues` with `sub_issue_id` set to the child's numeric `id` (not its `number`), per GitHub REST docs; not yet exercised here. Flips if: the endpoint needs a different payload or a feature flag on the repo, in which case the approval sweep falls back to a tasklist in the parent body.
- [ASSUMPTION] One controller process per repo per role; `--workers N` bounds concurrent workers inside that process. Flips if: the staff-fleet dispatcher wants to run controllers on several hosts for one repo, which would need the home-lab-monitor lock added to the claim step.
- [ASSUMPTION] A claim is a label (`bzr-drafting` or `bzr-building`) plus a comment `<!-- bzr-claim role=… host=… pid=… ts=… -->`. It is released only when the controller on that host finds the pid dead. There is no time limit. Flips if: a worker hangs forever (pid alive, no progress), in which case the operator kills it and the next tick releases the claim; an automatic no-progress detector would be a new feature.
- [ASSUMPTION] Worktrees live under `~/.bazaar/<owner>-<repo>/wt/<issue>` and logs under `~/.bazaar/<owner>-<repo>/logs/`, outside the repo checkout so the operator's working tree is never touched. Flips if: the operator wants worktrees beside the repo as the ASF scripts do.
- [ASSUMPTION] Transient failures are counted per issue and role with `bzr-attempt` marker comments; the third escalates to `bzr-blocked`. Flips if: see L1.
- [ASSUMPTION] Spec review and code review share one `run_review_cycle` with a `--mode` switch; only prompts and the "what to do at convergence" hook differ. Flips if: extraction shows the two loops differ in control flow, not only in text.

## Cross-component contracts

### Controller → GitHub (queue read)
- **Protocol:** `gh issue list --label <state> --state open --json number,title,labels,createdAt,updatedAt --limit 1000`, plus `gh api graphql` for `parent` to exclude sub-issues from the issue-role queue.
- **Request shape:** one query per queue label per tick.
- **Response shape:** JSON array; controller sorts by priority label (`P0`..`P3`, then none) then `createdAt` ascending.
- **Retry policy:** a failed `gh` call skips the tick; three consecutive failures halt the controller with exit 1.
- **Idempotency:** read-only.

### Controller → worker (spawn)
- **Protocol:** subprocess with env `BZR_ROLE`, `BZR_ISSUE`, `BZR_REPO`, `BZR_WORKTREE`, `BZR_BRANCH`, `BZR_LOG`, harness/model/effort variables.
- **Request shape:** exactly one issue number.
- **Response shape:** worker exit code plus the last line of its transcript, one sentinel (see L3s).
- **Retry policy:** none by the controller; the label state decides whether the issue is requeued.
- **Idempotency:** a re-spawn on the same issue must find its prior branch and PR and resume, not restart.

### Worker → GitHub (state write)
- **Protocol:** `gh issue edit --add-label/--remove-label`, `gh issue comment`, `gh pr create/edit/comment`, `gh api` for sub-issues and commit status.
- **Invariant:** every state transition is one add plus one remove in that order, so an interrupted write leaves the issue with two labels (detectable) rather than none (lost).

### Worker → lib/bazaar-review.sh
- **Protocol:** sourced bash library, see [BZR-FEAT-REVIEW-LIB](L3-review-lib.md).

### Human → system
- **Bounce reply:** any new comment on an issue in `bzr-needs-info` whose body lacks the `<!-- bzr-` marker and is newer than the agent's last marker comment requeues the issue (controller removes `bzr-needs-info`, so the issue is intake again).
- **Approval:** a comment on the spec PR matching `\bapproved\b` (case-insensitive) or a GitHub review with state `APPROVED`, from a login in `BZR_APPROVERS` (default: the authenticated user). Agent comments never contain that word; this is an invariant of the issue worker.
- **Merge:** the human merges the build PR. Merge closes the parent issue via `Closes #N` in the PR body.

## SLOs and latency budgets
Deferred. Observed ASF numbers: one implementer pass 5-30 min; one reviewer pass 1-7 min including retries. Target: controller tick under 10s; dispatch latency under one tick interval (default 60s).

## Failure-domain map
- **Cell:** one repo. A controller crash affects one repo's one role.
- **Worker crash:** one issue stays claimed until its host's controller sees the dead pid, then returns to queue as one attempt. Branch and any PR survive on origin (safety push before exit).
- **GitHub API down:** both controllers idle; no state lost.
- **Model backend down:** workers exit STUCK; issues return to queue as one attempt each; a long outage escalates every touched issue after three.

## bazaar-infra.yaml dependencies
N/A. External: `gh` (authenticated), `git`, `claude` CLI, `codex` CLI (only when a role selects codex), `jq`.

## Compliance posture
Single-user, self-hosted. Code and issue text go to Anthropic and OpenAI per the selected harnesses, as today. No PII beyond what is already in the repo's issues.

## Verifiers
- Architecture: Chris Robertson
- SRE: Chris Robertson
- Security: Chris Robertson (see `SECURITY-REVIEW-PLAN.md` in `babysit-specs/` for the inherited checklist)
- Compliance: N/A

## Failure modes & blast radius
- **Two controllers of the same role on one repo:** both read the same queue. Blast: double claim race. Mitigation: label claim is checked again immediately before spawn, and the worker aborts if the claim comment it posted is not the newest claim comment.
- **Claim released while the worker is alive:** cannot happen by time; only a wrong pid check could do it. Blast: conflicting pushes on one issue. Mitigation: pid check uses `kill -0` plus the process start time recorded in the marker, so a recycled pid is not mistaken for the worker.
- **Label deleted by hand:** the issue re-enters intake and a second spec draft starts. Blast: a duplicate spec PR. Mitigation: the issue worker checks for an existing `bzr/spec-<n>` branch and resumes it; `--audit` lists unlabelled issues that have a `bzr/` branch or claim comment.
- **Lib extraction regresses the review cycle:** every worker affected. Mitigation: the recording-stub harness (`BABYSIT_TEST_MODE` pattern) is ported to the lib before either worker uses it.

# Bounds

## Out of scope
- Cross-host locking, Jira, auto-merge, any change to `babysit-with-review.sh`.
- Priority inference by model. Priority is a label or nothing.
- Web UI. The GitHub issue page is the UI.

## Assumptions-that-could-flip
- **Labels as state.** Flipping to GitHub Projects fields would replace every `gh issue edit --add-label` with a GraphQL project mutation; queue reads would move to project views.
- **Two scripts over one lib.** Flipping to one script with a role flag is a mechanical merge; nothing in the contracts depends on the split.

## Composes with / replaces
- **Composes with:** `ASF-SYS-AUTONOMOUS-DEV` (untouched), `setup-branch-protection.sh`, `spec-guide.md`, helper scripts `prs`/`issues`/`specs`.
- **Replaces:** `babysit-work-prep.sh` and `babysit-builder.sh`, deleted in plan phase 5 (owner, 2026-09-19).

# Signals

## SLIs (leading)
Deferred. Informally tracked from logs: dispatches per tick, dead-pid releases, attempts and escalations, sentinel distribution per role.

## Error budget burn (lagging)
Deferred.

## Audit checkpoints
- `--audit` on either script (read-only): issues with two `bzr-*` labels, claims naming dead pids, `bzr/` branches with no open PR, open PRs with no `bzr-*` parent issue, sub-issue markers whose L4 no longer exists.

## Capacity headroom triggers
- Queue depth of `bzr-ready` above `2 × workers` for 24h → raise `--workers` or add a host.

## Kill criteria
Inherits [BZR-PROD-BAZAAR-BUILDER](L1-bazaar-builder.md).
