---
spec_type: feature
id: ARLO-FEAT-REVIEW-CYCLE
status: review
owners: [Chris Robertson]
depends_on: [ARLO-SYS-AUTONOMOUS-DEV, ARLO-FEAT-MCP-RESILIENCE]
parent_l1: ARLO-PROD-BABYSIT-WITH-REVIEW
parent_l2: ARLO-SYS-AUTONOMOUS-DEV
fit_check: passed
complexity:
  total: 2
  band: trivial
  drivers: [novelty, time_estimate]
  scored_on: 2026-06-28
---

# Frame

## TL;DR
Iterative review cycle (reviewer and implementer are independently selectable) that reviews PR code, feeds findings to the implementer for fixes, tracks convergence across cycles, and switches to prescriptive mode after cycle 3 to force concrete fix suggestions. When all BLOCKING findings are cleared, the wrapper sets a `codex-review=success` GitHub commit status and then merges — the status gate (enforced by `setup-branch-protection.sh`) is what actually prevents self-merge.

## Analog
Like a pull request review process with two reviewers: Codex (strict code reviewer) and Claude (implementer), iterating until all blocking issues are resolved or max cycles exhausted.

## Reader & next action
Implementing engineer: understand review cycle state machine, convergence tracking, and prescriptive mode trigger. QA: verify cycle termination conditions and label application.

## API surface fragment
```bash
# Triggered by outer loop when HANDOFF_REVIEW sentinel detected
run_review_cycle <PR_NUMBER>

# Codex review output format (strict markdown)
## BLOCKING
- <issue> — <file:line> — <reason>
  Suggested fix: <concrete code> (prescriptive mode only, cycle 3+)
  Root cause: <why this gap exists> (detailed mode, cycle 3+)
  Architectural context: <how this fits into system> (detailed mode, cycle 3+)
  Impact: <what breaks if not fixed> (detailed mode, cycle 3+)

## RECOMMENDED
- <issue> — <file:line> — <reason>

## INFORMATION
- <issue> — <file:line> — <context>

# Claude review sentinels
DONE_REVIEW                    # addressed findings, ready for next Codex pass
STUCK_REVIEW <reason>          # cannot proceed, bail review cycle

# Claude inline planning (cycle 2+, prompt-instructed)
# Prompts instruct Claude to plan inline (as text output) before implementing.
# Plan mode tool is explicitly forbidden — non-interactive runs cannot exit it.
# Plan output includes: steps, order, rationale, dependencies

# Claude commit message format (cycle 2+)
fix(<scope>): <what changed>

Why: <rationale explaining trade-offs, alternatives, constraints>
Impact: <failure mode addressed — metrics or observability>

# PR labels applied by cycle
review-incomplete              # human action required (stuck, max cycles, etc.)
review-mcp-outage             # Codex MCP transport failure (auto-retry)
review-codex-outdated         # Codex CLI too old for configured model; run `codex update`, remove label, restart
review-codex-no-credits        # Codex workspace out of credits; add credits, remove label, restart

# Cycle state (not exposed, internal to run_review_cycle)
REVIEW_HISTORY=()             # array of prior Codex reviews
review_start_sha              # git SHA at cycle start (for commit tracking)
JUSTIFICATIONS=""             # Claude's resolution justifications from previous cycle (cycle 5+)
# Template selected by cycle number: 8 prompts (4 Codex + 4 Claude), see prompt constants section
```

## Consumer
Orchestrator (babysit-with-review.sh outer loop) invoking run_review_cycle() function.

# Substance

## What we know
From implementation (babysit-with-review.sh):
- Cycle limit: MAX_REVIEW_CYCLES (default 6)
- Early exit conditions: BLOCKING=0, STUCK_REVIEW sentinel, HEAD unchanged after implementer pass
- Convergence tracking: cycle 2+ includes prior reviews + git log of implementer commits
- Prescriptive mode: cycle 3+ uses template requiring "Suggested fix:" for BLOCKING
- PR feedback collection: reviews, comments, inline comments (filtered to exclude self-posted — three prefixes: `**Codex review`, `**Claude review`, `**babysit-with-review:`)
- **Merge gate (codex-review status):** when BLOCKING=0, the wrapper first POSTs `gh api -X POST repos/<owner>/statuses/<sha> -f context=codex-review -f state=success` via `gh api`. If the POST fails, or owner/repo or head SHA cannot be resolved, it logs a WARNING and returns 0 *without merging*. Only after a successful status POST does it attempt `gh pr merge --squash --delete-branch --auto`, falling back to an immediate merge. `setup-branch-protection.sh` makes `codex-review` a required status check with `enforce_admins: true`; this is the actual mechanism that prevents implementation Claude from self-merging.
- **Graceful degradation:** if the selected reviewer binary is not installed, skip the review cycle (logged) and return 0.
- **Reviewer pre-flight probe (`reviewer_preflight`):** before the cycle loop, `run_review_cycle` calls `reviewer_preflight`. For Codex it runs `codex exec -s read-only "Say 'ok'."` with the configured model/effort, checks only `compat_re` and `credits_re` (no structural validation), and returns 3/4/1/0. For Claude, `reviewer_preflight` is a no-op (returns 0 immediately). If the probe returns 3, `run_review_cycle` calls `fail_review_cycle_codex_outdated` and returns 3. If it returns 4, it calls `fail_review_cycle_codex_no_credits` and returns 4. Any other non-zero calls `fail_review_cycle` and returns 0.
- **Structural validation:** `review_with_retry` (via `valid_review_structure` in ARLO-FEAT-MCP-RESILIENCE) returns 0 only when TMP_REVIEW passes the full contract (see L3-mcp-resilience for the exact awk rules). A structurally invalid output with rc=0 is treated as failure (return 1).
- **`fail_review_cycle` is fail-closed for labelling/draft commands:** `gh pr ready --undo` and `gh pr edit --add-label` failures abort the babysitter (`exit 1`). `gh pr comment` (posting the bail reason) remains best-effort.
- **`fail_review_cycle_codex_outdated`:** labels PR `review-codex-outdated`, marks draft, posts upgrade instructions comment, calls `exit 1`.
- **`fail_review_cycle_codex_no_credits`:** labels PR `review-codex-no-credits`, marks draft, posts add-credits instructions comment, calls `exit 1`.

