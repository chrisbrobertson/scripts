# scripts

Personal helper scripts for working with Claude Code and the home-lab fleet: the
autonomous loop family (`babysit-work-prep.sh` → `babysit-builder.sh` →
`babysit-with-review.sh`), `gh` CLI wrappers (`prs`, `issues`, `specs`), and one-off
empirical tests (`test-*`). No formal test suite, no build step, no CI.

## Conventions

- **Tracking.** Most files are intentionally untracked. Commit when something
  stabilises.
- **Helpers are repo-agnostic.** `prs`, `issues`, and `specs` wrap `gh` and
  operate on whichever repo the caller is in. Don't add cwd-specific assumptions
  to them.
- **New scripts** need a shebang and the executable bit (`chmod +x`).
- **Specs follow `spec-guide.md`.** That file is the schema for every
  `<project>-specs/` corpus here — read it before drafting or editing a spec, and
  follow its frontmatter, section layout, and ID scheme. Two standing rules from it:
  never infer a design decision into a spec (surface it and get an explicit answer),
  and only the owner moves a spec to `status: ready`. When a spec and the shipped
  code disagree, that's a lint finding to raise — not licence to edit the code to
  match the spec.
- **Tests are exploratory.** Document outcomes in commit messages or in specs
  under `~/repos/home-lab-monitor/specs/`; don't add them as assertions here.

## Files

