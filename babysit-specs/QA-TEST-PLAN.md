# QA Test Plan — babysit-with-review.sh

**Owner:** qa-lead  
**Status:** Test Suite 4 automated and passing (160/160, last run 2026-09-27), now
including automated pre-flight coverage for TC-1.2, lock-file-collision coverage
for TC-1.3/TC-1.3b, lock-file-removal coverage for TC-1.4, sentinel-detection
coverage for TC-1.5/TC-1.6, and MAX_ITER-exhaustion coverage for TC-1.8 (see
Suite 1), plus blocking-count coverage for TC-2.1/TC-2.2, sentinel/HEAD-unchanged
coverage for TC-2.4/TC-2.5, missing-reviewer graceful-degradation coverage for
TC-2.9, and a separate `test-babysit-review-feedback.sh` harness covering the
`collect_pr_feedback()` filter (TC-2.10/TC-2.11, see Suite 2); Test Suites 1-3
otherwise remain manual smoke tests against live Claude/Codex/gh, not yet
executed  
**Priority:** Medium (internal tool, existing implementation to verify)

## Test Strategy

**Approach:** Behavior-driven testing against acceptance criteria from L3 specs. Focus on state machine correctness, error handling, and edge cases.

**Environment:** Local developer workstation with:
- Clean test repo (or dedicated test branch in scripts repo)
- Claude Code CLI authenticated
- Codex CLI installed (optional, for review cycle tests)
- gh CLI authenticated
- git configured

**Test data:** Synthetic commits, PRs, and review scenarios created during test execution.

---

## Test Suite 1: L3-autonomous-outer-loop

**Reference:** L3-autonomous-outer-loop.md Acceptance Tests (lines 167-176)

### TC-1.1: Single Iteration Execution
**Given:** Clean git repo on default branch  
**When:** `MAX_ITER=1 ./babysit-with-review.sh`  
**Then:** 
- Exactly 1 iteration executes
- Log shows `=== iter 1 @ <timestamp> ===`
- Exit code 0
- No STOP sentinel output

**Test steps:**
1. Create test repo: `mkdir /tmp/test-babysit && cd /tmp/test-babysit && git init`
2. Set default branch: `git checkout -b main && git commit --allow-empty -m "init"`
3. Run: `MAX_ITER=1 ~/repo/scripts/babysit-with-review.sh`
4. Verify: `echo $?` returns 0
5. Verify: `grep -c "=== iter" ~/sisyphus-logs/test-babysit-*.log` returns 1

---

### TC-1.2: Pre-flight Check — Unstaged Changes
**Status: automated, not manual (added 2026-09-27).** The full pre-flight gate —
unstaged modifications, staged-uncommitted changes, untracked non-ignored files,
auto-switch off a non-default branch, ahead/diverged/behind-then-fast-forward
against origin — now has deterministic coverage in
`test-babysit-with-review-cli.sh` via `BABYSIT_TEST_MODE=outer-preflight`, which
runs the real pre-flight block (git state only; no live Claude/Codex/gh) against
disposable repos with a bare `origin` remote and exits before the outer loop's
first iteration. This TC's manual steps below remain as the original acceptance
reference; the automated cases are the ones that actually run before every commit.

**Given:** Unstaged changes in working tree  
**When:** `./babysit-with-review.sh` starts  
**Then:** 
- Pre-flight check fails
- Exit code 1
- Error message with corrective instructions

**Test steps:**
1. Create test repo with initial commit
2. Modify file: `echo "test" >> README.md`
3. Run: `~/repo/scripts/babysit-with-review.sh 2>&1 | tee test-output.log`
4. Verify: `echo $?` returns 1
5. Verify: `grep "unstaged modifications" test-output.log`

---

