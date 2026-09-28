# babysit-with-review.sh Specification

TIF (Trustable, Intuitive, Flexible) specifications documenting the autonomous development loop system.

## Specs

| Layer | File | Status | Description |
|---|---|---|---|
| **L1** | [L1-babysit-with-review.md](L1-babysit-with-review.md) | approved | Product spec: autonomous dev loop for solo/small teams (<10 users) |
| **L2** | [L2-autonomous-dev-system.md](L2-autonomous-dev-system.md) | approved | System architecture: bash orchestrator + selectable implementer/reviewer + gh/git |
| **L3** | [L3-autonomous-outer-loop.md](L3-autonomous-outer-loop.md) | approved | Iterative loop: worktree → collect_state → run_implementer → sentinel detection |
| **L3** | [L3-review-cycle.md](L3-review-cycle.md) | approved | Review cycle: reviewer → implementer fixes → convergence + codex-review status gate |
| **L3** | [L3-mcp-resilience.md](L3-mcp-resilience.md) | approved | MCP resilience: retry-with-backoff + valid_review_structure for Codex transport failures |
| **L3** | [L3-retrospective-review.md](L3-retrospective-review.md) | approved | Retrospective review: one-shot Codex review for merged PRs that bypassed forward-path |
| **L3** | L3-work-prep.md | review | Work-prep loop: ticket → TIF spec pipeline with human approval gate and sub-ticket creation — drafted on open PR #8 (`docs/l3-work-prep-spec`), not yet merged to main |
| **L3** | [L3-builder.md](L3-builder.md) | review | Builder loop: spec → PR pipeline with convergent adversarial review cycle and human merge gate |
| **L4** | [L4-selectable-implementer.md](L4-selectable-implementer.md) | **ready** | Select Claude or Codex implementation harness with role-specific model/effort |
| **L4** | [L4-selectable-reviewer.md](L4-selectable-reviewer.md) | **ready** | Select Claude or Codex review harness with role-specific model/effort |

## Plans & Amendments

| Plan | File | Description |
|---|---|---|
| **Security** | [SECURITY-REVIEW-PLAN.md](SECURITY-REVIEW-PLAN.md) | Review checklist: lock file races, auto-merge approval, telltale regex |
| **QA** | [QA-TEST-PLAN.md](QA-TEST-PLAN.md) | 28 manual TCs across outer loop, review cycle, and MCP resilience (Suites 1-3, not yet executed except TC-1.1's single-iteration gate, TC-1.2's pre-flight gate, TC-1.3/TC-1.3b's lock-file-collision gate, TC-1.4's lock-file-removal gate, TC-1.5/TC-1.6's sentinel-detection gate, and TC-1.8's MAX_ITER-exhaustion gate — all automated 2026-09-27), plus an automated Suite 4 for the selectable-implementer/reviewer surface and review-structure validation (`BABYSIT_TEST_MODE` + `test-babysit-with-review-cli.sh`, 168/168 passing) |

Note: the work-prep/builder amendment notes were applied directly to
`L1-babysit-with-review.md` and `L2-autonomous-dev-system.md` (see their "companion
scripts" sections) rather than kept in a separate amendments file — no
`AMENDMENTS-work-prep-builder.md` file was ever committed.

## Status

- **L1/L2/L3 features (original):** `approved` — security review complete, all findings accepted
  (see SECURITY-REVIEW-PLAN.md); QA smoke tests deferred pending a mock harness for
  Claude/Codex output (see QA-TEST-PLAN.md)
- **L3 work-prep + builder design decisions (7-9 below):** approved by owner 2026-08-27
- **L3 work-prep spec:** `review` — drafted 2026-08-27 on open PR #8 (`docs/l3-work-prep-spec`,
  not yet merged to main); several implementation mechanics are flagged `[ASSUMPTION]`
  pending owner sign-off