| File | Purpose |
| --- | --- |
| `new-fleet.sh` | Provision a staff-team fleet (staff-swe/sre/pm) for a service; see `docs/STAFF-FLEET.md` |
| `docs/STAFF-FLEET.md` | **Operator guide for the staff-fleet system**: quick start, architecture, tuning, troubleshooting. Read this before running `new-fleet.sh` or operating a fleet. |
| `claude-code-proxy.py` | Orphaned. OpenAI-compatible HTTP proxy that used to bridge Hermes to `claude -p`; `new-fleet.sh` dropped it for Hermes's native `openai-codex` provider in 84364ea (2026-05-11) — no longer wired to anything. |
| `install-poolside-s21-mac.sh` | One-shot installer/validator for running Poolside Laguna S 2.1 locally on a 128 GB Apple Silicon Mac (unrelated to the home-lab fleet — self-contained, no remote hosts). Installs Ollama, the model, Poolside Agent CLI, uv, LiteLLM, Claude Code, and Codex CLI as needed; runs Ollama/LiteLLM as per-user launchd services; creates `pool-poolside`/`claude-poolside`/`codex-poolside` wrapper commands; runs a protocol + end-to-end test suite. `--repoint-opus`/`--repoint-codex`/`--repoint-all` persistently reroute Claude Code's Opus tier or the Codex CLI to the local model; `--restore-harnesses` reverts. Requires `--accept-poolside-eula` (the Poolside installer is interactive otherwise). |
| `babysit-with-review.sh` | Autonomous implementation loop with independently selectable Claude/Codex implementer and reviewer harnesses, stop-file lock, and convergent PR-review cycle; see `--help` for role-specific model/effort switches. Pass `--repo-base PATH` (or `REPO_BASE` env var) if helper scripts live outside `~/repos/scripts` — auto-detects `~/repos` then `~/repo`. Versioned via semver (`--version`); current: 1.5.0. See **Locking & scheduled runs** below. |
| `babysit-work-prep.sh` | Ticket-to-spec intake loop. Drafts one TIF spec per GitHub/Jira ticket in an isolated worktree and opens a marked **draft** PR, then drives it through an adversarial spec review cycle (contradiction with existing specs, undeclared duplication, dangling references, schema violations, invented design decisions) — the PR only leaves draft at 0 BLOCKING, and the approval sweep refuses to act on a draft. Each review cycle's prompt also carries a `lint-spec-citations` run scoped to the spec under review, as a deterministic pre-check for the file:line citation sub-case of "dangling references" (`citation_check_block()`; the reviewer still has to judge whether an in-range citation describes the right thing). Then merges approved spec PRs and creates idempotent `sub-ticket` + `build-ready` sub-tickets for `babysit-builder.sh` to pick up (the *source* ticket gets `status:ready-to-build`, meaning "spec approved, sub-ticket exists"). Approval defaults to the authenticated GitHub user; see `--help` for source, model, dry-run, and approver settings. Versioned via semver (`--version`); current: 0.3.0. |
| `babysit-builder.sh` | Spec-to-PR build loop. Pulls any GitHub/Jira ticket labelled `build-ready`, implements its referenced spec in a per-ticket worktree, then runs the same convergent review cycle as `babysit-with-review.sh` — but **never merges**: it halts with the PR labelled for a human. Specs with gaps are kicked back (`SPEC_GAP` → `build-needs-clarification`) rather than built as-is. Own `build-*` label namespace and own stop file, so it runs concurrently with the other two loops. `resume_stalled_prs()` sweeps all three resumable quarantine labels (`build-mcp-outage`, `build-codex-outdated`, `build-codex-no-credits`) before the queue is read, mirroring the outer-loop fix in `babysit-with-review.sh` (#104) — the older `resume_outage_prs()` only covered `build-mcp-outage`, so a `build-codex-outdated`/`build-codex-no-credits` PR was never resumed and its ticket could be rebuilt into a duplicate PR. See `babysit-specs/L3-builder.md` and `--help`. Current: 0.2.1. |
| `babysit-codex-compat-fix-plan.md` | Historical design-plan record for the Codex version/model compatibility fix (`compat_re` telltale, `review-codex-outdated` label, pre-flight probe, fail-closed `fail_review_cycle`). Marked **implemented** in its own status banner; superseded by the shipped code and `babysit-specs/L3-mcp-resilience.md` / `L3-review-cycle.md` / `L3-retrospective-review.md`. Not a live TODO. |
| `babysit-scheduling-plan.md` | Historical design-plan record for babysit lock recovery + scheduled runs (stale-vs-live lock detection, `BABYSIT_NONINTERACTIVE`, `MAX_CONCURRENT_BABYSITS`, the `launchd/` template + install helper). Marked **implemented** in its own status banner; superseded by `babysit-with-review.sh` 1.5.0 and this file's own **Locking & scheduled runs** section below. Not a live TODO. |
| `setup-branch-protection.sh` | Enable the `codex-review` required status check on a repo's default branch; run once per repo after deploying the updated wrapper |
| `test-setup-branch-protection.sh` | Recording-stub coverage for `setup-branch-protection.sh`: repo/branch auto-detection vs explicit `--repo`/`--branch`, the `--check` override, the branch-protection payload shape via `--dry-run` (required context, `enforce_admins`, `required_approving_review_count`, `restrictions: null`), the real `gh api PUT` apply path (success and failure), and `--help`/unknown-argument handling. `gh` stubbed on PATH, no network. |
| `backfill-codex-reviews.py` | Post historical Codex reviews to closed PRs |
| `run-retrospective-review.sh` | One-shot Codex review for PRs that merged without automated review; posts findings as PR comments and opens issues for each BLOCKING finding |
| `test-run-retrospective-review.sh` | Recording-stub coverage for `run-retrospective-review.sh` (shipped with no test of its own, unlike its `find-bailed-merged-prs.sh` companion): all 10 of `L3-retrospective-review.md`'s acceptance tests — clean/blocking review outcomes, idempotency-marker re-run skip, non-merged-PR skip, compat-telltale skip, `--dry-run` (no codex/worktree/comment/issue), `--no-issues`, worktree EXIT cleanup leaving no orphaned entries, and issue dedup by title prefix independent of which PR filed it — plus the stdin TSV pipeline mode, a `gh pr view` failure, `--help`, and unknown-argument handling. `gh`/`codex` stubbed on PATH against a throwaway local git repo (real `git worktree`), no network. |
| `find-bailed-merged-prs.sh` | Scan babysit logs for review-cycle bails, then query GitHub to find which bailed PRs were subsequently merged (unreviewed code audit). `BAILED_PHRASES` mirrors all three of `codex_review_with_retry()`'s telltales (compat, credits, MCP) — the credits (`Your workspace is out of credits`) and MCP (`Transport send error:` / `` tool call failed for `codex_apps/ `` / `error sending request for url (https://chatgpt.com/`) phrases were added after only the compat phrase was present, the same parity gap just fixed in `run-retrospective-review.sh` (see its own CREDITS_RE fix) — without them, a credits- or MCP-outage bail fell through to the vaguer `UNKNOWN` classification instead of being labelled `BAILED` with a clear reason. |
| `test-find-bailed-merged-prs.sh` | Fixture-log coverage for `find-bailed-merged-prs.sh` (shipped with no test of its own): all three BAILED_PHRASES telltale families (compat/credits/MCP) are detected, the `gh pr checkout` phrase only counts as a bail when `failed` is on the same line, worst-outcome-wins ranking (BAILED > UNKNOWN > CLEARED) holds in both directions, a log missing the `=== babysit-with-review.sh @` header is skipped entirely, MERGED rows sort ahead of non-merged rows, and the repo-map/`--repo` override/no-mapping paths each resolve correctly. `gh` stubbed on PATH, no network. |
| `find-bailed-merged-prs.md` | Agent-instructions companion to `find-bailed-merged-prs.sh` for the same audit, run by an LLM agent instead of the script: use it when logs live on a remote host (SSH first, then grep), when the bail needs LLM-assisted triage of whether the merged diff actually addressed the unmet findings, when no `repo-map.tsv` exists yet and repos must be inferred from `~/repos/<project>`, or when the output needs narrative report context — prefer the script itself for a batch/deterministic run. Its `BAILED` match-phrase list is kept in sync with the script's `BAILED_PHRASES` (both carry the same 13 phrases as of #136). |
| `test-babysit-with-review-cli.sh` | Deterministic CLI regression harness for babysit-with-review.sh using recording stubs (`BABYSIT_TEST_MODE`) |
| `test-babysit-review-feedback.sh` | Recording-stub coverage for `collect_pr_feedback()`'s CodeRabbit-inclusion / self-posted-exclusion filter (QA-TEST-PLAN.md TC-2.10/TC-2.11); `gh` stub on PATH forwards the script's real `--json`/`-q`/`--jq` args to the real `jq` binary against canned fixtures, so the actual embedded filters run |
| `test-babysit-review-merge-draft.sh` | Recording-stub coverage for `merge_reviewed_pr()` — the zero-blocking-findings merge path always calls `gh pr ready` (best-effort) before `gh pr merge`, since a PR can reach that path still marked draft (see #82/#60); also covers the merge-failure split: a non-conflict failure gets `flag_review_cycle_merge_failed` (`review-merge-failed`), while a `gh pr view --json mergeable=CONFLICTING` failure gets `flag_review_cycle_merge_conflict` (`review-merge-conflict`) instead — neither re-drafts the PR |
| `test-babysit-review-false-positive.sh` | Recording-stub coverage for QA-TEST-PLAN.md TC-3.15 against `babysit-with-review.sh`'s own `codex_review_with_retry()` copy, via `BABYSIT_TEST_MODE=reviewer`: a clean, structurally valid review must win over an incidental `compat_re`/`credits_re` match elsewhere in the Codex transcript (the 2026-09-27 false-positive regression). `test-bazaar-review-lib.sh` already covers this regression for the extracted `lib/bazaar-review.sh` copy, and open PR #45 covers TC-3.1-3.6/3.9-3.14 for this script's own copy but explicitly excludes TC-3.15 — this file closes that remaining half standalone so it doesn't collide with #45's draft branch |
| `test-babysit-review-retry-log-format.sh` | Recording-stub coverage for QA-TEST-PLAN.md TC-3.7/TC-3.8 (the retry and MCP-failure log-message-format checks) against `babysit-with-review.sh`'s own `codex_review_with_retry()` copy, via `BABYSIT_TEST_MODE=reviewer` with `codex`/`sleep` stubbed on PATH. Open PR #45 covers TC-3.1-3.6/3.9-3.14 but not TC-3.7/3.8 by its own commit text — this file closes that remaining gap standalone, independently of #45 |
| `test-babysit-review-stalled-retry.sh` | Recording-stub coverage for the outer loop's stalled-PR retry sweep (all five resumable labels, see #82/#104/#111): sweep removes the label itself only once the reviewer CLI is confirmed available, never un-drafts before the re-review completes, defers (leaving the label in place) rather than starting new implementer work when the reviewer is still unavailable, skips the review cycle if the label-removal `gh pr edit` call itself fails, picks up `review-merge-failed` (the #60 orphan class) exactly like the other three, and for `review-merge-conflict` scans every labelled PR (not just the first) so a resolved PR behind a still-conflicting older one is found (#111 review cycle 3) |
| `test-babysit-builder-stalled-retry.sh` | Recording-stub coverage for `babysit-builder.sh`'s `resume_stalled_prs()` (the build-loop counterpart of the fix above): all three resumable labels — `build-mcp-outage`, `build-codex-outdated`, `build-codex-no-credits` — get swept and resumed, not just `build-mcp-outage` as the pre-fix `resume_outage_prs()` did |
| `test-llm-routing.py` | Empirical test: model-alias forwarding + OAuth rejection by Anthropic |
| `test-codex-review.sh` | Codex review helper |
| `prs` | `gh pr list` with CI rollup and review state |
| `issues` | `gh issue list` sorted by priority labels |
| `specs` | List spec files with frontmatter status and components; searches any `specs/` or `*-specs/` directory |
| `lint-spec-citations` | Scans every `*.md` file in the repo for `<file>.sh:<line>` / `<file>.py:<line>-<line>` citations (the comma/dash-range forms this corpus uses, e.g. `new-fleet.sh:836,923`) and flags any that cite a file that no longer exists or a line past the file's current end — the mechanical subset of the stale-line-ref drift that has driven dozens of `docs: fix stale line ref` PRs in this repo's history. Does not and cannot verify that a still-in-range citation still describes what the prose claims; that's still a human/LLM read of the diff. Also invoked by `babysit-work-prep.sh`'s spec review cycle, scoped to one spec file at a time (`citation_check_block()`), and by `lib/bazaar-review.sh`'s `--mode spec` review cycle, scoped to the union of every spec path drafted for the issue (its own `citation_check_block()`, since a Bazaar issue can draft several specs — e.g. L1+L2+L3 — reviewed together in one cycle). |
| `test-lint-spec-citations.sh` | End-to-end coverage for `lint-spec-citations` against fixture trees built fresh per case under a tmpdir (no stubs needed — the script is pure, dependency-free Python): missing-file and line-out-of-range findings, a backwards range (`end < start`) as malformed-citation, a comma-separated citation with one valid and one bad segment, findings across nested directories with the right counts, `.git`/`node_modules` exclusion, `--json` shape, `--help`, and the unknown-argument exit code. |
| `test-work-prep-citation-check.sh` | Recording-stub coverage for `babysit-work-prep.sh`'s `citation_check_block()` via its `WORK_PREP_TEST_MODE=citation-check` hook: a clean in-range citation, a line-out-of-range citation, a missing-file citation, and that findings are scoped to the spec file under review (a stale citation in a sibling doc does not leak into another spec's check). `gh` stubbed on PATH, `--dry-run` plus `HOME` redirected to a tmpdir so the real lock file and `sisyphus-logs` are untouched. |
| `spec-guide.md` | **Schema document for spec-driven work in this repo — read it before creating or editing any spec.** Defines the TIF L1–L4 format (frontmatter, section layout by layer, ID scheme), the raw-sources/wiki/schema architecture, and the ingest/query/lint workflows. |
| `babysit-specs/` | TIF specs for the babysit script family (L1–L4 + QA + security plans); see `babysit-specs/README.md` |
| `bazaar-builder-specs/` | TIF specs + implementation plan for **Bazaar Builder**, the two-controller successor to work-prep/builder (prefix `BZR`); read `index.md` first |
| `docs/BAZAAR-BUILDER.md` | **Operator guide for Bazaar Builder**: quickstart, prerequisites, label state machine, debugging, recovery recipes, config reference. Read this before running the controllers. |
| `lib/bazaar-review.sh` | Sourced library: convergent implementer/reviewer cycle (`run_review_cycle --mode code\|spec`), extracted from the builder and work-prep for Bazaar. Never labels, toggles draft, posts status, or merges. `babysit-with-review.sh` keeps its own copy. |
| `test-bazaar-review-lib.sh` | Recording-stub harness for `lib/bazaar-review.sh` (claude/codex/gh/sleep stubs on PATH, throwaway git origin); run before touching the lib |
| `lib/bazaar-common.sh` | Shared controller loop for the two Bazaar controllers: label queue, pid-held claims (no time lease), three-attempt escalation, comment guard, role hooks. bash 3.2 + python3, no jq. |
| `bazaar-issues.sh` | Bazaar issue controller: intake (open issue with no `bzr-*` label) → `bazaar-issue-worker.sh`; sweeps for human replies, spec-PR approval (status flip, `codex-review` status, merge, sub-issue reconcile), and rejected spec PRs. `--help`. |
| `bazaar-build.sh` | Bazaar build controller: `bzr-ready` → `bazaar-build-worker.sh`; merged-PR sweep closes the parent or queues the next round. `--issue N [--force]`. Never merges. |
| `bazaar-issue-worker.sh` | Bazaar issue worker (spawned by `bazaar-issues.sh`): verify → questions or normalise → draft specs on `bzr/spec-N` → draft-time sub-issues → spec review cycle → sentinel |
| `bazaar-build-worker.sh` | Bazaar build worker (spawned by `bazaar-build.sh`): precheck → plan → implement each sub-issue on one branch with a review cycle per unit, skip-and-revert on non-convergence → PR ready. Never merges. |
| `test-bazaar-*.sh` | Harnesses for the Bazaar libs, controllers, and workers plus `test-bazaar-e2e.sh` (both controllers driving the real workers end to end); seven scripts, all offline: fake gh + throwaway git origin + scripted claude/codex stubs. Run them all before committing Bazaar changes |
| `test-support/fake-gh.py` | Stateful `gh` stand-in over a JSON file; symlinked onto `PATH` as `gh` by every `test-bazaar-*.sh` harness except `test-bazaar-review-lib.sh` (which stubs `gh` directly) — `test-bazaar-common.sh`, `test-bazaar-build.sh`, `test-bazaar-issues.sh`, `test-bazaar-build-worker.sh`, `test-bazaar-issue-worker.sh`, `test-bazaar-e2e.sh` |
| `skills/test-coverage-validation/` | Claude Skill package (`SKILL.md` + `references/`): assesses whether a project has sufficient test coverage across unit, integration, contract, E2E, UX, performance, security, and accessibility levels, then prioritizes and optionally remediates gaps. Unrelated to the babysit/Bazaar loop family — a standalone skill versioned in this repo. |
| `launchd/com.chrisrobertson.babysit.PROJECT.plist.template` | launchd LaunchAgent template for scheduling `babysit-with-review.sh`; `__PROJECT__`/`__PROJECT_PATH__` placeholders. See **Locking & scheduled runs** below. |
| `launchd/install-babysit-agent.sh` | Fills the plist template for `<project_basename> <project_absolute_path>`, writes it to `~/Library/LaunchAgents/`, and bootstraps it via `launchctl` |
| `deprecated/babysit.sh` | Deprecated 2026-04-30, superseded by `babysit-with-review.sh` (commit `f7b5cab`); kept only for git history, not run or tested |

## babysit-with-review.sh — locking & scheduled runs

`babysit-with-review.sh` claims a per-project lock at `~/sisyphus-logs/<project>.stop`
containing its own PID. The whole stale-check-and-claim runs as one transaction
serialized by a persistent `fcntl.flock(LOCK_EX)` on a sibling `<project>.stop.guard`
file, so the stale-read / claim-write TOCTOU window is closed by the kernel: exactly
one holder is granted the guard at a time, and the lock releases itself the instant
the holder's fd closes — including on `kill -9` — with nothing left behind to
misinterpret as abandoned (the guard file itself is never removed, only the lock on
it is held for the duration of the claim). Within that guarded transaction the
script detects a stale (orphaned) lock — a PID that `os.kill(pid, 0)` reports as
no-longer-running, or an empty pre-upgrade `touch`-only file — and clears it
automatically; a lock whose PID is still alive is a real collision.

Set `BABYSIT_NONINTERACTIVE=1` to make both the live-lock collision and the
concurrency-cap paths below exit 0 ("[skip] ...") instead of erroring — used by
launchd/cron jobs so a busy project doesn't get marked as a failed run.

Set `MAX_CONCURRENT_BABYSITS` (default 1) to cap the total number of simultaneous
`babysit-with-review.sh` processes across all projects, counted via `pgrep`. Reaching
the cap always exits 0 ("skipping") — intentional back-pressure, not a failure —
regardless of `BABYSIT_NONINTERACTIVE`.

See `launchd/com.chrisrobertson.babysit.PROJECT.plist.template` for a LaunchAgent
example (`StartCalendarInterval`, no `KeepAlive`) and
`launchd/install-babysit-agent.sh` to materialise and bootstrap it for a given
project.

## Staff-fleet agents

`new-fleet.sh` scaffolds three always-on AI agents (staff-swe, staff-sre, staff-pm) for a
service, running on Hermes Agent's native `openai-codex` provider (ChatGPT OAuth, model
`gpt-5.5`) — no proxy in front of it. One fleet per service, each fully isolated.

