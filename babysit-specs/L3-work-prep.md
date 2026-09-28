---
spec_type: feature
id: ASF-FEAT-WORK-PREP
status: review
owners: [Chris Robertson]
depends_on: [ASF-SYS-AUTONOMOUS-DEV]
parent_l1: ASF-PROD-BABYSIT-WITH-REVIEW
parent_l2: ASF-SYS-AUTONOMOUS-DEV
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
                      [--reviewer claude|codex]
                      [--reviewer-model MODEL] [--reviewer-effort LEVEL]
                      [--max-tickets N] [--dry-run]

# Env (required when --source jira|both)
JIRA_BASE_URL           Jira instance base URL
JIRA_TOKEN              Bearer token for Jira REST API
JIRA_PROJECT            Jira project key to query

# Env (optional)
MAX_SPEC_REVIEW_CYCLES  Spec review cycles before a draft is quarantined (default 4)

# Flags
--repo OWNER/REPO   GitHub repo the spec PRs and sub-tickets are created in
--source SOURCE     Ticket origin: github (default), jira, or both
--reviewer ROLE     Spec review harness for the adversarial review cycle (default codex)
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
consumer of the `build-ready` sub-tickets this script creates.

# Substance

## What we know
Decisions already recorded in ASF-PROD-BABYSIT-WITH-REVIEW and ASF-SYS-AUTONOMOUS-DEV
(owner-approved 2026-08-27):

- **Two-phase outer loop, not one.** Phase 1 (drafting): for each undrafted ticket, a
  `git worktree` is created, the implementer researches the ticket against the current
  codebase and drafts a TIF spec file under the target repo's spec directory — `./specs`
  by default, or the first `./*-specs` directory found, overridable via
  `WORK_PREP_SPEC_DIR` — commits it, and opens a PR. Phase 2 (approval sweep): before drafting
  new tickets, the script scans PRs opened by prior work-prep runs for an approval
  comment; on match it merges the spec PR and files a new GitHub sub-ticket for the
  builder queue. For a GitHub source only, it also labels the source ticket
  `status:ready-to-build`.
- **Adversarial spec review cycle, not a structural check.** Every drafted spec PR opens
  as a **draft PR** and is driven through a convergent reviewer/implementer cycle
  (`run_spec_review_cycle`) — the same pattern `babysit-with-review.sh` and
  `babysit-builder.sh` use — via a selectable `--reviewer claude|codex` role (default
  `codex`). The reviewer judges the draft against every other spec in the corpus, the
  schema in `spec-guide.md`, and the code it describes, not just structural well-formedness.
  `MAX_SPEC_REVIEW_CYCLES` (default 4) caps the cycle count, with prescriptive mode
  (requiring a concrete suggested fix under each BLOCKING finding) from cycle 3. The PR
  leaves draft only once the review reaches zero BLOCKING findings; a draft that doesn't
  converge is labelled with one of the `spec-*` quarantine labels (`spec-review-max-cycles`,
  `spec-review-incomplete`, `spec-review-mcp-outage`, `spec-review-codex-outdated`,
  `spec-review-codex-no-credits`) and stays draft. The human approval comment is a second,
  independent gate on top of this — it is never asked to bless an unreviewed spec.
- **Approval detection:** `gh pr list --json comments` on each open spec PR, matched
  against a line starting with `approved` (case-insensitive, anchored to line start —
  accepts "Approved, let's build this" but rejects "this is not approved yet"), and only
  when posted by an authorized commenter. Authorization is `WORK_PREP_APPROVERS`
  (comma-separated GitHub logins, or `*` for any commenter), defaulting to the
  authenticated `gh` user — so by default only the operator can approve. Comments the
  wrapper posts itself (review/status comments) are excluded from the match so the
  wrapper can never self-approve.