**Historical note:** Before 2026-05-28, non-transport Codex failures did not call `fail_review_cycle`. PRs remained OPEN/non-draft, allowing the outer loop to merge them without review. The current code calls `fail_review_cycle` for all non-transport failures.

**Escalating cycle behavior (implemented 2026-06-29 via `01f089d`):**
- **Inline-plan-first on cycle 2+:** implementer outputs its plan as text before making changes — plan mode tool is explicitly forbidden (non-interactive, cannot exit without human approval)
- **Detailed explanations on cycle 3–4+:** reviewer provides deeper reasoning about why each gap exists, architectural context, and impact (prescriptive + detailed template)
- **Solution rationale (cycle 2+):** implementer documents why each fix was implemented via Why: and Impact: blocks in commit messages
- **Resolution justification on cycle 4+:** implementer posts a PR comment justifying each BLOCKING finding (resolved or invalid)
- **Adjudication on cycle 5–6:** reviewer adjudicates implementer's justifications; DISAGREED findings reappear as [RECURRENCE] in BLOCKING

## What we assume
- [ASSUMPTION] Codex review quality improves with prescriptive mode (cycle 3+). Flips if: prescriptive mode increases false positive rate, requiring mode to be optional or removed.
- [ASSUMPTION] Auto-merge on BLOCKING=0 is safe. Flips if: additional human sign-off is required, needing approval workflow integration.
- [ASSUMPTION] PR feedback filtering (exclude self-posted) is sufficient. Flips if: more sophisticated deduplication is needed (e.g., semantic similarity).
- [ASSUMPTION] Six cycles is adequate convergence budget. Flips if: complex PRs need more cycles, requiring dynamic limit based on PR size.
- [ASSUMPTION] Plan-first approach on cycle 2+ improves fix quality and reduces trial-and-error. Flips if: planning overhead exceeds benefit, or plan mode introduces latency that slows convergence.
- [ASSUMPTION] Detailed Codex explanations on cycle 3–4+ help Claude understand root causes better. Flips if: explanation verbosity confuses Claude or increases false positive rate.
- [ASSUMPTION] Solution rationale in commit messages aids future review cycles and human understanding. Flips if: Claude over-explains trivial fixes and bloats commit history.

## Contract

### Request shape (function arguments)
```bash
run_review_cycle <PR_NUMBER>
# PR_NUMBER: integer, must be valid open PR in current repo
```

### Response shape (return codes)
`run_review_cycle` returns (never calls `exit` itself):
- **0:** Cycle completed — BLOCKING=0 and merged, BLOCKING=0 but status POST failed (left open), graceful bail with label, or reviewer binary not found
- **2:** MCP transport failure after retries (Codex reviewer only; caller logs "Halting:" and breaks outer loop)
- **3:** Reviewer version incompatibility — `fail_review_cycle_codex_outdated` was called (which calls `exit 1`), so this code is only visible if that function's gh commands succeed
- **4:** Reviewer credits exhausted — `fail_review_cycle_codex_no_credits` was called (which calls `exit 1`), same caveat

`exit 1` (babysitter-level halt, not a return code) fires when:
- `fail_review_cycle*` gh label/draft commands fail
- `fail_review_cycle_codex_outdated` or `fail_review_cycle_codex_no_credits` complete successfully (they always call `exit 1`)

### Invariants
1. **Cycle order:** reviewer-binary check → `reviewer_preflight` → `gh pr checkout` → capture `review_start_sha` → (cycle loop) reviewer pass → implementer pass → repeat
2. **Convergence tracking:** Cycle N includes all prior reviews (1..N-1) and commits since cycle start
3. **Prescriptive mode trigger:** Cycle 3+ always uses prescriptive prompt template with "Suggested fix:" requirement
4. **Inline-plan-first trigger:** Cycle 2+ with BLOCKING issues instructs the implementer to plan inline (as text output) before implementing — plan mode tool is forbidden
5. **Detailed explanation trigger:** Cycle 3–4+ reviewer reviews include deeper reasoning and architectural context for each finding
6. **Solution rationale:** Implementer documents implementation rationale for each fix via Why: and Impact: blocks in commit messages (cycle 2+)
7. **Explicit resolution justification:** Cycle 4+ requires the implementer to explicitly justify how each BLOCKING finding was resolved or prove it is invalid with supporting references
8. **Adjudication:** Cycle 5–6 requires the reviewer to accept or provide reasoned disagreement for each of the implementer's resolution justifications from the previous cycle
9. **BLOCKING counting:** Only bullets under `## BLOCKING` that are not `- (none)` count. Structural validation is a pre-condition (see `valid_review_structure` in ARLO-FEAT-MCP-RESILIENCE): invalid output is a reviewer failure, not a zero-findings pass.
10. **PR branch checkout:** Cycle starts by checking out PR branch via `gh pr checkout <PR_NUMBER>`
11. **Label application:** `review-incomplete` for human-action bails, `review-mcp-outage` for transport failures, `review-codex-outdated` for backend compatibility failures, `review-codex-no-credits` for credit exhaustion
12. **Fail-closed labelling:** `fail_review_cycle` gh label/draft commands abort the babysitter on failure; only the follow-up `gh pr comment` is best-effort
13. **Merge gate:** BLOCKING=0 alone does not merge. The wrapper first POSTs `codex-review=success` via `gh api`. Failure to POST leaves the PR open. Only after a successful POST does merge proceed.