- **L3 builder spec:** `review` — drafted 2026-08-27 from the approved decisions, then
  revised same-day to key off a `build-ready` label across GitHub/Jira tickets (not
  just work-prep sub-tickets) and to kick back gap-having specs for clarification
  instead of building them as-is. **Implemented 2026-08-27** as `babysit-builder.sh`
  v0.1.0 (since bumped to v0.1.1); the spec was updated in the same pass to record what implementation settled:
  the worktree now lives through the build cycle (no `gh pr checkout`, so the
  operator's checkout is never touched), the four `build-*` quarantine labels are
  enumerated, the outage sweep runs before the queue is read, the reviewer probe is a
  startup fatal, and the shared-library question is resolved as duplication.
  Several mechanics are still flagged `[ASSUMPTION]` pending owner sign-off (see
  "What we assume" in [L3-builder.md](L3-builder.md)) — most notably the
  branch-protection interaction (a converged build PR gets a `codex-review=success`
  status posted without a merge), the multi-source Jira query mechanics, and the
  `build-incomplete` → `build-done` ticket swap.
  **Coordination resolved 2026-09-09:** `babysit-work-prep.sh` now emits
  `sub-ticket` + `build-ready`, and skips any ticket already in the build pipeline
  when deciding what to draft, so the two loops compose in both directions.
- **Spec review gate (work-prep v0.2.0, 2026-09-10):** work-prep was the only loop
  in the family with no adversarial reviewer — its sole gate was a structural
  check (one file, under the spec dir, frontmatter present) that never opened the
  rest of the corpus, so a spec contradicting an existing one passed. It now runs
  a convergent reviewer/implementer cycle (`run_spec_review_cycle`,
  `MAX_SPEC_REVIEW_CYCLES` default 4, prescriptive from cycle 3) judging the draft
  against every other spec in the corpus, the schema in `spec-guide.md`, and the
  code it describes. Spec PRs open as drafts and leave draft only at 0 BLOCKING.
  Adjudication mode (cycles 5-6 in `babysit-with-review.sh`) is deliberately
  omitted — the disagree-and-escalate protocol is for code, and a recurring
  finding on a spec should become a flagged `[ASSUMPTION]`, not an argument.
  **Note:** `L3-work-prep.md` still sits on unmerged PR #8 and predates all of
  this — it documents neither the review gate nor the `build-ready` output.
- **L4 tasks:** `ready` (both selectable-implementer and selectable-reviewer)
- **Complexity:** 2/30 (trivial band per TIF rubric)
- **Fit check:** Passed (specs are appropriate artifact)
- **Blockers to `ready` (L1/L2/L3):** 
  - ~~Security review decision: auto-merge approval gate~~ — resolved; `codex-review` status gate shipped in v1.1.0
  - ~~QA test harness~~ — `BABYSIT_TEST_MODE` + `test-babysit-with-review-cli.sh` exist
  - QA smoke tests (Phase 1 + Phase 2 from test plan) — still to execute
  - L3-builder: owner sign-off on the `[ASSUMPTION]` items above before status can move to `ready`

## Key Decisions Documented

1. **Scale:** <10 users at 6mo/18mo (personal/internal tool, not OSS distribution)
2. **Architecture:** Bash orchestrator with subprocess components (selectable implementer + selectable reviewer + gh + git); v1.4.0, 2,655 lines
3. **Review convergence:** Prescriptive mode kicks in at cycle 3 (requires "Suggested fix:"); inline planning (not plan mode) at cycle 2+
4. **MCP resilience:** 3 retries with 0/60s/300s backoff on transport failures
5. **Merge gate:** PRs merge only after `codex-review=success` status POSTed by `run_review_cycle` (enforced by `setup-branch-protection.sh`); BLOCKING=0 alone does not merge
6. **Six quarantine labels:** `review-incomplete` (human action, no retry), `review-mcp-outage` (auto-retry), `review-codex-outdated` (upgrade CLI), `review-codex-no-credits` (add credits), `review-merge-failed` (review passed, merge itself failed — sweep retries the merge only, not the review), `review-merge-conflict` (review passed, merge failed due to a real conflict against the base branch — sweep leaves the label in place until `gh pr view --json mergeable` shows the conflict is gone, never retries the merge blindly)
7. **Work-prep approval gate:** Human posts unambiguous approval comment (case-insensitive `\bapproved\b`) on spec PR → work-prep merges spec, labels the *source* ticket `status:ready-to-build` (meaning "spec approved, sub-ticket exists"), and creates a `sub-ticket` + `build-ready` sub-ticket that the builder picks up
8. **Builder halt (no auto-merge):** Builder halts when reviewer returns BLOCKING=0 OR max cycles exhausted; posts reviewer summary PR comment; human does final merge
9. **Parallel label namespaces:** Builder uses `build-*` labels; babysit-with-review.sh uses `review-*` labels; no overlap

## Next Steps

1. **Review specs** — verify accuracy against implementation
2. **Security review** — execute SECURITY-REVIEW-PLAN.md checklist (~2-4 hours)
3. **QA smoke tests** — run Phase 1 + Phase 2 from QA-TEST-PLAN.md (~3 hours)
4. **Resolve [OPEN] items** — or accept as deferred with owners assigned
5. **Update status to `ready`** — after blockers resolved
