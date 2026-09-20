---
spec_type: feature
id: BZR-FEAT-BUILD-WORKER
status: review
owners: [Chris Robertson]
depends_on: [BZR-SYS-BAZAAR, BZR-FEAT-REVIEW-LIB]
parent_l1: BZR-PROD-BAZAAR-BUILDER
parent_l2: BZR-SYS-BAZAAR
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [scope, surface_span, novelty]
  scored_on: 2026-09-19
---

# Frame

## TL;DR
Given one `bzr-ready` issue, the build worker checks that everything it needs is really there, fetches the issue's native sub-issues, plans their order, and implements them one at a time on a single branch `bzr/<issue>-<slug>` in a dedicated worktree, running the convergent code review cycle after each sub-issue. A sub-issue whose review does not converge is reverted off the branch, labelled `bzr-blocked`, and skipped; the rest continue. When the last one is done it marks the PR ready with whatever converged and labels the parent `bzr-pr-ready`. It never merges.

## Analog
Like a senior engineer picking up an epic: reads the stories, orders them, ships them one commit-series at a time on one branch, gets each slice reviewed, and asks the lead to merge at the end.

## Reader & next action
Implementing agent: build the worker in `bazaar-build.sh` on top of the lib. Chris Robertson: confirm the revert-on-skip and second-round mechanics.

## API surface fragment
*Proposed.*
```bash
bazaar-worker-build <issue>       # env from controller; branch bzr/<issue>-<slug>, worktree $BZR_HOME/<repo>/wt/<issue>

# Precheck outcome (wrapper, before any model call):
#   the parent's `Specs:` line (written by the approval sweep) names spec files that exist on origin/main with status: ready
#   every open sub-issue carries the `<!-- bzr-sub-issue … spec=<L4 ID> -->` marker and that L4 exists, or the parent has no sub-issues and its Specs: line names exactly one L4
#   branch does not exist on origin, or exists with a marker PR (resume)
# Otherwise: SPEC_GAP <what is missing> → bzr-blocked + comment, claim released.

# Sentinels per implementer pass (last line, bare):
PLAN_POSTED                       # plan pass only: ordered list posted as issue comment
SUBISSUE_DONE <n>                 # sub-issue n implemented, committed, pushed; wrapper runs review cycle
HANDOFF_REVIEW <pr>               # first pass only, PR opened (draft) after the first sub-issue
SPEC_GAP <reason>                 # spec not implementable; whole issue → bzr-blocked
STUCK <reason>                    # environmental; controller counts an attempt, issue → bzr-ready
```

## Consumer
[BZR-FEAT-CONTROLLER](L3-controller.md) (role build). Output consumed by the human merger.

# Substance

## What we know
- Owner decisions (2026-09-19): one branch and one PR per parent issue; review after each sub-issue; on a failed sub-issue skip it and continue (8, second round); check all required information before starting (brief); unique worktree and branch per unit of work (5); never merge (inherited, and `codex-review` branch protection enforces it); no time limits.
- The `Specs:` line and sub-issue marker bodies the precheck reads are written by the approval sweep in [BZR-FEAT-CONTROLLER](L3-controller.md).
- `babysit-builder.sh` v0.1.0 already implements: precheck of the referenced spec on the base ref (`extract_spec_path`, `spec_exists_on_base`, lines 1387-1434), a worktree that lives through the review cycle, the `HANDOFF_REVIEW`/`SPEC_GAP`/`STUCK` sentinel contract (lines 1585-1657), `run_build_cycle` with staged models per cycle (Sonnet cycles 1-3, Opus 4-8 cycles 4-6, lines 1245-1251), and the `codex-review=success` status post at convergence.
- Native sub-issue read: `GET /repos/{o}/{r}/issues/{n}/sub_issues` returns full issue objects; GraphQL `subIssuesSummary{total completed}` gives progress (probed 2026-09-19).

