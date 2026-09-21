# Bazaar Builder — operator guide

Bazaar Builder turns GitHub issues into reviewed pull requests with two small controllers
and two worker agents. You answer questions, approve specs, and merge PRs. Everything else
is automated.

```
  issue opened ──► bazaar-issues.sh ──► spec PR ──► YOU approve ──► bazaar-build.sh ──► build PR ──► YOU merge
                   (issue worker)                                   (build worker)
```

Specs and design history live in [`../bazaar-builder-specs/`](../bazaar-builder-specs/index.md).
This page is the how-to.

---

## 1. Quickstart

```bash
# 0. one-time: make sure the prerequisites in section 2 hold for the target repo
cd ~/repos/<your-repo>          # always run from inside the clone

# 1. take ONE issue through to a spec PR
~/repos/scripts/bazaar-issues.sh --issue 123 --once --reviewer claude

# 2. read the spec PR it opened (linked in a comment on #123). To accept it:
#    comment on the PR with a line containing the word "approved", or approve it as a GitHub review.

# 3. let the controller merge the spec, mark it ready, and queue the issue
~/repos/scripts/bazaar-issues.sh --once --reviewer claude

# 4. build it
~/repos/scripts/bazaar-build.sh --issue 123 --once --reviewer claude

# 5. review and merge the build PR yourself. The pipeline never merges code.
```

Drop `--reviewer claude` once the Codex workspace has credits; Codex is the default reviewer.

**Continuous mode** (the intended steady state):

```bash
~/repos/scripts/bazaar-issues.sh --workers 2 --reviewer claude   # ticks every 60s
~/repos/scripts/bazaar-build.sh  --workers 1 --reviewer claude   # second terminal or host
# stop gracefully (running workers finish, nothing new starts):
~/repos/scripts/bazaar-issues.sh --stop
~/repos/scripts/bazaar-build.sh --stop
```

Read section 4 before turning continuous mode on: intake is *every* open issue with no
`bzr-*` label.

---

## 2. What must be true outside the scripts

### On the machine that runs the controllers

| Requirement | Why | Check |
|---|---|---|
| `gh` authenticated as a user who can push branches, open PRs, edit issues, and merge spec PRs | every GitHub write goes through `gh` | `gh auth status` |
| `claude` CLI logged in | implementer for both loops; reviewer when `--reviewer claude` | `claude --version` |
| `codex` CLI logged in **and the workspace has credits** | default reviewer | `codex --version`; an out-of-credits workspace fails every review with `STUCK reviewer unavailable` |
| `python3` and `git` | all JSON handling is python; no `jq` needed | `python3 --version` |
| A local clone of the target repo, and you run from inside it | workers create worktrees from it; the approval sweep commits the `status: ready` flip in it | `git rev-parse --show-toplevel` |
| bash 3.2 or newer | macOS default works | `bash --version` |

Model spend is real: an issue costs roughly a few dollars in the issue loop (verification,
drafting, up to six review cycles) and more in the build loop (one implementer pass and up
to six review cycles per sub-issue). `--workers` is the cost dial.

### In the target repository

| Requirement | Why | If missing |
|---|---|---|
| **A spec corpus**: a `specs/` directory or the first `*-specs/` directory, following [`spec-guide.md`](../spec-guide.md) (or `WORK_PREP_SPEC_DIR=<path>`) | the issue worker drafts into it and the reviewer judges against it | every issue is marked `NOT_ACTIONABLE` and escalated. Bootstrap a corpus by hand first. |
| Native sub-issues enabled (default on GitHub) | the issue worker creates one sub-issue per L4; the build worker builds them in order | the attach call logs a warning and sub-issues stay detached |
| `CLAUDE.md` with build and test conventions | both implementers read it first | weaker drafts and builds |
| Optional: branch protection requiring the `codex-review` status on the default branch (`setup-branch-protection.sh --repo OWNER/REPO`) | hard guarantee that nothing merges without a converged review | the status is still posted; enforcement is by convention only |
| Optional: the issue template from [`bazaar-builder-specs/ISSUE-TEMPLATE.md`](../bazaar-builder-specs/ISSUE-TEMPLATE.md) as `.github/ISSUE_TEMPLATE/bazaar.md` | fewer question rounds | the worker rewrites bodies into the template anyway |

The seven `bzr-*` labels are created automatically on first run.

### From you, per issue

Exactly three touchpoints, all on GitHub:

