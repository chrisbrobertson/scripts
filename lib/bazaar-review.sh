#!/usr/bin/env bash
# lib/bazaar-review.sh — convergent implementer/reviewer cycle, extracted from
# babysit-builder.sh (control flow, code-mode prompts) and babysit-work-prep.sh
# (spec-mode prompts). Spec: bazaar-builder-specs/L3-review-lib.md
# (BZR-FEAT-REVIEW-LIB). babysit-with-review.sh keeps its own copy by design.
#
# Sourcing this file has no side effects. Every entry point asserts the globals
# it needs and exits 2 naming the first missing one.
#
# Globals read:
#   LOG                 append-only log file (required by every entry point)
#   TMP_REVIEW          reviewer output file          (reviewer functions, cycle)
#   TMP_CODEX_FULL      full codex transcript file    (codex reviewer, cycle)
#   TMP_REVIEW_RESULT   implementer output file       (cycle)
#   REVIEW_WORKDIR      worktree the reviewer/implementer run in (reviewer, cycle)
#   REPO                OWNER/REPO for gh             (cycle, status post)
#   IMPLEMENTER         claude|codex                  (implementer, cycle)
#   REVIEWER            claude|codex                  (reviewer, cycle)
#   IMPLEMENTER_MODEL IMPLEMENTER_EFFORT REVIEWER_MODEL REVIEWER_EFFORT  (optional)
#   BABYSIT_TEST_MODE   when non-empty, retry sleeps are skipped (stubs on PATH)
#
# --validate-cmd runs through `eval` in the CALLER's cwd, not the worktree; bake
# the worktree path into the command (e.g. 'validate_spec_change "$wt" ...').
#
# Globals written by run_review_cycle:
#   REVIEW_LAST_FILE    path of the last successful reviewer output; a per-cycle copy
#                       (${TMP_REVIEW}.c<N>) that survives later attempts zeroing TMP_REVIEW
#   REVIEW_CYCLES_RUN   number of cycles executed
#   REVIEW_FAIL_REASON  one-line reason on rc 10/20/2/3/4

BZR_REVIEW_LIB_VERSION="0.1.0"

# ---------- guards ----------

_bzr_require() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "bazaar-review: required global '$name' is unset (caller: ${FUNCNAME[1]})" >&2
      exit 2
    fi
  done
}

_bzr_sleep() {
  [ -n "${BABYSIT_TEST_MODE:-}" ] && return 0
  sleep "$1"
}

_bzr_log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

# ---------- implementer harness (babysit-builder.sh:650-716, verbatim) ----------

run_claude() {
  _bzr_require LOG
  local prompt="$1" out_file="$2" run_dir="$3" stage_model="${4:-claude-sonnet-5}"
  local model="${IMPLEMENTER_MODEL:-$stage_model}"
  local -a args=(-p "$prompt" --model "$model")
  [ -n "${IMPLEMENTER_EFFORT:-}" ] && args+=(--effort "$IMPLEMENTER_EFFORT")
  args+=(--dangerously-skip-permissions --output-format stream-json --verbose)
  (cd "$run_dir" && claude "${args[@]}" 2>> "$LOG" < /dev/null) \
    | tee -a "$LOG" \
    | python3 -c '
import json, sys
final = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    t = ev.get("type")
    if t == "system" and ev.get("subtype") == "init":
        sid = (ev.get("session_id") or "?")[:8]
        print(f"  [init] session {sid}", file=sys.stderr, flush=True)
    elif t == "assistant":
        for block in ev.get("message", {}).get("content", []):
            bt = block.get("type")
            if bt == "text":
                txt = (block.get("text") or "").strip()
                if txt:
                    print(f"  [text] {txt.splitlines()[0][:200]}", file=sys.stderr, flush=True)
            elif bt == "tool_use":
                name = block.get("name", "?")
                inp = block.get("input") or {}
                summary = (
                    inp.get("command") or inp.get("file_path")
                    or inp.get("pattern") or inp.get("path") or ""
                )
                summary = str(summary).splitlines()[0][:120] if summary else ""
                print(f"  [tool] {name} {summary}".rstrip(), file=sys.stderr, flush=True)
    elif t == "result":
        final = ev.get("result") or ""
sys.stdout.write(final)
' > "$out_file"
  return ${PIPESTATUS[0]}
}

run_codex_implementer() {
  _bzr_require LOG
  local prompt="$1" out_file="$2" run_dir="$3"
  local -a args=(exec --output-last-message "$out_file" --dangerously-bypass-approvals-and-sandbox)
  [ -n "${IMPLEMENTER_MODEL:-}" ] && args+=(--model "$IMPLEMENTER_MODEL")
  [ -n "${IMPLEMENTER_EFFORT:-}" ] && args+=(-c "model_reasoning_effort=\"$IMPLEMENTER_EFFORT\"")
  : > "$out_file"
  (cd "$run_dir" && codex "${args[@]}" "$prompt" 2>&1 < /dev/null) | tee -a "$LOG" >&2
  return ${PIPESTATUS[0]}
}

run_implementer() {
  _bzr_require LOG IMPLEMENTER
  case "$IMPLEMENTER" in
    claude) run_claude "$1" "$2" "$3" "${4:-claude-sonnet-5}" ;;
    codex) run_codex_implementer "$1" "$2" "$3" ;;
    *) echo "bazaar-review: unknown IMPLEMENTER '$IMPLEMENTER'" >&2; return 2 ;;
  esac
}

# ---------- reviewer harness (babysit-builder.sh:717-901) ----------