### Error model
- **Pre-flight probe: `compat_re` match:** Label PR `review-codex-outdated`, post upgrade instructions comment, `exit 1` (halts babysitter). Note: probe checks only `compat_re` and `credits_re`, not structural validity.
- **Pre-flight probe: `credits_re` match:** Label PR `review-codex-no-credits`, post add-credits instructions comment, `exit 1` (halts babysitter)
- **Pre-flight probe: non-zero, no telltale match:** Label PR `review-incomplete` (fail-closed), return 0
- **MCP transport failure from `review_with_retry`:** Retried by ARLO-FEAT-MCP-RESILIENCE (3× with backoff), if all fail → return 2
- **Reviewer backend compatibility failure (return 3 from `review_with_retry`):** Label PR `review-codex-outdated`, `exit 1` (halts babysitter)
- **Reviewer credit exhaustion (return 4 from `review_with_retry`):** Label PR `review-codex-no-credits`, `exit 1` (halts babysitter)
- **Reviewer non-transport failure (return 1):** Label PR `review-incomplete` (fail-closed), return 0
- **`count_blocking` produces non-integer:** Log FATAL, label PR `review-incomplete` (fail-closed), return 0
- **Implementer non-zero exit:** Label PR `review-incomplete` (fail-closed), return 0
- **`gh pr checkout` failure:** Label PR `review-incomplete` (fail-closed), return 0
- **HEAD unchanged after implementer `DONE_REVIEW`:** Label PR `review-incomplete` (fail-closed), return 0
- **MAX_REVIEW_CYCLES exhausted:** Label PR `review-incomplete` (fail-closed), return 0
- **`STUCK_REVIEW` sentinel:** Label PR `review-incomplete` (fail-closed), return 0
- **`codex-review` status POST fails or owner/SHA unresolvable:** Log WARNING, return 0 without merging (PR stays open)
- **`fail_review_cycle` gh label/draft command failure:** `exit 1` (babysitter halts; PR must be manually quarantined)

### Idempotency
Non-idempotent. Each cycle advances PR branch state (commits pushed). Re-running on same PR resumes from current state, not cycle 1.

### Versioning policy
Function is internal to script; no versioning. Breaking changes (sentinel format, label names) require manual migration.

### Cycle behavior

**Cycle 1 (baseline):**
- Codex reviews PR with descriptive template (BLOCKING / RECOMMENDED / INFORMATION)
- Claude addresses findings directly (no plan mode)
- Commits include standard messages ("fix(blocking): handle nil session")

**Cycle 2+ with BLOCKING issues (inline-plan-first with rationale and impact):**
- Reviewer reviews PR with descriptive template + convergence history
- **Implementer plans inline (as text output):** Lists findings and dependencies, determines fix order, notes trade-offs — plan mode tool is forbidden (non-interactive, cannot exit without human approval)
- **Implementer executes plan:** Implements each step sequentially, committing after each
- **Solution rationale and impact:** Each commit message includes "Why:" (trade-offs/alternatives) and "Impact:" (failure mode addressed)
  - Example: `fix(blocking): add null check in auth middleware\n\nWhy: Session can be null during logout flow. Considered moving check to caller, but middleware is the right boundary for this validation (single responsibility).\nImpact: Prevents 500 errors on ~5% of logout attempts.`

**Cycle 3+ with BLOCKING issues (prescriptive reviewer with detailed explanations):**
- **Reviewer uses prescriptive template:** Requires "Suggested fix:" with concrete code for each BLOCKING finding
- **Reviewer adds detailed explanations:** For each finding, includes:
  - **Root cause:** Why this gap exists (e.g., "Missing null check introduced in PR #456 when logout flow was refactored")
  - **Architectural context:** How this fits into the larger system (e.g., "Auth middleware is the trust boundary between public routes and protected resources")
  - **Impact:** What breaks if not fixed (e.g., "500 error on logout when session has already expired; affects ~5% of logout attempts per telemetry")
- **Implementer continues inline-plan-first with rationale and impact:** Same commit format as cycle 2+ (Why + Impact), but now informed by the reviewer's detailed explanations

**Cycle 4 with BLOCKING issues (explicit resolution justification):**
- **All cycle 3+ behaviors continue** (reviewer prescriptive + detailed, implementer inline-plan-first, solution rationale)
- **Implementer must explicitly address each BLOCKING finding** at end of cycle with one of:
  - **Resolution:** "BLOCKING <finding-description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how the change addresses the root cause and satisfies the architectural constraints>"
  - **Invalid finding:** "BLOCKING <finding-description> is invalid. Reason: <explanation>. Supporting reference: <link to spec, documentation, or validated source material proving the finding is incorrect>"
- **Format:** Added as comment to PR after implementer completes fixes, before DONE_REVIEW sentinel
- **Purpose:** Forces the implementer to demonstrate understanding of each finding and its resolution; prevents false "done" claims

**Cycle 5+ with BLOCKING issues (adjudication + implementer re-processing):**
- **Reviewer receives implementer's resolution justifications** (from the cycle 4+ PR comment) and must respond to each:
  - **If implementer claimed "resolved":** Reviewer re-examines code at the referenced commit. Either accepts ("ACCEPTED: <one-line confirmation>") or disagrees ("DISAGREED: <reasoned explanation of why the fix does not address the root cause or architectural constraint>")
  - **If implementer claimed "invalid":** Reviewer evaluates the reasoning and supporting reference. Either accepts ("ACCEPTED: finding withdrawn") or disagrees ("DISAGREED: <counter-argument with code-level evidence>")
- **Adjudication is a section in the reviewer output** (appears *before* BLOCKING/RECOMMENDED/INFORMATION):
  ```
  ## ADJUDICATION
  - BLOCKING <finding-description>: ACCEPTED — <confirmation>
  - BLOCKING <finding-description>: DISAGREED — <reasoned counter-argument with code evidence>
  ```
- **Implementer processes adjudication:** For any DISAGREED items, implementer must either:
  - Implement a different fix that addresses the counter-argument, OR
  - Escalate via STUCK_REVIEW with the specific finding and disagreement reason
- **Purpose:** Creates a structured debate that resolves ambiguous findings through evidence rather than repetition

**Benefits:**
- **Inline-plan-first (cycle 2+):** Reduces trial-and-error, ensures fixes are applied in correct order, catches cross-finding dependencies — without the human-approval block of plan mode
- **Detailed reviewer explanations (cycle 3+):** Helps the implementer understand *why* issues exist, not just *what* to fix; improves fix quality by surfacing architectural constraints
- **Solution rationale (cycle 2+):** Aids future reviewers (human or AI) in understanding decisions; creates better commit history
- **Explicit resolution justification (cycle 4+):** Forces the implementer to prove understanding of each finding; prevents false convergence claims; creates audit trail
- **Adjudication (cycle 5+):** Resolves ambiguous or disputed findings through structured debate; prevents infinite loops; creates clear accept/disagree record

