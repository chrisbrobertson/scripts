---
spec_type: feature
id: ARLO-FEAT-WORK-PREP
status: review
owners: [Chris Robertson]
depends_on: [ARLO-SYS-AUTONOMOUS-DEV]
parent_l1: ARLO-PROD-BABYSIT-WITH-REVIEW
parent_l2: ARLO-SYS-AUTONOMOUS-DEV
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [novelty, scope, external_integration]
  scored_on: 2026-08-27
---

# Frame

## TL;DR
A companion research loop (`babysit-work-prep.sh`) that turns raw tickets — GitHub
issues and/or Jira issues — into fully-scoped TIF spec files, opens a PR per spec, and
waits for a human approval comment before merging the spec and creating a labelled
sub-ticket that feeds `babysit-builder.sh`'s build queue.

## Analog
Like a staff engineer doing intake triage: reading a raw ticket, researching the
codebase, writing up a scoped design doc, and posting it for review — except the
research and drafting is done by an AI agent, and a human still has to say "approved"
before the design is considered final.

## Reader & next action
Implementing engineer: understand the two-phase loop (per-ticket drafting, then an
approval-gate sweep over already-opened spec PRs) and the GitHub/Jira source
abstraction. QA: verify idempotency of the approval gate and sub-ticket
deduplication before this is wired into a live ticket queue.

## API surface fragment
```bash
babysit-work-prep.sh [--repo OWNER/REPO] [--source github|jira|both]
                      [--implementer claude|codex]
                      [--implementer-model MODEL] [--implementer-effort LEVEL]
                      [--max-tickets N] [--dry-run]

# Env (required when --source jira|both)
JIRA_BASE_URL   Jira instance base URL
JIRA_TOKEN      Bearer token for Jira REST API
JIRA_PROJECT    Jira project key to query

# Flags
--repo OWNER/REPO   GitHub repo the spec PRs and sub-tickets are created in
--source SOURCE     Ticket origin: github (default), jira, or both
--max-tickets N     Cap on tickets drafted per invocation (default 20; see scale envelope)
--dry-run           List tickets that would be drafted / PRs that would be approval-swept;
                     no worktree, no implementer call, no gh/Jira writes

# Exit codes
0   # Completed normally, including a run that drafted zero tickets
1   # Fatal: pre-flight failure, gh/git auth failure, lock file collision
2   # Bad arguments
```

## Consumer
Operator running the research phase of the three-script pipeline
(work-prep → builder → babysit-with-review). `babysit-builder.sh` is the downstream
consumer of the `status:ready-to-build` sub-tickets this script creates.

# Substance

## What we know
Decisions already recorded in ARLO-PROD-BABYSIT-WITH-REVIEW and ARLO-SYS-AUTONOMOUS-DEV
(owner-approved 2026-08-27):

- **Two-phase outer loop, not one.** Phase 1 (drafting): for each undrafted ticket, a
  `git worktree` is created, the implementer researches the ticket against the current
  codebase and drafts a TIF spec file under `$SCRIPTS_DIR/specs` (or the target repo's
  spec directory), commits it, and opens a PR. Phase 2 (approval sweep): before drafting
  new tickets, the script scans PRs opened by prior work-prep runs for an approval
  comment; on match it merges the spec PR, labels the *source* ticket
  `status:ready-to-build`, and files a new sub-ticket for the builder queue.
- **No adversarial review cycle for spec drafts.** Unlike `babysit-with-review.sh`, spec
  PRs are not run through a Claude/Codex review cycle — the human approval comment *is*
  the review gate. Only an implementer role is invoked (`--implementer claude|codex`);
  there is no `--reviewer` flag for this script.
- **Approval detection:** `gh pr list --json comments` on each open spec PR, matched
  against a case-insensitive `\bapproved\b` regex on comment bodies.
- **Sub-ticket creation:** always a GitHub issue via `gh issue create`, labelled
  `sub-ticket` (plus `status:ready-to-build`), even when the source ticket was Jira —
  the builder queue (`gh issue list --label status:ready-to-build,sub-ticket`) only
  reads GitHub issues, so Jira-sourced work is bridged into a GitHub issue at approval
  time, not at draft time.