1. **Answer questions.** If the worker cannot establish the problem, outcome, acceptance
   criteria, or scope from the issue and the code, it posts numbered questions and labels the
   issue `bzr-needs-info`. Reply in a comment; the next tick requeues it. After two rounds it
   escalates instead of asking a third time.
2. **Approve the spec PR.** A comment containing the word `approved` (negations such as
   "not approved" are ignored) or a GitHub review approval, from a login in `BZR_APPROVERS`
   (default: the authenticated `gh` user). Closing the PR unmerged rejects it.
3. **Merge the build PR.** The pipeline posts `codex-review=success` and marks the PR ready.
   It never merges.

---

## 3. How the state machine works

All durable state is GitHub labels and marker comments. Nothing on disk matters except logs
and worktrees.

```
(no bzr label) ──► bzr-drafting ──► bzr-needs-info ──┐ (human replies → back to intake)
                        │                            │
                        ▼                            │
                  bzr-spec-review ── approval ──► bzr-ready ──► bzr-building ──► bzr-pr-ready ──► closed by merge
                                                                                          │
                              side state, either loop: bzr-blocked (human escalation only) ◄──────┘ (skipped sub-issues remain)
```

| Label | Meaning | Who moves it off |
|---|---|---|
| *(none)* | intake for `bazaar-issues.sh` | the controller, when it claims the issue |
| `bzr-drafting` | an issue worker holds it | the controller, from the worker's sentinel |
| `bzr-needs-info` | questions posted, waiting for you | the controller, when a human comment lands |
| `bzr-spec-review` | spec PR is non-draft, waiting for approval | the controller's approval sweep |
| `bzr-ready` | specs merged and `ready`; queue for `bazaar-build.sh` | the build controller, when it claims |
| `bzr-building` | a build worker holds it | the controller, from the worker's sentinel |
| `bzr-pr-ready` | build PR converged, waiting for your merge | the merged-PR sweep (closes the parent, or requeues for the next round) |
| `bzr-blocked` | escalated to a human | **you**, by removing it |

Rules that keep this safe:

- **Claims are held by processes, not clocks.** A claim comment records host and pid; the
  controller on that host releases the claim only when the pid is dead. Nothing times out.
- **Three transient failures escalate.** `STUCK`, a reviewer outage, or a worker crash returns
  the issue to its queue and posts an attempt marker. The third one adds `bzr-blocked`.
  Removing `bzr-blocked` resets the count.
- **Controllers own the parent's labels.** Workers only write comments, branches, PRs, and
  `bzr-blocked` on a *skipped sub-issue*.
- **Agent comments never contain the approval word** unless they carry a `<!-- bzr-` marker,
  and marker comments are never read as approvals. This matters because the agent and you
  share a GitHub login.
- **One branch, one open PR per issue.** Issue loop: `bzr/spec-<N>`. Build loop:
  `bzr/<N>-<slug>`, with `-r2`, `-r3` suffixes for later rounds after a partial merge.

### Inside the build loop

- **Precheck first, no model call:** the parent's `Specs:` line must name spec files that exist
  on the default branch with `status: ready`, and every open sub-issue must map to one L4.
  Otherwise `SPEC_GAP` and `bzr-blocked`, with the reasons in a comment.
- **Plan:** order is dependency-first (`Blocked by #n` text, L4 `depends_on`, then number);
  an implementer pass may reorder with reasons. The plan is posted once per round.
- **Per unit:** implement, commit, push, review cycle (up to `MAX_REVIEW_CYCLES`, default 6).
  A unit that does not converge is **reverted off the branch**, its sub-issue gets
  `bzr-blocked` with the last review, and units that depend on it are skipped too.
- **Finish:** everything that converged ships in one PR. `Closes #<parent>` appears only if
  nothing was skipped; otherwise the parent stays open and, after you merge, the sweep requeues
  it for the remaining sub-issues once you clear their `bzr-blocked`.

---

## 4. Choosing what runs

| Goal | Command |
|---|---|
| One specific issue, once | `bazaar-issues.sh --issue N --once` then `bazaar-build.sh --issue N --once` |
| Redo an issue that is `bzr-blocked` or otherwise labelled | add `--force` (replaces the label; the worker resumes its existing branch and PR) |
| See what a tick would do, no writes | `--dry-run` |
| Check for inconsistencies, no writes | `--audit` |
| Steady state | no `--issue`, no `--once`; set `--workers`, `--interval` |