## What we assume
- [ASSUMPTION] Each per-sub-issue review cycle reviews the whole PR diff against main, as the lib does today; only the final cycle posts the `codex-review` status. Flips if: cost grows with sub-issue count, in which case cycles 1..k-1 review only commits since the last converged SHA.
- [ASSUMPTION] Planning is a separate short implementer pass that reads the parent, the sub-issues, and their L4s, and posts an ordered list with a one-line dependency reason each. Order rule: explicit "Blocked by #N" first, then L4 `depends_on`, then issue number. Flips if: the owner wants the plan reviewed by the reviewer before implementation starts.
- [ASSUMPTION] Skip means: `git revert` the commit range recorded for sub-issue k, commit `revert: skip #<k> (review did not converge after N cycles)`, label sub-issue k `bzr-blocked` with the reviewer's last findings, mark k skipped in the marker block, and continue with the next sub-issue whose plan entry does not depend on k (dependents are skipped too, labelled with the reason). Flips if: the owner prefers to leave k's commits on the branch for the human to fix in place, which would keep the PR draft.
- [ASSUMPTION] Second round: when the PR merges with skipped sub-issues, the parent stays open; once a human clears `bzr-blocked` on a skipped sub-issue, the build controller's merged-PR sweep puts the parent back to `bzr-ready` and the next build uses branch `bzr/<issue>-<slug>-r2` for the remaining sub-issues. The one-branch invariant therefore reads "one open PR per issue at a time". Flips if: the owner wants skipped sub-issues promoted to standalone issues instead.
- [ASSUMPTION] Sub-issues close via `Closes #<sub>` lines in the PR body added as each completes, so merge closes parent and children together. Flips if: the owner wants sub-issues closed as each converges, before merge.
- [ASSUMPTION] Staged implementer models per review cycle are kept from the builder (Sonnet 5 early, Opus 4-8 late). Flips if: the owner wants a single configured model.
- [ASSUMPTION] `--issue N` bypass (`--force`) skips the label check but never the precheck. Flips if: the owner wants a "just build this" mode with no spec.

## Contract

### Request shape
One issue number, already labelled `bzr-building`.

### Response shape
Parent in exactly one of `bzr-pr-ready`, `bzr-blocked`, or back in `bzr-ready`; a PR on `bzr/<issue>-<slug>` (or `-rN`) whose body contains `Closes #<sub>` for every converged sub-issue, `Closes #<issue>` only when nothing was skipped, and a `<!-- bzr-build state=… -->` marker block recording per sub-issue: pending, converged (SHA range), or skipped (reason).

### Phases
0. **precheck** (bash): as in the surface fragment. Also: working tree of the worktree clean, `origin/main` fetched.
1. **plan** (implementer, short): posts the ordered plan as an issue comment, `PLAN_POSTED`. Skipped when there are no sub-issues.
2. **implement sub-issue k** (implementer): reads its L4, implements, tests, commits with `Refs #<sub>`, pushes, `SUBISSUE_DONE k` (or `HANDOFF_REVIEW <pr>` on k=1, after opening the draft PR).
3. **review** (lib, `--mode code`): convergent cycle per k. Converged → update marker block, next k. Not converged (cap or bail) → skip per the assumption above, next eligible k.
4. **finish**: after the last k, if at least one converged: post `codex-review=success`, mark PR ready, comment a summary (converged and skipped lists) on the parent, write `PR_READY <pr>` to `$BZR_SENTINEL` (the controller moves `bzr-building` → `bzr-pr-ready`). If every sub-issue was skipped: close the PR and write `BLOCKED <reason>` (controller escalates). The PR body carries `<!-- bzr-build issue=N round=R -->` so the controller's merged-PR sweep can find it.

### Invariants
1. No `gh pr merge`, no push to main, in any code path.
2. At most one open PR per parent issue at a time; round N uses branch suffix `-rN`.
3. Precheck runs before any model call; a failing precheck costs no tokens.
4. Sub-issues are implemented in the posted order; the order is never changed silently (a re-plan posts a new comment).
5. Every sub-issue's commits are reviewed at least once before the next sub-issue starts.
6. The `codex-review` status is posted only at finish, when every commit left on the branch has converged (skipped work is reverted, so the head reflects reviewed code only).
7. The PR body's `Closes #` list equals the set of converged sub-issues, plus the parent iff nothing was skipped.
8. Resume never re-implements a sub-issue recorded as converged in the marker block.
9. A skipped sub-issue leaves no commits on the branch head (its range is reverted) and carries `bzr-blocked` with the last reviewer findings.

### Error model
- Precheck fails: `SPEC_GAP`, `bzr-blocked`, comment listing each missing item.
- Implementer `STUCK`: safety push, back to `bzr-ready`; the controller counts the attempt and escalates on the third.
- Reviewer transport failure after the lib's retries: same as `STUCK` (the current sub-issue stays pending in the marker block and resumes next attempt).
- Reviewer backend outdated / no credits: comment on PR, controller exits 1 (operator action); not an attempt.
- Cap hit or bail on sub-issue k: skip per assumption.
- Push rejected (branch moved by someone else): `STUCK rebase-needed`; human intervention.

### Idempotency
Resume-safe through the marker block and the branch on origin. A second dispatch on a finished issue finds `bzr-pr-ready` and does nothing (controller never queues it).