- **Sub-ticket creation:** always a GitHub issue via `gh issue create`, labelled
  `sub-ticket` plus `build-ready` — the label the builder loop actually queues on —
  even when the source ticket was Jira. The issue body embeds a
  `<!-- babysit-work-prep-subticket source=<source> ticket=<ticket> -->` marker; before
  creating a sub-ticket the approval sweep searches issues (`gh issue list --state
  all --limit 1000`) for this marker keyed on `(source, ticket)`, and this search — not
  any label —
  is the idempotency check (see Approval-gate idempotency below). The `--limit 1000`
  bound means a matching sub-ticket older than the 1000 most recent issues in the repo
  would fall outside the search and could be re-created; acceptable at this repo's
  scale (<10 users, low issue volume) but noted as the failure mode. Only when the source
  is `github` does the approval sweep additionally label the *source* ticket
  `status:ready-to-build`, an informational marker ("spec approved, sub-ticket exists")
  — Jira tickets never get this label, since `gh issue edit` has no way to label a Jira
  issue. The builder queue (`gh issue list --label build-ready,sub-ticket`) only reads
  GitHub issues, so Jira-sourced work is bridged into a GitHub issue at approval time,
  not at draft time.
- **Multi-source ticket queue:** `--source both` merges `gh issue list` output with
  Jira's `$JIRA_BASE_URL/rest/api/3/search?jql=project=$JIRA_PROJECT+AND+status=Open`
  (Bearer auth via `JIRA_TOKEN`) into one queue; each ticket retains its origin so the
  approval-gate step knows whether to label a GitHub issue directly or create a bridging
  sub-ticket.
