#!/bin/bash
# run-retrospective-review.sh — one-shot Codex review for PRs that merged without automated review.
#
# Reviews the PR diff at the merge commit SHA, posts findings as a closed-PR comment,
# and opens one GitHub issue per blocking finding.
#
# Usage:
#   run-retrospective-review.sh [--repo OWNER/REPO] [--dry-run] [--no-issues]
#                                [--label LABEL] PR_NUMBER [PR_NUMBER ...]
#
#   Input can also come from stdin (TSV, second column = PR number — the shape
#   produced by find-bailed-merged-prs.sh):
#     find-bailed-merged-prs.sh --repo OWNER/REPO | run-retrospective-review.sh --repo OWNER/REPO
#
# Flags:
#   --repo OWNER/REPO   GitHub repo (required unless inferrable from gh context)
#   --dry-run           Print what would be posted/created; make no gh API calls
#   --no-issues         Post reviews but do not create follow-up issues
#   --label LABEL       Additional label to add to created issues (repeatable)
#
# Exit codes:
#   0   Completed (partial success: per-PR failures are logged, not fatal)
#   1   Fatal: bad arguments, gh auth failure, or all PRs failed

set -uo pipefail

# ---- arg parsing ----

REPO=""
DRY_RUN=0
NO_ISSUES=0
EXTRA_LABELS=()
PR_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --no-issues) NO_ISSUES=1; shift ;;
    --label)     EXTRA_LABELS+=("$2"); shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --)  shift; PR_ARGS+=("$@"); break ;;
    -*)  echo "Unknown argument: $1" >&2; exit 2 ;;
    *)   PR_ARGS+=("$1"); shift ;;
  esac
done

# Read PR numbers from stdin if piped (TSV: second column = PR number,
# matching the output shape of find-bailed-merged-prs.sh).
if [ ! -t 0 ]; then
  while IFS= read -r tsv_line; do
    pr_col=$(printf '%s' "$tsv_line" | awk -F'\t' '{print $2}')
    [[ "$pr_col" =~ ^[0-9]+$ ]] && PR_ARGS+=("$pr_col")
  done
fi

if [ "${#PR_ARGS[@]}" -eq 0 ]; then
  echo "ERROR: no PR numbers provided (pass as arguments or pipe TSV from find-bailed-merged-prs.sh)" >&2
  exit 1
fi

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
  if [ -z "$REPO" ]; then
    echo "ERROR: --repo OWNER/REPO is required (or run from inside a git repo with a GitHub remote)" >&2
    exit 1
  fi
fi

# ---- telltale regexes (same as babysit-with-review.sh) ----

COMPAT_RE='requires a newer version of Codex'
MCP_RE='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'
IDEMPOTENCY_PREFIX='<!-- retrospective-review: pr='

# ---- codex prompt template ----
# __PR_NUMBER__, __REPO__, __MERGED_AT__, __DIFF__ are substituted at runtime.

IFS= read -r -d '' CODEX_RETRO_PROMPT <<'PROMPT_EOF' || true
[RETROSPECTIVE REVIEW] You are performing a retrospective code review on PR #__PR_NUMBER__ in repository __REPO__, which merged on __MERGED_AT__ without automated review.

Review the diff below exactly as you would a live PR: look for correctness bugs, security issues, broken contracts, missing error handling, and code quality issues.

--- diff begin ---
__DIFF__
--- diff end ---

Output your review using EXACTLY this format (required section headers; no other text before, between, or after them):

## BLOCKING
- <one-line description> — <file:line> — <why it must be fixed>

## RECOMMENDED
- <one-line description> — <file:line> — <why it should be addressed>

## INFORMATION
- <one-line description> — <file:line> — <context, alternative, or fyi>

Categorization:
- BLOCKING = correctness bugs, security issues, broken tests, contract violations — anything that should not have merged.
- RECOMMENDED = quality improvements, missed edge cases, better patterns, error-handling gaps.
- INFORMATION = stylistic notes, alternative approaches, performance observations.

If a section has no findings, write `- (none)` as the only bullet under that heading.