### TC-1.3: Lock File Semantics
**Status: automated, not manual (added 2026-09-27).** This TC previously
described a single scenario ("lock file exists → first iteration executes
normally") that contradicts both the shipped code and
`L3-autonomous-outer-loop.md` acceptance tests 3/3b: a *pre-existing* stop
file is a startup collision (`exit 1`), not something the script tolerates.
The two real scenarios — collision on a pre-existing lock file, and normal
startup when none exists — are covered deterministically in
`test-babysit-with-review-cli.sh` via `BABYSIT_TEST_MODE=outer-preflight`
against a bare (collision case) or real (no-collision case) directory; no
Claude/Codex/gh involved. The corrected manual steps below remain as the
acceptance reference.

**Given:** Lock file exists before start-up  
**When:** Script runs  
**Then:** Exit 1 — collision (another instance may be running; the script
creates the lock file itself and never expects to find one already there)

**Test steps:**
1. Create test repo
2. Pre-create lock file: `mkdir -p ~/sisyphus-logs && touch ~/sisyphus-logs/test-babysit.stop`
3. Run: `MAX_ITER=1 ~/repo/scripts/babysit-with-review.sh`
4. Verify: Exit code 1, stderr contains `already exists`, no iteration executed

---

### TC-1.3b: Lock File Semantics — No Pre-Existing Lock
**Status: automated, not manual (added 2026-09-27).** Split out of TC-1.3
in the same commit that corrected it (both describe the shipped
`BABYSIT_TEST_MODE=outer-preflight` collision check, not two independent
behaviors). This scenario — no pre-existing stop file, startup proceeds
normally — is covered deterministically in `test-babysit-with-review-cli.sh`
as the "TC-1.3 AT3b" case, run against a real (non-bare) preflight repo; no
Claude/Codex/gh involved. The manual steps below remain as the acceptance
reference.

**Given:** No lock file exists before start-up  
**When:** Script runs  
**Then:** Script creates the lock file itself; first iteration executes normally

**Test steps:**
1. Create test repo (ensure `~/sisyphus-logs/test-babysit.stop` does not exist)
2. Run: `MAX_ITER=1 ~/repo/scripts/babysit-with-review.sh`
3. Verify: Exit code 0, iteration executed, lock file present during the run

---

### TC-1.4: Lock File Removal Mid-Run
**Status: automated, not manual (added 2026-09-27).** The per-iteration
stop-file check now has deterministic coverage in
`test-babysit-with-review-cli.sh` via `BABYSIT_TEST_MODE=outer-lockfile-removed`,
which drives the real `stop_file_removed()` function extracted from the outer
loop against a real file on disk (present, then removed) — no Claude/Codex/gh
involved. The manual steps below remain as the original acceptance reference.

**Given:** Lock file removed during run  
**When:** Next iteration checks lock file  
**Then:** Loop exits gracefully

**Test steps:**
1. Create test repo
2. Run in background: `MAX_ITER=10 SLEEP_SEC=5 ~/repo/scripts/babysit-with-review.sh &`
3. Wait for first iteration: `sleep 3`
4. Remove lock: `rm ~/sisyphus-logs/test-babysit.stop`
5. Wait for process: `wait`
6. Verify: Log shows "Stop file removed; exiting"

---

### TC-1.5: STOP Sentinel Detection
**Status: automated, not manual (added 2026-09-27).** The trailing-line
classification (STOP recognized only as the final line, not mid-output) is
extracted into `parse_sentinel()` and covered deterministically in
`test-babysit-with-review-cli.sh` via `BABYSIT_TEST_MODE=outer-sentinel`,
which feeds one simulated iteration's implementer RESULT through the real
function (no Claude/Codex/gh involved). The manual steps below remain as the
original acceptance reference; the automated cases are the ones that
actually run before every commit.

**Given:** Claude outputs `STOP` sentinel  
**When:** Iteration completes  
**Then:** Loop exits with code 0

**Test steps:**
1. Create test repo with no work (empty issues, no specs)
2. Run: `MAX_ITER=5 ~/repo/scripts/babysit-with-review.sh`
3. Verify: Exit code 0
4. Verify: Log shows "STOP signal received on iter N"

**Note:** This test requires Claude to naturally output STOP (no work available). May need to stub Claude output for deterministic testing.

---

### TC-1.6: HANDOFF_REVIEW Sentinel Detection
**Status: automated (parsing only), not manual (added 2026-09-27).** The
same `parse_sentinel()`/`outer-sentinel` harness covers PR-number extraction,
whitespace trimming, and the non-numeric "ignore" path. The actual
`run_review_cycle` invocation this sentinel triggers is not exercised by this
harness (it needs a real PR and gh/codex) — the manual steps below remain the
acceptance reference for that end-to-end behavior.

**Given:** Claude outputs `HANDOFF_REVIEW 123`  
**When:** Iteration completes  
**Then:** Review cycle runs before next iteration

**Test steps:**
1. Create test repo with open PR #123
2. Mock Claude to output `HANDOFF_REVIEW 123` (requires test harness)
3. Run: `MAX_ITER=2 ~/repo/scripts/babysit-with-review.sh`
4. Verify: Log shows `=== review handoff: PR #123`

**Note:** Requires test harness to mock Claude output. Alternative: manual test by observing real PR creation.

---

### TC-1.7: Stuck Detection
**Given:** Claude outputs identical result for STUCK_N consecutive iterations  
**When:** Stuck detection runs  
**Then:** Loop halts with "Stuck" message

**Test steps:**
1. Create test repo with no actionable work (forces identical Claude output)
2. Run: `MAX_ITER=10 STUCK_N=3 ~/repo/scripts/babysit-with-review.sh`
3. Verify: Exit code 0
4. Verify: Log shows "Stuck: last 3 results identical. Bailing on iter N"

---

### TC-1.8: MAX_ITER Exhaustion
**Status: automated, not manual (added 2026-09-27).** The exhaustion check
is extracted into `maxiter_exhausted()` and covered deterministically in
`test-babysit-with-review-cli.sh` via `BABYSIT_TEST_MODE=outer-maxiter`,
which feeds simulated post-iteration counters through the real function (no
Claude/Codex/gh involved). This TC's manual steps below remain as the
original acceptance reference; the automated cases are the ones that
actually run before every commit.

**Given:** MAX_ITER=5  
**When:** 5 iterations complete without STOP  
**Then:** Loop exits with "Hit MAX_ITER"

**Test steps:**
1. Create test repo with perpetual work (e.g., never-ending spec)
2. Run: `MAX_ITER=5 SLEEP_SEC=1 ~/repo/scripts/babysit-with-review.sh`
3. Verify: Exit code 0
4. Verify: Log shows "Hit MAX_ITER=5. Bailing."

---

## Test Suite 2: L3-review-cycle

**Reference:** L3-review-cycle.md Acceptance Tests (lines 184-196)

### TC-2.1: Review Cycle with BLOCKING Issues
**Status: automated (blocking-count only), not manual (added 2026-09-27).**
`review-blocking-count` in `test-babysit-with-review-cli.sh` drives the real
`count_blocking()` (the function whose output branches `run_review_cycle`
between "addressing findings" and auto-merge) over review markdown on stdin —
covering a single real finding and multiple findings with an indented
continuation line, counted once each. The `[claude] addressing findings...`
log line and the cycle-repeats behavior are not exercised by this harness (no
Claude/Codex/gh involved); the manual steps below remain the acceptance
reference for those.

**Given:** PR #123 with BLOCKING issues  
**When:** Review cycle runs  
**Then:** 
- Codex produces markdown review with `## BLOCKING` section
- Claude addresses findings
- Cycle repeats

**Test steps:**
1. Create test PR with intentional bug (e.g., undefined variable)
2. Checkout PR branch: `gh pr checkout 123`
3. Run: `MAX_REVIEW_CYCLES=3 ~/repo/scripts/babysit-with-review.sh` (invoke outer loop, trigger review)
4. Verify: Log shows `[codex] N blocking finding(s)` with N > 0
5. Verify: Log shows `[claude] addressing findings...`
6. Verify: Commit created after Claude pass

---

### TC-2.2: Zero BLOCKING Findings — Auto-Merge
**Status: automated (blocking-count only), not manual (added 2026-09-27).**
Same `review-blocking-count` harness as TC-2.1: covers a sole `- (none)`
bullet under `## BLOCKING` counting as zero, a review with no `## BLOCKING`
heading at all counting as zero, and non-blocking bullets under
`## RECOMMENDED` not leaking into the count. The actual `gh pr merge` and PR
state transition are not exercised by this harness; the manual steps below
remain the acceptance reference for those.

**Given:** Codex returns 0 BLOCKING findings  
**When:** Cycle completes  
**Then:** PR is merged via `gh pr merge --squash [--auto]`

**Test steps:**
1. Create test PR with clean code (no issues)
2. Run review cycle (via outer loop or direct function call)
3. Verify: Log shows "zero blocking findings; PR #N cleared after M cycle(s)"
4. Verify: Log shows "PR #N queued for auto-merge" or "PR #N merged"
5. Verify: `gh pr view N --json state -q .state` returns "MERGED"

---

### TC-2.3: Prescriptive Mode (Cycle 3+)
**Given:** Cycle 3 starts  
**When:** Codex prompt is assembled  
**Then:** Prescriptive template used (requires "Suggested fix:")

**Test steps:**
1. Create test PR that requires 3+ cycles (complex issues)
2. Run: `MAX_REVIEW_CYCLES=6 ~/repo/scripts/babysit-with-review.sh`
3. Verify: Log shows `[codex] template=prescriptive has_history=yes cycle=3/6`
4. Verify: Codex review output contains "Suggested fix:" lines under BLOCKING

**Note:** Requires PR with enough issues to trigger 3 cycles. May need to create intentionally buggy code.

---

### TC-2.4: STUCK_REVIEW Sentinel
**Status: automated (sentinel classification only), not manual (added
2026-09-27).** `review-sentinel` in `test-babysit-with-review-cli.sh` drives
the real `parse_review_sentinel()` (extracted from `run_review_cycle`'s
implementer-response handling) over a simulated implementer RESULT on
stdin — covering `STUCK_REVIEW <reason>` on the last line, bare
`DONE_REVIEW`, no sentinel at all (classified `NONE`, treated as
`DONE_REVIEW` by the caller), and a `STUCK_REVIEW`-looking line that isn't
the final line (not honored). The `review-incomplete` label application and
the function's return code are not exercised by this harness (no
Claude/Codex/gh involved); the manual steps below remain the acceptance
reference for those.

