---
spec_type: feature
id: BZR-FEAT-ISSUE-WORKER
status: review
owners: [Chris Robertson]
depends_on: [BZR-SYS-BAZAAR, BZR-FEAT-REVIEW-LIB]
parent_l1: BZR-PROD-BAZAAR-BUILDER
parent_l2: BZR-SYS-BAZAAR
fit_check: passed
complexity:
  total: 3
  band: moderate
  drivers: [novelty, scope, external_integration]
  scored_on: 2026-09-19
---

# Frame

## TL;DR
Given one claimed issue, the issue worker verifies that the issue is actionable, asks the human when it is not, rewrites the body into the standard template, classifies it as bug or feature, drafts the specs it needs into a spec branch, runs the corpus-wide spec review cycle until 0 BLOCKING, and parks the issue in `bzr-spec-review` with a ready (non-draft) spec PR. It never approves anything and never marks a spec `ready`.

## Analog
Like a product analyst refining a ticket into a PRD and a task list, then handing it to the lead for sign-off.

## Reader & next action
Implementing agent: build the worker prompt set and its bash wrapper in `bazaar-issues.sh`. Chris Robertson: confirm the template.

## API surface fragment
*Proposed.*
```bash
# Invoked by the controller; not a user-facing command.
bazaar-worker-issue <issue>       # env from controller: BZR_REPO BZR_WORKTREE BZR_BRANCH BZR_LOG
                                  # branch: bzr/spec-<issue>   worktree: $BZR_HOME/<repo>/wt/spec-<issue>

# Sentinels (last line of the implementer transcript, bare):
NEEDS_INFO <n>                    # n questions posted; issue → bzr-needs-info
SPEC_PR <pr_number>               # spec PR open (draft); wrapper runs the spec review cycle
NOT_ACTIONABLE <reason>           # question, duplicate, no spec corpus, won't-fix candidate; issue → bzr-blocked + comment
STUCK <reason>                    # environmental; controller counts an attempt, claim label removed (issue is intake again)

# Agent comment marker (every comment the agent posts starts with this line):
<!-- bzr-issue-worker phase=verify|questions|spec|review ts=<iso8601> -->
```

## Consumer
[BZR-FEAT-CONTROLLER](L3-controller.md) (role issue). Output consumed by the controller's approval sweep and then by [BZR-FEAT-BUILD-WORKER](L3-build-worker.md).

# Substance

## What we know
- Owner decisions (2026-09-19): human approval is the only gate to ready (4); the agent may edit the issue body (5); bug vs feature is label-first, judgement fallback, and the plan ships a template (10); sub-issues are native and the issue loop may create them (7).
- Spec drafting and the adversarial spec review already exist in `babysit-work-prep.sh` v0.2.0: the drafting prompt, `run_spec_review_cycle` (line 1040), the review checklist (contradiction with existing specs, undeclared duplication, dangling references, schema violations, invented design decisions), and the convergence note that a recurring design-decision finding becomes an `[ASSUMPTION]`, not an argument (lines 973, 1007).
- `spec-guide.md` is the schema. Its standing rules apply: never infer a design decision into a spec; only the owner moves a spec to `ready`.
- Comment authorship carries no signal; the marker line is the only way to tell agent comments apart.