- **Jira degrades, does not fail the run.** If the Jira API is unavailable, Jira tickets
  are skipped and the run continues with GitHub-sourced tickets only (per
  ASF-SYS-AUTONOMOUS-DEV's cross-component contract for this integration).
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
- [ASSUMPTION] Approval-gate idempotency: the approval sweep dedupes by searching the
  most recent 1000 issues (`gh issue list --state all --limit 1000`, see Sub-ticket
  creation above for the bound and its residual duplicate-creation risk) for the
  embedded sub-ticket marker keyed on `(source, ticket)` — never by a
  label on the source ticket, since that label is GitHub-only (see Sub-ticket creation
  above) and, even for GitHub sources, could be applied on one run while sub-ticket
  creation itself fails on that same run. Keying on the marker instead means a partial
  failure (merge and label succeed, `gh issue create` fails) is safely retried on the
  next run instead of the sub-ticket being permanently suppressed. Flips if: the owner
  wants re-approval to be able to spawn a second sub-ticket (e.g., spec amended after
  initial approval).
  Owner should confirm whether re-approval after a spec amendment is a supported flow
  and, if so, what triggers a second sub-ticket.
- [ASSUMPTION] Rejection path: a changes-requested comment does not trigger re-drafting.
  The existing open PR remains linked to the ticket; a human must close that PR before
  the ticket can be drafted again on a later run. No rejection-comment sentinel is
  implemented. Owner should confirm whether closing the PR is the intended re-draft
  trigger.
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
                      [--reviewer claude|codex]
                      [--reviewer-model MODEL] [--reviewer-effort LEVEL]
                      [--max-tickets N] [--dry-run]
# --repo: optional; auto-detected via `gh repo view` when omitted
# --source: defaults to github
# --reviewer: defaults to codex
# Unknown flags: exit 2 with usage message
```

### Response shape
```
# stdout: example events (verbatim forms the script echoes — see Telemetry contract)
[draft] ticket 42 (github) → draft PR #101 opened (babysit-specs/example.md), entering spec review
[draft] ticket PROJ-7 (jira) → draft PR #102 opened (babysit-specs/example-jira.md), entering spec review
[draft] ticket 43 (github) → already has open/merged spec PR #98, skipped
[approve] PR #98 → approved by chris, merged/reconciled, sub-ticket #103 created
[approve] PR #99 → no authorized approval comment yet, skipped

# exit 0 even when zero tickets are drafted or approved this run
```

### Invariants
1. **Two-phase ordering:** the approval sweep always runs before new drafting begins in
   a given invocation, so an approval landing between runs is acted on promptly.
2. **Draft idempotency:** a ticket with an existing open or merged work-prep PR is never
   re-drafted in the same run (see assumption above for exact matching mechanism).
3. **Approval idempotency:** a source ticket whose sub-ticket already exists — matched
   by the embedded `(source, ticket)` marker, never by a label — is never reprocessed by
   the approval sweep.
4. **No auto-merge without approval:** a spec PR is merged only after a matching
   approval comment is found; `gh pr merge` is never called speculatively.
5. **Sub-ticket always GitHub:** regardless of ticket source, the sub-ticket fed to the
   builder queue is a GitHub issue labelled `sub-ticket` + `build-ready`.
6. **Max-tickets cap:** no more than `--max-tickets` (default 20) new drafts are started
   per invocation, regardless of queue size.
7. **Dry-run is read-only:** `--dry-run` performs `gh`/Jira reads only — no worktree, no
   implementer invocation, no PR/issue/label writes.
8. **No approval on an unreviewed spec:** the approval sweep skips any PR still marked
   draft by `gh`, regardless of comment content — a spec must converge in the adversarial
   review cycle before a human approval comment can act on it.

### Idempotency
Idempotent per ticket and per PR: re-running the script with an unchanged queue and no
new approval comments produces no new PRs, merges, or sub-tickets.

### Versioning policy
Companion script to `babysit-with-review.sh`, with its own independent version number
— shipped as `babysit-work-prep.sh` v0.2.1. Breaking changes to the approval-comment
regex or sub-ticket label schema require manual migration of any open spec PRs and
unlabelled tickets.

## Performance budget
- **Per-ticket draft latency:** comparable to a single `babysit-with-review.sh` outer
  iteration (p50 ~2min, p95 ~10min) for the drafting pass, plus one or more spec review
  cycles (reviewer + implementer fix pass each) before the PR can leave draft.
- **Approval sweep latency:** dominated by `gh pr list --json comments` calls; expected
  sub-second per open PR.
- **Run of 20 tickets:** on the order of an hour, dominated by implementer inference
  time (no formal SLO — internal tool, see ASF-SYS-AUTONOMOUS-DEV SLOs section).

## Security model
- **AuthN / AuthZ:** Inherits `gh auth status`; Jira access via `JIRA_TOKEN` bearer
  token, read-only (search endpoint only).
- **Tenant isolation:** Single-user; PRs/issues created in the authenticated account's
  accessible repos.
- **PII handling:** Ticket titles/descriptions and code context only; no user data.
- **Approval spoofing:** resolved by `WORK_PREP_APPROVERS` (default: the authenticated
  `gh` user only), which restricts who can trigger a merge + sub-ticket. The residual
  risk is operator misconfiguration — setting `WORK_PREP_APPROVERS=*` on a repo with
  non-owner collaborators re-opens the gap.

## Telemetry contract
Events emitted to stdout (verbatim forms the script `echo`s):
- `[draft] ticket <id> (<source>) → draft PR #N opened (<spec-path>), entering spec review`
- `[draft] ticket <id> (<source>) → already has open/merged spec PR #N, skipped`
- `[approve] PR #N → approved by <login>, merged/reconciled, sub-ticket #K created`
- `[approve] PR #N → no authorized approval comment yet, skipped`

Source labelling is a **conditional action, not an emitted event**: after a
successful approval the sweep runs `gh issue edit --add-label status:ready-to-build`
only when the source is `github`, and it emits no dedicated success line for that
label (a failure to apply it is logged to stderr — see below).

Events emitted to stderr:
- `[draft] ticket <id>: implementer failed; any committed work remains on local branch <branch>`
- `[approve] PR #N: could not label source issue #M; will retry next run`
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
- **Approval regex false positive** (e.g., a comment whose first line reads "Approved
  in principle, still needs another pass" matches the line-start-anchored rule even
  though it isn't an unambiguous sign-off): spec merges prematurely. Blast: a spec that
  wasn't actually ready for build enters the sub-ticket queue; caught at PR-review time
  by the builder's own review cycle, but wastes a build cycle. Mitigated by tightening
  the regex or requiring an exact-phrase marker — open question, see assumptions above.
- **Duplicate sub-ticket creation** (idempotency check fails): builder queue gets two
  entries for the same spec. Blast: builder does duplicate work on two PRs; low, since
  the builder's own review cycle would still gate merge.
- **Worktree/implementer failure mid-draft:** ticket logged to stderr and skipped;
  picked up again next run since no PR was opened (no partial-PR state to clean up).

# Bounds

## Out of scope
- **Automated rejection handling:** no rejection-comment sentinel is implemented. A
  rejected spec PR requires a human edit, or a human must close the PR before a later
  work-prep run can draft the ticket again.
- **Non-GitHub, non-Jira ticket sources:** Linear, Shortcut, etc. are out of scope (see
  ASF-PROD-BABYSIT-WITH-REVIEW out-of-scope list).
- **Code changes:** this script only drafts spec documents; it never touches
  implementation code. `babysit-builder.sh` owns that step.
- **Adjudication/escalation mode:** the disagree-and-escalate protocol used by
  `babysit-with-review.sh`'s later cycles is deliberately not ported here — a recurring
  spec finding should become a flagged `[ASSUMPTION]`, not an argument with the reviewer.

## Assumptions-that-could-flip
- **GitHub-bridge-for-Jira assumption.** If flipped (builder should read Jira directly):
  `babysit-builder.sh`'s build-queue query would need its own Jira integration instead
  of a GitHub sub-ticket bridge.

## Composes with / replaces
- **Composes with:**
  - `babysit-builder.sh` (consumes `build-ready,sub-ticket` issues)
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
   **then** it is skipped in the drafting phase with a `already has open/merged spec PR`
   message and no duplicate PR is opened.
3. **Given** a converged (non-draft) spec PR for a GitHub-sourced ticket with a comment
   containing "Approved, let's build this" from an authorized approver, **when** the
   approval sweep runs, **then** the PR is merged, the source ticket is labelled
   `status:ready-to-build`, and a new sub-ticket issue labelled `sub-ticket` +
   `build-ready` is created.
4. **Given** the same scenario for a Jira-sourced ticket, **when** the approval sweep
   runs, **then** the PR is merged and the sub-ticket is created exactly as above, but
   the Jira source ticket is never labelled (`gh issue edit` cannot label a Jira issue).
5. **Given** an open spec PR with no approval comment, **when** the approval sweep
   runs, **then** the PR is left open and untouched.
6. **Given** `--source jira` and `JIRA_BASE_URL`/`JIRA_TOKEN` pointing at an
   unreachable host, **when** the script runs, **then** it logs the Jira failure to
   stderr and exits 0 having processed zero tickets (no GitHub fallback needed since
   source is Jira-only in this case).
7. **Given** `--source both` with one open GitHub issue and one open Jira issue,
   **when** the script runs, **then** both are drafted in the same invocation and each
   PR references its origin.
8. **Given** a source ticket whose sub-ticket already exists (an issue carrying the
   embedded `(source, ticket)` marker), **when** the approval sweep runs and finds a
   (still-present) approval comment on its now-merged PR, **then** no second sub-ticket
   is created.
9. **Given** `--max-tickets 1` and 3 undrafted tickets in the queue, **when** the script
   runs, **then** exactly 1 PR is opened and the other 2 remain queued for next run.
10. **Given** `--dry-run`, **when** the script runs, **then** it prints the tickets that
    would be drafted and the PRs that would be approval-swept, with no worktree, gh, or
    Jira write calls made.
11. **Given** a spec PR still marked draft (the spec review cycle has not yet converged
    to zero BLOCKING findings), **when** the approval sweep runs, **then** the PR is
    skipped regardless of any approval comment present.
12. **Given** a source ticket whose spec PR was merged and, on a prior run, was labelled
    `status:ready-to-build` but sub-ticket creation then failed (no issue carries the
    marker yet), **when** the approval sweep runs again, **then** it retries and creates
    exactly one sub-ticket — the earlier partial failure does not permanently suppress
    it.

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