**Costs:**
- **Inline planning overhead:** ~10-30 seconds per cycle 2+ (planning text before execution)
- **Detailed explanations:** +10-20% reviewer inference time (more tokens in/out)
- **Rationale overhead:** +10-15% implementer time (composing explanations)
- **Resolution justification overhead:** +15-30 seconds per cycle 4+ (posting PR comment via gh CLI)
- **Adjudication overhead:** +20-40% reviewer time for cycle 5+ (reading justifications + reasoning)
- **Total impact:** Cycle 2+ takes ~4-5 minutes (vs. 4 minutes baseline); Cycle 3+ takes ~6-7 minutes; Cycle 4 takes ~7-8 minutes; Cycle 5+ takes ~8-10 minutes

## Performance budget

- **p50 cycle latency:**
  - Cycle 1: ~4 minutes (reviewer ~1min + implementer fixes ~3min)
  - Cycle 2-3: ~4-5 minutes (+inline planning: ~10-30s, negligible vs. cycle 1)
  - Cycle 3-4: ~6-7 minutes (+detailed explanations: 10-20% reviewer time)
  - Cycle 4: ~7-8 minutes (+resolution justification: 15-30s for PR comment)
  - Cycle 5-6: ~8-10 minutes (+adjudication: 20-40% Codex time for reasoning about justifications)
- **p95 cycle latency:** ~22-25 minutes (plan mode + detailed explanations + justification + adjudication + complex diffs)
- **p99 cycle latency:** ~45 minutes (retries + all enhancements + large changesets)
- **Cost per cycle:**
  - Cycle 1: ~$1-3
  - Cycle 2-3: ~$1.50-4 (+plan mode tokens)
  - Cycle 3-4: ~$2-5 (+detailed explanation tokens)
  - Cycle 4: ~$2.50-5.50 (+resolution justification tokens)
  - Cycle 5-6: ~$3-7 (+adjudication tokens — Codex reasoning about justifications + Claude processing disagreements)

## Security model
- **AuthN / AuthZ:** Inherits from gh CLI (`gh auth status`) and Codex CLI (Codex MCP auth)
- **Tenant isolation:** N/A (single-user tool)
- **PII handling:** None (operates on code diffs, commit messages, PR metadata)
- **Rate limits:** Bounded by MAX_REVIEW_CYCLES; Codex/Claude rate limits handled by respective CLIs

## Prompt templates

Each cycle uses a complete, deterministic prompt with NO conditional logic or template variables. The bash orchestrator selects which prompt constant to use based on cycle number, then performs literal string replacement for runtime values (PR number, review text, history).

**String replacement markers** (bash performs literal string substitution before sending to CLI; `${...}` forms are NOT used — they would be expanded by bash inside the heredoc):
- `__PR_NUMBER__` → actual PR number
- `__CYCLE__` → current cycle number
- `__MAX_CYCLES__` → configured max (default 6)
- `__HISTORY__` → prior reviews + commits (cycles 2+)
- `__PR_FEEDBACK__` → collected PR comments/reviews
- `__REVIEW__` → reviewer output from current cycle
- `__JUSTIFICATIONS__` → implementer's resolution justifications from previous cycle (cycles 5+)

### Codex prompt: Cycle 1
```
You are performing a code review on PR #${PR_NUM} for this repository. The PR branch is currently checked out.

This is review cycle 1 of ${MAX_CYCLES}. This is the first review of this PR.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

Output your review using EXACTLY this format:

## BLOCKING
- <one-line description> — <file:line> — <why it must be fixed before merge>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Format rules:
- BLOCKING, RECOMMENDED, and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
```

### Codex prompt: Cycle 2
```
You are performing a code review on PR #${PR_NUM} for this repository. The PR branch is currently checked out.

This is review cycle 2 of ${MAX_CYCLES}. The previous cycle did not fully resolve BLOCKING issues.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
${HISTORY}
--- cycle history end ---

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line> — <why it must be fixed before merge>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Convergence tracking:
- Mark each BLOCKING finding with [NEW] if it was not flagged in previous cycles, or [RECURRENCE] if it was flagged before but remains unresolved.

Format rules:
- BLOCKING bullets start with [NEW|RECURRENCE] tag, followed by single-line description.
- RECOMMENDED and INFORMATION are single-line bullets only (no tags).
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
```

### Codex prompt: Cycles 3-4 (prescriptive + detailed)
```
You are performing a code review on PR #${PR_NUM} for this repository. The PR branch is currently checked out.

This is review cycle ${CYCLE} of ${MAX_CYCLES}. Multiple previous cycles have not resolved BLOCKING issues. This cycle uses prescriptive mode with detailed explanations.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
${HISTORY}
--- cycle history end ---

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line> — <why it must be fixed before merge>
  Suggested fix: <concrete code change — show the exact replacement or patch sketch>
  Root cause: <why this gap exists — when/how introduced, what changed>
  Architectural context: <how this component fits into the system, what boundaries it enforces>
  Impact: <what breaks if not fixed — user-facing symptoms, error rates, affected flows>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Prescriptive mode requirements:
- Each BLOCKING finding MUST include all four parts: suggested fix, root cause, architectural context, impact.
- If you cannot produce all four parts for a finding, downgrade it to RECOMMENDED.
- Suggested fix must be concrete code showing the exact change needed.

Convergence tracking:
- Mark each BLOCKING finding with [NEW] if it was not flagged in previous cycles, or [RECURRENCE] if it was flagged before but remains unresolved.

Format rules:
- BLOCKING bullets are multi-line with four required sub-bullets (suggested fix, root cause, architectural context, impact).
- RECOMMENDED and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
```

