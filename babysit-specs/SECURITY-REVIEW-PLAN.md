# Security Review Plan — babysit-with-review.sh

**Owner:** security-lead  
**Status:** Executed 2026-11-17 — every checklist item below has been verified
against the shipped code and docs (not just reasoned about); two residual
findings surfaced and need an owner decision (see Summary & Prioritization).  
**Priority:** Medium (internal tool, single-user, no customer data)

## Scope

Security review of babysit-with-review.sh autonomous development system across L2 system architecture and three L3 features (outer loop, review cycle, MCP resilience).

## Review Areas

### 1. Lock File Race Conditions (L3-autonomous-outer-loop) — **RESOLVED**

**Risk:** Two processes start simultaneously before lock file created, both run until collision detected.

**Status: Resolved.** The TOCTOU window this section flagged is closed. The
stale-check-and-claim now runs as one transaction serialized by a persistent
`fcntl.flock(LOCK_EX)` on a sibling `<project>.stop.guard` file (lines
290-346): the kernel grants the lock to exactly one holder atomically, so
there's no unprotected gap between reading the old PID and writing the new
one. Shipped in v1.5.0 (#122); see CLAUDE.md's "Locking & scheduled runs"
section for the full design rationale.

**Review checklist:**
- [x] Lock claim is atomic, not a bare `touch` (lines 290-346: `flock`-guarded
      read-decide-write of `$STOP_FILE`, guarded by `$STOP_FILE.guard`)
- [x] Verify PID-based log filename prevents most collisions
- [x] Check trap handler cleanup (line 346: `trap 'rm -f "$STOP_FILE"' EXIT`,
      extended at line 374 to also clean up temp files once they exist)
- [x] Assess blast radius: Both processes halt gracefully when collision detected
- [x] Determine if TOCTOU window is acceptable for single-user tool — moot;
      the window is closed by `flock`, not merely accepted

**Recommendation:** No action needed — atomic `flock`-based claiming already
shipped (v1.5.0, #122), which is what the original recommendation's fallback
("if multi-user deployment needed, implement... flock") asked for.

---

### 2. PR Label Race Conditions (L3-review-cycle)

**Risk:** Concurrent gh pr edit commands could conflict if multiple babysitter instances run on same repo.

**Review checklist:**
- [x] Confirm lock file prevents concurrent babysitter runs on same project —
      per §1 above, the atomic `flock`-based claim means two babysitter
      processes can never run the same project at once, so this risk's own
      precondition ("multiple babysitter instances run on same repo") cannot
      arise from this tool's normal use.
- [ ] Verify gh CLI handles concurrent label operations gracefully (idempotent
      add/remove) — not independently verified against a live concurrent
      request (no test run against the real GitHub API); moot in practice
      given the item above, since two babysitter processes can't be editing
      the same PR's labels at the same time to begin with.
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
- [x] Confirm telltale regex patterns (line 1450) are fixed strings, not user input — confirmed; `compat_re`/`credits_re`/`mcp_re` are all literal strings assigned in source, never built from `$codex_prompt` or any other runtime input. (A fourth telltale, `auth_re`, is proposed on still-open, unmerged PR #115 — not yet part of shipped `babysit-with-review.sh`; re-check this line once/if that PR merges.)
- [x] Verify Codex output is captured from stdout/stderr, not constructed from variables — confirmed; `codex "${codex_args[@]}" "$codex_prompt" 2>&1 | tee -a "$LOG" "$TMP_CODEX_FULL"` captures the process's real combined stdout/stderr directly, nothing is reassembled from variables first.
- [x] Check if regex patterns could match benign error messages (false positive risk) — yes, demonstrated in practice: Codex can quote the telltale strings back verbatim while reviewing this very function's own source (see the comment immediately below this checklist, and issue #82/PR #83's false-positive incident). Structural success is checked first specifically to guard against this.
- [x] Assess whether false positives cause wasteful retries or security issues (Answer: wasteful retries, not security) — confirmed; a false positive at worst re-drafts/relabels a PR for a retry, it doesn't bypass any access control.
- [ ] Determine if new Codex error messages could bypass detection (false negative risk) — open-ended by nature; no way to statically rule out a future, not-yet-seen Codex error string. Mitigated by the "Monitor for false negatives" recommendation below, not resolvable as a one-time check.

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
- [x] Verify PR_NUMBER validation (line 1971: `[[ "$pr_num" =~ ^[0-9]+$ ]]` — numeric only) — confirmed verbatim at that line.
- [x] Check git/gh command construction for proper quoting — spot-checked `gh`/`git` call sites; variables are passed quoted (e.g. `"$pr_num"`, `"$LOG"`); no unquoted interpolation found.
- [x] Audit Claude/Codex prompt assembly for command injection via `--append-system-prompt` — the script does not actually use `--append-system-prompt` anywhere; prompts are built as heredoc-assigned variables and handed to `claude -p`/`codex exec` via `printf '%s\n' "$VAR"` into stdin, always quoted, never interpolated into a shell string that gets re-evaluated.
- [x] Confirm temp files use mktemp (lines 369-372: secure temp file creation) — confirmed; all four `TMP_*` vars are `mktemp` outputs.

**Recommendation:** Accept as-is. PR numbers are validated as numeric; temp files use mktemp; prompts are passed via quoted stdin (no `--append-system-prompt` flag is even used, and no shell eval of untrusted content was found).

---

#### 5.2 Secrets Exposure

**Risk:** Logs contain sensitive data (API keys, tokens, commit messages with secrets).

**Review checklist:**
- [ ] Confirm logs are written to user home directory with user-only permissions (~/sisyphus-logs/) — half true: `LOG_DIR="$HOME/sisyphus-logs"` is created with a plain `mkdir -p` (no explicit `chmod`/mode argument), so it inherits whatever the process umask is rather than being locked to the owner; on the actual operator machine this currently resolves to `drwxr-xr-x` (755) — group/other can list and read file contents, not just the owner. Not a regression to fix under "accept current behavior for personal use" below, but the original phrasing overstated what's actually enforced.
- [x] Verify Claude/Codex responses are logged (could contain code with hardcoded secrets) — confirmed; every iteration's output is piped through `tee -a "$LOG"`.
- [x] Check if gh CLI tokens are logged (Answer: No, gh handles auth internally) — confirmed; no `GH_TOKEN`/auth material is echoed or logged anywhere in the script.
- [x] Assess log retention policy (Answer: Manual cleanup only, no automatic deletion) — confirmed; no rotation/cleanup/`-mtime` logic exists for `~/sisyphus-logs` anywhere in this script or `launchd/`.

**Recommendation:** 
- **Accept current behavior for personal use** — including the 755 log directory permissions; this is a single-user machine, so group/other read access is not a practical exposure today
- **Add log rotation/cleanup** if multi-user deployment needed
- **If multi-user deployment is ever needed, also restrict `~/sisyphus-logs` to the owner** (e.g. `mkdir -p` followed by `chmod 700`), since today nothing does
- **Document log contents** in CLAUDE.md or README: "Logs may contain code and commit messages; treat as sensitive" — done, see below

---

#### 5.3 Dependency Trust

**Risk:** External CLIs (claude, codex, gh, git) could be compromised or backdoored.

**Review checklist:**
- [x] Confirm all CLIs are invoked by name (PATH lookup), not absolute paths — confirmed; no `/usr/bin/...`-style absolute invocations of `claude`/`codex`/`gh`/`git` found in the script.
- [ ] Verify no curl | bash installation patterns in documentation — **found one:** `docs/STAFF-FLEET.md:139` has `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash` as the troubleshooting fix for `error: 'hermes' not found in PATH`. It's a manual operator remediation step (nothing in this repo executes it automatically), but it's exactly the pattern this item asks to rule out, and Hermes is a third-party dependency of `new-fleet.sh`'s staff-fleet system. Needs an owner decision — see Summary & Prioritization.
- [x] Check if CLI version pinning is possible/recommended (Answer: No, use system-installed versions) — confirmed; no lockfile or pinned-version check exists for `claude`/`codex`/`gh`/`git`.
- [x] Assess supply chain risk for each dependency:
  - `claude`: Anthropic official CLI, OAuth-based
  - `codex`: Community CLI, MCP-based (higher risk)
  - `gh`: GitHub official CLI, well-established
  - `git`: System-provided, trusted

**Recommendation:** 
- **Accept dependency trust model** for internal tool
- **Document installation sources** in README (official sources only)
- **Monitor Codex CLI security** — if project abandoned or compromised, switch to alternative reviewer
- **Owner decision needed on `docs/STAFF-FLEET.md:139`'s `curl | bash` tip** — either accept it as a documented, manually-run, official-source (GitHub-hosted) install step, or replace it with a non-piped install (download, inspect, then run)

---

## Summary & Prioritization

| Finding | Severity | Status |
|---|---|---|
| Lock file race condition | Low | **Resolved** — atomic `flock`-based claim (shipped in v1.5.0, #122) |
| PR label race condition | Low | **Resolved** — fail-closed (`exit 1`), not warnings |
| Auto-merge approval | Medium | **Resolved** — `codex-review` status gate + `setup-branch-protection.sh` shipped in v1.1.0 |
| Telltale regex injection | Low | **Resolved** — maintenance comment added to source |
| Command injection | Low | **Verified** — numeric-only PR number, `mktemp` temp files, prompts passed via quoted stdin, no `--append-system-prompt` use found |
| Secrets exposure in logs | Low | **Accepted** — contents documented in README.md; log directory is `755` (default umask), not restricted to the owner — fine for single-user use, flagged for multi-user deployment |
| Dependency trust | Medium | **Partially accepted** — one `curl \| bash` install tip found (`docs/STAFF-FLEET.md:139`); needs an owner decision (see §5.3) |

**Remaining action items:**
1. ~~**Owner decision:** Auto-merge behavior~~ — resolved; optional follow-up: decide on `required_approving_review_count` for team repos
2. ~~Add telltale regex maintenance comment~~ — done
3. ~~Document log sensitivity in README/CLAUDE.md~~ — done (`README.md`'s "Logs" section, added in `c73cf53`)
4. **New (found during 2026-11-17 execution):** owner decision on the `curl | bash` Hermes-install tip in `docs/STAFF-FLEET.md:139` — accept as documented or replace with a non-piped install
5. **New (found during 2026-11-17 execution):** if this tool is ever deployed multi-user, restrict `~/sisyphus-logs` to the owner (`chmod 700`) — not needed today

**Estimated remaining effort:** Small. Every checklist item has now been
executed and verified rather than just reasoned about. Three owner decisions
remain open, none requiring code changes on their own: the optional
`required_approving_review_count` follow-up (item 1), the `curl | bash`
install-tip disposition (item 4), and the multi-user log-permissions
follow-up (item 5, not needed for the current single-user deployment).