Full operator guide: **`docs/STAFF-FLEET.md`** — quick start, architecture, tuning, troubleshooting.

## Testing

**Local-first.** Most scripts run directly on your machine without any fleet
dependency.

**Fleet-based tests** (those that need Ollama, LiteLLM, GPU, a specific OS, or
`claude` CLI on a remote host): use the home-lab dev fleet. See
`~/repos/home-lab-monitor/HOMELAB_DEV_USAGE.md` for the slot-reservation
workflow, host inventory, and SSH prerequisites.

**SSH-stdin pattern** — the established convention for running a test script
non-interactively on a remote dev host without Docker:

```
ssh chrisrobertson@mbp16.local 'python3 -' < test-llm-routing.py
```

Exemplar: `test-llm-routing.py:18-25`. Notes:
- Works on `dev-laptop` role hosts (`mbp16.local`, `mbp15-1.local`,
  `CRs-MacBook-Pro-2.local` — confirmed reachable: `mbp16.local`/`mbp15-1.local`
  directly, `CRs-MacBook-Pro-2.local` via `config.yml`). `config.yml`'s
  2026-09-12 host consolidation replaced this fleet's literal `192.168.1.x`
  addresses with mDNS names after a subnet move; this doc previously still
  listed the old IPs (`.81`/`.85`/`.84`/`.229`) and was out of sync.
