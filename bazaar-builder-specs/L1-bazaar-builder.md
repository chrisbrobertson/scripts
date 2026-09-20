---
spec_type: product
id: BZR-PROD-BAZAAR-BUILDER
status: review
owners: [Chris Robertson]
depends_on: []
experience_authority: none
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [scope, surface_span, novelty]
  scored_on: 2026-09-19
---

# Frame

## TL;DR
Bazaar Builder turns GitHub issues into merged, reviewed pull requests with two small controllers and two worker agents. The **issue loop** verifies an issue, drafts and cross-checks the specs it needs, and parks it for one human approval. The **build loop** takes one approved issue (with its sub-issues), plans the sequence, implements on a single feature branch, and drives the PR through the existing adversarial review cycle without ever merging. It replaces the ticket-selection logic inside today's `babysit-work-prep.sh` / `babysit-builder.sh` with a plain queue and a GitHub label state machine.

## Analog
Like a Kanban board with two swim-lanes (Refine, Build) where a dumb dispatcher pulls the top card and hands it to a specialist, but the specialists are Claude/Codex agents and the board is GitHub issue labels.

# Substance

## What we know
- **Owner decisions, 2026-09-19 (this conversation):**
  1. Human approval is the only gate between "spec complete" and "ready for development".
  2. The issue-loop agent may edit the issue body while doing spec work.
  3. GitHub issues only. No Jira.
  4. `babysit-with-review.sh` is left untouched for use elsewhere. The review loop is extracted into a library for this tool.
  5. Concurrency is a cost configuration. All work happens in unique worktrees on unique feature branches named for the issue ID.
  6. Controllers are simple, non-thinking models that only queue the next work item. Default accepted: a bash label query is the queue; a cheap model is called only to break ties or write the one-line reason an item was skipped.
  7. Sub-issues use GitHub native sub-issues. The issue loop may create them.
  8. One branch, one PR per parent issue. Review after each sub-issue. On a failed sub-issue, skip it and continue (owner, 2026-09-19, replacing the halt default).
  9. Human bounce for issue verification is a comment plus a label. Body editing is allowed (decision 2 supersedes the read-only default).
  10. Bug vs feature routing: issue label first, agent judgement as fallback. The plan ships an issue template.
  11. Controller model defaults to Haiku 4.5. Implementer and reviewer keep claude/codex selectability with per-role model and effort flags.
  12. New standalone corpus `bazaar-builder-specs/`, prefix `BZR`.
  13. (Second round, 2026-09-19) Every open issue without a `bzr-*` label is intake. Sub-issues are created at draft time so the human sees the breakdown. No time-based claim lease; everything is asynchronous. No outage labels: a failed step is retried next run; `bzr-blocked` is only for human escalation or after three automatic attempts. Two scripts. A repo with no spec corpus makes the issue non-actionable. `babysit-builder.sh` and `babysit-work-prep.sh` are merged into this work and retired. `--effort low` is the controller setting.
- **Existing raw sources being reused:** `babysit-builder.sh` v0.1.0 (1,827 lines) holds the newest copy of the convergent review cycle (`run_build_cycle`, line 1093; `codex_review_with_retry`, line 793; `valid_review_structure`, line 733). `babysit-work-prep.sh` v0.2.0 holds the spec-mode variant (`run_spec_review_cycle`, line 1040) whose prompts check contradiction, duplication, dangling references, schema violations, and invented design decisions. `valid_review_structure` and `review_with_retry` are byte-identical between builder and work-prep; `run_claude` and `codex_review_with_retry` have drifted (md5 differs across all three scripts, checked 2026-09-19).
- **GitHub capability probed 2026-09-19:** `GET /repos/{owner}/{repo}/issues/{n}/sub_issues` and the GraphQL `Issue.subIssues` / `subIssuesSummary` / `parent` fields both answer for this account. `gh issue` has no sub-issue subcommand, so workers use `gh api`.
- **Authorship is not a signal:** `gh api user` returns the same login the human uses in the browser, so "a human replied" cannot be detected by comment author. Agent comments carry an HTML marker instead.
- **Scale:** same envelope as ASF: under 10 users, a handful of repos, personal home-lab hosts.

