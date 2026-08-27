# babysit-with-review.sh Specification

TIF (Trustable, Intuitive, Flexible) specifications documenting the autonomous development loop system.

## Specs

| Layer | File | Status | Description |
|---|---|---|---|
| **L1** | [L1-babysit-with-review.md](L1-babysit-with-review.md) | review | Product spec: autonomous dev loop for solo/small teams (<10 users) |
| **L2** | [L2-autonomous-dev-system.md](L2-autonomous-dev-system.md) | review | System architecture: bash orchestrator + selectable implementer/reviewer + gh/git |
| **L3** | [L3-autonomous-outer-loop.md](L3-autonomous-outer-loop.md) | review | Iterative loop: worktree → collect_state → run_implementer → sentinel detection |
| **L3** | [L3-review-cycle.md](L3-review-cycle.md) | review | Review cycle: reviewer → implementer fixes → convergence + codex-review status gate |
| **L3** | [L3-mcp-resilience.md](L3-mcp-resilience.md) | review | MCP resilience: retry-with-backoff + valid_review_structure for Codex transport failures |
| **L3** | [L3-retrospective-review.md](L3-retrospective-review.md) | review | Retrospective review: one-shot Codex review for merged PRs that bypassed forward-path |
| **L3** | [L3-work-prep.md](L3-work-prep.md) | review | Work-prep loop: ticket → TIF spec pipeline with human approval gate and sub-ticket creation |
| **L3** | L3-builder.md | **planned** | Builder loop: spec → PR pipeline with convergent adversarial review cycle and human merge gate — decisions approved, spec not yet drafted |
| **L4** | [L4-selectable-implementer.md](L4-selectable-implementer.md) | **ready** | Select Claude or Codex implementation harness with role-specific model/effort |
| **L4** | [L4-selectable-reviewer.md](L4-selectable-reviewer.md) | **ready** | Select Claude or Codex review harness with role-specific model/effort |

## Plans & Amendments

| Plan | File | Description |
|---|---|---|
| **Security** | [SECURITY-REVIEW-PLAN.md](SECURITY-REVIEW-PLAN.md) | Review checklist: lock file races, auto-merge approval, telltale regex |
| **QA** | [QA-TEST-PLAN.md](QA-TEST-PLAN.md) | 27 test cases across outer loop, review cycle, and MCP resilience (test harness: `BABYSIT_TEST_MODE` + `test-babysit-with-review-cli.sh`) |

Note: the work-prep/builder amendment notes were applied directly to
`L1-babysit-with-review.md` and `L2-autonomous-dev-system.md` (see their "companion
scripts" sections) rather than kept in a separate amendments file.

## Status

- **L1/L2/L3 features (original):** `review` (awaiting approval)
- **L3 work-prep + builder design decisions (7-9 below):** approved by owner 2026-08-27
- **L3 work-prep spec:** `review` — drafted 2026-08-27 from the approved decisions;
  several implementation mechanics are flagged `[ASSUMPTION]` pending owner sign-off
  (see "What we assume" in L3-work-prep.md)
- **L3 builder spec:** `planned` — decisions approved, TIF spec not yet drafted
- **L4 tasks:** `ready` (both selectable-implementer and selectable-reviewer)
- **Complexity:** 2/30 (trivial band per TIF rubric)
- **Fit check:** Passed (specs are appropriate artifact)
- **Blockers to `ready` (L1/L2/L3):** 
  - ~~Security review decision: auto-merge approval gate~~ — resolved; `codex-review` status gate shipped in v1.1.0
  - ~~QA test harness~~ — `BABYSIT_TEST_MODE` + `test-babysit-with-review-cli.sh` exist
  - QA smoke tests (Phase 1 + Phase 2 from test plan) — still to execute

## Key Decisions Documented

1. **Scale:** <10 users at 6mo/18mo (personal/internal tool, not OSS distribution)
2. **Architecture:** Bash orchestrator with subprocess components (selectable implementer + selectable reviewer + gh + git); v1.1.0, 1,921 lines
3. **Review convergence:** Prescriptive mode kicks in at cycle 3 (requires "Suggested fix:"); inline planning (not plan mode) at cycle 2+
4. **MCP resilience:** 3 retries with 0/60s/300s backoff on transport failures
5. **Merge gate:** PRs merge only after `codex-review=success` status POSTed by `run_review_cycle` (enforced by `setup-branch-protection.sh`); BLOCKING=0 alone does not merge
6. **Four quarantine labels:** `review-incomplete` (human action, no retry), `review-mcp-outage` (auto-retry), `review-codex-outdated` (upgrade CLI), `review-codex-no-credits` (add credits)
7. **Work-prep approval gate:** Human posts unambiguous approval comment (case-insensitive `\bapproved\b`) on spec PR → work-prep merges spec, labels source ticket `status:ready-to-build`, creates sub-ticket for builder
8. **Builder halt (no auto-merge):** Builder halts when reviewer returns BLOCKING=0 OR max cycles exhausted; posts reviewer summary PR comment; human does final merge
9. **Parallel label namespaces:** Builder uses `build-*` labels; babysit-with-review.sh uses `review-*` labels; no overlap

## Next Steps

1. **Review specs** — verify accuracy against implementation
2. **Security review** — execute SECURITY-REVIEW-PLAN.md checklist (~2-4 hours)
3. **QA smoke tests** — run Phase 1 + Phase 2 from QA-TEST-PLAN.md (~3 hours)
4. **Resolve [OPEN] items** — or accept as deferred with owners assigned
5. **Update status to `ready`** — after blockers resolved