- **Mac Mini (`mac-mini.local`) does NOT work** — reconfirmed 2026-11-11:
  both plain and `-tt` (forced-PTY) non-interactive SSH are closed
  immediately. The original explanation lived as an inline comment on
  `config.yml`'s Mac Mini host entry ("SSH requires interactive PTY"); that
  comment was dropped, without explanation, in that repo's 2026-09-12 host
  consolidation (`2994b09`) and nothing has replaced it — the behavior still
  holds, but take "requires a PTY" as the last recorded explanation rather
  than a confirmed one.
- **Spark DGX (`spark-86fd.local`) is the GPU host** — prefer it when the
  test needs CUDA/Ollama inference; treat it as shared.

## babysit-with-review.sh — review gate and self-merge prevention

**Review gate.** The wrapper is the only path that may merge a PR. The implementation Claude prompt forbids `gh pr merge` directly and requires ending each iteration with `HANDOFF_REVIEW <PR>` to hand off to the Codex review cycle. Before merging a PR that passed Codex review, the wrapper POSTs a `codex-review=success` commit status via `gh api`. This is the only code path that sets this status.

**Branch protection (operator step, per repo).** Run `setup-branch-protection.sh --repo OWNER/REPO` once per managed repo after deploying the wrapper. This requires the `codex-review` status check and blocks direct `git push origin main` — so even if implementation Claude attempts a direct push or `gh pr merge`, GitHub rejects it. Deploy order: ship the wrapper first (so it can set the status), then enable protection.