## What we assume
- [ASSUMPTION] The approval comment authorises the tool to flip the spec's frontmatter to `status: ready` when it merges the spec PR. Flips if: the owner wants to edit `status:` by hand before approving, in which case the sweep refuses to merge a spec still marked `review`.
- [ASSUMPTION] A rejected spec (PR closed unmerged) escalates the issue to `bzr-blocked` and closes its draft-time sub-issues, rather than silently returning to intake. Flips if: the owner wants rejection to mean "redraft", in which case the controller strips the label and the worker starts over with the rejection comments as input.
- [ASSUMPTION] Three automatic attempts before escalation, counted per role via marker comments. Flips if: transient failures cluster (e.g. a backend outage burns all three in an hour), in which case attempts within one controller run count as one.

## Scale envelope
- Launch: 1 user, 2-3 repos, 1-2 concurrent workers per repo.
- 6 months: under 5 users, under 10 repos, up to 4 workers per host.
- 18 months: under 10 users. No multi-tenant hosting. Volume bounded by model spend, not by the tool.

## Business case
- **Value:** removes the two hand steps that stall the current pipeline (deciding what to build next; splitting a ticket into build units) and makes the human's only job "answer questions on the issue, approve the spec, merge the PR".
- **Cost model:** per issue, one issue-worker run (Sonnet-class, plus up to 4 spec-review cycles) and one build-worker run (Sonnet/Opus per stage, plus up to 6 review cycles per sub-issue). Controller cost is near zero (Haiku, one short call per dispatch, none when the queue has one candidate).
- **Success metric:** median wall-clock from issue opened to `bzr-pr-ready` under 24h with at most one human touch in between.

## Approvers
- Product: Chris Robertson
- Engineering: Chris Robertson
- Finance-GTM: N/A (personal tool)
- Compliance: N/A

## Failure modes & blast radius
- **Controller dispatches the same issue twice:** two workers race on one branch. Blast: a force-push or a conflicting PR. Mitigation: per-issue claim label plus a claim marker naming host and pid, checked against live processes before spawn (see [BZR-FEAT-CONTROLLER](L3-controller.md)).
- **Issue worker invents requirements:** spec looks complete but encodes guesses. Blast: a wrong feature gets built. Mitigation: spec review cycle flags invented decisions; human approval gate.
- **Build worker merges:** would bypass review. Blast: unreviewed code on main. Mitigation: no merge path in the worker; branch protection with the `codex-review` status remains the hard stop.
- **Reviewer backend outage:** review cannot run. Blast: the attempt fails, the issue returns to its queue, nothing merges; three failures escalate to a human.

# Bounds

## Out of scope
- Jira and any non-GitHub tracker.
- Auto-merge of any PR.
- Cross-host coordination (the home-lab-monitor `/api/babysit` lock stays with the staff-fleet dispatcher).
- Time limits on workers or claims.
- Changes to `babysit-with-review.sh`.
- Multi-repo issues (one issue maps to one repo).

## Assumptions-that-could-flip
- **Label state machine on GitHub is the only durable state.** Flipping to a local DB would require a sync step and a recovery story; rejected for now because labels are visible and hand-editable.
- **One PR per parent issue.** Flipping to stacked PRs per sub-issue changes the review-cycle contract and the merge-order story.

## Composes with / replaces
- **Replaces:** `babysit-work-prep.sh` and `babysit-builder.sh` entirely; both are deleted in plan phase 5 (owner, 2026-09-19).
- **Composes with:** `ASF-FEAT-REVIEW-CYCLE` (its logic is the extraction source for [BZR-FEAT-REVIEW-LIB](L3-review-lib.md)); `setup-branch-protection.sh`; the `prs`, `issues`, `specs` helpers; `spec-guide.md`.
- **Leaves alone:** `ASF-PROD-BABYSIT-WITH-REVIEW` and its script.

# Signals

## Leading indicators (first 30-90 days)
- Share of triaged issues that reach `bzr-spec-review` without a `bzr-needs-info` bounce.
- Human touches per issue (target: 2, the approval and the merge).
- Spec review cycles per draft (target: median 2 or fewer).

## Lagging indicators (90+ days)
- PRs labelled `bzr-pr-ready` that were merged unchanged.
- Issues reopened after merge.

## Kill criteria
- More than 30% of `bzr-pr-ready` PRs need hand rework before merge over 30 days.
- More than 50% of triaged issues bounce to `bzr-needs-info` twice or more.
- Controller double-dispatch observed more than once after the claim protocol ships.
