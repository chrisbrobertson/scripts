# Plan — Codex version/model compatibility: silent-merge bug fix + retrospective review

> **Status:** implemented. `compat_re`/`review-codex-outdated` shipped in
> `babysit-with-review.sh` (see `compat_re` at the retry and pre-flight functions,
> `fail_review_cycle_codex_outdated` for the labelling/halt path), and
> `babysit-specs/L3-mcp-resilience.md` + `babysit-specs/L3-review-cycle.md` were
> updated accordingly. This plan doc is kept for historical context only.

---

## Spec files to update

| File | Action | What changes |
| --- | --- | --- |
| `babysit-specs/L3-mcp-resilience.md` | **Update** | Add `compat_re` telltale constant, return code 3 (backend compatibility failure), new error-model row, updated assumptions-that-could-flip (telltale assumption flipped 2026-05-10), new failure-mode blast-radius entry, out-of-scope note delegating pre-flight ownership to review cycle spec |
| `babysit-specs/L3-review-cycle.md` | **Update** | Add `review-codex-outdated` label in API surface, pre-flight probe + structural validation in "What we know", fail-closed behaviour for `fail_review_cycle` gh commands, two new failure modes, three new acceptance tests |
| `babysit-specs/L3-retrospective-review.md` | **New file** | Full spec for `run-retrospective-review.sh`: worktree-at-merge-SHA scope, Codex review, idempotency contract (HTML marker), PR comment + issue-creation flow, failure modes, acceptance tests |

All other specs (`L3-autonomous-outer-loop.md`, `L3-mcp-resilience.md` assumptions only,
`L1-babysit-with-review.md`, `L2-autonomous-dev-system.md`, `QA-TEST-PLAN.md`) do not
require changes — the outer loop contract and product-level behaviours are unaffected.

---

## Context

### What happened (evidence from May 9 log)

During the `secondbrain` babysit run on 2026-05-10, every Codex review cycle failed
silently. Log evidence (lines 683–731 of
`~/sisyphus-logs/secondbrain-babysit-with-review-20260509-181648-31173.log`):

```
--- review cycle 1 / 3 (PR #133) @ 2026-05-10T01:42:46Z ---
OpenAI Codex v0.117.0 (research preview)
model: gpt-5.5
...
ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error",
"message":"The 'gpt-5.5' model requires a newer version of Codex. Please
upgrade to the latest app or CLI and try again."}}
  [codex] non-zero exit; bailing review cycle
=== iter 4 @ 2026-05-10T01:43:02Z ===
```

The same pattern hit every PR opened that run: #132, #133, #134 ×2, #135, #136,
#137, #139, #140 — 10 review cycles, all failing with the same HTTP 400 error. In the
**old** version of the script, `fail_review_cycle` was never called after a Codex
non-zero exit. Every PR stayed `OPEN`, non-draft, and unlabelled. The outer Claude
loop encountered those PRs in subsequent iterations and merged them without code review.

### Bug decomposition

**Bug A — Old code didn't call `fail_review_cycle` on non-transport Codex failure.**
Direct cause of the silent merge. The current script patches this (line 887–890 now
calls `fail_review_cycle`). But the spec (`L3-review-cycle.md`) never documented this
path, so the failure modes remain unaudited.

**Bug B — `fail_review_cycle` is best-effort; its gh commands can fail silently.**
`fail_review_cycle` runs `gh pr ready --undo` and `gh pr edit --add-label` but
swallows failures with a WARNING log (no abort). If gh auth expires or the network is
down, the PR stays OPEN/non-draft — reopening the same hole Bug A created.

**Bug C — Version incompatibility is not a named failure class.**
The script classifies every Codex exit as: (0) success, (1) non-transport failure, (2)
MCP transport failure. "Model requires newer Codex CLI" gets `review-incomplete` — the
same label as STUCK_REVIEW and exhausted cycles. The fix is `codex update`, not a human
code review; the operator gets no actionable signal.

**Bug D — No Codex pre-flight before the review loop starts.**
Version incompatibility is only detected when the first PR hits a review cycle. Ten PRs
queue up and waste ten cycles before the problem is obvious.

**Bug E — No structural validation of Codex output (defence-in-depth gap).**
`codex_review_with_retry` returns 0 if `rc=0 AND -s TMP_REVIEW`. A future Codex failure
that exits 0 with non-review content (e.g., a deprecation warning) would count as "zero
blocking findings" and immediately merge the PR. Positive structural validation is
missing.