Note at the top of your INFORMATION section: "Reviewer note: verify all BLOCKING findings against current HEAD before acting — subsequent commits may have already addressed them."
PROMPT_EOF

# ---- helpers ----

count_blocking_from_file() {
  awk '
    BEGIN { in_block = 0; n = 0 }
    /^## BLOCKING[[:space:]]*$/ { in_block = 1; next }
    /^## /                      { in_block = 0; next }
    in_block && /^-[[:space:]]/ {
      line = $0; sub(/^-[[:space:]]+/, "", line)
      if (line != "(none)") n++
    }
    END { print n }
  ' "$1"
}

extract_blocking_lines_from_file() {
  awk '
    /^## BLOCKING[[:space:]]*$/ { in_block = 1; next }
    /^## /                      { in_block = 0; next }
    in_block && /^-[[:space:]]/ {
      line = $0; sub(/^-[[:space:]]+/, "", line)
      if (line != "(none)") print line
    }
  ' "$1"
}

# Global worktree + tempfile cleanup (spec invariant #3: cleaned on EXIT).
_CLEANUP_WTS=()
_CLEANUP_FILES=()
_cleanup_exit() {
  for wt in "${_CLEANUP_WTS[@]+"${_CLEANUP_WTS[@]}"}"; do
    git worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$wt"
  done
  rm -f "${_CLEANUP_FILES[@]+"${_CLEANUP_FILES[@]}"}"
}
trap '_cleanup_exit' EXIT

# ---- per-PR review ----

n_reviewed=0
n_skipped=0
n_failed=0

