# QA Test Plan — babysit-with-review.sh

**Owner:** qa-lead  
**Status:** Recommended plan (not yet executed)  
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
**Given:** Lock file exists  
**When:** Script runs  
**Then:** First iteration executes normally

**Test steps:**
1. Create test repo
2. Pre-create lock file: `mkdir -p ~/sisyphus-logs && touch ~/sisyphus-logs/test-babysit.stop`
3. Run: `MAX_ITER=1 ~/repo/scripts/babysit-with-review.sh`
4. Verify: Exit code 0, iteration executed

---

### TC-1.4: Lock File Removal Mid-Run
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
**Given:** Claude outputs `DONE_REVIEW` but HEAD SHA unchanged  
**When:** Cycle checks HEAD  
**Then:** PR labeled `review-incomplete`

**Test steps:**
1. Create test PR
2. Mock Claude to output DONE_REVIEW without making commits (requires test harness)
3. Verify: Log shows "HEAD unchanged (no commits made) — bailing review cycle"
4. Verify: PR labeled `review-incomplete`

**Note:** Difficult to test without mocking. May skip in favor of code review verification.

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

### Short-term (Manual Testing)
- Use test repo: `~/test-babysit-repo/` for isolated testing
- Document test results in spreadsheet or markdown table
- Run smoke tests before each release

### Long-term (Automated Testing)
- Create test harness to mock Claude/Codex output (stub via environment variable or wrapper script)
- Use bats (Bash Automated Testing System) for test runner
- Add CI pipeline (GitHub Actions) to run smoke tests on each push

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