### Codex prompt: Cycles 5-6 (prescriptive + detailed + adjudication)
```
You are performing a code review on PR #${PR_NUM} for this repository. The PR branch is currently checked out.

This is review cycle ${CYCLE} of ${MAX_CYCLES}. Multiple previous cycles have not resolved BLOCKING issues. Claude posted resolution justifications for the previous cycle's findings. You must adjudicate those justifications AND review the current code state.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
${HISTORY}
--- cycle history end ---

--- Claude's resolution justifications (from previous cycle) begin ---
${JUSTIFICATIONS}
--- Claude's resolution justifications end ---

You have two responsibilities this cycle:

RESPONSIBILITY 1: Adjudicate Claude's resolution justifications.
For each justification Claude posted, you must respond:
- If Claude claimed a finding is "resolved": examine the referenced commit and the current code. Either the fix genuinely addresses the root cause and architectural constraints, or it does not.
- If Claude claimed a finding is "invalid": evaluate the reasoning and the cited supporting reference. Either the reference proves the finding incorrect, or it does not.

RESPONSIBILITY 2: Review the current code state for any remaining or new issues (same as previous cycles).

Output your review using EXACTLY this format:

## ADJUDICATION
- BLOCKING <one-line finding from previous cycle>: ACCEPTED — <one-line confirmation that the fix/invalidity argument is sound>
- BLOCKING <one-line finding from previous cycle>: DISAGREED — <reasoned explanation with code-level evidence of why the fix does not resolve the issue or why the finding remains valid>

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line> — <why it must be fixed before merge>
  Suggested fix: <concrete code change — show the exact replacement or patch sketch>
  Root cause: <why this gap exists — when/how introduced, what changed>
  Architectural context: <how this component fits into the system, what boundaries it enforces>
  Impact: <what breaks if not fixed — user-facing symptoms, error rates, affected flows>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, suggestion, or fyi>

Categorization rules:
- BLOCKING = correctness bugs, security issues, broken tests, build failures, contract violations, broken invariants — anything that should not merge.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, doc gaps, error-handling gaps. Should be addressed but not strictly blocking.
- INFORMATION = stylistic notes, alternative approaches, performance observations, fyi context. Optional.

Adjudication rules:
- You MUST adjudicate every justification Claude posted. No justification may be silently ignored.
- ACCEPTED means you agree the finding is resolved or invalid — it will not recur in future reviews.
- DISAGREED means the finding remains unresolved — it MUST appear in your BLOCKING section as [RECURRENCE] with an updated suggested fix that addresses your counter-argument.
- Your disagreement must include specific code-level evidence (file:line references, logic traces, or behavioral analysis). Generic disagreements ("this doesn't look right") are not acceptable.

Prescriptive mode requirements:
- Each BLOCKING finding MUST include all four parts: suggested fix, root cause, architectural context, impact.
- If you cannot produce all four parts for a finding, downgrade it to RECOMMENDED.
- Suggested fix must be concrete code showing the exact change needed.

Convergence tracking:
- Mark each BLOCKING finding with [NEW] if it was not flagged in previous cycles, or [RECURRENCE] if it was flagged before but remains unresolved.

Format rules:
- ADJUDICATION section comes first, before BLOCKING/RECOMMENDED/INFORMATION.
- BLOCKING bullets are multi-line with four required sub-bullets (suggested fix, root cause, architectural context, impact).
- RECOMMENDED and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT make code changes. This is review only.
```

### Claude prompt: Cycle 1
```
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 1 of __MAX_CYCLES__. This is the first review of this PR.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

Implementation:
- Address all BLOCKING findings with minimal, targeted changes.
- Run relevant tests after each fix.
- Commit each fix separately using standard format: fix(<scope>): <what changed>
- Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next review cycle and performs the merge once it passes.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before outputting DONE_REVIEW, run the full test suite and verify no new surface introduced.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- codex review begin ---
__REVIEW__
--- codex review end ---
```

### Claude prompt: Cycles 2-3 (inline-plan-first)
```
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. The previous cycle(s) did not fully resolve BLOCKING issues.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Plan your approach BEFORE implementing.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit. Instead, plan inline:

Step 1: Analyze and outline your approach (as text output):
  - List all BLOCKING findings and their dependencies
  - Determine the correct order to address them (some fixes may depend on others)
  - Identify any cross-finding interactions or shared root causes
  - Note trade-offs and alternatives for non-obvious decisions

Step 2: Execute your plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next review cycle and performs the merge once it passes.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before outputting DONE_REVIEW, run the full test suite and verify no new surface introduced.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- codex review begin ---
__REVIEW__
--- codex review end ---
```

### Claude prompt: Cycle 4 (inline-plan-first + resolution justification)
```
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 4 of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Plan your approach BEFORE implementing.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit. Instead, plan inline:

Step 1: Analyze and outline your approach (as text output):
  - List all BLOCKING findings and their dependencies
  - Determine the correct order to address them (some fixes may depend on others)
  - Identify any cross-finding interactions or shared root causes
  - Note trade-offs and alternatives for non-obvious decisions

Step 2: Execute your plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next review cycle and performs the merge once it passes.

Step 3: Post resolution justification as PR comment:
  For EACH BLOCKING finding in the review, you must post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by Codex and satisfies the architectural constraints>"
  - If invalid: "BLOCKING <one-line finding description> is invalid. Reason: <explanation>. Supporting reference: <link to spec/docs/validated source proving the finding is incorrect>"

  Use `gh pr comment __PR_NUMBER__ --body "<text>"` to post the justification.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before Step 3, run the full test suite and verify no new surface introduced.
- Step 3 is MANDATORY before DONE_REVIEW.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address AND posted resolution justifications)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- codex review begin ---
__REVIEW__
--- codex review end ---
```