**Gap F — Retrospective coverage for PRs already merged unreviewed.**
Even after the forward-path bugs are fixed, the PRs that merged during the broken window
(PR #133 and siblings) contain AI-generated code that was never reviewed. No mechanism
exists to run a new Codex review against their merged commits, assess their findings, and
create follow-up fix issues.

---

## Design decisions

1. **Version incompatibility gets its own label: `review-codex-outdated`.**
   Unlike `review-incomplete` (human code-action) or `review-mcp-outage` (auto-retry),
   a version mismatch requires a CLI upgrade. Distinct label = distinct operator action.

2. **Version incompatibility halts the entire babysitter.**
   The error is deterministic — it will recur on every subsequent PR. After detection,
   label the affected PR, post a comment with fix instructions, then `exit 1`. The
   launchd/cron runner retries at the next tick; by then the operator should have
   upgraded.

3. **`fail_review_cycle` becomes fail-closed for labelling, not best-effort.**
   If `gh pr ready --undo` or `gh pr edit --add-label` fails, the wrapper should abort
   with a clear error rather than continue with an unlabelled PR. A PR that wasn't
   quarantined must not re-enter the outer loop. (The follow-up `gh pr comment` posting
   the bail reason remains best-effort — a failed comment doesn't affect PR safety.)

4. **Structural validation is added to `codex_review_with_retry` (return code 1).**
   If TMP_REVIEW is non-empty but lacks all three mandatory section headers (`## BLOCKING`,
   `## RECOMMENDED`, `## INFORMATION`), treat it as a non-transport failure. This makes
   an exit-0-but-garbage-output fail explicitly rather than silently pass.

5. **Codex pre-flight is a live probe, not a version-number comparison.**
   Version numbers and model aliases drift; comparing CLI versions is whack-a-mole. A
   live probe (`codex exec` with a trivial prompt that requests the three-section format)
   validates both that the CLI is installed and that the configured model responds. The
   structural validator (decision 4) confirms the probe output is valid.

6. **Retrospective review runs against the merge commit, not current HEAD.**
   Reviewing current HEAD would miss regressions introduced by the unreviewed PR and
   falsely attribute subsequent-commit fixes. Checking out `mergeCommit.oid` in an
   isolated worktree and diffing against its parent is the correct scope.

7. **Retrospective review creates GitHub issues for blocking findings, not fix PRs.**
   Automated fix PRs require the babysitter to be running, which assumes the Codex
   version problem is resolved. Issues are safer: they land in the project backlog where
   the next babysit run or human operator can act on them.

8. **`find-bailed-merged-prs.sh` already does detection. Reuse it, don't duplicate.**
   The retrospective flow pipes its output into the new review script rather than
   re-implementing log scanning.

---

## Part 1: Forward path — spec changes

### 1. `L3-mcp-resilience.md` — add backend-compatibility failure class

**Section "What we know"** — add:
- `codex_review_with_retry` recognises a third failure class: **backend compatibility**
  (return code 3). Detected by telltale `compat_re` (separate from `mcp_re`). Not
  retried; caller must halt the babysitter.

**Section "Contract / Return codes"** — add:
```
3  # Backend compatibility failure — Codex CLI too old for the configured model.
   # TMP_REVIEW is empty. Caller MUST halt the babysitter (do not retry).
```

**Telltale constants** — add `compat_re` alongside `mcp_re`:
```bash
compat_re='requires a newer version of Codex'
```
`mcp_re` is unchanged. `compat_re` fires on attempt 1 only — no retry warranted.

**Section "Invariants"** — update invariant 4:
> Return code 2 = MCP transport (all 3 retries exhausted, `mcp_re` match).
> Return code 3 = backend compatibility (attempt 1 only, `compat_re` match, no retry).

**Section "Error model"** — add row:
- Codex exit non-zero, `compat_re` match → return 3 immediately, no retry.

**Section "Assumptions-that-could-flip"** — update telltale assumption:
> Flipped 2026-05-10: `gpt-5.5` + Codex v0.117.0 produced HTTP 400 outside all
> `mcp_re` patterns. Fix: separate `compat_re` for version/model errors; unknown
> non-zero exits without a telltale continue to return 1.

**Section "Failure modes"** — add:
- **Backend compatibility failure (return 3):** Codex CLI too old. Blast: all review
  cycles in the run fail silently. Fix: halt babysitter, label PR `review-codex-outdated`.

**Section "Out of scope"** — add note:
> Codex pre-flight version detection is owned by the review cycle spec
> (ARLO-FEAT-REVIEW-CYCLE), not this spec.

### 2. `L3-review-cycle.md` — pre-flight, structural validation, fail-closed bail, new label

**Section "API surface fragment"** — add to label constants:
```
review-codex-outdated   # Codex CLI too old for model; upgrade CLI, then remove label
```

**Section "What we know"** — add:
- Pre-flight probe: before the cycle loop, `run_review_cycle` runs a 1-shot structural
  probe using the configured model. If the probe returns non-zero or fails structural
  validation, label the PR `review-codex-outdated` and halt the babysitter.
- Structural validation: `codex_review_with_retry` checks that TMP_REVIEW contains all
  three section headers before returning 0. Missing sections → return 1, even if `rc=0`.
- `fail_review_cycle` is now fail-closed: if `gh pr ready --undo` or `gh pr edit
  --add-label` return non-zero, the wrapper exits 1 rather than logging WARNING and
  continuing.

**Section "Invariants"** — add:
- **Structural pre-condition:** A Codex result is only "clean" if TMP_REVIEW passes
  positive structural validation (all three section headers present).
- **Fail-closed bail:** `fail_review_cycle` gh-label/gh-draft commands are not
  best-effort; a failure there aborts the babysitter.

**Section "Assumptions-that-could-flip"** — update `count_blocking` assumption:
> `count_blocking` returns 0 when the `## BLOCKING` section is absent. Previously
> treated as "zero findings → merge." Now: structural validation is a pre-condition;
> absent section header = Codex failure, not a clean pass.

**Section "Failure modes"** — add:
- **Codex backend compat failure:** All review cycles in the run fail. Old handling: no
  `fail_review_cycle`, PR stayed OPEN, outer loop merged unreviewed. New: label
  `review-codex-outdated`, halt babysitter.
- **`fail_review_cycle` gh command failure:** Previously swallowed. New: babysitter
  exits 1; PR must be manually quarantined before restart.

**Section "Acceptance tests"** — add:
- Given Codex exits non-zero with `requires a newer version of Codex`, then PR is
  labelled `review-codex-outdated` and babysitter exits 1.
- Given Codex exits 0 but TMP_REVIEW lacks `## BLOCKING`, then `codex_review_with_retry`
  returns 1.
- Given `fail_review_cycle`'s `gh pr ready --undo` returns non-zero, then babysitter
  exits 1, not 0.

---

## Part 1: Forward path — script changes

### 3. Extend `codex_review_with_retry` (structural check + `compat_re`)

```bash
local compat_re='requires a newer version of Codex'

# Inside the attempt loop, immediately after rc is captured:
if grep -qE "$compat_re" "$TMP_CODEX_FULL" 2>/dev/null; then
  echo "  [codex] backend compatibility failure on attempt $attempt (rc=$rc): Codex CLI too old for configured model" | tee -a "$LOG" >&2
  return 3
fi

# Existing MCP telltale check (unchanged):
if grep -qE "$mcp_re" "$TMP_CODEX_FULL" 2>/dev/null; then
  ...
fi

# Positive structural check — only after rc=0 AND -s TMP_REVIEW:
if [ "$rc" -eq 0 ] && [ -s "$TMP_REVIEW" ]; then
  if grep -qE '^## BLOCKING[[:space:]]*$' "$TMP_REVIEW" 2>/dev/null && \
     grep -qE '^## RECOMMENDED[[:space:]]*$' "$TMP_REVIEW" 2>/dev/null && \
     grep -qE '^## INFORMATION[[:space:]]*$' "$TMP_REVIEW" 2>/dev/null; then
    return 0
  else
    echo "  [codex] output missing required section headers; treating as non-transport failure" | tee -a "$LOG" >&2
    # fall through to return 1 at loop end
  fi
fi
```

### 4. Add `fail_review_cycle_codex_outdated` + rc=3 dispatch

New function (after `fail_review_cycle_mcp`):

```bash
fail_review_cycle_codex_outdated() {
  local pr_num="$1" reason="$2"
  echo "  [review] FATAL: Codex version incompatibility for PR #$pr_num: $reason" | tee -a "$LOG" >&2
  echo "  [review]   Fix: codex update && restart babysitter" | tee -a "$LOG" >&2

  gh label create review-codex-outdated --color "e4e669" --force \
    --description "Babysit stalled: Codex CLI too old for model; run codex update" \
    >>"$LOG" 2>&1 || true

  gh pr ready --undo "$pr_num" >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr ready --undo failed for PR #$pr_num" | tee -a "$LOG" >&2
  gh pr edit "$pr_num" --add-label review-codex-outdated >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr edit --add-label failed for PR #$pr_num" | tee -a "$LOG" >&2

  gh pr comment "$pr_num" --body "**babysit-with-review: Codex CLI version incompatibility**

The Codex CLI installed on this host is too old for the configured model.

**Fix:** Run \`codex update\`, then remove the \`review-codex-outdated\` label and restart babysitter." \
    >>"$LOG" 2>&1 || true
}
```

In `run_review_cycle`, rc dispatch (before the existing rc=2 branch):
```bash
if [ "$codex_rc" -eq 3 ]; then
  fail_review_cycle_codex_outdated "$pr_num" "Codex CLI too old (cycle $cycle)"
  exit 1   # halt entire babysitter; affects all subsequent PRs
elif [ "$codex_rc" -eq 2 ]; then
  ...
```

### 5. Make `fail_review_cycle` fail-closed for label/draft gh commands

```bash
# OLD (best-effort):
gh pr ready --undo "$pr_num" >>"$LOG" 2>&1 \
  || echo "  [review] WARNING: gh pr ready --undo failed for PR #$pr_num" | tee -a "$LOG" >&2

# NEW (fail-closed):
if ! gh pr ready --undo "$pr_num" >>"$LOG" 2>&1; then
  echo "ERROR: gh pr ready --undo failed for PR #$pr_num — PR may still be non-draft." \
    " Manually quarantine before restarting." | tee -a "$LOG" >&2
  exit 1
fi
if ! gh pr edit "$pr_num" --add-label review-incomplete >>"$LOG" 2>&1; then
  echo "ERROR: gh pr edit --add-label failed for PR #$pr_num — PR is unlabelled." \
    " Manually add review-incomplete label before restarting." | tee -a "$LOG" >&2
  exit 1
fi
# gh pr comment remains best-effort (notification only):
gh pr comment "$pr_num" --body "$body" >>"$LOG" 2>&1 || true
```

Apply same pattern in `fail_review_cycle_mcp`.

### 6. Add Codex pre-flight probe to `run_review_cycle`

After the existing `command -v codex` check:

```bash
local _pf_review _pf_full _pf_rc
_pf_review=$(mktemp)
_pf_full=$(mktemp)
_pf_rc=0

set +e
codex exec --output-last-message "$_pf_review" -s read-only \
  'Respond with exactly these three lines and nothing else:
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)' 2>&1 | tee -a "$LOG" "$_pf_full" >/dev/null
_pf_rc=${PIPESTATUS[0]}
set -e

_compat_fail=0
if grep -qE 'requires a newer version of Codex' "$_pf_full" 2>/dev/null; then
  _compat_fail=1
elif [ "$_pf_rc" -ne 0 ] || ! [ -s "$_pf_review" ]; then
  _compat_fail=1
elif ! grep -qE '^## BLOCKING[[:space:]]*$' "$_pf_review" 2>/dev/null || \
     ! grep -qE '^## RECOMMENDED[[:space:]]*$' "$_pf_review" 2>/dev/null || \
     ! grep -qE '^## INFORMATION[[:space:]]*$' "$_pf_review" 2>/dev/null; then
  _compat_fail=1
fi
rm -f "$_pf_review" "$_pf_full"

if [ "$_compat_fail" -eq 1 ]; then
  fail_review_cycle_codex_outdated "$pr_num" "Codex pre-flight probe failed (rc=$_pf_rc)"
  exit 1
fi
```

---

## Part 2: Retrospective review — scope

The forward-path fixes prevent future silent merges. But PRs from the broken window
(PR #133 and siblings, and any others identified by `find-bailed-merged-prs.sh`) merged
without Codex review and may contain unfixed bugs. Part 2 adds:

1. **Retrospective review runner** — new script that checks out a merged PR's commit,
   runs Codex, posts the review as a closed-PR comment, and opens follow-up issues for
   blocking findings.
2. **Spec coverage** — a new `L3-retrospective-review.md` (it's a distinct flow from
   the live review cycle).

### Design

- **Input:** `(repo, pr_number)` pairs, piped from `find-bailed-merged-prs.sh` or
  provided directly.
- **Scope:** Codex reviews the diff at the PR's `mergeCommit.oid`, not current HEAD.
  This captures what actually landed, not subsequent patches.
- **Worktree isolation:** Each PR is reviewed in a `git worktree` at the merge SHA.
  The main checkout is never touched.
- **Codex prompt:** Same Cycle 1 prompt template (descriptive, no convergence tracking)
  plus a `[RETROSPECTIVE]` header so the output is clearly labelled.
- **Outcome — zero blocking:** Post a `[RETROSPECTIVE REVIEW — PASSED]` comment. No
  issue created.
- **Outcome — blocking findings:** Post the full review as a PR comment, then create
  a GitHub issue per finding (or one issue per PR with all findings grouped) labelled
  `kind:bug retrospective priority:high`.
- **Outcome — Codex failure:** Report to stderr with the PR URL; skip, don't create
  an issue (the review itself failed, not the code).
- **Idempotency:** Check for a `<!-- retrospective-review: pr=N -->` HTML marker on
  existing PR comments before posting (same pattern as `backfill-codex-reviews.py`).

### New script: `run-retrospective-review.sh`

```
Usage:
  run-retrospective-review.sh [--dry-run] [--repo OWNER/REPO] PR_NUMBER [PR_NUMBER ...]
  find-bailed-merged-prs.sh --repo OWNER/REPO | run-retrospective-review.sh --repo OWNER/REPO

Flags:
  --repo OWNER/REPO   GitHub repo (required unless piped from find-bailed-merged-prs.sh)
  --dry-run           Print what would be posted/created; don't call gh
  --no-issues         Post reviews but do not create follow-up issues
  --label LABEL       Additional label to add to created issues (repeatable)
```

The script (bash + python inline, matching the style of `find-bailed-merged-prs.sh`):

**Step 1 — Resolve PR metadata:**
```bash
gh pr view "$pr_num" --repo "$REPO" \
  --json number,state,mergedAt,title,mergeCommit,headRefName,baseRefName
```
If `state != MERGED`, skip with a note.

**Step 2 — Worktree at merge commit:**
```bash
MERGE_SHA=$(jq -r .mergeCommit.oid <<< "$pr_json")
WORK_DIR=$(mktemp -d)
git -C "$(git rev-parse --show-toplevel)" worktree add "$WORK_DIR" "$MERGE_SHA"
trap 'git worktree remove "$WORK_DIR" --force 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT
```

**Step 3 — Build the diff for context:**
```bash
gh pr diff "$pr_num" --repo "$REPO" 2>/dev/null \
  || git -C "$WORK_DIR" diff "${MERGE_SHA}^".."$MERGE_SHA"
```
The diff is embedded in the Codex prompt preamble so Codex has the exact change set.

**Step 4 — Run Codex (with `codex_review_with_retry` logic):**
Call `codex exec --output-last-message "$TMP_REVIEW" -s read-only "$RETRO_PROMPT"` from
inside `$WORK_DIR` so Codex sees the repo at the merge snapshot. Use the same retry /
structural-validation logic from the forward path (extract as a shared function, or
inline it in the retro script).

The `RETRO_PROMPT` is a one-shot variant of `CODEX_REVIEW_PROMPT_CYCLE1` with a
preamble:
```
[RETROSPECTIVE REVIEW] This is a post-merge code review of PR #N (merged YYYY-MM-DD).
The PR was not reviewed at merge time due to a Codex CLI version incompatibility.
Review the diff below and the code in its current checkout state.

<DIFF>
...
</DIFF>

Output your review using EXACTLY this format...
```

**Step 5 — Post review as PR comment:**
```bash
MARKER="<!-- retrospective-review: pr=$pr_num -->"
HEADER="**[RETROSPECTIVE] Codex review — PR #$pr_num (merged $MERGED_AT)**  $MARKER"
gh pr comment "$pr_num" --repo "$REPO" --body "$HEADER

\`\`\`
$REVIEW_BODY
\`\`\`"
```

**Step 6 — Create follow-up issues for blocking findings:**

Parse the `## BLOCKING` section (reuse `count_blocking` logic). For each non-`(none)`
finding:

```bash
ISSUE_TITLE="[retrospective] <one-line finding> (from merged PR #$pr_num)"
ISSUE_BODY="**Source:** merged PR #$PR_URL (merged $MERGED_AT without Codex review)
**Retrospective review:** $PR_URL#issuecomment-<comment_id>

## Finding
$FINDING_TEXT

## Why this may still be an issue
The code from this PR landed on the default branch unreviewed. Subsequent commits may
or may not have addressed this; verify before closing.

## Next steps
1. Check if current HEAD still contains this code path.
2. If yes: open a fix PR. If no: close this issue with a note on which commit resolved it."

gh issue create --repo "$REPO" \
  --title "$ISSUE_TITLE" \
  --body "$ISSUE_BODY" \
  --label "kind:bug,retrospective,priority:high"
```

**Step 7 — Summary:**
```
PR #133: 2 blocking findings → review posted, 2 issues created
PR #134: 0 blocking findings → review posted (PASSED)
PR #135: Codex failure (compat error) → skipped, see stderr
```

### New spec: `L3-retrospective-review.md`

New file `babysit-specs/L3-retrospective-review.md`. Key sections:

**TL;DR:** One-shot Codex review runner for PRs that merged without automated review.
Outputs review as a closed-PR comment and opens follow-up issues for blocking findings.

**API surface:**
```bash
run-retrospective-review.sh [--dry-run] [--repo OWNER/REPO] [--no-issues] PR_NUMBER...
# Input: PR numbers (merged or open)
# Output: PR comments + GitHub issues; summary to stdout
```

**Contract:**
- Idempotent: `<!-- retrospective-review: pr=N -->` marker prevents duplicate posts.
- Reviews the state AT merge commit, not current HEAD.
- Creates at most 1 issue per blocking finding per PR (dedup on issue title prefix).
- Exits 0 even when some PRs fail (partial success is reported).

**Failure modes:**
- Codex compat failure → logged, PR skipped (same compat_re telltale).
- `gh pr view` failure → PR skipped with stderr note.
- Worktree creation failure → PR skipped.
- `gh issue create` failure → logged as WARNING, review comment already posted.

**Acceptance tests:**
- Given a merged PR with no valid prior review and blocking findings, when script runs,
  then PR receives retrospective review comment and one issue per finding is opened.
- Given the script is run twice, then only one retrospective review comment exists (idempotent).
- Given Codex compat failure on a PR, then PR is skipped (no comment, no issue).

---

## Part 3: `find-bailed-merged-prs.sh` — extend for version-compat bail detection

The existing script identifies `bailing review cycle` phrases. Add `requires a newer version
of Codex` and `non-MCP failure` as additional `BAILED_PHRASES`:

```python
BAILED_PHRASES = [
    'bailing review cycle',
    'hit MAX_REVIEW_CYCLES',
    'HEAD unchanged',
    'STUCK_REVIEW',
    'gh pr checkout',
    'marking PR',
    'non-MCP failure',                    # NEW: non-transport Codex failure
    'requires a newer version of Codex',  # NEW: version incompatibility telltale
    'non-zero exit',                      # NEW: legacy (old code) phrase
]
```

Also add a `BAIL_REASON` column that preserves the telltale phrase so the operator can
see at a glance whether a bail was a Codex compat issue vs. a logic bail.

---

## Files modified / added

| Path | Change |
| --- | --- |
| `babysit-specs/L3-mcp-resilience.md` | Add `compat_re`, return code 3, backend-compat failure class, updated telltale assumption. |
| `babysit-specs/L3-review-cycle.md` | Add pre-flight probe, structural validation, fail-closed `fail_review_cycle`, `review-codex-outdated` label in API surface and failure modes. |
| `babysit-specs/L3-retrospective-review.md` | NEW — spec for one-shot retrospective review of merged PRs. |
| `babysit-with-review.sh` | New `compat_re`, structural section check in `codex_review_with_retry`, `fail_review_cycle_codex_outdated`, rc=3 branch in `run_review_cycle`, pre-flight probe, fail-closed `fail_review_cycle`. |
| `run-retrospective-review.sh` | NEW — standalone script: worktree checkout at merge SHA, Codex review, PR comment, issue creation. |
| `find-bailed-merged-prs.sh` | Add version-compat phrases to `BAILED_PHRASES`; add `BAIL_REASON` column to output. |

No new runtime dependencies. All tools (`codex`, `gh`, `git worktree`, `mktemp`,
`grep`, `jq`) are already present in the babysit environment.

---

## Verification

### Forward path

**Structural validation (unit):**
```bash
printf 'ERROR: some garbage output\n' > /tmp/bad_review.txt
grep -qE '^## BLOCKING[[:space:]]*$' /tmp/bad_review.txt && echo "PASS (should not match)" || echo "FAIL: correctly rejected"
```

**`compat_re` telltale:**
```bash
printf 'ERROR: The gpt-5.5 model requires a newer version of Codex.\n' \
  | grep -qE 'requires a newer version of Codex' && echo "MATCH" || echo "MISS"
```

**Pre-flight fast-fail (live test, requires Codex):**
Run in a test repo with the real Codex; temporarily configure an invalid model alias.
Expected: `[review] FATAL: Codex version incompatibility` + `exit 1` before any PR cycle.

**`fail_review_cycle` fail-closed (synthetic):**
```bash
GH_TOKEN=expired_token_xyz ./babysit-with-review.sh 2>&1 | head -5
echo "exit: $?"   # expect 1, not 0
```

### Retrospective path

**Idempotency:**
```bash
./run-retrospective-review.sh --repo chrisbrobertson/secondbrain 133
# Run twice; second run should print "skipped (already retrospective-reviewed)"
./run-retrospective-review.sh --repo chrisbrobertson/secondbrain 133
```

**Dry-run:**
```bash
./run-retrospective-review.sh --dry-run --repo chrisbrobertson/secondbrain 133 134
# Expect summary with "would post" and "would create N issues"
```

**Blast radius (confirm worktree cleaned up):**
```bash
git worktree list   # before
./run-retrospective-review.sh --dry-run --repo chrisbrobertson/secondbrain 133
git worktree list   # after — must be identical
```

---

## Delivery

Four commits across one PR against `main` of `chrisbrobertson/scripts`:

1. **`spec(L3-mcp-resilience): add backend-compatibility failure class (compat_re, return 3)`**
2. **`spec(L3-review-cycle): pre-flight, structural validation, fail-closed bail, review-codex-outdated`**
3. **`spec(L3-retrospective-review): new spec for one-shot retrospective PR review`**
4. **`fix(babysit): detect Codex compat failure; structural validation; retrospective review script`**
   (includes `babysit-with-review.sh`, `run-retrospective-review.sh`, `find-bailed-merged-prs.sh`)

PR title: *babysit: Codex compat detection + retrospective review for silently-merged PRs*

---

## Critical files referenced

| Path | Why |
| --- | --- |
| `babysit-specs/L3-mcp-resilience.md` lines 29–43 | `codex_review_with_retry` API surface — add `compat_re` and return 3. |
| `babysit-specs/L3-mcp-resilience.md` lines 57–64 | `What we know` — add backend-compat class. |
| `babysit-specs/L3-mcp-resilience.md` lines 87–98 | `Error model` — add compat row. |
| `babysit-specs/L3-mcp-resilience.md` lines 138–144 | `Failure modes` — add backend-compat item. |
| `babysit-specs/L3-review-cycle.md` lines 61–64 | Label constants — add `review-codex-outdated`. |
| `babysit-specs/L3-review-cycle.md` lines 77–80 | `What we know` — add pre-flight + structural validation. |
| `babysit-with-review.sh` lines 750–787 | `codex_review_with_retry` — add `compat_re`, structural header check. |
| `babysit-with-review.sh` lines 680–708 | `fail_review_cycle` — make gh label/draft commands fail-closed. |
| `babysit-with-review.sh` lines 714–741 | After `fail_review_cycle_mcp` — add `fail_review_cycle_codex_outdated`. |
| `babysit-with-review.sh` lines 800–806 | Pre-flight `command -v codex` block — add model probe. |
| `babysit-with-review.sh` lines 884–891 | `run_review_cycle` codex_rc dispatch — add rc=3 branch. |
| `find-bailed-merged-prs.sh` lines 68–75 | `BAILED_PHRASES` — add compat/legacy phrases. |