for pr_num in "${PR_ARGS[@]}"; do
  if ! [[ "$pr_num" =~ ^[0-9]+$ ]]; then
    echo "WARNING: skipping non-numeric PR argument '$pr_num'" >&2
    n_skipped=$((n_skipped + 1))
    continue
  fi

  echo "=== PR #$pr_num ===" >&2

  # ---- fetch PR metadata ----
  pr_json=$(gh pr view "$pr_num" --repo "$REPO" \
    --json number,state,mergedAt,title,mergeCommit 2>/dev/null) || {
    echo "PR #$pr_num: gh pr view failed → skipped" >&2
    n_failed=$((n_failed + 1))
    continue
  }

  _parsed=$(printf '%s' "$pr_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
mc = d.get("mergeCommit") or {}
print(d.get("state") or "")
print(mc.get("oid") or "")
print(d.get("mergedAt") or "unknown")
' 2>/dev/null) || _parsed=""
  pr_state=$(printf '%s\n' "$_parsed" | sed -n '1p')
  merge_sha=$(printf '%s\n' "$_parsed" | sed -n '2p')
  merged_at=$(printf '%s\n' "$_parsed" | sed -n '3p')
  unset _parsed

  if [ "$pr_state" != "MERGED" ]; then
    echo "PR #$pr_num: not merged → skipped (state=$pr_state)"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  if [ -z "$merge_sha" ]; then
    echo "PR #$pr_num: no mergeCommit SHA available → skipped" >&2
    n_failed=$((n_failed + 1))
    continue
  fi

  # ---- idempotency check (spec invariant #2) ----
  marker="${IDEMPOTENCY_PREFIX}${pr_num} -->"
  existing_marker=$(gh pr view "$pr_num" --repo "$REPO" \
    --json comments -q '.comments[].body' 2>/dev/null \
    | grep -F "$marker" | head -1 || echo "")
  if [ -n "$existing_marker" ]; then
    echo "PR #$pr_num: already reviewed → skipped (idempotent)"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "PR #$pr_num: [dry-run] would review at SHA $merge_sha (merged $merged_at)"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  # ---- worktree at merge SHA (spec invariant #1: scope at merge commit) ----
  wt_dir=$(mktemp -d)
  tmp_review=$(mktemp)
  tmp_codex_full=$(mktemp)
  _CLEANUP_WTS+=("$wt_dir")
  _CLEANUP_FILES+=("$tmp_review" "$tmp_codex_full")

  # Ensure the SHA is locally reachable.
  git fetch origin "$merge_sha" 2>/dev/null \
    || git fetch origin 2>/dev/null \
    || true

  if ! git worktree add "$wt_dir" "$merge_sha" 2>/dev/null; then
    echo "PR #$pr_num: worktree creation failed at $merge_sha → skipped" >&2
    n_failed=$((n_failed + 1))
    continue
  fi

  # ---- get diff ----
  pr_diff=$(gh pr diff "$pr_num" --repo "$REPO" 2>/dev/null \
    || git -C "$wt_dir" diff "${merge_sha}^..${merge_sha}" 2>/dev/null \
    || echo "(diff unavailable)")

  # ---- build codex prompt ----
  codex_prompt="${CODEX_RETRO_PROMPT//__PR_NUMBER__/$pr_num}"
  codex_prompt="${codex_prompt//__REPO__/$REPO}"
  codex_prompt="${codex_prompt//__MERGED_AT__/$merged_at}"
  codex_prompt="${codex_prompt//__DIFF__/$pr_diff}"

  # ---- codex with retry (same logic as codex_review_with_retry in babysit-with-review.sh) ----
  delays=(0 60 300)
  codex_rc=0
  review_ok=0
  compat_failed=0

  for attempt in 1 2 3; do
    if [ "${delays[$((attempt - 1))]}" -gt 0 ]; then
      echo "  [codex] waiting ${delays[$((attempt - 1))]}s before retry (attempt $attempt of 3)..." >&2
      sleep "${delays[$((attempt - 1))]}"
    fi
    : > "$tmp_review"
    : > "$tmp_codex_full"

    codex_rc=0
    set +e
    # Run from inside the worktree so Codex sees the repo at merge time.
    (cd "$wt_dir" && codex exec --output-last-message "$tmp_review" -s read-only "$codex_prompt") 2>&1 \
      | tee "$tmp_codex_full" >&2
    codex_rc=${PIPESTATUS[0]}
    set -e

    # Compat check first — no retry, caller must upgrade CLI.
    if grep -qE "$COMPAT_RE" "$tmp_codex_full" 2>/dev/null; then
      echo "PR #$pr_num: Codex failure (compat) → skipped (upgrade Codex CLI before retrying)" >&2
      compat_failed=1
      break
    fi

    # Structural validation: require all three section headers.
    if [ "$codex_rc" -eq 0 ] && [ -s "$tmp_review" ]; then
      if grep -qE '^## BLOCKING[[:space:]]*$' "$tmp_review" 2>/dev/null \
          && grep -qE '^## RECOMMENDED[[:space:]]*$' "$tmp_review" 2>/dev/null \
          && grep -qE '^## INFORMATION[[:space:]]*$' "$tmp_review" 2>/dev/null; then
        review_ok=1
        break
      fi
      echo "  [codex] exit 0 but review missing required section headers; treating as failure" >&2
    fi

    # MCP transport failure — retry.
    if grep -qE "$MCP_RE" "$tmp_codex_full" 2>/dev/null; then
      echo "  [codex] MCP transport failure on attempt $attempt of 3 (rc=$codex_rc)" >&2
      [ "$attempt" -lt 3 ] && continue
    fi

    break  # non-transport failure or last MCP retry: stop
  done

  if [ "$compat_failed" -eq 1 ]; then
    n_skipped=$((n_skipped + 1))
    # Eager cleanup (spec invariant #3 note: don't accumulate worktrees mid-run).
    git worktree remove --force "$wt_dir" 2>/dev/null || true
    rm -rf "$wt_dir"
    continue
  fi

  if [ "$review_ok" -ne 1 ]; then
    echo "PR #$pr_num: Codex review failed (rc=$codex_rc) → skipped" >&2
    n_failed=$((n_failed + 1))
    git worktree remove --force "$wt_dir" 2>/dev/null || true
    rm -rf "$wt_dir"
    continue
  fi

  review=$(cat "$tmp_review")

  # ---- count blocking findings ----
  n_blocking=$(count_blocking_from_file "$tmp_review")
  if ! [[ "$n_blocking" =~ ^[0-9]+$ ]]; then
    n_blocking=0
  fi

  # ---- post review comment ----
  if [ "$n_blocking" -eq 0 ]; then
    review_header="**[RETROSPECTIVE REVIEW — PASSED]** (PR #$pr_num, merged $merged_at)"
  else
    review_header="**[RETROSPECTIVE REVIEW — $n_blocking BLOCKING finding(s)]** (PR #$pr_num, merged $merged_at)"
  fi

  comment_body="${review_header}

${IDEMPOTENCY_PREFIX}${pr_num} -->

${review}

---
*Generated retrospectively at merge commit \`${merge_sha}\` by \`run-retrospective-review.sh\`. Verify all BLOCKING findings against current HEAD before acting — subsequent commits may have already addressed them.*"

  if ! printf '%s\n' "$comment_body" \
      | gh pr comment "$pr_num" --repo "$REPO" --body-file - >/dev/null 2>&1; then
    echo "PR #$pr_num: failed to post review comment → skipped" >&2
    n_failed=$((n_failed + 1))
    git worktree remove --force "$wt_dir" 2>/dev/null || true
    rm -rf "$wt_dir"
    continue
  fi

  pr_url="https://github.com/${REPO}/pull/${pr_num}"

  # ---- create GitHub issues for blocking findings (spec invariant #5: dedup) ----
  n_issues_created=0
  if [ "$n_blocking" -gt 0 ] && [ "$NO_ISSUES" -eq 0 ]; then
    # Ensure required labels exist (best-effort; idempotent via --force).
    for lbl_name in "retrospective" "priority:high"; do
      gh label create "$lbl_name" --force --repo "$REPO" >/dev/null 2>&1 || true
    done

    issue_labels="retrospective,priority:high"
    for lbl in "${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"}"; do
      issue_labels="${issue_labels},${lbl}"
    done

    while IFS= read -r finding_line; do
      [ -z "$finding_line" ] && continue

      # Truncate to 80 chars for the issue title prefix.
      short="${finding_line:0:80}"
      issue_title="[retrospective] ${short} (merged PR #$pr_num)"

      # Dedup: skip if an issue with this title prefix exists (open or closed).
      existing_issue=$(gh issue list \
        --repo "$REPO" \
        --state all \
        --search "[retrospective]" \
        --json title \
        --jq ".[] | select(.title | startswith(\"[retrospective] ${short}\")) | .title" \
        2>/dev/null | head -1 || echo "")
      if [ -n "$existing_issue" ]; then
        echo "  [issue] dedup: skipping already-tracked finding: $short" >&2
        continue
      fi

      issue_body="**Retrospective finding from PR #$pr_num** (merged $merged_at, repo \`$REPO\`)

**Finding:** ${finding_line}

**PR:** ${pr_url}

---
⚠️ This finding was identified in code that merged without automated review.
Verify it against current HEAD before filing a fix — subsequent commits may have already addressed it."

      if gh issue create \
          --repo "$REPO" \
          --title "$issue_title" \
          --body "$issue_body" \
          --label "$issue_labels" \
          >/dev/null 2>&1; then
        n_issues_created=$((n_issues_created + 1))
        echo "  [issue] created: $issue_title" >&2
      else
        echo "  [issue] WARNING: failed to create issue for: $short" >&2
      fi
    done < <(extract_blocking_lines_from_file "$tmp_review")
  fi

  # ---- summary line (stdout, per spec telemetry contract) ----
  if [ "$n_blocking" -eq 0 ]; then
    echo "PR #$pr_num: 0 blocking finding(s) → review posted (PASSED)"
  else
    echo "PR #$pr_num: $n_blocking blocking finding(s) → review posted, $n_issues_created issue(s) created"
  fi

  n_reviewed=$((n_reviewed + 1))

  # Eager worktree cleanup (spec invariant #3).
  git worktree remove --force "$wt_dir" 2>/dev/null || true
  rm -rf "$wt_dir"
done

# ---- final summary (stderr) ----
echo ""
echo "retrospective review complete: $n_reviewed reviewed, $n_skipped skipped, $n_failed failed" >&2

# Exit 1 only if everything failed (nothing was successfully reviewed and there were failures).
if [ "$n_reviewed" -eq 0 ] && [ "$n_failed" -gt 0 ]; then
  exit 1
fi
exit 0