## What we assume
- [ASSUMPTION] Verification is a checklist the agent answers against the issue, its linked issues, and the code: problem statement present, desired outcome present, acceptance criteria present or derivable, scope bounded, no contradiction with the codebase or existing specs. Any "no" that the agent cannot resolve from the repo becomes a numbered question. Flips if: the owner wants the agent to resolve more by exploring (fewer bounces, more guesses) or less (more bounces).
- [ASSUMPTION] The body rewrite preserves the original text verbatim inside a `<details><summary>Original report</summary>` block below the templated sections. Flips if: the owner prefers the agent to comment the structured version instead of editing.
- [ASSUMPTION] Classification: `bug` label → L4 against the existing L3 that owns the behaviour (or a new L3 if none exists); `enhancement`/`feature` label → new or amended L3 plus one L4 per PR-sized unit; no label → agent decides and states why in the spec PR body. Flips if: the owner adds more labels (e.g. `chore`, `docs`) with their own mapping.
- [ASSUMPTION] Sub-issues are created by the worker at draft time, one per L4 when there are two or more, and reconciled on every spec revision (create missing, close dropped) so the human always sees the current breakdown on the parent issue (owner, 2026-09-19). Each carries the `<!-- bzr-sub-issue parent=<n> spec=<L4 ID> -->` marker and `Refs #<parent>`. Flips if: churn from reconciliation is annoying, in which case sub-issues are created only when the spec PR first reaches 0 BLOCKING.
- [ASSUMPTION] Specs go under the repo's existing `specs/` or first `*-specs/` directory (same discovery as `WORK_PREP_SPEC_DIR`). A repo with no such directory makes every issue `NOT_ACTIONABLE no spec corpus` (owner, 2026-09-19); bootstrapping a corpus is a human task. Flips if: the owner later wants a `--bootstrap-specs` mode.
- [ASSUMPTION] `MAX_SPEC_REVIEW_CYCLES` stays 4 and prescriptive mode starts at cycle 3, as in work-prep. Flips if: convergence data says otherwise.

## Contract

### Request shape
One issue number, already labelled `bzr-drafting` by the controller.

### Response shape
One sentinel; the issue in exactly one of `bzr-needs-info`, `bzr-spec-review`, `bzr-blocked`, or unlabelled (intake again); for `SPEC_PR`, an open non-draft PR on branch `bzr/spec-<issue>` whose body links the issue with `Refs #<issue>` (not `Closes`, the issue must stay open).