# Count BLOCKING findings in a strict-markdown review on stdin.
# Treats a single `- (none)` bullet as zero findings.
count_blocking() {
  awk '
    BEGIN { in_block = 0; n = 0 }
    /^## BLOCKING[[:space:]]*$/ { in_block = 1; next }
    /^## /                      { in_block = 0; next }
    in_block && /^-[[:space:]]/ {
      line = $0
      sub(/^-[[:space:]]+/, "", line)
      if (line == "(none)") next
      n++
    }
    END { print n }
  '
}

# Validate the strict review parser contract shared by all reviewer harnesses.
valid_review_structure() {
  local review_file="$1"
  [ -s "$review_file" ] || return 1
  awk '
    BEGIN { current = 0; valid = 1 }
    /^[[:space:]]*$/ { next }
    /^## ADJUDICATION[[:space:]]*$/ {
      adjudication_headings++
      if (adjudication_headings != 1 || blocking_headings || recommended_headings || information_headings) valid = 0
      current = 4
      next
    }
    /^## BLOCKING[[:space:]]*$/ {
      blocking_headings++
      if (blocking_headings != 1 || recommended_headings || information_headings) valid = 0
      current = 1
      next
    }
    /^## RECOMMENDED[[:space:]]*$/ {
      recommended_headings++
      if (blocking_headings != 1 || recommended_headings != 1 || information_headings) valid = 0
      current = 2
      next
    }
    /^## INFORMATION[[:space:]]*$/ {
      information_headings++
      if (blocking_headings != 1 || recommended_headings != 1 || information_headings != 1) valid = 0
      current = 3
      next
    }
    /^## / { valid = 0; current = 0; next }
    /^- / {
      if (current < 1 || current > 4) {
        valid = 0
        next
      }
      is_none = ($0 == "- (none)")
      if (none[current] || (is_none && bullets[current] > 0)) valid = 0
      bullets[current]++
      if (is_none) none[current] = 1
      next
    }
    /^[[:space:]]+/ {
      if (current >= 1 && current <= 4 && bullets[current] > 0 && !none[current]) next
      valid = 0
      next
    }
    { valid = 0 }
    END {
      if (blocking_headings != 1 || recommended_headings != 1 || information_headings != 1) valid = 0
      if (bullets[1] < 1 || bullets[2] < 1 || bullets[3] < 1) valid = 0
      if (adjudication_headings == 1 && bullets[4] < 1) valid = 0
      exit(valid ? 0 : 1)
    }
  ' "$review_file" 2>/dev/null
}

# Run codex exec with retry on MCP transport failures. Runs inside $REVIEW_WORKDIR.
# Verbatim from babysit-builder.sh except: REVIEW_WORKDIR, _bzr_sleep, guards.
# Returns: 0 clean, 1 non-transport failure, 2 MCP outage (retries exhausted),
#          3 Codex CLI too old, 4 workspace out of credits.
codex_review_with_retry() {
  _bzr_require LOG TMP_REVIEW TMP_CODEX_FULL REVIEW_WORKDIR
  local codex_prompt="$1"
  local attempt rc
  local delays=(0 60 300)
  local compat_re='requires a newer version of Codex'
  local credits_re='Your workspace is out of credits'
  # Telltale patterns for MCP transport failures. Update if Codex changes its error format.
  local mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'

  for attempt in 1 2 3; do
    if [ "${delays[$((attempt - 1))]}" -gt 0 ]; then
      echo "  [codex] waiting ${delays[$((attempt - 1))]}s before retry (attempt $attempt of 3)..." | tee -a "$LOG" >&2
      _bzr_sleep "${delays[$((attempt - 1))]}"
    fi
    : > "$TMP_REVIEW"
    : > "$TMP_CODEX_FULL"

    local -a codex_args=(exec --output-last-message "$TMP_REVIEW" -s read-only)
    [ -n "${REVIEWER_MODEL:-}" ] && codex_args+=(--model "$REVIEWER_MODEL")
    [ -n "${REVIEWER_EFFORT:-}" ] && codex_args+=(-c "model_reasoning_effort=\"$REVIEWER_EFFORT\"")
    (cd "$REVIEW_WORKDIR" && codex "${codex_args[@]}" "$codex_prompt" 2>&1 < /dev/null) \
      | tee -a "$LOG" "$TMP_CODEX_FULL" >&2
    rc=${PIPESTATUS[0]}

    if grep -qE "$compat_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      echo "  [codex] FATAL: backend compatibility failure on attempt $attempt (rc=$rc); Codex CLI is too old for the configured model" | tee -a "$LOG" >&2
      return 3
    fi
    if grep -qE "$credits_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      echo "  [codex] FATAL: Codex workspace out of credits on attempt $attempt (rc=$rc); add credits and restart" | tee -a "$LOG" >&2
      return 4
    fi

    if [ "$rc" -eq 0 ] && [ -s "$TMP_REVIEW" ]; then
      if valid_review_structure "$TMP_REVIEW"; then return 0; fi
      echo "  [codex] exit 0 but review missing required section headers; treating as failure" | tee -a "$LOG" >&2
    fi

    if grep -qE "$mcp_re" "$TMP_CODEX_FULL" 2>/dev/null; then
      local review_state
      review_state=$([ -s "$TMP_REVIEW" ] && echo "present" || echo "empty")
      echo "  [codex] MCP transport failure on attempt $attempt of 3 (rc=$rc, review=$review_state)" | tee -a "$LOG" >&2
      [ "$attempt" -lt 3 ] && continue
      return 2
    fi

    return 1
  done
}

