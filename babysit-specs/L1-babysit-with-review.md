---
spec_type: product
id: ARLO-PROD-BABYSIT-WITH-REVIEW
status: review
owners: [Chris Robertson]
depends_on: []
experience_authority: none
fit_check: passed
complexity:
  total: 2
  band: trivial
  drivers: [novelty, time_estimate]
  scored_on: 2026-06-28
---

# Frame

## TL;DR

An autonomous development loop for solo developers and small teams that iterates on a project by invoking Claude for implementation work, then orchestrates Claude-Codex review cycles to ensure quality before merge. A companion research loop (`babysit-work-prep.sh`) translates raw tickets into fully-scoped TIF spec files ready for AI-agent building, with human approval required before hand-off. A builder loop (`babysit-builder.sh`) implements approved specs using the same adversarial review cycle, halting for human merge rather than auto-merging.

## Analog

Like GitHub Actions continuous integration workflows, but instead of running tests on human-written code, this runs an AI agent to write code and another AI agent to review it, iterating until quality gates pass.

# Substance

## What we know

From the existing implementation (babysit-with-review.sh):

- Script operates on a single git repository (PWD-based invocation)
- Successfully used in personal scripts repo (evidence: commit history showing convergence-aware review cycle implementation)
- Handles 50+ iterations per run with configurable limits
- Two companion scripts extend the loop: `babysit-work-prep.sh` (ticket → spec pipeline with human approval gate) and `babysit-builder.sh` (spec → PR pipeline with human merge gate). Both reuse the same REPO_BASE infrastructure, stop-file protocol, and selectable implementer/reviewer harnesses.
- Codex review integration is optional (graceful degradation when codex CLI unavailable)
- Logging infrastructure exists at ~/sisyphus-logs/ with per-project lock files
- Helper scripts (prs, issues, specs) provide state collection via --json output

## What we assume

- [ASSUMPTION] Target users are solo developers or small teams (1-5 people) working on projects where autonomous iteration adds value. Flips if: enterprise adoption requires audit trails, approval gates, and compliance documentation.
- [ASSUMPTION] The tool is for personal/internal use, not public distribution. Flips if: OSS distribution requires installation docs, versioning strategy, support model, and security hardening.
- [ASSUMPTION] Users are comfortable with shell scripts and CLI tools. Flips if: GUI or hosted service is needed, requiring web application infrastructure.
- [ASSUMPTION] Single-repo operation is sufficient. Flips if: monorepo or multi-repo orchestration is needed, requiring workspace management.

## Scale envelope

- Users at launch: 1 (Chris Robertson)
- Users at 6mo: < 10 (organic adoption within immediate team)
- Users at 18mo: < 10 (limited distribution, personal/internal tool)
- Repos per user: 1-10 active projects
- Iterations per run: typically 5-20, max 50
- Review cycles per PR: typically 1-3, max 6
- Spec-drafting tickets per work-prep run: typically 5-20, max 20
- Build tickets per builder run: typically 1-5 per run
- Geographies: developer workstations (no cloud hosting)
- Growth curve: organic word-of-mouth within engineering teams

## Business case

- Revenue model: Internal tool, no direct revenue
- Value proposition: Reduces time-to-PR for well-scoped tasks from hours to minutes; reduces manual review burden through automated quality gates
- Cost model: 
  - Infra cost: $0 (runs on developer workstation)
  - Anthropic API cost: ~$0.50-2.00 per iteration (estimated based on claude -p usage with OAuth)
  - Maintenance cost: ad-hoc improvements by owner
- Unit economics: Cost-per-iteration decreases as prompts stabilize and fewer review cycles are needed
- Success metric: Developer reports net-positive time savings after accounting for babysitter setup and prompt tuning

## Approvers

- Product: Chris Robertson (owner/user)
- Engineering: Chris Robertson
- Finance / GTM: N/A (internal tool)
- Compliance: N/A (operates on local workstation, no data retention beyond logs)

## Failure modes & blast radius

- If we ship and nobody uses it beyond the author: Zero blast radius, remains a personal productivity tool
- If review cycle produces false positives (flags valid code): Developer time wasted investigating non-issues; mitigated by prescriptive mode requiring concrete suggested fixes
- If review cycle misses bugs (false negatives): Code quality degrades; mitigated by human review still required before production deployment
- If MCP outage persists: PRs stall with review-mcp-outage label; graceful - developer can manually review and merge

# Bounds

## Out of scope

- GUI or web-based interface (CLI only at launch)
- Multi-repo orchestration (single repo per invocation)
- Team coordination features (no shared queue, no work assignment)
- Hosted/SaaS deployment (developer workstation only)
- Windows support (macOS/Linux bash environments only)
- Integration with issue trackers beyond GitHub and Jira (no Linear, Shortcut, etc.)
- Jira status transitions (label-based handoff only; Jira/GitHub sync is operator-configured)

## Assumptions-that-could-flip

- Developer workstation execution assumption. If flipped to cloud/CI execution: requires environment setup automation, secrets management, and remote log access.
- Single-user workflow assumption. If flipped to multi-user: requires lock file coordination across machines, shared state management, and conflict resolution.
- Claude Code CLI availability. If flipped to direct API: requires API key management, rate limit handling, and streaming response parsing.
- Bash script delivery assumption. If flipped to compiled binary or language-native (Python/Go): requires packaging, distribution, and cross-platform builds.

## Composes with / replaces

- Replaces: Manual iterative development where developer writes code, runs tests, commits, reviews
- Composes with: 
  - Existing CI/CD pipelines (babysitter creates PRs, CI validates before merge)
  - Code review tools (CodeRabbit, human reviewers provide additional feedback)
  - Project management tools (gh issues provides work queue)
  - `babysit-work-prep.sh` (ticket → spec pipeline, feeds builder queue)
  - `babysit-builder.sh` (spec → PR pipeline, produces review-ready PRs)

# Signals

## Leading indicators (first 30-90 days)

- Activation: Developer runs babysit-with-review.sh on at least one project
- Time-to-value: First successful PR merged via autonomous loop within first week of use
- Engagement depth: Developer uses tool on 2+ separate projects; runs 5+ iterations per week
- Iteration quality: Average iterations-per-completed-task decreases over time (prompt improvement)

## Lagging indicators (90+ days)

- Retention: Developer continues using tool 90 days after first use
- Productivity: Net time saved (autonomous iteration time - prompt tuning time - issue resolution time) > 0
- Quality: PRs created by babysitter pass code review at same or higher rate than manually created PRs
- Adoption: Tool usage spreads to other developers in organization (if shared)

## Kill criteria

- If time-to-PR via babysitter exceeds manual development time for >70% of tasks after 90 days → kill or pivot to different prompt strategy
- If false positive rate in review cycle exceeds 50% → pivot to human-only review
- If MCP outage frequency causes >30% of PRs to stall → remove Codex dependency, use alternative review approach