### Versioning policy
With `bazaar-build.sh`.

## Performance budget
Per sub-issue: 10-40 min implement plus 1-7 min per review cycle times up to 6. An issue with 3 sub-issues: 1-4 h wall-clock, roughly $10-40.

## Security model
Inherits `gh` auth and branch protection. The worker's only write to main-adjacent state is the commit status, and only at finish.

## Telemetry contract
`[build:<n>] phase=<p> sub=<k>/<K> …`, `review cycle=<c> blocking=<b>`, `sentinel=<word>`. Sink: `$BZR_HOME/<repo>/logs/build-<n>-<ts>.log`.

## Verifiers
- Tech lead: Chris Robertson
- QA: stubbed sentinel paths, plan phase 4.

## Failure modes & blast radius
- **Plan order wrong:** sub-issue k fails to build because k+1 was needed first. Blast: k skipped and its dependents with it; human reorders by comment, clears `bzr-blocked`, round 2 picks them up.
- **Revert conflicts:** k+1 touched files k changed, so reverting k fails. Blast: the worker cannot skip cleanly; it stops, marks the PR draft, and escalates the parent to `bzr-blocked` with the conflict. Only in this case does the whole issue halt.
- **Whole-PR review cost blow-up:** late cycles review a large diff. Blast: money and time; see review-scope assumption.
- **Marker block corrupted by a hand edit:** resume re-implements or skips. Blast: one issue; audit detects a mismatch between marker and `Closes #` list.
- **Two sub-issues touch the same file:** later one conflicts with a review fix on the earlier. Blast: extra review cycles.

# Bounds

## Out of scope
Merging, stacked PRs, parallel sub-issues within one issue, cross-issue dependencies (an issue blocked by another open issue is a precheck failure with `SPEC_GAP blocked by #N`), Jira, time limits, promoting skipped sub-issues to standalone issues.

## Assumptions-that-could-flip
- **One PR per issue.** See L1.
- **Whole-PR review per sub-issue.** See above.

## Composes with / replaces
Composes with [BZR-FEAT-REVIEW-LIB](L3-review-lib.md) (`--mode code`), `setup-branch-protection.sh`. Replaces `babysit-builder.sh`'s `build_ticket` for repos managed by Bazaar.

# Signals

## Acceptance tests
1. **Given** a `bzr-ready` issue whose spec is still `status: review`, **when** dispatched, **then** precheck fails with `SPEC_GAP`, no model call, issue `bzr-blocked`.
2. **Given** an issue with three sub-issues where #12 says "Blocked by #11", **when** planned, **then** the posted order has #11 before #12.
3. **Given** the plan, **when** sub-issue 1 completes, **then** a draft PR exists with `Closes #<parent>` and `Closes #<sub1>` and one review cycle has run.
4. **Given** sub-issue 2 of 3 hits the review cap, **when** the worker skips it, **then** its commits are reverted, sub-issue 2 is `bzr-blocked` with the findings, sub-issue 3 is implemented, and the finish comment lists 2 as skipped.
5. **Given** that PR merges and a human clears `bzr-blocked` on sub-issue 2, **when** the merged sweep runs and the parent is re-dispatched, **then** round 2 builds only sub-issue 2 on `…-r2` and sub-issues 1 and 3 are untouched.
6. **Given** all sub-issues converge, **when** finish runs, **then** `codex-review=success` is on the head SHA, the PR is ready with `Closes` for the parent and every sub-issue, and the parent is `bzr-pr-ready`.
7. **Given** the reviewer transport fails after the lib's retries, **when** the worker exits `STUCK`, **then** the parent is `bzr-ready` again, an attempt marker exists, and the marker block still shows the current sub-issue pending.
7b. **Given** sub-issue 3 depends on skipped sub-issue 2 per the plan, **when** the worker reaches 3, **then** 3 is skipped too with reason `depends on #2`.
8. **Given** an issue with no sub-issues and one L4, **when** dispatched, **then** the plan phase is skipped and one implement/review pass runs.
9. **Given** `--issue N` on an issue without `bzr-ready` and no `--force`, **when** run, **then** exit 2 with a usage message.
10. **Given** any transcript, **when** grepped for `gh pr merge`, **then** no match in worker prompts or wrapper.

## Telemetry events tied to L1 KPIs
Time from `bzr-building` to `bzr-pr-ready`; review cycles per sub-issue.

## AEAB cases
N/A.

## Kill criteria
More than 30% of `bzr-pr-ready` PRs need rework; median review cycles per sub-issue above 4.