# Run a Claude review with non-mutating plan permissions, inside $REVIEW_WORKDIR.
claude_review() {
  _bzr_require LOG TMP_REVIEW REVIEW_WORKDIR
  local review_prompt="$1" rc
  local -a args=(-p "$review_prompt" --permission-mode plan)
  [ -n "${REVIEWER_MODEL:-}" ] && args+=(--model "$REVIEWER_MODEL")
  [ -n "${REVIEWER_EFFORT:-}" ] && args+=(--effort "$REVIEWER_EFFORT")
  args+=(--output-format stream-json --verbose)
  : > "$TMP_REVIEW"
  (cd "$REVIEW_WORKDIR" && claude "${args[@]}" 2>&1 < /dev/null) \
    | tee -a "$LOG" \
    | python3 -c '
import json, sys
final = ""
for line in sys.stdin:
    try:
        event = json.loads(line)
    except Exception:
        continue
    if event.get("type") == "result":
        final = event.get("result") or ""
sys.stdout.write(final)
' > "$TMP_REVIEW"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "  [claude reviewer] non-zero exit (rc=$rc); treating review as incomplete" | tee -a "$LOG" >&2
    return 1
  fi
  if ! valid_review_structure "$TMP_REVIEW"; then
    echo "  [claude reviewer] review missing required section headers; treating as failure" | tee -a "$LOG" >&2
    return 1
  fi
}

review_with_retry() {
  _bzr_require LOG REVIEWER
  case "$REVIEWER" in
    codex) codex_review_with_retry "$1" ;;
    claude) claude_review "$1" ;;
    *) echo "bazaar-review: unknown REVIEWER '$REVIEWER'" >&2; return 1 ;;
  esac
}

# Codex-only preflight: compat and credit detection before any implementer time
# is spent. Returns 0 ok / 1 probe failed / 3 too old / 4 no credits.
reviewer_preflight() {
  _bzr_require LOG REVIEWER
  [ "$REVIEWER" = "codex" ] || return 0
  local compat_re='requires a newer version of Codex'
  local credits_re='Your workspace is out of credits'
  local probe_full rc
  probe_full=$(mktemp "${TMPDIR:-/tmp}/bzr-probe.XXXXXX")
  local -a args=(exec -s read-only)
  [ -n "${REVIEWER_MODEL:-}" ] && args+=(--model "$REVIEWER_MODEL")
  [ -n "${REVIEWER_EFFORT:-}" ] && args+=(-c "model_reasoning_effort=\"$REVIEWER_EFFORT\"")
  codex "${args[@]}" "Say 'ok'." 2>&1 < /dev/null | tee -a "$LOG" "$probe_full" >/dev/null
  rc=${PIPESTATUS[0]}
  if grep -qE "$compat_re" "$probe_full" 2>/dev/null; then rm -f "$probe_full"; return 3; fi
  if grep -qE "$credits_re" "$probe_full" 2>/dev/null; then rm -f "$probe_full"; return 4; fi
  rm -f "$probe_full"
  [ "$rc" -eq 0 ] || return 1
}

# ---------- GitHub helpers used by the cycle ----------

# All existing PR feedback minus this pipeline's own comments.
collect_pr_feedback() {
  _bzr_require REPO
  local pr_num="$1"
  # No --jq (hosts lack jq and the test stub serves plain JSON); pipeline-authored
  # comments (bzr markers, Codex/Claude review posts, babysit summaries) are excluded
  # so prior reviews are not fed back as "existing feedback" on top of the history block.
  {
    gh pr view "$pr_num" --repo "$REPO" --json reviews,comments 2>/dev/null || echo '{}'
    echo '@@INLINE@@'
    gh api "repos/${REPO}/pulls/${pr_num}/comments" 2>/dev/null || echo '[]'
  } | python3 -c '
import json, sys
raw = sys.stdin.read().split("@@INLINE@@", 1)
try: p = json.loads(raw[0] or "{}")
except Exception: p = {}
try: inline = json.loads(raw[1] if len(raw) > 1 and raw[1].strip() else "[]")
except Exception: inline = []
def ours(b): return b.lstrip().startswith(("<!-- bzr-", "**Codex review", "**Claude review", "**bazaar", "**babysit-builder:"))
out = []
for r in p.get("reviews", []) or []:
    b = r.get("body") or ""
    if b and not ours(b): out.append("### Review by %s [%s]\n%s\n" % ((r.get("author") or {}).get("login", "?"), r.get("state", ""), b))
for c in p.get("comments", []) or []:
    b = c.get("body") or ""
    if not ours(b): out.append("### Comment by %s\n%s\n" % ((c.get("author") or {}).get("login", "?"), b))
for c in inline or []:
    out.append("### Inline comment by %s on %s:%s\n%s\n" % ((c.get("user") or {}).get("login", "?"), c.get("path", "?"), c.get("line") or c.get("original_line") or "?", c.get("body") or ""))
sys.stdout.write("\n".join(out) if out else "(none)")'
}

post_reviewer_review() {
  _bzr_require LOG REPO REVIEWER
  local pr_num="$1" cycle="$2" max="$3" review_file="$4"
  [ -s "$review_file" ] || return 0
  local reviewer_name body
  case "$REVIEWER" in codex) reviewer_name="Codex" ;; claude) reviewer_name="Claude" ;; *) reviewer_name="$REVIEWER" ;; esac
  body="<!-- bzr-review reviewer=$REVIEWER cycle=$cycle of=$max -->
**${reviewer_name} review — PR #${pr_num} cycle ${cycle} of ${max}**