**Given:** Claude outputs `STUCK_REVIEW cannot fix X`  
**When:** Cycle processes response  
**Then:** 
- PR labeled `review-incomplete`
- Function returns 0

**Test steps:**
1. Create test PR with unfixable issue (e.g., requires external API change)
2. Manually monitor Claude output or mock Claude to output STUCK_REVIEW
3. Verify: Log shows "STUCK_REVIEW — bailing review cycle"
4. Verify: `gh pr view N --json labels -q '.labels[].name'` includes "review-incomplete"

---

### TC-2.5: HEAD Unchanged After DONE_REVIEW (Defensive Check)
**Status: automated (predicate only), not manual (added 2026-09-27).**
`review-head-unchanged` in `test-babysit-with-review-cli.sh` drives the real
`review_head_unchanged()` (extracted from `run_review_cycle`'s post-pass
check) over `pre_sha post_sha` pairs on stdin — covering identical SHAs
(flagged), differing SHAs (not flagged), and an empty pre-SHA (never
flagged, since a failed `git rev-parse` shouldn't be conflated with "no
commits made"). The `review-incomplete` label application is not exercised
by this harness (no Claude/Codex/gh involved); the manual steps below
remain the acceptance reference for that.

**Given:** Claude outputs `DONE_REVIEW` but HEAD SHA unchanged  
**When:** Cycle checks HEAD  
**Then:** PR labeled `review-incomplete`

**Test steps:**
1. Create test PR
2. Mock Claude to output DONE_REVIEW without making commits (requires test harness)
3. Verify: Log shows "HEAD unchanged (no commits made) — bailing review cycle"
4. Verify: PR labeled `review-incomplete`

---

### TC-2.6: MAX_REVIEW_CYCLES Exhaustion
**Given:** MAX_REVIEW_CYCLES=3  
**When:** Cycle limit reached  
**Then:** PR labeled `review-incomplete`

**Test steps:**
1. Create test PR with persistent BLOCKING issues (issues remain after fixes)
2. Run: `MAX_REVIEW_CYCLES=3 ~/repo/scripts/babysit-with-review.sh`
3. Verify: Log shows "hit MAX_REVIEW_CYCLES=3 on PR #N"
4. Verify: PR labeled `review-incomplete`

---

### TC-2.7: Convergence Tracking (Cycle 2+)
**Given:** Cycle 2 starts  
**When:** Codex prompt is assembled  
**Then:** History block includes cycle 1 review and git log

**Test steps:**
1. Create test PR that requires 2+ cycles
2. Run: `MAX_REVIEW_CYCLES=6 ~/repo/scripts/babysit-with-review.sh`
3. Verify: Log shows `[codex] template=descriptive has_history=yes cycle=2/6`
4. Inspect Codex prompt (logged to file): contains "--- prior review cycles ---" section

**Note:** Requires inspecting prompt content, which may not be logged by default. Add debug logging if needed.

---

### TC-2.8: Codex MCP Transport Failure (3 Retries)
**Given:** Codex MCP transport fails 3 times  
**When:** Retry exhausted  
**Then:** 
- PR labeled `review-mcp-outage`
- Function returns 2

**Test steps:**
1. Create test PR
2. Simulate MCP failure: temporarily block https://chatgpt.com via /etc/hosts or firewall
3. Run review cycle
4. Verify: Log shows "MCP transport failure on attempt 1 of 3"
5. Verify: Log shows "waiting 60s before retry (attempt 2 of 3)"
6. Verify: Log shows "MCP transport failure on attempt 3 of 3"
7. Verify: PR labeled `review-mcp-outage`
8. Restore connectivity and verify auto-retry on next outer loop iteration

---

### TC-2.9: Codex CLI Not Installed (Graceful Degradation)
**Status: automated, not manual (added 2026-09-27).**
`BABYSIT_TEST_MODE=review-cycle-missing-reviewer` drives the real
`run_review_cycle()` with the selected reviewer binary removed from PATH,
exercising the graceful-degradation return in full (not just the
`reviewer_binary_available()` predicate that Suite 4 already covered) — no
gh/git call happens before that check, so no stub is needed. Asserts both the
exact skip log line and that the function returns 0 (PR left open for
external review). The manual steps remain the acceptance reference for an
actually-uninstalled system `codex` binary.

**Given:** Codex CLI not installed  
**When:** Cycle starts  
**Then:** Logged message, function returns 0

**Test steps:**
1. Create test PR
2. Temporarily rename codex: `sudo mv /usr/local/bin/codex /usr/local/bin/codex.bak`
3. Run review cycle
4. Verify: Log shows "codex CLI not found; skipping review cycle (PR #N remains open)"
5. Restore codex: `sudo mv /usr/local/bin/codex.bak /usr/local/bin/codex`

---

### TC-2.10: Existing CodeRabbit Comments Included
**Status: automated, not manual (added 2026-09-27).** `test-babysit-review-feedback.sh`
drives the real `collect_pr_feedback()` (via `BABYSIT_TEST_MODE=review-feedback`)
against a `gh` stub that forwards the function's actual `--json`/`-q`/`--jq`
arguments to the real `jq` binary against canned review/comment/inline-comment
fixtures — so the embedded jq filters run unmodified, not a bash
re-implementation of them. This directly verifies the unit-test alternative this
TC's note below already proposed. The manual steps remain the acceptance
reference for the live-PR path (the actual prompt Claude receives).

**Given:** PR has existing CodeRabbit comments  
**When:** collect_pr_feedback runs  
**Then:** Comments included in Claude prompt

**Test steps:**
1. Create test PR
2. Add CodeRabbit comment manually via gh API: `gh api repos/{owner}/{repo}/issues/{pr}/comments -f body="CodeRabbit test comment"`
3. Run review cycle
4. Verify: Claude prompt (if logged) includes CodeRabbit comment text

**Note:** Requires PR feedback logging or inspection via debugger. May verify via code review instead.

---

### TC-2.11: Self-Posted Codex Comments Excluded
**Status: automated, not manual (added 2026-09-27).** Same
`test-babysit-review-feedback.sh` harness as TC-2.10: the `--json reviews`
fixture covers all three self-posted prefixes (`**Codex review`, `**Claude
review`, `**babysit-with-review:`), and the assertions confirm
`collect_pr_feedback()` excludes all three from that call. The `--json
comments` fixture additionally confirms exclusion of a self-posted `**Codex
review` in top-level PR comments. Inline review comments (`gh api
.../comments`) have no self-posted fixture, so exclusion there is untested by
this harness. The manual steps remain the acceptance reference for the
live-PR path.

**Given:** PR has self-posted Codex review comment  
**When:** collect_pr_feedback runs  
**Then:** Comment excluded

**Test steps:**
1. Create test PR
2. Post Codex-style comment: `gh pr comment N --body "**Codex review — PR #N cycle 1 of 6**\n..."`
3. Run second review cycle
4. Verify: collect_pr_feedback does not return self-posted comment
5. Verify: Log shows Claude prompt without duplicate Codex review

**Note:** Requires inspecting prompt content. Alternative: verify filter logic via unit test of collect_pr_feedback function.

---

## Test Suite 3: L3-mcp-resilience

**Reference:** L3-mcp-resilience.md Acceptance Tests (lines 174-182)

### TC-3.1: Codex Success on Attempt 1
**Given:** Codex succeeds on attempt 1  
**When:** Function called  
**Then:** Return 0 with no retries

**Test steps:**
1. Create test PR
2. Run review cycle with functional Codex
3. Verify: Log shows `[codex] reviewing PR #N...` (once)
4. Verify: No retry messages in log
5. Verify: Review cycle completes successfully

---

### TC-3.2: Retry After Attempt 1 Failure
**Given:** Codex fails on attempt 1 with telltale match, succeeds on attempt 2  
**When:** Function called  
**Then:** Return 0 after 60s delay

**Test steps:**
1. Create test PR
2. Simulate transient MCP failure: block chatgpt.com for 30 seconds via firewall
3. Run review cycle
4. Verify: Log shows "MCP transport failure on attempt 1 of 3"
5. Verify: Log shows "waiting 60s before retry (attempt 2 of 3)"
6. Restore connectivity after 30s
7. Verify: Attempt 2 succeeds, function returns 0

---

### TC-3.3: Retry After Attempts 1 and 2 Failure
**Given:** Codex fails on attempts 1 and 2, succeeds on attempt 3  
**When:** Function called  
**Then:** Return 0 after 60s + 300s delays

**Test steps:**
1. Create test PR
2. Simulate MCP failure for 2 minutes: block chatgpt.com
3. Run review cycle
4. Verify: Attempts 1 and 2 fail with retry messages
5. Restore connectivity after 2 minutes
6. Verify: Attempt 3 succeeds, total delay ~6 minutes (60 + 300 + Codex time)

---

### TC-3.4: All 3 Attempts Fail
**Given:** Codex fails on all 3 attempts with telltale match  
**When:** Function called  
**Then:** Return 2 (MCP transport failure)

**Test steps:**
1. Create test PR
2. Simulate persistent MCP failure: block chatgpt.com for 10 minutes
3. Run review cycle
4. Verify: Log shows 3 retry attempts with backoff delays
5. Verify: Function returns 2
6. Verify: PR labeled `review-mcp-outage`
7. Restore connectivity

---

### TC-3.5: Non-Transport Failure (No Retry)
**Given:** Codex fails on attempt 1 with no telltale match  
**When:** Function called  
**Then:** Return 1 (non-transport failure) with no retries

**Test steps:**
1. Create test PR with malformed prompt (if possible to trigger Codex error)
2. Run review cycle
3. Verify: Codex exits non-zero, no telltale match in output
4. Verify: Function returns 1 (no retries)
5. Verify: PR labeled `review-incomplete` (not `review-mcp-outage`)

**Note:** Difficult to simulate non-transport Codex failure. May verify via code review or mock test.

---

### TC-3.6: Codex Exit 0 but Empty TMP_REVIEW
**Given:** Codex exit 0 but TMP_REVIEW empty on attempt 1  
**When:** Function called  
**Then:** Treat as failure, check telltale, potentially retry

**Test steps:**
1. Mock Codex to exit 0 with no output (requires test harness)
2. Run review cycle
3. Verify: Function treats as failure, checks telltale regex
4. If telltale match: retry; else: return 1

**Note:** Requires test harness to mock Codex behavior. May verify via code review instead.

---

### TC-3.7: Retry Log Message Format
**Given:** Attempt 2 starts  
**When:** Function sleeps  
**Then:** Log message "waiting 60s before retry (attempt 2 of 3)" appears

**Test steps:**
1. Trigger retry scenario (TC-3.2)
2. Verify: `grep "waiting 60s before retry (attempt 2 of 3)" ~/sisyphus-logs/*.log`

---

### TC-3.8: MCP Failure Log Message Format
**Given:** Attempt 3 fails with telltale match  
**When:** Function returns  
**Then:** Log message shows "MCP transport failure on attempt 3 of 3 (rc=N, review=empty)"

**Test steps:**
1. Trigger 3-attempt failure scenario (TC-3.4)
2. Verify: `grep "MCP transport failure on attempt 3 of 3" ~/sisyphus-logs/*.log`

---

## Test Suite 4: L4-selectable-implementer / L4-selectable-reviewer

**Reference:** L4-selectable-implementer.md, L4-selectable-reviewer.md

**Status: automated, not manual.** This suite postdates the rest of this plan — the
selectable-implementer/reviewer feature and its test harness
(`test-babysit-with-review-cli.sh`, using `BABYSIT_TEST_MODE` recording stubs for
`claude`/`codex`/`gh`/`sleep`) landed 2026-07-15, after this plan's Test Suites 1-3
were drafted (2026-06-28). It is deterministic and requires no live Claude/Codex/gh
calls, so — unlike Suites 1-3 — it runs in CI-suitable time and is expected to pass
before every commit that touches harness selection or review-structure validation.

**Run:** `./test-babysit-with-review-cli.sh` — last run 2026-09-27, 160 assertions,
0 failed. 18 of those are the Suite 1 pre-flight cases (TC-1.2) added the same day;
everything else below is selectable-implementer/reviewer and review-structure
coverage.

**Coverage (paraphrased from the harness's own assertions, not a numbered TC list —
add TC IDs here if this suite is ever split into individually-run cases):**
- Default implementer is Claude, default reviewer is Codex, with no model/effort
  forced unless explicitly requested
- `--name VALUE` and `--name=VALUE` both parse for every selectable flag
- Per-role model/effort selection does not leak across roles (an implementer model
  never reaches the reviewer invocation and vice versa) or across harnesses (Claude
  settings never reach a Codex invocation and vice versa), including when the same
  harness is selected for both roles
- Claude implementer gets `--dangerously-skip-permissions`; Codex implementer gets
  `--dangerously-bypass-approvals-and-sandbox` — neither bypass is ever granted to a
  reviewer invocation
- Codex reviewer runs sandboxed and read-only (`-s read-only`); Claude reviewer runs
  in plan mode (`--permission-mode plan`)
- Model policy: a Claude implementer defaults to the stage default at startup but
  keeps whatever model a review cycle selected on remediation passes; a Codex
  implementer's configured default applies at both startup and remediation unless a
  model is explicitly set, in which case the explicit model applies at both stages
- A selected reviewer binary that is missing is detected gracefully (falls back
  rather than crashing) and reported when the other selected harness is present
- `--help` documents `--implementer`, `--implementer-model`, `--implementer-effort`,
  `--reviewer`, `--reviewer-model`, `--reviewer-effort` without confusing a harness
  name for a model name
- Review-structure validation (`valid_review_structure`, shared with
  `ASF-FEAT-REVIEW-CYCLE`): rejects headings with no bullets, bulletless
  BLOCKING/RECOMMENDED/INFORMATION sections, duplicate or out-of-order core headings,
  prose outside/between sections, unknown top-level headings, and a "none" bullet
  followed by more bullets in the same section — while accepting prescriptive
  multiline findings, a leading ADJUDICATION section, and multiple real findings with
  indented detail lines

This suite does not exercise the outer loop, the review-cycle state machine, or MCP
resilience (Test Suites 1-3 still cover those, manually, until a
`BABYSIT_TEST_MODE`-style harness exists for them too — see "Test Automation
Recommendations" below).

---

## Test Execution Plan

### Phase 1: Smoke Tests (1 hour)
Run TC-1.1, TC-1.2, TC-2.1, TC-3.1 to verify basic functionality.

### Phase 2: Happy Path (2 hours)
Run TC-1.5, TC-1.8, TC-2.2, TC-2.9, TC-3.1 to verify typical usage.

### Phase 3: Error Handling (3 hours)
Run TC-1.7, TC-2.4, TC-2.6, TC-2.8, TC-3.4 to verify error recovery.

### Phase 4: Edge Cases (2 hours)
Run TC-1.4, TC-2.5, TC-2.7, TC-3.2, TC-3.3 to verify edge cases.

### Phase 5: Regression Suite (optional, 4 hours)
Run all test cases as regression suite after code changes.

**Total estimated effort:** 8-12 hours (initial pass) + 4 hours per regression run

---

## Test Automation Recommendations

**Done, for the selectable-implementer/reviewer surface:** the "mock Claude/Codex
output via a stub" recommendation below is no longer future work for that surface —
`test-babysit-with-review-cli.sh` is exactly that harness, gated by
`BABYSIT_TEST_MODE`, and it is Test Suite 4 above. Run it before any commit that
touches flag parsing, harness selection, model/effort forwarding, or
`valid_review_structure`.

**Partially done, for Suite 1's outer-loop mechanics:** `BABYSIT_TEST_MODE` now has
sibling stub modes (`outer-preflight`, `outer-sentinel`, `outer-maxiter`,
`outer-lockfile-removed`) that extract the pre-flight gate, sentinel parsing, MAX_ITER
exhaustion, and mid-run lock-file removal into pure functions and drive them
deterministically — no Claude/Codex/gh involved. This covers TC-1.2 through TC-1.6 and
TC-1.8 (see each TC's own status note above). TC-1.1 (a full single-iteration run,
including the per-iteration git worktree and branch rename) and TC-1.7 (stuck-loop
detection) have not been converted this way as of this writing; check each TC's own
status note for the current state, since this file is not always updated when a new
stub mode ships.

**Partially done, for Suite 2's PR-feedback filter:** `BABYSIT_TEST_MODE=review-feedback`
drives the real `collect_pr_feedback()` against a stubbed `gh` (`test-babysit-review-feedback.sh`),
covering TC-2.10/TC-2.11.

**Partially done, for Suite 2's review-cycle sentinel handling:**
`BABYSIT_TEST_MODE` has sibling stub modes `review-sentinel` and
`review-head-unchanged` that extract `run_review_cycle`'s implementer-sentinel
classification and its HEAD-unchanged defensive check into pure functions
(`parse_review_sentinel()`, `review_head_unchanged()`) and drive them
deterministically — no Claude/Codex/gh involved. This covers TC-2.4 and TC-2.5
(see each TC's own status note above). A third sibling mode,
`review-cycle-missing-reviewer`, drives `run_review_cycle`'s own
graceful-degradation early return (not a pure-function extraction, since that
return happens before any gh/git call) and covers TC-2.9. The cycle loop
itself, label application, and TC-2.6/2.8 remain untouched — no stub exists
yet for those.

**Still open, for the rest of Test Suite 2 and all of Suite 3** (review-cycle state
machine, MCP resilience): those cases still require live Claude/Codex/gh calls or
manual network interference (blocking `chatgpt.com` to simulate MCP failures)
because no `BABYSIT_TEST_MODE`-style stub exists yet for `run_review_cycle`'s cycle
loop or for `codex_review_with_retry`'s transport-failure paths. Extending
`BABYSIT_TEST_MODE` (or a sibling stub mode) to cover those two surfaces would let
the rest of Suites 2-3 collapse into the same fast, deterministic run as Suite 4
and Suite 1's/Suite 2's automated cases.

### Short-term (Manual Testing, Suites 1-3 only)
- Use test repo: `~/test-babysit-repo/` for isolated testing
- Document test results in spreadsheet or markdown table
- Run smoke tests before each release

### Long-term (Automated Testing, Suites 1-3 only)
- Extend `BABYSIT_TEST_MODE` (or a comparable stub mode) to cover the outer loop and
  MCP-resilience retry paths, following the pattern `test-babysit-with-review-cli.sh`
  already established for the selectable-harness surface
- Add CI pipeline (GitHub Actions) to run the fast suites (4, and 1-3 once stubbed)
  on each push

**Example bats test:**
```bash
#!/usr/bin/env bats

@test "TC-1.1: Single iteration execution" {
  cd /tmp/test-babysit-repo
  MAX_ITER=1 ~/repo/scripts/babysit-with-review.sh
  [ $? -eq 0 ]
  [ $(grep -c "=== iter" ~/sisyphus-logs/test-babysit-*.log) -eq 1 ]
}
```

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Tests require live Claude/Codex API calls (slow, expensive) | Mock API responses via test harness or environment variables |
| MCP transport failures difficult to simulate consistently | Use network blocking tools (iptables, pfctl) or mock Codex CLI |
| Tests modify real PRs/repos | Use dedicated test repo; clean up after each test run |
| Non-deterministic Claude output | Accept variability or mock output for deterministic tests |

---

## Definition of Done

Test suite passes when:
- All Completeness checks pass (all TCs execute without errors)
- All Accuracy checks pass (all TCs produce expected outcomes)
- All Coherence checks pass (no contradictory behavior across test suites)

Specs can move to `ready` status after:
- Security review action items resolved
- QA smoke tests pass (Phase 1 + Phase 2)
- Owner accepts remaining [OPEN] items as deferred or resolved
