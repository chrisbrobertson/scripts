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
- [ ] Check if label application failures are logged and recoverable (lines 425-426, 456-457)
- [ ] Assess whether failed label operations block review cycle progress (Answer: No, logged as warnings)

**Recommendation:** Accept as-is. Lock file prevents concurrent runs; gh CLI label operations are idempotent; failures are non-blocking warnings.

---

### 3. Auto-Merge Approval (L3-review-cycle)

**Risk:** PRs auto-merge when BLOCKING=0 without additional human approval gate.

**Review checklist:**
- [ ] Confirm auto-merge only triggers after Codex review clears all BLOCKING findings (line 623)
- [ ] Verify CI must still pass before merge completes (`--auto` flag waits for CI)
- [ ] Check if manual approval can be enforced via GitHub branch protection rules (external to script)
- [ ] Assess blast radius: PR merges to default branch; reversible via revert commit
- [ ] Determine if organization policy requires human approval before merge (context-dependent)

**Recommendation:** 
- **Accept auto-merge for personal repos** where developer owns default branch
- **Add approval requirement for team repos**: Modify review cycle to skip auto-merge or require GitHub branch protection with required reviewers

**Code change (if approval needed):**
```bash
# Replace lines 623-629 with:
if [ "$n_blocking" -eq 0 ]; then
  echo "  [review] zero blocking findings; PR #$pr_num cleared after $cycle cycle(s)" | tee -a "$LOG" >&2
  gh pr ready "$pr_num" >>"$LOG" 2>&1 || true  # Mark ready, but don't merge
  echo "  [review] PR #$pr_num ready for human approval" | tee -a "$LOG" >&2
  return 0
fi
```

---

### 4. Telltale Regex Injection Risk (L3-mcp-resilience)

**Risk:** Attacker-controlled input in Codex output could manipulate telltale regex detection.

**Review checklist:**
- [ ] Confirm telltale regex patterns (line 484) are fixed strings, not user input
- [ ] Verify Codex output is captured from stdout/stderr, not constructed from variables
- [ ] Check if regex patterns could match benign error messages (false positive risk)
- [ ] Assess whether false positives cause wasteful retries or security issues (Answer: wasteful retries, not security)
- [ ] Determine if new Codex error messages could bypass detection (false negative risk)

**Telltale patterns:**
```bash
mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'
```

**Recommendation:** 
- **Accept patterns as-is** — fixed strings, not injectable
- **Monitor for false negatives** — if new Codex MCP errors appear, update regex
- **Document pattern maintenance** — add comment in code: "Update regex if Codex changes error format"

**Code change:**
```bash
# Add comment at line 484:
# Telltale patterns for MCP transport failures. Update if Codex error format changes.
# Monitored via MCP outage rate in L1 KPIs (threshold: >30% → escalate).
local mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'
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

| Finding | Severity | Recommendation |
|---|---|---|
| Lock file race condition | Low | Accept (rare, single-user scenario) |
| PR label race condition | Low | Accept (prevented by lock file) |
| Auto-merge approval | Medium | **Decision required:** Accept for personal repos OR add approval gate for team repos |
| Telltale regex injection | Low | Accept, add maintenance comment |
| Command injection | Low | Accept (validated input, proper quoting) |
| Secrets exposure in logs | Low | Accept for personal use, document log sensitivity |
| Dependency trust | Medium | Accept, document installation sources, monitor Codex CLI |

**Action items:**
1. **Owner decision:** Auto-merge behavior (accept as-is or add approval requirement)
2. Add telltale regex maintenance comment (5-minute code change)
3. Document log sensitivity in README/CLAUDE.md (10-minute doc update)

**Estimated effort:** 2-4 hours (review) + 15 minutes (code/doc changes if needed)