**Per-iteration worktree.** Each outer-loop iteration creates a `git worktree` on a placeholder branch (`wip/<project>/iter-N`) and runs Claude inside it via `(cd "$wt_dir" && claude -p ...)`. Claude's first instruction is to rename the branch to reflect the work item (e.g. `feat/close-goals-124`), making the worktree branch the PR branch. The worktree is removed **before** `run_review_cycle` runs — `gh pr checkout` would error if the same branch were still checked out in the worktree. If Claude committed but didn't open a PR (no `HANDOFF_REVIEW`), any unpushed commits are pushed to origin as a safety net before the worktree is discarded.

## babysit-with-review.sh — MCP resilience and pre-flight

**PR labels.** The review cycle uses six distinct labels:

- `review-incomplete` — a bail for a human-action reason (STUCK, no progress, max cycles exhausted). The wrapper will NOT retry; manual operator review is required before the PR can merge.
- `review-mcp-outage` — the codex MCP backend was unreachable. No code-quality review took place. The wrapper retries automatically at the top of each outer iteration. Remove the label manually only if you merge the PR without waiting — do not remove it as a "recovery" step, since removing it prematurely is what disables the retry (see below).
- `review-codex-outdated` — Codex CLI is too old for the configured model. The wrapper halts (exits) when this happens, so there's no running process left to "wait" on: run `codex update`, then restart the babysitter — the retry sweep finds the labelled PR at the top of the first outer iteration and resumes it automatically. Do NOT remove this label yourself.
- `review-codex-no-credits` — Codex workspace has no credits. Same as `review-codex-outdated`: the wrapper has already halted, so add credits then restart the babysitter. Do NOT remove this label yourself.
- `review-merge-failed` — the review already passed (zero BLOCKING findings, `codex-review=success` already set) but `gh pr merge` itself failed, typically a transient CI or branch-protection race. Unlike the three labels above, this does **not** halt the wrapper and does **not** re-draft the PR — the reviewer backend is fine and the review result is still valid, so the pre-iteration sweep retries it on the very next outer iteration of the same run, no restart needed. Do NOT remove this label yourself; regression coverage for a real orphaned PR in this repo's backlog (#60) that predates this label — see below.
- `review-merge-conflict` (wrapper ≥1.4.0) — same starting point as `review-merge-failed` (review already passed, `codex-review=success` already set), but `gh pr merge` failed because `gh pr view --json mergeable` reports the PR `CONFLICTING` against the base branch — a permanent condition, not a transient race. Retrying the identical merge can never succeed, so this label is gated rather than blindly retried like the other four: it IS part of the stalled-PR retry sweep's resumable set, but the sweep checks `gh pr view --json mergeable` first and only acts once that reports the conflict is actually gone. Does not halt the wrapper or re-draft the PR. Resolve by rebasing the branch onto the base branch and pushing (the sweep detects the conflict is gone and runs a fresh review cycle against the merged-up diff on a later iteration, no restart needed) or by closing the PR. Regression for the #82 backlog: #83/#91/#9 sat in the `review-merge-failed` retry loop for a full day behind branches that had drifted into real conflicts, since nothing distinguished a permanent conflict from a transient failure. A second regression (#111 review cycle 2): while unresolved, the gated check must defer without re-`continue`ing the outer loop back onto the same PR — otherwise an unresolved conflict burns the entire `MAX_ITER` budget re-selecting itself, starving both new work and any other stalled PR, exactly as if the label weren't resumable at all.

