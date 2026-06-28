# babysit-with-review.sh Specification

TIF (Trustable, Intuitive, Flexible) specifications documenting the autonomous development loop system.

## Specs

| Layer | File | Description |
|---|---|---|
| **L1** | [L1-babysit-with-review.md](L1-babysit-with-review.md) | Product spec: autonomous dev loop for solo/small teams (<10 users) |
| **L2** | [L2-autonomous-dev-system.md](L2-autonomous-dev-system.md) | System architecture: bash orchestrator + Claude/Codex/gh/git components |
| **L3** | [L3-autonomous-outer-loop.md](L3-autonomous-outer-loop.md) | Iterative loop: state collection → Claude → sentinel detection |
| **L3** | [L3-review-cycle.md](L3-review-cycle.md) | Review cycle: Codex reviews → Claude fixes → convergence tracking |
| **L3** | [L3-mcp-resilience.md](L3-mcp-resilience.md) | MCP resilience: retry-with-backoff for Codex transport failures |

## Plans

| Plan | File | Description |
|---|---|---|
| **Security** | [SECURITY-REVIEW-PLAN.md](SECURITY-REVIEW-PLAN.md) | Review checklist: lock file races, auto-merge approval, telltale regex |
| **QA** | [QA-TEST-PLAN.md](QA-TEST-PLAN.md) | 38 test cases across outer loop, review cycle, and MCP resilience |

## Status

- **Current status:** `review` (awaiting approval)
- **Complexity:** 2/30 (trivial band per TIF rubric)
- **Fit check:** Passed (specs are appropriate artifact)
- **Blockers to `ready`:** 
  - Security review decision: auto-merge approval gate (accept as-is or add approval requirement)
  - QA smoke tests (Phase 1 + Phase 2 from test plan)

## Key Decisions Documented

1. **Scale:** <10 users at 6mo/18mo (personal/internal tool, not OSS distribution)
2. **Architecture:** Bash orchestrator with subprocess components (Claude, Codex, gh, git)
3. **Review convergence:** Prescriptive mode kicks in at cycle 3 (requires "Suggested fix:")
4. **MCP resilience:** 3 retries with 0/60s/300s backoff on transport failures
5. **Auto-merge:** PRs merge automatically when BLOCKING=0 (decision point for team repos)

## Next Steps

1. **Review specs** — verify accuracy against implementation
2. **Security review** — execute SECURITY-REVIEW-PLAN.md checklist (~2-4 hours)
3. **QA smoke tests** — run Phase 1 + Phase 2 from QA-TEST-PLAN.md (~3 hours)
4. **Resolve [OPEN] items** — or accept as deferred with owners assigned
5. **Update status to `ready`** — after blockers resolved