**Intake caveat.** Without `--issue`, `bazaar-issues.sh` treats every open issue that has no
`bzr-*` label and is not a sub-issue as work. On a repo with a large backlog it will start
drafting specs for all of it, `--workers` at a time, oldest and highest priority first
(`P0`..`P3` or `priority:*` labels). Options today: use `--issue` per issue, or run continuous
mode on a repo whose open issues you actually want specified. An opt-in intake label is a small
change if you want it.

**Priority.** Label issues `P0`, `P1`, `P2`, `P3` (or `priority:high` etc.). Ties at the top
priority are broken by a Haiku call; `--controller-model none` turns that off.

---

## 5. Debugging

### What the terminal shows

Controller events, one line each, prefixed `[ctl:issues]` or `[ctl:build]`: `start`,
`tick: queue empty`, `dispatch #N worker=<pid> log=<path>`, `skip #N <reason>`, `bounce`,
`approved`, `sub-issue #M created`, `merged-sweep`, `worker-exit #N rc=<n> sentinel=<word>`,
`attempt #N n=<k>`, `escalate #N`, `stop file present`, `stopped`.

Worker progress is relayed live with the issue number as prefix, so one terminal tells the
whole story even with several workers running:

```
[#758] [issue-worker] #758 resuming existing branch bzr/spec-758
[#758] [claude implementer] verifying #758...
[#758] [tool] Bash grep -rn "help" bz/bin bz/lib | head -80
[#758] [text] The fallback branch prints usage and exits 1 because ...
[#758] [claude reviewer] template=spec-baseline cycle=1/6
[#758] [review:spec] PR #770 → cycle 1: 2 BLOCKING, 6 RECOMMENDED
[#758] [issue-worker] #758 sentinel=SPEC_REVIEW 770
```

Only lines that start with `[` are relayed; the raw model stream and prompt text stay in the
worker's log file. `BZR_NO_STREAM=1` turns the relay off (cron jobs, for instance).

### Where to look



| What | Where |
|---|---|
| Controller log, one per role per day | `~/.bazaar/<owner>-<repo>/logs/ctl-issues-YYYYMMDD.log`, `ctl-build-YYYYMMDD.log` |
| Worker log, one per run (full model transcripts) | `~/.bazaar/<owner>-<repo>/logs/issues-<N>-<timestamp>.log`, `build-<N>-<timestamp>.log` |
| The worker's final decision | `~/.bazaar/<owner>-<repo>/run/<N>.sentinel` |
| Human-readable trail | the marker comments on the issue and the review comments on the PR |
| Worktrees (removed after each run) | `~/.bazaar/<owner>-<repo>/wt/` |
| Lock and stop files | `~/.bazaar/<owner>-<repo>/issues.lock`, `issues.stop`, `build.lock`, `build.stop` |

Readable lines in a worker log start with two spaces (`  [tool] …`, `  [text] …`,
`  [review:spec] …`); the JSON lines are the raw model stream. This works well:

```bash
grep -v '^{"type"' ~/.bazaar/<owner>-<repo>/logs/issues-123-*.log | tail -40
```

### Sentinels and what they mean

| Sentinel | Loop | Meaning | What happens |
|---|---|---|---|
| `SPEC_REVIEW <pr>` | issue | spec review converged | issue → `bzr-spec-review`, PR out of draft |
| `NEEDS_INFO <n>` | issue | questions posted | issue → `bzr-needs-info` |
| `NOT_ACTIONABLE <why>` | issue | duplicate, question, no spec corpus | escalated |
| `PR_READY <pr>` | build | build converged | issue → `bzr-pr-ready` |
| `SPEC_GAP <why>` | build | precheck or implementer found the spec unbuildable | escalated, nothing built |
| `BLOCKED <why>` | both | review cap hit, contract violated, every unit skipped, revert conflict | escalated |
| `STUCK <why>` | both | transient: model or reviewer unavailable, push failed, crash | back to queue; third time escalates |

### Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `STUCK reviewer unavailable: Codex workspace out of credits` | Codex has no credits | add credits, or pass `--reviewer claude` |
| `STUCK reviewer unavailable: Codex CLI too old` | `codex` needs upgrading for the configured model | `codex update` |
| Issue escalated with `n automatic attempts failed` | three transient failures in a row | read the attempt markers on the issue, fix the cause, remove `bzr-blocked` |
| `BLOCKED spec review: 6 cycles did not clear every BLOCKING finding` | reviewer kept finding real gaps | read the last review on the PR; fix by hand and comment `approved`, or close the PR; then remove `bzr-blocked` |
| `BLOCKED draft violated the spec-only contract: out-of-scope change: …` | the drafting model touched a file outside the spec directory (anything under it, at any depth, is allowed) | usually a prompt/CLAUDE.md conflict; check the worker log, then `--force` to retry |
| `SPEC_GAP … is status: review, not ready` | the spec PR was merged by hand without the approval sweep | let the sweep run (`bazaar-issues.sh --once`) or set `status: ready` yourself |
| `SPEC_GAP the issue body has no Specs: line` | same as above, or the body was edited | as above |
| `ERROR: bazaar-issues already running (pid …)` | a controller is up, or its lock is stale | `kill -0 <pid>`; if dead, delete the lock file |
| Issue sits in `bzr-drafting`/`bzr-building` with no worker | the worker's host is not the one running the controller | run a controller on that host, or delete the claim comment and label by hand |
| Same issue dispatched twice | two controllers of the same role on one repo, or a hand-edited label | run one controller per role per repo; use `--audit` |
| Nothing dispatched, log says `skip #N labels-changed` | labels moved between the queue read and the claim | harmless; next tick |

### Recovery recipes

- **Requeue an escalated issue:** remove `bzr-blocked`. For the issue loop it then has no
  label and is intake again; for the build loop also make sure it carries `bzr-ready`. The
  escalation comment says which.
- **Restart a run from scratch:** delete the `bzr/spec-<N>` (or `bzr/<N>-…`) branch on origin
  and close its PR, then `--issue N --force`.
- **Resume after a crash mid-review:** just run again. The issue worker resumes at the review
  when its PR exists; the build worker reads its progress from the PR body's state block and
  never re-implements a converged unit.
- **A skipped sub-issue:** it carries `bzr-blocked` and the last review. Fix the spec or the
  code, remove the label; after the current PR merges the parent is requeued for it.
- **Stop everything now:** `--stop` on both controllers, then wait for workers to exit. Killing a
  worker is safe: its EXIT trap pushes any commits and writes a `STUCK` sentinel.

---

## 6. Configuration reference

Flags common to both controllers:

```
--repo OWNER/REPO          default: gh repo view in cwd
--workers N                concurrent workers, 1-8 (default 1)
--once                     one tick then exit
--interval SECONDS         default 60
--controller-model MODEL   tie-break model (default claude-haiku-4-5-20251001; 'none' disables)
--implementer claude|codex --implementer-model M --implementer-effort E
--reviewer    claude|codex --reviewer-model M    --reviewer-effort E
--dry-run  --audit  --stop  --help  --version
```

`bazaar-issues.sh` and `bazaar-build.sh` both add `--issue N` and `--force`.

Environment:

| Variable | Default | Purpose |
|---|---|---|
| `BZR_HOME` | `~/.bazaar` | state root |
| `BZR_APPROVERS` | the `gh` login | comma-separated logins allowed to approve spec PRs; `*` = anyone |
| `MAX_ATTEMPTS` | 3 | transient failures before escalation |
| `MAX_SPEC_REVIEW_CYCLES` | 6 | spec review cap |
| `MAX_REVIEW_CYCLES` | 6 | code review cap per unit |
| `WORK_PREP_SPEC_DIR` | auto | override spec directory discovery |

Implementer models per review cycle are staged (Sonnet early, Opus 4-8 from cycle 4) unless
`--implementer-model` pins one.

---

## 7. Developing the tools

Seven offline harnesses cover the libs, controllers, workers, and an end-to-end run. They use
a fake `gh` (`test-support/fake-gh.py`), a throwaway git origin, and scripted `claude`/`codex`
stubs; nothing touches the network.

```bash
cd ~/repos/scripts
for t in test-bazaar-*.sh; do ./$t | tail -1; done
```

Run them all before committing a change to `lib/bazaar-*.sh`, the controllers, or the workers.
Design decisions and their history are in `bazaar-builder-specs/log.md`; the label state
machine and sentinel contracts are in the L3 specs there. Two facts that shaped the code and
still apply: the hosts run bash 3.2 and have no `jq`.

## 8. Known limits

- GitHub only. No Jira.
- One controller per role per repo. Cross-host coordination is out of scope; claims from
  another host are never touched.
- Intake has no opt-in label yet (see section 4).
- A Codex credit or version failure counts as a transient attempt rather than halting the
  controller, so three runs in that state escalate the issue.
- Each spec review cycle reviews the whole PR; cost grows with draft size.
