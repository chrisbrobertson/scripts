#!/bin/bash
# test-codex-review.sh — smoke-test the codex review pass + count_blocking
# parser used by babysit-with-review.sh, against a real PR.
#
# Usage: cd into a project dir, then:
#   test-codex-review.sh <PR_NUMBER>
#
# Runs `codex exec -s read-only` with the same strict-format prompt the
# wrapper uses, parses BLOCKING findings with the same awk logic, and
# reports counts. Does NOT run claude, push commits, or modify the PR.

set -uo pipefail

PR_NUM="${1:-}"
if [ -z "$PR_NUM" ] || ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <PR_NUMBER>" >&2
  exit 2
fi

LOG_DIR="$HOME/sisyphus-logs"
mkdir -p "$LOG_DIR"
PROJECT=$(basename "$PWD")
LOG="$LOG_DIR/test-codex-review-${PROJECT}-pr${PR_NUM}-$(date +%Y%m%d-%H%M%S).log"
TMP_REVIEW=$(mktemp)
trap 'rm -f "$TMP_REVIEW"' EXIT

touch "$LOG"
echo "test-codex-review: PR #$PR_NUM in $PROJECT → $LOG"

# Same codex review prompt template as babysit-with-review.sh.
IFS= read -r -d '' CODEX_REVIEW_PROMPT_TEMPLATE <<'PROMPT_EOF' || true
You are performing a code review on PR #__PR_NUMBER__ for this repository. The PR branch is currently checked out.

Inspect the diff of the current branch against the project's default branch (use `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` to find it, then `git diff <default>...HEAD`). Read changed files and surrounding context as needed to evaluate the change.

Output your review using EXACTLY this format. Use all three headings in this order, even if a section has no findings:

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
- One bullet per finding. Be concise — single line, three em-dash-separated parts.
- If a section has no findings, write `- (none)` as the only bullet under that heading.
- Do NOT output anything before, between, or after the three sections.
- Do NOT make code changes. This is review only.
PROMPT_EOF

# Same count_blocking logic as babysit-with-review.sh.
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

# Same per-section count for reporting.
count_section() {
  local section="$1"
  awk -v sec="^## ${section}[[:space:]]*$" '
    BEGIN { in_block = 0; n = 0 }
    $0 ~ sec                   { in_block = 1; next }
    /^## /                     { in_block = 0; next }
    in_block && /^-[[:space:]]/ {
      line = $0
      sub(/^-[[:space:]]+/, "", line)
      if (line == "(none)") next
      n++
    }
    END { print n }
  '
}

ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
echo "  [setup] orig branch: $ORIG_BRANCH"
echo "  [setup] checking out PR #$PR_NUM..."
if ! gh pr checkout "$PR_NUM" >>"$LOG" 2>&1; then
  echo "ERROR: gh pr checkout $PR_NUM failed; see $LOG" >&2
  exit 1
fi
echo "  [setup] now on: $(git rev-parse --abbrev-ref HEAD)"

CODEX_PROMPT="${CODEX_REVIEW_PROMPT_TEMPLATE//__PR_NUMBER__/$PR_NUM}"

echo "--- codex review begin ---" >> "$LOG"
echo "  [codex] running review (this may take several minutes)..."

START=$(date +%s)
if ! codex exec \
    --output-last-message "$TMP_REVIEW" \
    -s read-only \
    "$CODEX_PROMPT" 2>&1 \
    | tee -a "$LOG" >&2 ; then
  echo "ERROR: codex exec returned non-zero; see $LOG" >&2
  RC=$?
fi
END=$(date +%s)
ELAPSED=$((END - START))

echo "--- codex review end (${ELAPSED}s) ---" >> "$LOG"

echo ""
echo "===================================================================="
echo "Codex pass complete in ${ELAPSED}s. Review saved to: $TMP_REVIEW"
echo "===================================================================="

if [ ! -s "$TMP_REVIEW" ]; then
  echo "FAIL: codex produced empty output" >&2
  echo "  (full codex log in $LOG)"
  if [ -n "$ORIG_BRANCH" ] && [ "$ORIG_BRANCH" != "HEAD" ]; then
    git checkout "$ORIG_BRANCH" >>"$LOG" 2>&1 || true
  fi
  exit 1
fi

REVIEW=$(cat "$TMP_REVIEW")

echo ""
echo "----- raw review output -----"
printf '%s\n' "$REVIEW"
echo "----- end raw review -----"
echo ""

# Save raw review verbatim into the log too.
{
  echo "--- raw review ---"
  printf '%s\n' "$REVIEW"
  echo "--- end raw review ---"
} >> "$LOG"

N_BLOCKING=$(printf '%s\n' "$REVIEW" | count_blocking)
N_RECOMMENDED=$(printf '%s\n' "$REVIEW" | count_section "RECOMMENDED")
N_INFORMATION=$(printf '%s\n' "$REVIEW" | count_section "INFORMATION")

echo "----- parser results -----"
printf "  BLOCKING:    %s\n" "$N_BLOCKING"
printf "  RECOMMENDED: %s\n" "$N_RECOMMENDED"
printf "  INFORMATION: %s\n" "$N_INFORMATION"
echo "----- end parser results -----"

# Check format compliance.
HAS_B=$(printf '%s\n' "$REVIEW" | grep -c '^## BLOCKING[[:space:]]*$' || true)
HAS_R=$(printf '%s\n' "$REVIEW" | grep -c '^## RECOMMENDED[[:space:]]*$' || true)
HAS_I=$(printf '%s\n' "$REVIEW" | grep -c '^## INFORMATION[[:space:]]*$' || true)
echo ""
echo "----- format compliance -----"
echo "  ## BLOCKING heading present:    $([ "$HAS_B" = "1" ] && echo yes || echo "NO ($HAS_B)")"
echo "  ## RECOMMENDED heading present: $([ "$HAS_R" = "1" ] && echo yes || echo "NO ($HAS_R)")"
echo "  ## INFORMATION heading present: $([ "$HAS_I" = "1" ] && echo yes || echo "NO ($HAS_I)")"
echo "----- end format compliance -----"

# Restore branch.
if [ -n "$ORIG_BRANCH" ] && [ "$ORIG_BRANCH" != "HEAD" ]; then
  echo ""
  echo "  [cleanup] restoring branch: $ORIG_BRANCH"
  git checkout "$ORIG_BRANCH" >>"$LOG" 2>&1 || true
fi

echo ""
echo "Done. Full log: $LOG"