### Claude prompt: Cycles 5-6 (inline-plan-first + resolution justification + adjudication)
```
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. The reviewer has adjudicated your previous resolution justifications.

You MUST action every BLOCKING finding before this PR can merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Process the ADJUDICATION section first, then plan your approach inline.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit.

Step 1: Process adjudication results:
  - For each ACCEPTED item: the finding is resolved. No further action needed.
  - For each DISAGREED item: the reviewer has provided a reasoned counter-argument with code evidence. You must either:
    (a) Implement a different fix that specifically addresses the counter-argument, OR
    (b) If you believe the counter-argument is itself incorrect, report via STUCK_REVIEW with the specific finding, the argument, and why you disagree (this escalates to human review).

Step 2: Outline your implementation plan (as text output) for all remaining BLOCKING findings:
  - Include all DISAGREED items that you will re-address (from Step 1a)
  - Include all new BLOCKING findings from the current review
  - Determine the correct order to address them
  - Note trade-offs and alternatives for non-obvious decisions

Step 3: Execute your plan:
  - Implement each step sequentially
  - Run relevant tests after each fix
  - Commit each fix separately with this format:
    fix(<scope>): <what changed>

    Why: <rationale explaining trade-offs, alternatives considered, constraints>
    Impact: <failure mode addressed — metrics or observability>
  - Push commits to PR branch when complete. Do NOT merge the PR — the wrapper merges after re-review.

**Merge policy (non-negotiable):**
- Only merge a PR after ALL blockers identified in the reviews have been handled.
- YOU MUST NEVER MERGE A PR THAT HAS NOT BEEN REVIEWED. Never run `gh pr merge` yourself — push your fixes and end with `DONE_REVIEW`; the wrapper runs the next review cycle and performs the merge once it passes.

Step 4: Post resolution justification as PR comment:
  For EACH BLOCKING finding (including DISAGREED items you re-addressed), post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause and satisfies the architectural constraints>"
  - If invalid: "BLOCKING <one-line finding description> is invalid. Reason: <explanation>. Supporting reference: <link to spec/docs/validated source proving the finding is incorrect>"
  - If re-addressed after disagreement: "BLOCKING <one-line finding description> re-addressed after disagreement. Previous fix was insufficient because: <acknowledge the reviewer's point>. New fix in commit <SHA>: <explanation of how new approach resolves the concern>"

  Use `gh pr comment __PR_NUMBER__ --body "<text>"` to post the justification.

Scope discipline:
- Make minimal, targeted changes. Do NOT refactor adjacent code unless required by a finding.
- Each finding gets its own commit.
- Before Step 4, run the full test suite and verify no new surface introduced.
- Step 4 is MANDATORY before DONE_REVIEW.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address AND posted resolution justifications)
- STUCK_REVIEW <one-line reason> (you cannot proceed — use this if the reviewer's disagreement is itself incorrect and needs human review)

--- existing PR feedback begin ---
__PR_FEEDBACK__
--- existing PR feedback end ---

--- codex review begin ---
__REVIEW__
--- codex review end ---
```
## Telemetry contract

**Events emitted** (role-prefixed; `$REVIEWER` and `$IMPLEMENTER` are substituted at runtime):
- `[review] marking PR #N incomplete: <reason>` (via `fail_review_cycle`)
- `[review] codex MCP outage for PR #N: <reason>` (via `fail_review_cycle_mcp`)
- `[$REVIEWER reviewer] reviewing PR #N...` (per cycle, before reviewer invocation)
- `[$REVIEWER reviewer] adjudication: N accepted, M disagreed` (cycle 5+, after reviewer pass)
- `[$REVIEWER reviewer] N blocking finding(s)` (per cycle)
- `[review] FATAL: count_blocking produced non-integer ('<value>'); bailing to prevent spurious merge`
- `[review] zero blocking findings; PR #N cleared after M cycle(s)` (success)
- `[review] codex-review status set to success for <sha8>` (after successful status POST)
- `[review] WARNING: failed to set codex-review status for PR #N; leaving PR open rather than merging without the status check`
- `[review] WARNING: could not resolve repo or head SHA for PR #N; leaving PR open rather than merging without the status check`
- `[review] PR #N queued for auto-merge (merges when CI passes)` or `[review] PR #N merged.` (merge success)
- `[$REVIEWER reviewer] template=<descriptive-baseline|descriptive-convergence|prescriptive-detailed|prescriptive-adjudication> cycle=M/N` (mode tracking)
- `[claude] resolution justifications posted to PR #N` (cycle 4+ — after `gh pr comment` succeeds)

**Sinks:** Main log file (~/sisyphus-logs/<project>-<timestamp>-<pid>.log)

**Linkage to L1 KPIs:**
- Quality KPI: (PRs merged with BLOCKING=0 / total PRs) = quality gate pass rate
- Productivity KPI: Average cycles-per-PR (lower = better convergence)
- Reliability KPI: (MCP outage failures / total cycles) = Codex availability
- Inline-plan effectiveness KPI: (PRs converging in cycle 2 with inline plan / PRs converging in cycle 2 without inline plan)
- Explanation value KPI: (cycle 3+ fix accuracy / cycle 1-2 fix accuracy) — measures if detailed explanations improve fixes

**AEAB-eligible eval cases:** N/A (no eval framework yet)

## Verifiers
- Tech lead: Chris Robertson
- API council / platform review: N/A (internal function)
- Security: PR label race conditions accepted (lock file prevents concurrent runs; gh label ops idempotent). Auto-merge requires `codex-review=success` status (enforced by `setup-branch-protection.sh`). See SECURITY-REVIEW-PLAN.md §2–3.
- QA: Test cases documented in QA-TEST-PLAN.md (TC-2.*). Test harness exists: `BABYSIT_TEST_MODE` + `test-babysit-with-review-cli.sh`.

## Failure modes & blast radius
- **Contract violation (malformed Codex review):** Structural validation (ARLO-FEAT-MCP-RESILIENCE) catches this before `count_blocking` runs; returns 1 → `fail_review_cycle`. Blast: PR labeled `review-incomplete`, no false-clean merge.
- **Codex backend compatibility failure:** All review cycles in the run fail. Old behaviour (pre-fix): no `fail_review_cycle` call, PR stayed OPEN, outer loop merged unreviewed. New behaviour: `review-codex-outdated` label, babysitter exits 1 after first affected PR.
- **`fail_review_cycle` gh command failure (gh auth expired, network down):** Old behaviour: WARNING logged, continued. New behaviour: babysitter exits 1; unlabelled PR must be manually quarantined before restart.
- **Perf regression (Codex/Claude latency spike):** Cycle slows, may hit MAX_REVIEW_CYCLES before converging. Blast: PR labeled `review-incomplete`, developer reviews manually.
- **Telemetry loss (gh pr comment failure for bail reason):** Bail reason comment not posted; label and draft state are still applied (fail-closed). Blast: PR is safely quarantined; operator sees the label but no comment context.
- **False positive (BLOCKING for valid code):** Developer wastes time investigating. Mitigated by prescriptive mode requiring concrete fix.
- **False negative (BLOCKING missed):** Bug merges. Mitigated by retrospective review (ARLO-FEAT-RETROSPECTIVE-REVIEW) for known unreviewed PRs.

