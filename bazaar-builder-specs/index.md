# Bazaar Builder specs

TIF specs for **Bazaar Builder**: a two-controller, two-worker replacement for the ticket-selection logic in the babysit loop family. Issues go in, human-approved specs and reviewed PRs come out. Prefix `BZR`. Schema: `../spec-guide.md`. Standalone corpus; `babysit-specs/` (prefix `ASF`) is referenced, never edited.

## Specs

| Layer | File | Status | Description |
|---|---|---|---|
| **L1** | [**L1-bazaar-builder.md**](L1-bazaar-builder.md) | review | Product: issue → verified spec → approved → single-branch build with review; owner decisions 1-12 of 2026-09-19 |
| **L2** | [**L2-bazaar-system.md**](L2-bazaar-system.md) | review | System: two controllers, two workers, shared review lib, GitHub labels as the only durable state, claim protocol |
| **L3** | [**L3-controller.md**](L3-controller.md) | review | **Implemented 2026-09-19** (82 harness cases green). `bazaar-issues.sh` / `bazaar-build.sh` over `lib/bazaar-common.sh`: intake = no `bzr-*` label, pid-held claims (no TTL), three-attempt escalation, sweeps (dead-pid, bounce, approval, rejected spec, merged PR), optional Haiku tie-break |
| **L3** | [**L3-issue-worker.md**](L3-issue-worker.md) | review | Verify → ask/normalise → classify → draft specs and draft-time sub-issues → corpus-wide spec review → park for approval; no corpus = not actionable |
| **L3** | [**L3-build-worker.md**](L3-build-worker.md) | review | Precheck → fetch sub-issues → plan → implement sequentially on `bzr/<issue>-<slug>` → review per sub-issue, skip and revert non-converging ones → `bzr-pr-ready`, never merge |
| **L3** | [**L3-review-lib.md**](L3-review-lib.md) | review | `lib/bazaar-review.sh` v0.1.0 (**implemented 2026-09-19**, harness green): extraction of the convergent review cycle from builder/work-prep; `babysit-with-review.sh` untouched |

## Plans & Amendments

| Page | File | Description |
|---|---|---|
| Plan | [IMPLEMENTATION-PLAN.md](IMPLEMENTATION-PLAN.md) | Five phases: corpus, lib extraction, controller, issue worker, build worker, rollout; gates per phase |
| Template | [ISSUE-TEMPLATE.md](ISSUE-TEMPLATE.md) | Issue body layout the worker normalises into; ships as a GitHub issue template |

## Status

- All specs `review`, drafted 2026-09-19 from the owner's decisions in conversation. Nothing is implemented; API surface fragments are marked *proposed*.
- **Phase 1 done 2026-09-19:** `lib/bazaar-review.sh` extracted, `test-bazaar-review-lib.sh` 59/59 green.
- **Phase 2 done 2026-09-19:** `lib/bazaar-common.sh`, `bazaar-issues.sh`, `bazaar-build.sh`, `test-support/fake-gh.py`; 82 controller harness cases green. Workers (phases 3-4) are next; until they land, `role_worker_cmd` points at `bazaar-issue-worker.sh` / `bazaar-build-worker.sh`, which do not exist yet.
- **Blockers to `ready`:** owner sign-off on the remaining assumptions below and on the implementation as it lands.
- Complexity: L1/L2/L3s scored 2-3 (trivial/moderate band); fit check passed for all (a spec corpus is the right artifact because the owner wants a plan that agents will build from).

### Decisions taken 2026-09-19 (second round)

All eleven open decisions from the first draft were answered the same day and folded into the specs; see `log.md`. Remaining `[ASSUMPTION]` items the owner may still want to look at before phase 2:

1. **Attempt counter** as `bzr-attempt` marker comments, reset by the `bzr-escalated` marker (controller L3).
2. **Rejected spec PR** escalates to `bzr-blocked` rather than redrafting (L1).
3. **Skip mechanics:** revert the sub-issue's commit range, label the sub-issue `bzr-blocked`, skip dependents; a revert conflict is the one case that halts the whole issue (build-worker L3).
4. **Second round** after a merge with skipped sub-issues uses branch suffix `-rN`; invariant is one open PR per issue at a time (build-worker L3).
5. **Draft-time sub-issues are reconciled on every spec revision** (issue-worker L3).
6. **Sub-issue POST payload** is from the REST docs, not yet exercised (L2).

## Key Decisions Documented

1. **Two controllers, two workers, two scripts.** Controllers are label queues with a pid-held claim protocol and no time limits; all judgement lives in workers (owner, 2026-09-19).
2. **Human approval is the only gate** between spec complete and ready for development (owner, 2026-09-19).
3. **The issue worker may edit the issue body**, preserving the original verbatim (owner, 2026-09-19).
4. **GitHub only.** No Jira (owner, 2026-09-19).
5. **`babysit-with-review.sh` is untouched.** The review loop is extracted into `lib/bazaar-review.sh` for this tool (owner, 2026-09-19).
6. **Concurrency is `--workers N`.** Every unit of work has a unique worktree and branch (owner, 2026-09-19).
7. **Native GitHub sub-issues**, created by the issue worker at draft time; parent issue is the build unit; one branch `bzr/<issue>-<slug>` and one open PR per parent at a time; review after each sub-issue; a non-converging sub-issue is reverted, labelled, and skipped (owner, 2026-09-19).
8. **Bounce channel** is a marker comment plus `bzr-needs-info`; authorship is not a signal because agent and human share a login (probed 2026-09-19).
9. **Bug vs feature** routes by label first, agent judgement second; the corpus ships an issue template (owner accepted default, 2026-09-19).
10. **Controller model Haiku 4.5**, tie-break only; implementer/reviewer keep claude/codex selectability (owner accepted default, 2026-09-19).
11. **Standalone corpus, prefix `BZR`** (owner, 2026-09-19).
12. **Intake is every open issue with no `bzr-*` label**; seven labels total; `bzr-blocked` only for human escalation or after three automatic attempts (owner, 2026-09-19).
13. **`babysit-builder.sh` and `babysit-work-prep.sh` are retired** in phase 5; `babysit-with-review.sh` is untouched (owner, 2026-09-19).
14. **A repo with no spec corpus makes issues non-actionable** (owner, 2026-09-19).

## Next Steps

1. Owner glances at the six remaining assumptions above; none blocks phase 1.
2. ~~Phase 1: extract the lib with the harness green.~~ Done 2026-09-19.
3. ~~Phase 2: controllers.~~ Done 2026-09-19. Phases 3-4 (workers) in order; each lands with its L3's acceptance tests as harness cases.
4. Pilot on one repo; write the operator guide; update `CLAUDE.md`.
5. Update status to `ready` once blockers clear.