**Retry policy.** When a codex transport failure is detected (telltales: `Transport send error:`, `tool call failed for \`codex_apps/`, or `error sending request for url (https://chatgpt.com/`), the wrapper retries codex up to 3 times with 0 / 60s / 300s delays. If all retries fail, it labels the PR `review-mcp-outage`, marks it draft, and halts the babysitter.

**Stalled-PR retry sweep (all five resumable labels, wrapper ≥1.4.0; four as of 1.3.0, three as of 1.2.0).** At the top of every outer-loop iteration, the wrapper checks for an open PR labelled `review-mcp-outage`, `review-codex-outdated`, `review-codex-no-credits`, `review-merge-failed`, or `review-merge-conflict`, in that priority order. For the first three, it removes the label and re-runs the review cycle immediately (PR stays in draft throughout — only a clean review un-drafts it). `review-merge-failed` is different: the sweep compares the head SHA recorded when the merge failed against the PR's current head, and only when they still match does it take a merge-only retry shortcut (no reviewer CLI invoked, PR stays ready/un-drafted); on any mismatch it falls back to a full review cycle instead of reusing a stale `codex-review=success` status against a since-changed head — and if `gh pr view --json mergeable` shows the PR is actually `CONFLICTING` (a stale label left over from a prior failed removal — see below), it re-routes to `review-merge-conflict` instead of wasting a merge attempt (#111 review cycle 2). `review-merge-conflict` is gated rather than acted on unconditionally: the sweep checks `gh pr view --json mergeable` and only removes the label and runs a fresh review cycle once the conflict is actually gone; while unresolved, it leaves the label in place **and falls through to new work in the same iteration** rather than looping back onto the same PR (#111 review cycle 2 — the earlier `continue`-based version of this defer burned the entire `MAX_ITER` budget re-selecting an unresolved conflict, starving new work and any other stalled PR). The label must still be on the PR for this sweep to find it — **the operator must never remove it by hand**; before 1.2.0, only `review-mcp-outage` had this sweep, so removing a `review-codex-outdated`/`review-codex-no-credits` label (even after fixing the underlying cause and restarting the babysitter) left the PR sitting in draft forever — skipped by the priority-order rules — while the loop started new work each restart instead. That gap is what produced a growing backlog of draft PRs stuck behind an outdated Codex CLI; see issue #82. Manually removing the label reproduces the exact same symptom on any wrapper version, since the sweep has nothing left to find — see issue #104. `review-merge-failed` (added in 1.3.0) closes a related but distinct gap: a PR that passed review cleanly but whose `gh pr merge` call itself failed had *no label at all* before this fix (see PR #60 in this repo's own backlog), so it was invisible to every version of this sweep, label-priority order notwithstanding.