# Bounds

## Out of scope
- **Out-of-feature behaviors:**
  - Codex retry logic (handled by ARLO-FEAT-MCP-RESILIENCE)
  - PR creation (handled by outer loop / Claude)
  - State collection for Claude prompt (handled by outer loop)
- **Capacity limits:**
  - MAX_REVIEW_CYCLES hard cap (no dynamic adjustment)
  - Single PR per cycle (no batch review)
- **Adjacent capabilities deferred:**
  - Parallel review (multiple PRs simultaneously)
  - Human-in-the-loop approval (auto-merge on BLOCKING=0)
  - Cross-PR review (e.g., detecting conflicts with other open PRs)

## Assumptions-that-could-flip
- **Codex-only review assumption.** If flipped to multi-reviewer (Codex + CodeRabbit + human): requires aggregation, prioritization, and conflict resolution.
- **Sequential cycle assumption.** If flipped to parallel: requires parallel Codex invocation, which may conflict with Codex CLI limitations.
- **Prescriptive mode at cycle 3 assumption.** If flipped to earlier/later: requires tuning based on empirical convergence data.
- **Auto-merge assumption.** If flipped to approval-required: requires gh workflow approval API integration or manual merge step.
- **`count_blocking` zero = clean pass assumption.** **Flipped 2026-05-10:** Codex v0.117.0 with gpt-5.5 produced non-review output that exited 0, which would have been counted as zero blocking findings → immediate merge. Fix: structural validation (all three section headers required) is now a pre-condition; absent header = Codex failure, not a clean pass.
- **`fail_review_cycle` always succeeds assumption.** **Flipped 2026-05-10 (old code):** Old code did not call `fail_review_cycle` on non-transport Codex failures at all. Fix: always call `fail_review_cycle` for all non-transport failures; make it fail-closed.
- **Inline-plan-first at cycle 2 assumption.** If flipped to cycle 3+ only or disabled: requires A/B testing to measure inline planning impact on convergence rate.
- **Detailed explanations at cycle 3 assumption.** If flipped to earlier cycles or all cycles: requires cost/benefit analysis (token usage vs. fix quality improvement).
- **Solution rationale in commits assumption.** If flipped to separate doc or PR description: requires alternative mechanism for preserving decision context.
- **Resolution justification at cycle 4 assumption.** If flipped to earlier/later or disabled: requires empirical testing of false convergence rate (Claude claiming DONE_REVIEW without actually resolving findings).
- **Codex adjudication at cycle 5 assumption.** If flipped to cycle 4 (immediately after first justification) or disabled: must assess whether one cycle of justification is sufficient context for meaningful adjudication, or whether the extra cycle provides better signal.

## Composes with / replaces
- **Replaces:** Manual code review loop (open PR → human reviews → implementer fixes → re-review)
- **Composes with:**
  - ARLO-FEAT-OUTER-LOOP (triggered by HANDOFF_REVIEW sentinel)
  - ARLO-FEAT-MCP-RESILIENCE (provides Codex retry with backoff)
  - CodeRabbit / human reviewers (external feedback collected via collect_pr_feedback)

# Signals

## Acceptance tests

