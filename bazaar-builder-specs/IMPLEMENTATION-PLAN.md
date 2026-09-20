# Bazaar Builder — implementation plan

Non-spec page. Phased plan to build the system specified in this corpus. Each phase is one or more PRs against `~/repos/scripts`. Owner decisions that gate a phase are listed under it; the plan does not proceed past a gate on a guess.

## Phase 0 — corpus (this PR)

- Write `bazaar-builder-specs/` (L1, L2, four L3s, this plan, issue template, index, log).
- Owner answered the eleven open decisions the same day; answers are folded into the specs and recorded in `log.md`.
- Exit: owner reads the remaining `[ASSUMPTION]` items in `index.md`; specs stay `review` until the owner flips them.

## Phase 1 — extract `lib/bazaar-review.sh` (BZR-FEAT-REVIEW-LIB) — DONE 2026-09-19

1. Port the recording-stub harness: `test-bazaar-review-lib.sh` modelled on `test-babysit-with-review-cli.sh`, stubbing `claude`, `codex`, `gh`, `sleep`.
2. Move functions from `babysit-builder.sh` lines 644-1093 into the lib unchanged; commit the md5 table of function bodies in the PR description.
3. Fold `run_build_cycle` and `run_spec_review_cycle` into `run_review_cycle --mode code|spec`; move prompt text into the registry keyed by mode and cycle band.
4. Strip label, draft/ready, and status-post side effects out of the cycle; expose `post_codex_review_status` separately.
5. Replay QA-TEST-PLAN TC-3.1 to TC-3.8 against the lib.
6. Do not touch `babysit-with-review.sh`, `babysit-builder.sh`, or `babysit-work-prep.sh`.

Gate: none beyond decision 8 (already made).

## Phase 2 — `lib/bazaar-common.sh` + `bazaar-issues.sh` + `bazaar-build.sh` controllers (BZR-FEAT-CONTROLLER)

1. Lib skeleton: shared arg parsing, `--workers`, `--once`, `--interval`, stop file, `BZR_HOME` layout, label bootstrap (`ensure_bzr_labels`, seven labels), comment helper with the "approved" guard.
2. Queue read (intake = no `bzr-*` label; sub-issue and PR exclusion), priority sort, live re-check before claim, claim protocol (label, remove, marker with host/pid/start-time).
3. Dead-pid release and startup release; attempt counter and escalation.
4. `bazaar-issues.sh` sweeps: bounce, approval (status flip, `codex-review` status, merge, sub-issue reconciliation, `Specs:` line), rejected spec. `bazaar-build.sh` sweeps: merged PR (close parent or requeue for round 2).
5. Optional Haiku tie-break (`--effort low`) with strict output validation and `none` switch.
6. `--dry-run`, `--audit`.
7. Harness cases 1-14 from the controller L3.

Gates: none; decisions taken 2026-09-19.

## Phase 3 — issue worker (BZR-FEAT-ISSUE-WORKER)

1. Prompts: verify checklist, questions, normalise (template in `ISSUE-TEMPLATE.md`), classify, draft (reuse work-prep drafting prompt and `spec-guide.md` handoff), resume-from-marker.
2. Wrapper: worktree `bzr/spec-<n>`, sentinel parsing, marker comments, draft-time sub-issue create/reconcile, `run_review_cycle --mode spec`, label transitions, `NOT_ACTIONABLE` on missing corpus.
3. Harness cases 1-11 from the issue-worker L3.

Gates: body-rewrite format (assumed: template plus verbatim original in a details block).

## Phase 4 — build worker (BZR-FEAT-BUILD-WORKER)

1. Precheck in bash (spec exists on `origin/main`, `status: ready`, L4 per sub-issue, branch state).
2. Sub-issue fetch and plan pass; ordered plan comment.
3. Per-sub-issue implement pass and `run_review_cycle --mode code`; marker block in PR body; `Closes #` maintenance.
4. Skip path: revert range, label sub-issue, skip dependents; revert-conflict halt.
5. Finish: status post, PR ready, `bzr-pr-ready`; all-skipped path; round-N branch suffix.
6. `--issue N` / `--force`.
7. Harness cases 1-10 (with 4, 5, 7, 7b as rewritten) from the build-worker L3.

Gates: revert-on-skip and second-round mechanics (assumed; see the build-worker L3).

## Phase 5 — rollout

1. `ensure_bzr_labels` on one pilot repo; run both controllers with `--workers 1 --once` from a shell, then from cron on a dev-laptop host.
2. Update `CLAUDE.md` file table and `docs/` with the operator guide.
3. Retire `babysit-builder.sh` and `babysit-work-prep.sh` (owner, 2026-09-19): delete both scripts, remove their rows from `CLAUDE.md`, add a "superseded by bazaar-builder-specs" note to `babysit-specs/README.md` Status, close `babysit-specs` PR #8 (`L3-work-prep.md`) as superseded. `babysit-with-review.sh` stays.
4. Move specs to `ready` as the owner sees fit.

## Sizing

| Phase | New/changed lines (est.) | Notes |
|---|---|---|
| 1 | 1,188 lib + 230 harness (actual) | mostly moved code; 12 prompts verbatim |
| 2 | ~500 | new |
| 3 | ~400 wrapper + prompts | prompts partly reused from work-prep |
| 4 | ~500 wrapper + prompts | prompts partly reused from builder |
| 5 | docs | |

Estimates are for scoping only; they are not commitments and will be revised in `log.md` as phases land.
