# Security Review Plan — babysit-with-review.sh

**Owner:** security-lead  
**Status:** Recommended plan (not yet executed)  
**Priority:** Medium (internal tool, single-user, no customer data)

## Scope

Security review of babysit-with-review.sh autonomous development system across L2 system architecture and three L3 features (outer loop, review cycle, MCP resilience).

## Review Areas

### 1. Lock File Race Conditions (L3-autonomous-outer-loop)

**Risk:** Two processes start simultaneously before lock file created, both run until collision detected.

**Review checklist:**
- [ ] Analyze lock file creation timing (line 94: `touch "$LOG" "$STOP_FILE"`)
- [ ] Verify PID-based log filename prevents most collisions
- [ ] Check trap handler cleanup (line 95: removes lock file on EXIT)
- [ ] Assess blast radius: Both processes halt gracefully when collision detected
- [ ] Determine if TOCTOU (time-of-check-to-time-of-use) window is acceptable for single-user tool

**Recommendation:** Accept as-is for single-user scenario. If multi-user deployment needed, implement atomic lock file creation (e.g., `set -o noclobber` or `flock`).

---

### 2. PR Label Race Conditions (L3-review-cycle)

**Risk:** Concurrent gh pr edit commands could conflict if multiple babysitter instances run on same repo.

**Review checklist:**
- [ ] Confirm lock file prevents concurrent babysitter runs on same project
- [ ] Verify gh CLI handles concurrent label operations gracefully (idempotent add/remove)
- [x] Confirm label application failures: `gh pr ready --undo` and `gh pr edit --add-label` are **fail-closed** — they call `exit 1` on failure (`fail_review_cycle*` functions). Only `gh pr comment` (posting the bail reason) is best-effort.
- [x] Assess whether failed label operations block review cycle progress: **Yes, they halt the babysitter.** A PR that was not quarantined must not re-enter the outer loop; fail-closed is intentional.

**Recommendation:** ~~Accept as-is. Failures are non-blocking warnings.~~ **Status updated:** Label/draft failures are already fail-closed (`exit 1`). This is correct behavior — no action needed.

---

### 3. Auto-Merge Approval (L3-review-cycle) — **RESOLVED**

**Risk:** PRs auto-merge when BLOCKING=0 without additional human approval gate.

**Status: Resolved.** The approval gate shipped as part of v1.1.0. Action item 1 from the original plan is done.

**What shipped:**
- When BLOCKING=0, `run_review_cycle` POSTs `codex-review=success` via `gh api -X POST repos/<owner>/statuses/<sha> -f context=codex-review -f state=success` before attempting any merge. If the POST fails (network, permissions, or unresolvable owner/SHA), the function returns 0 without merging — the PR stays open.
- `setup-branch-protection.sh --repo OWNER/REPO` (run once per managed repo by the operator) makes `codex-review` a required status check with `enforce_admins: true`. This means: (a) direct `git push origin main` is rejected, (b) `gh pr merge` without the status passes only if branch protection is configured, (c) implementation Claude cannot set this status (only `run_review_cycle` sets it).
- CI must still pass before auto-merge completes (`--auto` flag).

**Review checklist:**
- [x] `codex-review=success` status set before merge attempt — verified in `run_review_cycle`
- [x] POST failure leaves PR open rather than merging without the status
- [x] `enforce_admins: true` prevents operator-level bypasses
- [x] CI must still pass (`--auto` flag)
- [ ] **Remaining team-repo decision:** whether required human reviewer approval is also needed (GitHub branch protection `required_approving_review_count`). The status gate alone may not satisfy all team policies.

---

### 4. Telltale Regex Injection Risk (L3-mcp-resilience)

**Risk:** Attacker-controlled input in Codex output could manipulate telltale regex detection.

**Review checklist:**
- [ ] Confirm telltale regex patterns (line 484) are fixed strings, not user input
- [ ] Verify Codex output is captured from stdout/stderr, not constructed from variables
- [ ] Check if regex patterns could match benign error messages (false positive risk)
- [ ] Assess whether false positives cause wasteful retries or security issues (Answer: wasteful retries, not security)
- [ ] Determine if new Codex error messages could bypass detection (false negative risk)