- **Multi-source ticket queue:** `--source both` merges `gh issue list` output with
  Jira's `$JIRA_BASE_URL/rest/api/3/search?jql=project=$JIRA_PROJECT+AND+status=Open`
  (Bearer auth via `JIRA_TOKEN`) into one queue; each ticket retains its origin so the
  approval-gate step knows whether to label a GitHub issue directly or create a bridging
  sub-ticket.
- **Jira degrades, does not fail the run.** If the Jira API is unavailable, Jira tickets
  are skipped and the run continues with GitHub-sourced tickets only (per
  ARLO-SYS-AUTONOMOUS-DEV's cross-component contract for this integration).
- **Shared infrastructure with `babysit-with-review.sh`:** same `REPO_BASE`
  auto-detection, same selectable-implementer plumbing, own stop file
  (`~/sisyphus-logs/<project>-work-prep.stop`) so it can run concurrently with
  `babysit-with-review.sh` and `babysit-builder.sh` on the same project.
- **Scale envelope (from L1):** typically 5-20 tickets drafted per run, max 20 —
  `--max-tickets` enforces this as a hard cap, defaulting to 20.

## What we assume
These mechanics are NOT yet confirmed by the owner — they are the author's best
reconstruction from the L1/L2 decisions above, filled in to make the contract concrete
enough to implement. Flag for explicit owner sign-off before `babysit-work-prep.sh` is
built against this spec:

- [ASSUMPTION] Drafting idempotency: a ticket with an already-open (or already-merged)
  work-prep PR is not re-drafted. Mechanism proposed: search for an existing PR whose
  branch name or body references the ticket ID before creating a worktree. Flips if:
  the owner wants re-drafts on demand (e.g., a `--redraft` flag).
  Owner should also confirm the intended commit destination for spec PRs — some
  callers may want a target repo's own `specs/` directory rather than
  `$SCRIPTS_DIR/specs` when work-prep runs against a project other than `scripts`.
- [ASSUMPTION] Approval-gate idempotency: once a source ticket carries
  `status:ready-to-build`, the approval sweep skips it even if the approval comment
  is still present (prevents duplicate sub-ticket creation on every run). Flips if:
  the owner wants re-approval to be able to spawn a second sub-ticket (e.g., spec
  amended after initial approval).
  Owner should confirm whether re-approval after a spec amendment is a supported flow
  and, if so, what triggers a second sub-ticket.
  Owner should confirm who is authorized to post the approval comment (any commenter,
  or only `owners:` from the spec frontmatter / a specific GitHub login) — the `\bapproved\b`
  regex alone does not restrict by author.
- [ASSUMPTION] Rejection path: no rejection sentinel is defined yet. Proposed: a
  comment matching `\bchanges requested\b` (or similar) leaves the ticket undrafted and
  logs a note; the ticket is picked up for re-drafting on the next run.
  Owner should confirm the exact rejection sentinel and re-draft trigger, or whether
  rejection is closed-PR-only (human closes the spec PR, ticket returns to the queue).
- [ASSUMPTION] Sub-ticket body/metadata: proposed to carry the merged spec's file path,
  its `id:` frontmatter value, and the originating ticket link, so the builder can
  locate the approved spec without re-parsing PR history.
  Owner should confirm the required sub-ticket fields the builder actually needs to
  start work.

## Contract

### Request shape
```bash
babysit-work-prep.sh [--repo OWNER/REPO] [--source github|jira|both]
                      [--implementer claude|codex]
                      [--implementer-model MODEL] [--implementer-effort LEVEL]
                      [--max-tickets N] [--dry-run]
# --repo: optional; auto-detected via `gh repo view` when omitted
# --source: defaults to github
# Unknown flags: exit 2 with usage message
```

### Response shape
```
# stdout: per-phase summary
[draft] ticket #42 (github) → PR #101 opened
[draft] ticket PROJ-7 (jira) → PR #102 opened
[draft] ticket #43 (github) → already has open spec PR #98, skipped
[approve] PR #98 → approved comment found → merged, ticket #40 labelled status:ready-to-build, sub-ticket #103 created
[approve] PR #99 → no approval comment yet, skipped

# exit 0 even when zero tickets are drafted or approved this run
```

### Invariants
1. **Two-phase ordering:** the approval sweep always runs before new drafting begins in
   a given invocation, so an approval landing between runs is acted on promptly.
2. **Draft idempotency:** a ticket with an existing open or merged work-prep PR is never
   re-drafted in the same run (see assumption above for exact matching mechanism).
3. **Approval idempotency:** a source ticket already labelled `status:ready-to-build` is
   never processed by the approval sweep again.
4. **No auto-merge without approval:** a spec PR is merged only after a matching
   approval comment is found; `gh pr merge` is never called speculatively.
5. **Sub-ticket always GitHub:** regardless of ticket source, the sub-ticket fed to the
   builder queue is a GitHub issue labelled `sub-ticket` + `status:ready-to-build`.
6. **Max-tickets cap:** no more than `--max-tickets` (default 20) new drafts are started
   per invocation, regardless of queue size.
7. **Dry-run is read-only:** `--dry-run` performs `gh`/Jira reads only — no worktree, no
   implementer invocation, no PR/issue/label writes.

### Idempotency
Idempotent per ticket and per PR: re-running the script with an unchanged queue and no
new approval comments produces no new PRs, merges, or sub-tickets.

### Versioning policy
Companion script to `babysit-with-review.sh`; no independent version number proposed
yet. Breaking changes to the approval-comment regex or sub-ticket label schema require
manual migration of any open spec PRs and unlabelled tickets.

## Performance budget
- **Per-ticket draft latency:** comparable to a single `babysit-with-review.sh` outer
  iteration (p50 ~2min, p95 ~10min) — one implementer pass, no review cycle.
- **Approval sweep latency:** dominated by `gh pr list --json comments` calls; expected
  sub-second per open PR.
- **Run of 20 tickets:** on the order of an hour, dominated by implementer inference
  time (no formal SLO — internal tool, see ARLO-SYS-AUTONOMOUS-DEV SLOs section).

## Security model
- **AuthN / AuthZ:** Inherits `gh auth status`; Jira access via `JIRA_TOKEN` bearer
  token, read-only (search endpoint only).
- **Tenant isolation:** Single-user; PRs/issues created in the authenticated account's
  accessible repos.
- **PII handling:** Ticket titles/descriptions and code context only; no user data.
- **Approval spoofing:** [ASSUMPTION-linked] until the "who can approve" question above
  is resolved, any commenter on the spec PR can trigger a merge + sub-ticket by writing
  a comment containing "approved" — this is a real gap if the repo has non-owner
  collaborators with comment access.

## Telemetry contract
Events emitted to stdout:
- `[draft] ticket <id> (<source>) → PR #N opened`
- `[draft] ticket <id> (<source>) → already has open spec PR #N, skipped`
- `[approve] PR #N → approved comment found → merged, ticket #M labelled status:ready-to-build, sub-ticket #K created`
- `[approve] PR #N → no approval comment yet, skipped`

Events emitted to stderr:
- `[draft] ticket <id>: worktree/implementer failure → skipped`
- `[jira] Jira API unavailable → skipping Jira-sourced tickets this run`

## Verifiers
- Tech lead: Chris Robertson
- Security: verify the approval-comment authorization gap above before this spec moves
  to `ready`
- QA: verify draft idempotency, approval-sweep idempotency, and sub-ticket
  deduplication with a repeated-run test

## Failure modes & blast radius
- **Jira API unavailable:** Jira-sourced tickets skipped for the run; GitHub-sourced
  tickets still processed. Blast: partial coverage, no run failure.
- **Approval regex false positive** (e.g., a comment saying "this is not approved yet"
  matches `\bapproved\b`): spec merges prematurely. Blast: a spec that wasn't actually
  ready for build enters the sub-ticket queue; caught at PR-review time by the builder's
  own review cycle, but wastes a build cycle. Mitigated by tightening the regex or
  requiring an exact-phrase marker — open question, see assumptions above.
- **Duplicate sub-ticket creation** (idempotency check fails): builder queue gets two
  entries for the same spec. Blast: builder does duplicate work on two PRs; low, since
  the builder's own review cycle would still gate merge.
- **Worktree/implementer failure mid-draft:** ticket logged to stderr and skipped;
  picked up again next run since no PR was opened (no partial-PR state to clean up).

# Bounds

## Out of scope
- **Automated rejection handling beyond re-queueing:** no automatic spec revision loop;
  a rejected/changes-requested spec PR requires either a human edit or a fresh work-prep
  run against the same ticket.
- **Non-GitHub, non-Jira ticket sources:** Linear, Shortcut, etc. are out of scope (see
  ARLO-PROD-BABYSIT-WITH-REVIEW out-of-scope list).
- **Code changes:** this script only drafts spec documents; it never touches
  implementation code. `babysit-builder.sh` owns that step.
- **Review cycles:** no Claude/Codex adversarial review of spec drafts; human approval
  comment is the only gate.

## Assumptions-that-could-flip
- **Single-approver-any-commenter assumption.** If flipped (need restricted approval
  authority): approval check must filter comment author against `owners:` in the
  spec's frontmatter or a configured allowlist.
- **GitHub-bridge-for-Jira assumption.** If flipped (builder should read Jira directly):
  `babysit-builder.sh`'s build-queue query would need its own Jira integration instead
  of a GitHub sub-ticket bridge.
- **No-review-cycle-for-specs assumption.** If flipped (specs need automated review
  too): would require wiring the same `review_with_retry` infrastructure used by
  `babysit-with-review.sh`, turning this into a three-role pipeline.

## Composes with / replaces
- **Composes with:**
  - `babysit-builder.sh` (consumes `status:ready-to-build,sub-ticket` issues)
  - `babysit-with-review.sh` (shares `REPO_BASE`, selectable-implementer plumbing, and
    `~/sisyphus-logs/` conventions, but runs as an independent process with its own
    stop file)
  - GitHub Issues and Jira (ticket sources)
- **Distinct from `babysit-with-review.sh`:** produces spec documents, not code PRs;
  gated by human comment, not automated review.

# Signals

## Acceptance tests
1. **Given** an open GitHub issue with no existing work-prep PR, **when** the script
   runs, **then** a worktree is created, a spec file is drafted and committed, and a PR
   is opened referencing the ticket.
2. **Given** a ticket that already has an open spec PR, **when** the script runs,
   **then** it is skipped in the drafting phase with a `already has open spec PR`
   message and no duplicate PR is opened.
3. **Given** an open spec PR with a comment containing "Approved, let's build this",
   **when** the approval sweep runs, **then** the PR is merged, the source ticket is
   labelled `status:ready-to-build`, and a new sub-ticket issue is created.
4. **Given** an open spec PR with no approval comment, **when** the approval sweep
   runs, **then** the PR is left open and untouched.
5. **Given** `--source jira` and `JIRA_BASE_URL`/`JIRA_TOKEN` pointing at an
   unreachable host, **when** the script runs, **then** it logs the Jira failure to
   stderr and exits 0 having processed zero tickets (no GitHub fallback needed since
   source is Jira-only in this case).
6. **Given** `--source both` with one open GitHub issue and one open Jira issue,
   **when** the script runs, **then** both are drafted in the same invocation and each
   PR references its origin.
7. **Given** a source ticket already labelled `status:ready-to-build`, **when** the
   approval sweep runs and finds a (still-present) approval comment on its now-merged
   PR, **then** no second sub-ticket is created.
8. **Given** `--max-tickets 1` and 3 undrafted tickets in the queue, **when** the script
   runs, **then** exactly 1 PR is opened and the other 2 remain queued for next run.
9. **Given** `--dry-run`, **when** the script runs, **then** it prints the tickets that
   would be drafted and the PRs that would be approval-swept, with no worktree, gh, or
   Jira write calls made.

## Telemetry events tied to L1 KPIs
- **Tickets drafted per run** → throughput of the intake pipeline
- **Time-to-approval per spec PR** → human review latency, distinct from AI drafting time
- **Approval-to-merge rate** → fraction of drafted specs that are ultimately approved
  vs. abandoned/rejected

## AEAB cases
N/A — no eval framework yet. Future: record (ticket_id, source, drafted_at,
approved_at, sub_ticket_id) to compute drafting-to-build lead time.

## Kill criteria
- If the approval-comment regex produces false positives on >10% of spec PRs → require
  an exact-phrase marker (e.g., `LGTM-APPROVED`) instead of a loose regex
- If drafted specs are approved-then-rejected by the builder's review cycle at a high
  rate (>50%) → the drafting prompt needs more codebase context, or a lightweight
  automated pre-check before human approval
- If Jira integration failure rate exceeds 20% of `--source jira|both` runs → treat
  Jira as unsupported until the integration is hardened