**Known false-positive class on `review-codex-outdated` / `review-codex-no-credits` (see #82, fixed by #83).** In wrapper versions before this fix, `codex_review_with_retry()` scanned the *entire* raw Codex transcript for the compat/credits telltale regexes before checking whether the review itself had actually succeeded. Codex reviews agentically with full repo read access, so it can surface those literal regex strings as incidental exploration noise — they live permanently in `codex_review_with_retry()`'s own source and in `L3-mcp-resilience.md` — and get flagged even when the real review came back structurally valid with zero BLOCKING findings. If you see either label on a PR whose diff has no plausible connection to a real Codex CLI-version or credits problem, pull the actual review transcript and check for a clean, structurally valid verdict before trusting the label; a wrapper with the fix applied checks review success first and can't produce this false positive. Full incident trace and per-PR verification: issue #82; the fix itself: PR #83.

**Pre-flight.** Before the outer loop starts, the wrapper ensures the working tree is clean and on the default branch. It auto-switches to the default branch and fast-forwards if the branch is behind origin (both are safe when the tree is otherwise clean). It refuses to start — with corrective instructions — if there are uncommitted modifications, untracked non-ignored files, or a diverged/ahead-of-origin default branch. Seeing `[preflight] switching from 'fix/...' to 'main'` is **normal** after every review cycle: `run_review_cycle` calls `gh pr checkout` and doesn't switch back, so the auto-switch is the expected recovery path on re-run.

## babysit-with-review.sh — convergence-aware review flow

**Scope discipline.** The Claude review prompt tells Claude to make minimal targeted changes, commit each finding separately, run tests after every fix, and avoid touching code Codex did not flag. This reduces the "shifting goalposts" failure mode where a fix introduces new surface for Codex to flag.

**Cycle history (cycle 2+).** Each Codex pass from cycle 2 onward receives the full text of all prior reviews plus a `git log` of commits Claude made since the review cycle started. Codex tags each finding `[NEW]` or `[RECURRENCE]` so Claude can see whether it is converging or spinning.

**Prescriptive mode (cycle 3+).** From cycle 3 onward the wrapper switches to a stricter Codex prompt that requires a concrete `Suggested fix:` line under every BLOCKING bullet. If Codex cannot propose a concrete fix it must downgrade the finding to RECOMMENDED.

**Default `MAX_REVIEW_CYCLES` is 6** (was 3). Prescriptive mode kicks in at cycle 3, so the cap needs room for it to help.

## Related repos

- `~/repos/home-lab-monitor/` — separate project. Hosts the fleet monitoring
  server, agent, specs, and the slot-reservation system used by fleet-based
  tests.