### Phases
1. **verify** — read issue, comments, linked issues, referenced files. Produce the checklist. If unresolved gaps: post one comment with numbered questions, `NEEDS_INFO`. On a re-entry after a bounce, read the human's replies first and do not repeat answered questions.
2. **normalise** — rewrite the body into the template (`ISSUE-TEMPLATE.md`), original preserved.
3. **classify** — bug vs feature per the mapping; record the decision and evidence in the spec PR body.
4. **draft** — in the worktree, write or amend specs per `spec-guide.md`; every unknown is `[ASSUMPTION]` with a flip clause or `[OPEN]` with owner; update `index.md` and append `log.md`. Commit, push, open draft PR. Then create or reconcile sub-issues from the L4 list (marker body, attached via the sub-issues API, listed in the PR body). `SPEC_PR`.
5. **review** (wrapper) — `run_review_cycle --mode spec` from the lib. At 0 BLOCKING: mark PR ready, comment on the issue with the PR link and the one-line summary of what will be built, write `SPEC_REVIEW <pr>` to `$BZR_SENTINEL` (the controller moves `bzr-drafting` → `bzr-spec-review`; see the controller L3's implementation notes, 2026-09-19). On cap or bail: `BLOCKED <reason>` with the reviewer summary posted on the PR.

### Invariants
1. The worker never writes `status: ready` and never merges.
2. No agent comment contains the word "approved" in any case.
3. Every agent comment begins with the marker line.
4. Questions are numbered and each names what decision it unblocks.
5. A re-entry never re-asks a question the human has answered.
6. The spec PR touches only files under the spec directory.
7. The issue leaves `bzr-drafting` on every exit path, including crash (the controller's dead-pid release covers crash).
8. Original issue text is never lost.
9. The set of open sub-issues carrying this parent's marker always equals the L4 set in the current spec PR head.

### Error model
- Cannot read issue (`gh` fails): `STUCK`, claim released.
- Issue is a sub-issue or closed: `NOT_ACTIONABLE`.
- Duplicate of an open issue (agent finds it): `NOT_ACTIONABLE duplicate of #N`; human decides.
- Spec review transport failure after the lib's retries: PR stays draft, `STUCK reviewer-unavailable`; the controller counts an attempt and the issue is intake again; re-entry resumes the existing branch and PR.
- Spec review cap hit: `bzr-blocked`, findings summarised on the PR.

### Idempotency
Re-entry with an existing `bzr/spec-<issue>` branch resumes: fetch, rebase on main, continue from the last completed phase (phase recorded in the PR body's marker block).

### Versioning policy
Prompts versioned with `bazaar-issues.sh`; a prompt change bumps the minor version.

## Performance budget
Verify + normalise + classify: 3-10 min Sonnet-class. Draft: 10-30 min. Review cycles: 1-7 min reviewer plus 5-15 min revision each, up to 4. Cost per issue: roughly $2-10 depending on cycles.

## Security model
Inherits `gh` auth. The worker can edit issue bodies and open PRs but cannot merge (no code path) and, with branch protection, cannot push to main.

## Telemetry contract
`[issue:<n>] phase=<p> …`, `sentinel=<word>`, `spec-review cycle=<k> blocking=<b>`. Sink: `$BZR_HOME/<repo>/logs/issue-<n>-<ts>.log`.

## Verifiers
- Tech lead: Chris Robertson
- QA: stubbed transcripts for each sentinel path (plan phase 3).

## Failure modes & blast radius
- **Agent answers its own question:** a guess becomes a spec. Blast: wrong build. Mitigation: review cycle's "invented decision" check; approval gate.
- **Body rewrite mangles the report:** original block preserved; blast is cosmetic.
- **Endless bounce loop:** human answers vaguely, agent asks again. Blast: stalled issue. Mitigation: after 2 bounces the worker labels `bzr-blocked` with "needs a synchronous conversation".
- **Spec PR opened against the wrong corpus directory:** review fails schema check; blast one issue.

# Bounds

## Out of scope
Approval, merging, any code change, Jira, multi-repo issues, bootstrapping a spec corpus, time limits.

## Assumptions-that-could-flip
- **Agent edits the body.** Flipping back to comment-only removes phase 2 and moves the template into a required issue form.

## Composes with / replaces
Composes with [BZR-FEAT-REVIEW-LIB](L3-review-lib.md) (`--mode spec`) and `spec-guide.md`. Replaces `babysit-work-prep.sh`'s draft-and-review path for repos managed by Bazaar.

# Signals

## Acceptance tests
1. **Given** an issue with only a title, **when** the worker runs, **then** it posts numbered questions, labels `bzr-needs-info`, and exits `NEEDS_INFO`.
2. **Given** that issue with human answers, **when** re-entered, **then** it does not repeat the questions, normalises the body, and proceeds.
3. **Given** a `bug`-labelled issue whose behaviour is owned by an existing L3, **when** it drafts, **then** the PR adds exactly one L4 with `parent_feature` set to that L3.
4. **Given** a feature issue needing three PR-sized units, **when** it drafts, **then** the PR contains one L3 and three L4s, `index.md`/`log.md` are updated, and three sub-issues with markers hang off the parent.
4b. **Given** a review cycle drops one L4, **when** the revision is pushed, **then** the matching sub-issue is closed with a comment and the other two remain.
5. **Given** the spec reviewer returns 2 BLOCKING then 0 after revision, **when** the cycle ends, **then** the PR is non-draft, the issue is `bzr-spec-review`, and the issue has a marker comment linking the PR.
6. **Given** the reviewer keeps a BLOCKING finding that is a design decision, **when** cycle 3 runs, **then** the revision converts it to `[ASSUMPTION]` and the finding clears.
7. **Given** an issue that duplicates an open issue, **when** verified, **then** `NOT_ACTIONABLE duplicate of #N` and `bzr-blocked`.
8. **Given** any agent comment, **when** grepped case-insensitively for `approved`, **then** no match.
9. **Given** a body rewrite, **when** the issue is read back, **then** the original text is present verbatim in the details block.
10. **Given** a crash mid-draft, **when** the worker re-enters after the dead-pid release, **then** it resumes on the existing branch without a second PR.
11. **Given** a repo with no `specs/` or `*-specs/` directory, **when** any issue is verified, **then** `NOT_ACTIONABLE no spec corpus` and `bzr-blocked`.

## Telemetry events tied to L1 KPIs
`NEEDS_INFO` count per issue → bounce indicator; `spec-review cycle` count → convergence indicator.

## AEAB cases
N/A. A future eval would replay stored issues and score question quality and classification accuracy.

## Kill criteria
Median spec review cycles above 3 for 30 days; two or more bounces on more than half of issues.