0. **Given** Codex pre-flight probe matches `compat_re` (model too old), **when** `run_review_cycle` is called, **then** PR is labelled `review-codex-outdated` and babysitter exits 1 (no cycles run).
0b. **Given** Codex pre-flight probe matches `credits_re`, **when** `run_review_cycle` is called, **then** PR is labelled `review-codex-no-credits` and babysitter exits 1 (no cycles run).
0c. **Given** `fail_review_cycle`'s `gh pr ready --undo` returns non-zero, **when** function executes, **then** babysitter exits 1 (not logs WARNING and continues).
1. **Given** PR #123 with BLOCKING issues, **when** review cycle runs, **then** Codex produces markdown review with `## BLOCKING` section, Claude addresses findings, cycle repeats.
2. **Given** reviewer returns 0 BLOCKING findings, **when** cycle completes, **then** wrapper POSTs `codex-review=success` status, then PR is merged via `gh pr merge --squash --delete-branch [--auto]` and function returns 0.
2b. **Given** `codex-review` status POST fails, **when** BLOCKING=0, **then** wrapper logs WARNING and returns 0 without merging (PR stays open).
3. **Given** cycle 3 starts, **when** Codex prompt is assembled, **then** prescriptive template is used (requires "Suggested fix:" for BLOCKING).
4. **Given** Claude outputs `STUCK_REVIEW cannot fix X`, **when** cycle processes response, **then** PR is labeled `review-incomplete` and function returns 0.
5. **Given** Claude outputs `DONE_REVIEW` but HEAD SHA unchanged, **when** cycle checks, **then** PR is labeled `review-incomplete` (defensive against no-op).
6. **Given** MAX_REVIEW_CYCLES=3 exhausted, **when** cycle limit reached, **then** PR is labeled `review-incomplete` and function returns 0.
7. **Given** cycle 2 starts, **when** Codex prompt is assembled, **then** history block includes cycle 1 review and git log of Claude commits.
8. **Given** Codex MCP transport fails 3 times, **when** retry exhausted, **then** PR is labeled `review-mcp-outage` and function returns 2.
9. **Given** reviewer binary not installed, **when** cycle starts, **then** logged message "$REVIEWER CLI not found; skipping review cycle" and function returns 0 (graceful degradation).
10. **Given** PR has existing CodeRabbit comments, **when** collect_pr_feedback runs, **then** comments are included in implementer prompt (not filtered out).
11. **Given** PR has self-posted review comments with prefixes `**Codex review`, `**Claude review`, or `**babysit-with-review:`, **when** collect_pr_feedback runs, **then** those comments are excluded (all three prefixes are filtered).
14. **Given** cycle 2+ with inline planning, **when** implementer commits a fix, **then** commit message includes "Why: <rationale>" explaining trade-offs and alternatives.
15. **Given** cycle 3 starts, **when** Codex prompt is assembled, **then** prescriptive template includes "Root cause:", "Architectural context:", and "Impact:" fields for each BLOCKING finding.
16. **Given** cycle 3+ Codex review with detailed explanations, **when** Claude reads review, **then** Claude can reference root cause and architectural context in its fix rationale.
17. **Given** cycle 3+ with detailed explanations, **when** Claude commits a fix, **then** commit message includes "Impact: <failure mode addressed>" in addition to "Why:" rationale.
18. **Given** cycle 2+ inline plan identifies fix dependencies, **when** plan text is output and then executed, **then** fixes are applied in the order the implementer determined (not necessarily Codex review order); no plan mode tool invocation appears in the log.
19. **Given** cycle 3+ with prescriptive mode and detailed explanations, **when** Codex cannot provide all required fields for a finding, **then** finding is downgraded to RECOMMENDED (per template rules).
20. **Given** cycle 4 completes with BLOCKING findings addressed, **when** Claude finishes Step 3, **then** PR has comment with resolution justification for each BLOCKING finding (format: "BLOCKING <desc> resolved in commit <SHA>. Why this resolves it: <explanation>").
21. **Given** cycle 4+ with invalid BLOCKING finding, **when** Claude justifies findings, **then** PR comment includes "BLOCKING <desc> is invalid. Reason: <explanation>. Supporting reference: <link>" with valid external reference.
22. **Given** cycle 4+ completes, **when** DONE_REVIEW sentinel is output, **then** all BLOCKING findings from Codex review have corresponding resolution justifications posted to PR (verified via `gh pr view`).
23. **Given** cycle 5 starts, **when** Codex prompt is assembled, **then** prompt includes Claude's resolution justifications from cycle 4 in a dedicated `--- Claude's resolution justifications ---` section.
24. **Given** cycle 5+ Codex review with adjudication, **when** Claude claimed "resolved" and fix is correct, **then** Codex outputs "ACCEPTED" for that finding in the ADJUDICATION section.
25. **Given** cycle 5+ Codex review with adjudication, **when** Claude claimed "resolved" but fix is insufficient, **then** Codex outputs "DISAGREED" with code-level evidence AND the finding reappears as [RECURRENCE] in BLOCKING.
26. **Given** cycle 5+ Codex review with adjudication, **when** Claude claimed "invalid" with valid reference, **then** Codex outputs "ACCEPTED: finding withdrawn."
27. **Given** cycle 5+ Claude receives DISAGREED adjudication, **when** Claude processes it, **then** Claude either implements a different fix addressing Codex's counter-argument OR reports STUCK_REVIEW escalating to human.
28. **Given** cycle 5+ Claude re-addresses a DISAGREED finding, **when** Claude posts resolution justification, **then** justification includes "re-addressed after Codex disagreement" acknowledging the previous insufficiency.
29. **Given** cycle 5+ Codex review with adjudication, **when** Claude claimed "invalid" but Codex disagrees, **then** Codex outputs "DISAGREED" with counter-argument explaining why the finding is valid AND the finding reappears as [RECURRENCE] in BLOCKING.
30. **Given** cycle 5+ with ACCEPTED findings, **when** next cycle (6) runs, **then** those ACCEPTED findings do NOT reappear in BLOCKING section (verified via absence in Codex review).
31. **Given** same BLOCKING finding DISAGREED on 2+ consecutive cycles (5 and 6), **when** cycle 6 Claude processes the second DISAGREED, **then** Claude reports STUCK_REVIEW escalating ping-pong to human review (per kill criterion).

## Telemetry events tied to L1 KPIs
- **Cycles per PR** → Productivity KPI (lower = better prompt quality, faster convergence)
- **BLOCKING=0 rate** → Quality KPI (higher = better code quality at merge)
- **review-incomplete rate** → Reliability KPI (lower = fewer stuck cases)
- **review-mcp-outage rate** → Codex availability KPI (lower = more reliable Codex)

## AEAB cases
N/A — no eval framework integration yet.

Future: Could record (PR_NUMBER, cycle_count, BLOCKING_history, outcome) for offline eval of convergence rate.

## Kill criteria

- If prescriptive mode (cycle 3+) increases false positive rate by >20% vs. descriptive mode → revert to descriptive-only or make mode configurable
- If review cycle convergence rate (BLOCKING=0 / total PRs) drops below 50% → halt feature, improve reviewer prompt or switch review approach
- If average cycles-per-PR exceeds 4 for >70% of PRs → halt feature, increase MAX_REVIEW_CYCLES or improve prompt quality
- If reviewer MCP outage rate exceeds 30% → remove Codex dependency, use alternative review (e.g., CodeRabbit API, Claude self-review)
- If inline-plan-first mode (cycle 2+) does NOT reduce cycles-per-PR by >15% vs. baseline → disable inline planning, too much overhead for insufficient benefit
- If detailed explanations (cycle 3+) do NOT improve fix accuracy by >10% vs. cycle 1-2 → disable detailed mode, explanation verbosity not helping
- If solution rationale bloats commit messages by >3× average length with no measurable review benefit → shorten rationale template or move to PR description
- If resolution justifications (cycle 4+) do NOT reduce false convergence rate (PRs re-opened due to unresolved BLOCKING) by >20% → remove Step 3, justification overhead not worth benefit
- If Codex adjudication (cycle 5+) DISAGREED rate exceeds 80% → Codex may be too strict or Claude's fixes systematically inadequate; investigate root cause before continuing
- If adjudication creates ping-pong (same finding DISAGREED across 2+ consecutive cycles) → force STUCK_REVIEW escalation to human on second disagreement
- If cycle 5-6 with all enhancements takes >15 minutes on >70% of PRs → reduce enhancement scope or make enhancements opt-in per PR