\`\`\`
$(cat "$review_file")
\`\`\`"
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --repo "$REPO" --body-file - >> "$LOG" 2>&1 \
    || _bzr_log "  [review] WARNING: gh pr comment ($REVIEWER review) failed for PR #$pr_num"
}

# Post the codex-review=success commit status. The caller decides when; the
# cycle itself never calls this (BZR-FEAT-REVIEW-LIB invariant 3).
# Args: <sha> <pr_num> [description]
post_codex_review_status() {
  _bzr_require LOG REPO
  local sha="$1" pr_num="$2" desc="${3:-review passed}"
  gh api -X POST "repos/${REPO}/statuses/${sha}" \
    -f state=success \
    -f context=codex-review \
    -f description="$desc" \
    -f target_url="https://github.com/${REPO}/pull/${pr_num}" \
    >> "$LOG" 2>&1
}

# ---------- prompt registry ----------
# Text is verbatim from babysit-builder.sh (code) and babysit-work-prep.sh (spec).
# Keys: review_prompt <mode> <cycle> ; remediation_prompt <mode> <cycle> ;
#       remediation_model <mode> <cycle>. Unknown keys fail loudly.

IFS= read -r -d '' BZR_CODE_REVIEW_C1 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle 1 of __MAX_CYCLES__. This is the first review of this PR.

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
PROMPT_EOF

IFS= read -r -d '' BZR_CODE_REVIEW_C2 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle 2 of __MAX_CYCLES__. The previous cycle did not fully resolve BLOCKING issues.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
__HISTORY_BLOCK__
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
PROMPT_EOF

IFS= read -r -d '' BZR_CODE_REVIEW_C3_4 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. This cycle uses prescriptive mode with detailed explanations.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
__HISTORY_BLOCK__
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
PROMPT_EOF

IFS= read -r -d '' BZR_CODE_REVIEW_C5_6 <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. The implementer posted resolution justifications for the previous cycle's findings. You must adjudicate those justifications AND review the current code state.

Inspect the diff of the current branch against the project's default branch. Read changed files and surrounding context as needed to evaluate the change.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

--- implementer resolution justifications (from previous cycle) begin ---
__JUSTIFICATIONS__
--- implementer resolution justifications end ---

You have two responsibilities this cycle:

RESPONSIBILITY 1: Adjudicate the implementer's resolution justifications.
For each justification posted, you must respond:
- If a finding was claimed "resolved": examine the referenced commit and the current code. Either the fix genuinely addresses the root cause and architectural constraints, or it does not.
- If a finding was claimed "invalid": evaluate the reasoning and the cited supporting reference. Either the reference proves the finding incorrect, or it does not.

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
- You MUST adjudicate every justification the implementer posted. No justification may be silently ignored.
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
PROMPT_EOF

IFS= read -r -d '' BZR_CODE_REM_C1 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 1 of __MAX_CYCLES__. This is the first review of this PR.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

Implementation:
- Address all BLOCKING findings with minimal, targeted changes.
- Run relevant tests after each fix.
- Commit each fix separately using standard format: fix(<scope>): <what changed>
- Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

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

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

IFS= read -r -d '' BZR_CODE_REM_C2_3 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. The previous cycle(s) did not fully resolve BLOCKING issues.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

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
  - Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

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

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

IFS= read -r -d '' BZR_CODE_REM_C4 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle 4 of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

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
  - Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Step 3: Post resolution justification as PR comment:
  For EACH BLOCKING finding in the review, you must post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by the reviewer and satisfies the architectural constraints>"
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

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

IFS= read -r -d '' BZR_CODE_REM_C5_6 <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below, along with existing feedback from automated tools and human reviewers.

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple previous cycles have not resolved BLOCKING issues. The reviewer has adjudicated your previous resolution justifications.

You MUST action every BLOCKING finding before this PR can be handed to a human for merge. Treat actionable issues in existing PR feedback with the same BLOCKING priority.

**CRITICAL: Process the ADJUDICATION section first, then plan your approach inline.** Do NOT use the plan mode tool — you are running non-interactively and plan mode requires human approval to exit.

Step 1: Process the reviewer's adjudication results:
  - For each ACCEPTED item: the finding is resolved. No further action needed.
  - For each DISAGREED item: the reviewer has provided a reasoned counter-argument with code evidence. You must either:
    (a) Implement a different fix that specifically addresses the counter-argument, OR
    (b) If you believe the counter-argument is itself incorrect, report via STUCK_REVIEW with the specific finding, the reviewer's argument, and why you disagree (this escalates to human review).

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
  - Push commits to the PR branch when complete.

**Merge policy (non-negotiable):**
- NEVER run `gh pr merge`. This pipeline has no automated merge path at all — a human performs every merge after the build cycle halts.
- Do not edit issues, labels, or commit statuses; the wrapper owns all ticket and PR lifecycle changes.
- If you disagree with the review agent on a blocker and choose to override it, that decision process must be documented in detail, with supporting material, on the PR.

Step 4: Post resolution justification as PR comment:
  For EACH BLOCKING finding (including DISAGREED items you re-addressed), post a comment explaining:
  - If resolved: "BLOCKING <one-line finding description> resolved in commit <SHA>. Why this resolves it: <specific explanation of how your change addresses the root cause identified by the reviewer and satisfies the architectural constraints>"
  - If invalid: "BLOCKING <one-line finding description> is invalid. Reason: <explanation>. Supporting reference: <link to spec/docs/validated source proving the finding is incorrect>"
  - If re-addressed after disagreement: "BLOCKING <one-line finding description> re-addressed after reviewer disagreement. Previous fix was insufficient because: <acknowledge the reviewer's point>. New fix in commit <SHA>: <explanation of how the new approach resolves the concern>"

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

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

IFS= read -r -d '' BZR_SPEC_REVIEW_C1 <<'PROMPT_EOF' || true
You are adversarially reviewing a NEWLY DRAFTED specification before a human is asked to approve it. Be a skeptic: your job is to find every reason this spec should not be approved as written.

The spec under review: __SPEC_PATH__
It was drafted from this ticket:
  Ticket: __TICKET__ (__TICKET_URL__)
  Title: __TICKET_TITLE__
  Description:
  ---
  __TICKET_BODY__
  ---

This is review cycle __CYCLE__ of __MAX_CYCLES__. This is the first review of this spec.

Before judging, READ:
1. The spec under review, in full.
2. EVERY OTHER SPEC in ./__SPEC_DIR__/ — you cannot assess consistency or duplication without knowing what the corpus already says. This is the most important step and the one most easily skipped.
3. ./CLAUDE.md for project conventions.
4. The schema this corpus follows: __SPEC_GUIDE__ (read it if the path exists and is readable; if it is not, apply the criteria below on their own).
5. The actual code the spec describes, enough to tell whether its claims about current behavior are true.

Judge the spec on these criteria. A finding is BLOCKING if it would make the spec wrong to approve:

- **Contradiction with an existing spec.** The spec asserts something another spec in the corpus contradicts, without acknowledging or superseding it. Cite both files.
- **Undeclared duplication.** The spec covers work an existing spec already covers, without saying so or explaining the relationship. Cite the overlapping spec.
- **Dangling references.** Any `depends_on`, `parent_l1`, `parent_l2`, `parent_feature` or in-body spec ID that does not resolve to a real file in the corpus; broken relative links.
- **Schema violation.** Missing or malformed frontmatter keys for its layer, wrong ID scheme, missing required sections, wrong layer for what it actually describes.
- **Not implementable.** No acceptance criteria or equivalent definition of done; requirements too vague to build against; contract (inputs, outputs, error cases) left undefined.
- **Invented design decisions.** The spec states a design decision as settled that the ticket, the code, and the corpus do not establish — the author inferred it. This is the single most damaging failure mode in a spec corpus and it is easy to miss because invented decisions read as confident prose. An unconfirmed decision must be flagged `[ASSUMPTION]` with what would flip it, not asserted.
- **Claims about current behavior that are false.** The spec describes the code as doing something it does not do. Verify against the code, do not trust the prose.

Output your review using EXACTLY this format:

## BLOCKING
- <one-line description> — <file:line or spec section> — <why it must be fixed before a human approves this spec>

## RECOMMENDED
- <one-line description> — <file:line or spec section> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line or spec section> — <context, suggestion, or fyi>

Format rules:
- BLOCKING, RECOMMENDED, and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT edit any file. This is review only.
PROMPT_EOF

IFS= read -r -d '' BZR_SPEC_REVIEW_C2 <<'PROMPT_EOF' || true
You are adversarially reviewing a NEWLY DRAFTED specification before a human is asked to approve it. Be a skeptic: your job is to find every reason this spec should not be approved as written.

The spec under review: __SPEC_PATH__
It was drafted from this ticket:
  Ticket: __TICKET__ (__TICKET_URL__)
  Title: __TICKET_TITLE__
  Description:
  ---
  __TICKET_BODY__
  ---

This is review cycle __CYCLE__ of __MAX_CYCLES__. The previous cycle did not resolve every BLOCKING finding.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

Re-read the spec as it stands now, plus EVERY OTHER SPEC in ./__SPEC_DIR__/, ./CLAUDE.md, and __SPEC_GUIDE__ if readable. Do not rely on the previous cycle's reading of the corpus — the spec has changed.

Judge the spec on the same criteria as before. A finding is BLOCKING if it would make the spec wrong to approve:
- Contradiction with an existing spec (cite both files)
- Undeclared duplication of an existing spec's scope
- Dangling `depends_on` / `parent_*` / in-body spec IDs, or broken links
- Schema violation for its layer (frontmatter, ID scheme, required sections)
- Not implementable: no acceptance criteria, undefined contract, requirements too vague
- Invented design decisions asserted as settled rather than flagged `[ASSUMPTION]`
- False claims about what the code currently does

Watch specifically for regressions: a fix for one finding that introduced a new contradiction, or a requirement quietly deleted rather than resolved.

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line or spec section> — <why it must be fixed before a human approves this spec>

## RECOMMENDED
- <one-line description> — <file:line or spec section> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line or spec section> — <context, suggestion, or fyi>

Convergence tracking:
- Mark each BLOCKING finding [NEW] if it was not flagged in a previous cycle, or [RECURRENCE] if it was flagged before and remains unresolved.

Format rules:
- BLOCKING bullets start with the [NEW|RECURRENCE] tag, then a single-line description.
- RECOMMENDED and INFORMATION are single-line bullets only (no tags).
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT edit any file. This is review only.
PROMPT_EOF

IFS= read -r -d '' BZR_SPEC_REVIEW_C3 <<'PROMPT_EOF' || true
You are adversarially reviewing a NEWLY DRAFTED specification before a human is asked to approve it. Be a skeptic, but this cycle you must also be constructive.

The spec under review: __SPEC_PATH__
It was drafted from this ticket:
  Ticket: __TICKET__ (__TICKET_URL__)
  Title: __TICKET_TITLE__
  Description:
  ---
  __TICKET_BODY__
  ---

This is review cycle __CYCLE__ of __MAX_CYCLES__. Multiple cycles have not resolved every BLOCKING finding. This cycle uses prescriptive mode.

--- cycle history begin ---
__HISTORY_BLOCK__
--- cycle history end ---

Re-read the spec as it stands now, plus EVERY OTHER SPEC in ./__SPEC_DIR__/, ./CLAUDE.md, and __SPEC_GUIDE__ if readable.

Same criteria as previous cycles (contradiction, undeclared duplication, dangling references, schema violation, not implementable, invented design decisions, false claims about the code).

**Prescriptive requirement:** every BLOCKING finding MUST carry a concrete `Suggested wording:` line — the actual replacement text or frontmatter change the spec should carry. If you cannot write the replacement yourself, you do not understand the finding well enough to block on it: downgrade it to RECOMMENDED.

**A note on convergence:** if a finding recurs because the underlying question is a design decision nobody has made, the correct resolution is NOT to keep demanding a different answer. It is to require the spec to flag it `[ASSUMPTION]` with a "Flips if:" clause and move on. Specs are allowed to have open questions; they are not allowed to hide them.

Output your review using EXACTLY this format:

## BLOCKING
- [NEW|RECURRENCE] <one-line description> — <file:line or spec section> — <why it must be fixed before a human approves this spec>
  Suggested wording: <the concrete replacement text or frontmatter change>

## RECOMMENDED
- <one-line description> — <file:line or spec section> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line or spec section> — <context, suggestion, or fyi>

Format rules:
- BLOCKING bullets are the tagged description line plus the required `Suggested wording:` line, indented two spaces.
- RECOMMENDED and INFORMATION are single-line bullets only.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT edit any file. This is review only.
PROMPT_EOF

IFS= read -r -d '' BZR_SPEC_REM <<'PROMPT_EOF' || true
An adversarial review of the specification you drafted has produced the findings below. This is cycle __CYCLE__ of __MAX_CYCLES__.

The spec under review: __SPEC_PATH__

You MUST resolve every BLOCKING finding before this spec can go to a human for approval.

How to resolve each kind of finding:
- **Contradiction / undeclared duplication with an existing spec:** read the spec named in the finding. Either reconcile the wording, or state the relationship explicitly (supersedes, extends, narrows). Do not silently delete the conflicting requirement.
- **Dangling reference:** fix the ID or the link. If the referenced spec genuinely does not exist yet, say so in the body rather than pointing at a file that isn't there.
- **Schema violation:** fix the frontmatter, ID, or section layout to match the corpus convention.
- **Not implementable:** add the missing acceptance criteria or contract detail. If you cannot, that is itself the finding — flag it.
- **Invented design decision:** you asserted something the ticket, the code, and the corpus do not establish. Do NOT invent a better-sounding answer. Convert it to an `[ASSUMPTION]` with a "Flips if:" clause so the owner can confirm or correct it. Getting an open question flagged is a success, not a failure.
- **False claim about current behavior:** verify against the code and correct the spec to describe what the code actually does.

Constraints — these are hard:
- Edit ONLY files under the spec directory ./__SPEC_DIR__: the spec(s) under review (__SPEC_PATH__), the corpus's `index.md` and `log.md`, and any corpus support files the schema keeps there (evidence, decisions, plans). Do NOT change code, tests, configuration, or any file outside that directory. The wrapper verifies this after every cycle and will bail the review if you touch anything else.
- If the corpus has a `log.md`, append one entry per revision cycle recording what the review flagged and what you changed (the schema requires it, and reviewers block on a stale log). Keep `index.md` rows in step with any status, id, or description change.
- Commit your revisions with a message explaining what the review flagged and what you changed.
- Do NOT push, do NOT open or edit a PR, do NOT comment on GitHub, do NOT edit issues or labels. The wrapper owns every lifecycle action.
- Do NOT mark the spec `status: ready`. Only the owner does that.

If you believe a BLOCKING finding is wrong, you may leave it unresolved — but you must add a short note in the spec explaining why the reviewer's reading is incorrect, with a citation. Silent refusal is not acceptable; the next review cycle will simply flag it again.

End your final message with EXACTLY ONE of these sentinels on its own line:
- DONE_REVIEW (you have addressed everything you intend to address)
- STUCK_REVIEW <one-line reason> (you cannot proceed)

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

review_prompt() {
  local mode="$1" cycle="$2"
  case "$mode:$cycle" in
    code:1) printf '%s' "$BZR_CODE_REVIEW_C1" ;;
    code:2) printf '%s' "$BZR_CODE_REVIEW_C2" ;;
    code:3|code:4) printf '%s' "$BZR_CODE_REVIEW_C3_4" ;;
    code:*) printf '%s' "$BZR_CODE_REVIEW_C5_6" ;;
    spec:1) printf '%s' "$BZR_SPEC_REVIEW_C1" ;;
    spec:2) printf '%s' "$BZR_SPEC_REVIEW_C2" ;;
    spec:*) printf '%s' "$BZR_SPEC_REVIEW_C3" ;;   # prescriptive; spec mode never adjudicates
    *) echo "bazaar-review: no review prompt for mode='$mode'" >&2; return 2 ;;
  esac
}

review_prompt_name() {
  local mode="$1" cycle="$2"
  case "$mode:$cycle" in
    code:1) echo descriptive-baseline ;;
    code:2) echo descriptive-convergence ;;
    code:3|code:4) echo prescriptive-detailed ;;
    code:*) echo prescriptive-adjudication ;;
    spec:1) echo spec-baseline ;;
    spec:2) echo spec-convergence ;;
    spec:*) echo spec-prescriptive ;;
    *) return 2 ;;
  esac
}

remediation_prompt() {
  local mode="$1" cycle="$2"
  case "$mode:$cycle" in
    code:1) printf '%s' "$BZR_CODE_REM_C1" ;;
    code:2|code:3) printf '%s' "$BZR_CODE_REM_C2_3" ;;
    code:4) printf '%s' "$BZR_CODE_REM_C4" ;;
    code:*) printf '%s' "$BZR_CODE_REM_C5_6" ;;
    spec:*) printf '%s' "$BZR_SPEC_REM" ;;
    *) echo "bazaar-review: no remediation prompt for mode='$mode'" >&2; return 2 ;;
  esac
}

# Stage model per cycle (babysit-builder.sh:1245-1251). Spec mode uses the stage default.
remediation_model() {
  local mode="$1" cycle="$2"
  case "$mode:$cycle" in
    code:1|code:2|code:3) echo claude-sonnet-5 ;;
    code:*) echo claude-opus-4-8 ;;
    *) echo claude-sonnet-5 ;;
  esac
}

# ---------- the cycle ----------

# run_review_cycle --mode code|spec --pr N --worktree DIR --branch NAME
#                  [--max-cycles N] [--validate-cmd CMD]
#                  [--spec-path P --spec-dir D --spec-guide G
#                   --ticket T --ticket-url U --ticket-title S --ticket-body B]
#
# Returns: 0 converged (BLOCKING=0, worktree pushed)
#          10 cycle cap hit with BLOCKING open (worktree pushed)
#          20 bail: reviewer failed (rc 1), implementer failed / STUCK_REVIEW /
#             no progress / validate-cmd failed / parse error
#          2 reviewer transport outage  3 codex too old  4 codex no credits
# Side effects: reviewer output posted as a PR comment each cycle; pushes the
# worktree to origin/<branch> after each remediation and at the end. Never
# labels, never toggles draft, never posts a commit status, never merges.
run_review_cycle() {
  _bzr_require LOG TMP_REVIEW TMP_REVIEW_RESULT REPO IMPLEMENTER REVIEWER
  local mode="" pr_num="" worktree="" branch="" max_cycles="" validate_cmd=""
  local spec_path="" spec_dir="" spec_guide="" ticket="" ticket_url="" ticket_title="" ticket_body=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --pr) pr_num="$2"; shift 2 ;;
      --worktree) worktree="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --max-cycles) max_cycles="$2"; shift 2 ;;
      --validate-cmd) validate_cmd="$2"; shift 2 ;;
      --spec-path) spec_path="$2"; shift 2 ;;
      --spec-dir) spec_dir="$2"; shift 2 ;;
      --spec-guide) spec_guide="$2"; shift 2 ;;
      --ticket) ticket="$2"; shift 2 ;;
      --ticket-url) ticket_url="$2"; shift 2 ;;
      --ticket-title) ticket_title="$2"; shift 2 ;;
      --ticket-body) ticket_body="$2"; shift 2 ;;
      *) echo "bazaar-review: run_review_cycle: unknown option '$1'" >&2; return 2 ;;
    esac
  done
  case "$mode" in code|spec) ;; *) echo "bazaar-review: --mode must be code|spec" >&2; return 2 ;; esac
  [ -n "$pr_num" ] && [ -n "$worktree" ] && [ -n "$branch" ] || { echo "bazaar-review: --pr, --worktree, --branch are required" >&2; return 2; }
  if [ -z "$max_cycles" ]; then
    if [ "$mode" = code ]; then max_cycles="${MAX_REVIEW_CYCLES:-6}"; else max_cycles="${MAX_SPEC_REVIEW_CYCLES:-6}"; fi
  fi
  [ "$REVIEWER" = codex ] && _bzr_require TMP_CODEX_FULL

  REVIEW_WORKDIR="$worktree"
  REVIEW_LAST_FILE=""; REVIEW_CYCLES_RUN=0; REVIEW_FAIL_REASON=""
  local cycle=0 review_start_sha="" justifications="" tag="[review:$mode]"
  local -a REVIEW_HISTORY=()

  _bzr_log "=== $mode review cycle: PR #$pr_num @ $(date -u +%FT%TZ) ==="
  review_start_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo "")

  while [ "$cycle" -lt "$max_cycles" ]; do
    cycle=$((cycle + 1)); REVIEW_CYCLES_RUN=$cycle
    _bzr_log "--- $mode review cycle $cycle / $max_cycles (PR #$pr_num) @ $(date -u +%FT%TZ) ---"

    local history_block=""
    if [ "$cycle" -ge 2 ] && [ "${#REVIEW_HISTORY[@]}" -gt 0 ]; then
      local _hb="" _i _commits
      for _i in "${!REVIEW_HISTORY[@]}"; do
        _hb="${_hb}### cycle $(( _i + 1 )) review
${REVIEW_HISTORY[$_i]}
"
      done
      _commits=$(git -C "$worktree" log --oneline "${review_start_sha}..HEAD" 2>/dev/null || true)
      _hb="${_hb}--- commits the implementer made since the review cycle started ---
${_commits:-"(none)"}
--- end commits ---
"
      history_block="--- prior review cycles (for convergence tracking) ---
${_hb}--- end prior review cycles ---
"
      unset _hb _i _commits
    fi

    local review_prompt
    review_prompt=$(review_prompt "$mode" "$cycle") || return 2
    review_prompt="${review_prompt//__PR_NUMBER__/$pr_num}"
    review_prompt="${review_prompt//__CYCLE__/$cycle}"
    review_prompt="${review_prompt//__MAX_CYCLES__/$max_cycles}"
    review_prompt="${review_prompt//__HISTORY_BLOCK__/$history_block}"
    review_prompt="${review_prompt//__JUSTIFICATIONS__/$justifications}"
    review_prompt="${review_prompt//__SPEC_PATH__/$spec_path}"
    review_prompt="${review_prompt//__SPEC_DIR__/$spec_dir}"
    review_prompt="${review_prompt//__SPEC_GUIDE__/$spec_guide}"
    review_prompt="${review_prompt//__TICKET__/$ticket}"
    review_prompt="${review_prompt//__TICKET_URL__/$ticket_url}"
    review_prompt="${review_prompt//__TICKET_TITLE__/$ticket_title}"
    review_prompt="${review_prompt//__TICKET_BODY__/$ticket_body}"
    _bzr_log "  [$REVIEWER reviewer] template=$(review_prompt_name "$mode" "$cycle") cycle=${cycle}/${max_cycles}"

    local reviewer_rc=0
    review_with_retry "$review_prompt" || reviewer_rc=$?
    case "$reviewer_rc" in
      0) ;;
      2) REVIEW_FAIL_REASON="reviewer transport failure after retries (cycle $cycle)"; return 2 ;;
      3) REVIEW_FAIL_REASON="Codex CLI too old for the configured model (cycle $cycle)"; return 3 ;;
      4) REVIEW_FAIL_REASON="Codex workspace out of credits (cycle $cycle)"; return 4 ;;
      *) REVIEW_FAIL_REASON="$REVIEWER review failed during cycle $cycle"; return 20 ;;
    esac

    local review
    review=$(cat "$TMP_REVIEW")
    REVIEW_HISTORY+=("$review")
    cp "$TMP_REVIEW" "${TMP_REVIEW}.c${cycle}"
    REVIEW_LAST_FILE="${TMP_REVIEW}.c${cycle}"
    post_reviewer_review "$pr_num" "$cycle" "$max_cycles" "$TMP_REVIEW"
    {
      echo "--- $REVIEWER $mode review (cycle $cycle) ---"
      printf '%s\n' "$review"
      echo "--- end $REVIEWER $mode review ---"
    } >> "$LOG"

    local n_blocking
    n_blocking=$(printf '%s\n' "$review" | count_blocking)
    if ! [[ "$n_blocking" =~ ^[0-9]+$ ]]; then
      REVIEW_FAIL_REASON="count_blocking produced non-integer output ('$n_blocking') in cycle $cycle"
      return 20
    fi
    local n_recommended
    n_recommended=$(printf '%s\n' "$review" | awk '
      /^## RECOMMENDED[[:space:]]*$/ { s = 1; next }
      /^## / { s = 0; next }
      s && /^-[[:space:]]/ { line = $0; sub(/^-[[:space:]]+/, "", line); if (line != "(none)") n++ }
      END { print n + 0 }')
    echo "$tag PR #$pr_num → cycle $cycle: $n_blocking BLOCKING, $n_recommended RECOMMENDED"
    _bzr_log "  $tag cycle=$cycle blocking=$n_blocking recommended=$n_recommended new=$(printf '%s\n' "$review" | grep -c '^- \[NEW\]' || true) recurrence=$(printf '%s\n' "$review" | grep -c '^- \[RECURRENCE\]' || true)"

    if [ "$n_blocking" -eq 0 ]; then
      _bzr_log "  $tag zero blocking findings; PR #$pr_num converged after $cycle cycle(s)"
      if ! git -C "$worktree" push origin "HEAD:refs/heads/$branch" >> "$LOG" 2>&1; then
        REVIEW_FAIL_REASON="converged but the final push to origin/$branch failed"
        return 20
      fi
      return 0
    fi

    # ---- implementer remediation pass ----
    local pr_feedback="(none)"
    [ "$mode" = code ] && { pr_feedback=$(collect_pr_feedback "$pr_num" 2>> "$LOG"); [ -z "$pr_feedback" ] && pr_feedback="(none)"; }

    local rem_prompt rem_model
    rem_prompt=$(remediation_prompt "$mode" "$cycle") || return 2
    rem_model=$(remediation_model "$mode" "$cycle")
    rem_prompt="${rem_prompt//__PR_NUMBER__/$pr_num}"
    rem_prompt="${rem_prompt//__CYCLE__/$cycle}"
    rem_prompt="${rem_prompt//__MAX_CYCLES__/$max_cycles}"
    rem_prompt="${rem_prompt//__REVIEW__/$review}"
    rem_prompt="${rem_prompt//__PR_FEEDBACK__/$pr_feedback}"
    rem_prompt="${rem_prompt//__SPEC_PATH__/$spec_path}"

    local pre_sha post_sha
    pre_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo "")
    echo "  [$IMPLEMENTER implementer] addressing findings for PR #$pr_num (cycle $cycle)..." >&2
    if ! run_implementer "$rem_prompt" "$TMP_REVIEW_RESULT" "$worktree" "$rem_model"; then
      REVIEW_FAIL_REASON="$IMPLEMENTER exited non-zero while addressing review (cycle $cycle)"
      return 20
    fi

    local last_line
    last_line=$(sed -e 's/[[:space:]]*$//' "$TMP_REVIEW_RESULT" | grep -v '^$' | tail -n 1)
    case "$last_line" in
      "STUCK_REVIEW"*)
        _bzr_log "  [$IMPLEMENTER implementer] $last_line — bailing review cycle"
        REVIEW_FAIL_REASON="$IMPLEMENTER reported ${last_line} (cycle $cycle)"
        return 20 ;;
    esac

    if [ -n "$validate_cmd" ] && ! eval "$validate_cmd" >> "$LOG" 2>&1; then
      REVIEW_FAIL_REASON="post-remediation validation failed (cycle $cycle): $validate_cmd"
      return 20
    fi

    post_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$pre_sha" ] && [ "$pre_sha" = "$post_sha" ]; then
      REVIEW_FAIL_REASON="$IMPLEMENTER made no commits while addressing review (cycle $cycle)"
      return 20
    fi

    git -C "$worktree" push origin "HEAD:refs/heads/$branch" >> "$LOG" 2>&1 \
      || _bzr_log "  $tag WARNING: push to origin/$branch failed after cycle $cycle"

    if [ "$mode" = code ] && [ "$cycle" -ge 4 ]; then
      justifications=$(gh pr view "$pr_num" --repo "$REPO" --json comments -q '.comments[-1].body' 2>/dev/null || echo "")
    fi
  done

  git -C "$worktree" push origin "HEAD:refs/heads/$branch" >> "$LOG" 2>&1 || true
  REVIEW_FAIL_REASON="$max_cycles cycles did not clear every BLOCKING finding"
  return 10
}