**Telltale patterns (current, in `codex_review_with_retry`):**
```bash
mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'
```

**Recommendation:** 
- **Accept patterns as-is** — fixed strings, not injectable
- **Monitor for false negatives** — if new Codex MCP errors appear, update regex

**Action item 2: DONE.** The maintenance comment already exists verbatim in `codex_review_with_retry`:
```bash
# Telltale patterns for MCP transport failures. Update if Codex changes its error format.
# Monitored via the MCP outage rate KPI (see L3-mcp-resilience.md kill criteria: >30% → find alternative reviewer).
local mcp_re='Transport send error:|...'
```

---

### 5. Additional Security Considerations

#### 5.1 Command Injection (Cross-Cutting)

**Risk:** User-controlled input (PR numbers, commit messages) passed to shell commands.

**Review checklist:**
- [ ] Verify PR_NUMBER validation (line 864: `[[ "$pr_num" =~ ^[0-9]+$ ]]` — numeric only)
- [ ] Check git/gh command construction for proper quoting
- [ ] Audit Claude/Codex prompt assembly for command injection via `--append-system-prompt`
- [ ] Confirm temp files use mktemp (line 90-93: secure temp file creation)

**Recommendation:** Accept as-is. PR numbers are validated as numeric; temp files use mktemp; prompts are passed via stdin or --flag (not shell eval).

---

#### 5.2 Secrets Exposure

**Risk:** Logs contain sensitive data (API keys, tokens, commit messages with secrets).

**Review checklist:**
- [ ] Confirm logs are written to user home directory with user-only permissions (~/sisyphus-logs/)
- [ ] Verify Claude/Codex responses are logged (could contain code with hardcoded secrets)
- [ ] Check if gh CLI tokens are logged (Answer: No, gh handles auth internally)
- [ ] Assess log retention policy (Answer: Manual cleanup only, no automatic deletion)

**Recommendation:** 
- **Accept current behavior for personal use**
- **Add log rotation/cleanup** if multi-user deployment needed
- **Document log contents** in CLAUDE.md or README: "Logs may contain code and commit messages; treat as sensitive"

---

#### 5.3 Dependency Trust

**Risk:** External CLIs (claude, codex, gh, git) could be compromised or backdoored.

**Review checklist:**
- [ ] Confirm all CLIs are invoked by name (PATH lookup), not absolute paths
- [ ] Verify no curl | bash installation patterns in documentation
- [ ] Check if CLI version pinning is possible/recommended (Answer: No, use system-installed versions)
- [ ] Assess supply chain risk for each dependency:
  - `claude`: Anthropic official CLI, OAuth-based
  - `codex`: Community CLI, MCP-based (higher risk)
  - `gh`: GitHub official CLI, well-established
  - `git`: System-provided, trusted

**Recommendation:** 
- **Accept dependency trust model** for internal tool
- **Document installation sources** in README (official sources only)
- **Monitor Codex CLI security** — if project abandoned or compromised, switch to alternative reviewer

---

## Summary & Prioritization

| Finding | Severity | Status |
|---|---|---|
| Lock file race condition | Low | Accepted (rare, single-user scenario) |
| PR label race condition | Low | **Resolved** — fail-closed (`exit 1`), not warnings |
| Auto-merge approval | Medium | **Resolved** — `codex-review` status gate + `setup-branch-protection.sh` shipped in v1.1.0 |
| Telltale regex injection | Low | **Resolved** — maintenance comment added to source |
| Command injection | Low | Accepted (validated input, proper quoting) |
| Secrets exposure in logs | Low | Accepted for personal use, document log sensitivity |
| Dependency trust | Medium | Accepted, document installation sources, monitor Codex CLI |

**Remaining action items:**
1. ~~**Owner decision:** Auto-merge behavior~~ — resolved; optional follow-up: decide on `required_approving_review_count` for team repos
2. ~~Add telltale regex maintenance comment~~ — done
3. Document log sensitivity in README/CLAUDE.md (10-minute doc update) — still open

**Estimated remaining effort:** ~10 minutes (log sensitivity doc update)
