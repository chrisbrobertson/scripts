#!/bin/bash
# babysit-with-review.sh — babysit.sh + Claude<->Codex PR-review handoff.
#
# Same outer loop as babysit.sh. When Claude ends an iteration with the
# sentinel `HANDOFF_REVIEW <PR_NUMBER>` on its own line, this wrapper runs
# up to MAX_REVIEW_CYCLES (default 3) of:
#   1. codex exec — produces a strict-markdown review with three sections:
#      ## BLOCKING / ## RECOMMENDED / ## INFORMATION
#   2. claude -p  — addresses BLOCKING (must), RECOMMENDED (should), and
#                   considers INFORMATION findings; commits and pushes.
# The cycle exits early when codex reports zero BLOCKING findings, when
# claude reports STUCK_REVIEW, or when HEAD doesn't advance during a
# claude pass (defensive against "DONE_REVIEW but no commits made").
#
# Env vars:
#   MAX_ITER           default 50   hard cap on outer iterations
#   SLEEP_SEC          default 10   pause between outer iterations (seconds)
#   STUCK_N            default 3    consecutive identical results = stuck
#   MAX_REVIEW_CYCLES  default 3    max codex<->claude cycles per PR

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: babysit-with-review.sh [-h|--help]

Run from inside a project root. Outer loop is identical to babysit.sh.
When Claude ends an iteration with `HANDOFF_REVIEW <PR_NUMBER>` on its
own line, runs a Claude<->Codex review cycle on that PR (up to
MAX_REVIEW_CYCLES) before resuming the outer loop.

Env vars:
  MAX_ITER           default 50
  SLEEP_SEC          default 10  (seconds)
  STUCK_N            default 3
  MAX_REVIEW_CYCLES  default 3

Logs land in ~/sisyphus-logs/<project>-<timestamp>-<pid>.log.

Examples:
  babysit-with-review.sh
  MAX_REVIEW_CYCLES=5 babysit-with-review.sh
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

MAX_ITER="${MAX_ITER:-50}"
SLEEP_SEC="${SLEEP_SEC:-10}"
STUCK_N="${STUCK_N:-3}"
MAX_REVIEW_CYCLES="${MAX_REVIEW_CYCLES:-3}"

PROJECT=$(basename "$PWD")
LOG_DIR="$HOME/sisyphus-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${PROJECT}-$(date +%Y%m%d-%H%M%S)-$$.log"
STOP_FILE="$LOG_DIR/${PROJECT}.stop"

if [ -f "$STOP_FILE" ]; then
  cat >&2 <<EOF
ERROR: $STOP_FILE already exists.

Another babysit may already be running for '$PROJECT'.

To check:
  pgrep -af babysit

If no other instance is running (e.g. a previous run crashed), remove the
lock file and try again:
  rm $STOP_FILE
EOF
  exit 1
fi

TMP_RESULT=$(mktemp)
TMP_REVIEW=$(mktemp)
TMP_REVIEW_RESULT=$(mktemp)
TMP_CODEX_FULL=$(mktemp)
touch "$LOG" "$STOP_FILE"
trap 'rm -f "$STOP_FILE" "$TMP_RESULT" "$TMP_REVIEW" "$TMP_REVIEW_RESULT" "$TMP_CODEX_FULL"' EXIT

echo "Babysitting $PROJECT (max=$MAX_ITER, stuck=$STUCK_N, review_cycles=$MAX_REVIEW_CYCLES) → $LOG"
echo "  graceful stop: rm $STOP_FILE"

# ---------- prompts ----------

IFS= read -r -d '' BASE_PROMPT <<'PROMPT_EOF' || true
You are working autonomously on this project as one iteration of a long-running babysitter loop. Each invocation should ship ONE well-scoped unit of progress. Over many iterations, the project gets built.

The current project state (PRs, issues, specs) is provided above — use it directly without re-running discovery commands.

Start by reading ./CLAUDE.md and the spec(s) relevant to whatever you decide to work on. Specs live under ./specs/ at the root and recursively under component directories; each has YAML frontmatter with a `status` field (draft|review|approved|deprecated) and a `components` field naming the directories it governs.

Helper scripts (available for targeted mid-iteration queries):
  ~/repos/scripts/prs              — enhanced `gh pr list` with CI check rollup and review state
  ~/repos/scripts/issues           — enhanced `gh issue list` sorted by priority labels
  ~/repos/scripts/specs            — list all specs with status/components (*/specs/**/*.md)
  ~/repos/scripts/specs --status STATUS      — filter by status value (approved|draft|review|deprecated)
  ~/repos/scripts/specs --check-impl         — also show whether component dirs contain source files
  ~/repos/scripts/specs --json / ~/repos/scripts/prs --json / ~/repos/scripts/issues --json  — machine-readable output

Pick the next unit of work in this priority order — stop at the first level that yields an actionable item:

1. Open PRs you can advance. Top priority: PRs in the project state above that are NOT draft and NOT labelled `review-incomplete` (STATE column shows empty). Address review comments or CI failures on any such PR (yours or a previous iteration's) before considering anything else.

   SKIP any PR whose STATE is `draft` or `BLOCKED` in the prs table (or `isDraft: true` / labels include `review-incomplete` in the JSON). These PRs were marked by a previous review cycle as needing human intervention — re-attempting them wastes iterations. Move on to item 2.
2. Open issues you can complete in one iteration. See open issues in the project state above. Pick the highest-priority one that fits the scope discipline below.
3. Approved specs with no implementation. See specs in the project state above — look for rows where IMPL is `no` or `?`. Scaffold the next missing piece — project skeleton, an interface stub, the first integration test, etc.
4. Proto definitions without consumers. Files under ./proto/ that no service implements. Generate stubs or wire a service skeleton that consumes them.
5. Specs needing refinement. Specs with `status: draft` or `status: review` that are actively blocking implementation work. Tighten ambiguous sections, resolve contradictions, expand thin areas.
6. Open questions. Pick one from ./specs/open-questions.md (if it exists), propose a resolution grounded in existing specs, and update the relevant spec(s) to record the decision.

Scope discipline: pick something completable in this iteration — roughly 1–3 hours of work. Prefer landing one small thing fully (code + tests + docs + CHANGELOG entry) over starting several things. Follow every convention in CLAUDE.md.

Per-iteration workflow:
1. State which item you picked and why it is the most valuable next step right now.
2. Implement it fully — code, tests, docs, and a CHANGELOG entry if the project uses one.
3. Run the relevant test suite. If it fails, fix the underlying issue.
4. Commit with a message that explains why the change was made.
5. If the unit of work is shippable on its own, push the branch and open a PR via `gh pr create`.

End-of-iteration sentinels (mutually exclusive — output exactly one as the LAST line of your final message, with no surrounding quotes, code fences, or punctuation):

- HANDOFF_REVIEW <PR_NUMBER>
  Use this if you opened a new PR or pushed new commits to an existing PR during this iteration. The wrapper will run an automated code review (codex) and may invoke you again to address findings before resuming the outer loop. PR_NUMBER must be a bare integer (no leading `#`). Example: `HANDOFF_REVIEW 42`.

- STOP
  Use this ONLY if BOTH are true:
  * Every spec under ./specs/ (recursively) with `status: approved` has a corresponding implementation that compiles and passes its tests, AND
  * There are no open PRs or issues you can act on.

- (no sentinel)
  If neither applies — e.g. you committed work that isn't yet a PR, or you advanced an existing PR without making it review-ready — end your message normally. The outer loop will start the next iteration.

If you hit a transient obstacle (failing test, missing dependency, ambiguous spec section) — DO NOT output STOP. Work around it: pick a different item, scaffold the missing dependency first, file an issue capturing the ambiguity, or commit what you have with a clear note on what is blocked. STOP terminates the entire loop, so reserve it for genuine completion. Do not output STOP or HANDOFF_REVIEW in code, quotes, or as part of a sentence.
PROMPT_EOF

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

IFS= read -r -d '' CLAUDE_REVIEW_PROMPT_TEMPLATE <<'PROMPT_EOF' || true
A code review on PR #__PR_NUMBER__ has produced the findings below.

You MUST action every BLOCKING finding before this PR can merge.
You SHOULD action every RECOMMENDED finding (if you skip one, note the reason in the commit message).
You may CONSIDER each INFORMATION finding — apply if clearly beneficial, otherwise ignore.

For each finding you action:
1. Make the change.
2. Run the relevant tests; fix any failures introduced.
3. Commit with a message that names the finding category and what changed
   (e.g. "fix(blocking): handle nil session in auth middleware").
4. Push to the PR branch when done with this batch.

End your final message with EXACTLY ONE of these sentinels on its own line:

- DONE_REVIEW
  You have addressed everything you intend to address in this pass. The wrapper will run another codex review.

- STUCK_REVIEW <one-line reason>
  You cannot proceed (e.g. missing dependency, contradictory finding, environment issue). The wrapper will exit the review cycle.

Do not output STOP or HANDOFF_REVIEW — those belong to the outer loop.

--- review begin ---
__REVIEW__
--- review end ---
PROMPT_EOF

# ---------- helpers ----------

collect_state() {
  echo "=== project state @ $(date -u +%FT%TZ) ==="
  echo ""
  echo "## open PRs"
  ~/repos/scripts/prs 2>/dev/null || echo "(unavailable)"
  echo ""
  echo "## open issues"
  ~/repos/scripts/issues 2>/dev/null || echo "(unavailable)"
  echo ""
  echo "## specs"
  ~/repos/scripts/specs --check-impl 2>/dev/null || echo "(none found)"
  echo ""
  echo "==="
}

# Stream a claude -p iteration to the log AND a human-readable summary on
# stderr. Captures the final .result into the file passed as $2.
# Returns claude's exit code (PIPESTATUS[0]).
run_claude() {
  local prompt="$1"
  local out_file="$2"
  claude -p "$prompt" \
    --model opusplan \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --verbose 2>>"$LOG" \
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

# Count BLOCKING findings in a strict-markdown codex review on stdin.
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

# Post a codex review as a PR comment. Best-effort: failures logged, do not abort.
# Args: <pr_num> <cycle> <max_cycles> <review_file>
post_codex_review() {
  local pr_num="$1"
  local cycle="$2"
  local max="$3"
  local review_file="$4"

  [ -s "$review_file" ] || return 0

  local body
  body="**Codex review — PR #${pr_num} cycle ${cycle} of ${max}**

\`\`\`
$(cat "$review_file")
\`\`\`"

  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment (codex review) failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Mark a PR as needing manual review when a review cycle bails for any reason.
# Args: <pr_num> <reason_string>
# Best-effort: gh failures are logged but do not abort the caller.
fail_review_cycle() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] marking PR #$pr_num incomplete: $reason" | tee -a "$LOG" >&2

  # Ensure the label exists (idempotent via --force).
  gh label create review-incomplete \
    --color B60205 \
    --description "Babysit review cycle did not complete cleanly" \
    --force >>"$LOG" 2>&1 || true

  # Convert to draft so the PR cannot be merged without operator action.
  gh pr ready "$pr_num" --undo >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr ready --undo failed for PR #$pr_num" | tee -a "$LOG" >&2

  # Add the label.
  gh pr edit "$pr_num" --add-label review-incomplete >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr edit --add-label failed for PR #$pr_num" | tee -a "$LOG" >&2

  # Post the bail reason. (Codex review content is already on the PR via post_codex_review.)
  local body
  body="**babysit-with-review: review cycle bailed — manual review required**

Reason: ${reason}"
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Mark a PR as stalled by a codex MCP transport failure.
# The babysitter will retry the review cycle on its next run.
# Args: <pr_num> <reason_string>
# Best-effort: gh failures are logged but do not abort the caller.
fail_review_cycle_mcp() {
  local pr_num="$1"
  local reason="$2"

  echo "  [review] codex MCP outage for PR #$pr_num: $reason" | tee -a "$LOG" >&2

  gh label create review-mcp-outage \
    --color 0075CA \
    --description "Babysit codex review stalled by MCP transport failure; wrapper will retry" \
    --force >>"$LOG" 2>&1 || true

  gh pr ready "$pr_num" --undo >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr ready --undo failed for PR #$pr_num" | tee -a "$LOG" >&2

  gh pr edit "$pr_num" --add-label review-mcp-outage >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr edit --add-label failed for PR #$pr_num" | tee -a "$LOG" >&2

  local body
  body="**babysit-with-review: codex MCP transport failure — review pending**

Reason: ${reason}

The codex MCP backend was unreachable. No code-quality review took place. The babysitter will retry this review cycle automatically on its next run.

Label \`review-mcp-outage\` has been added. Remove it manually if you merge this PR without waiting for an automated review."
  printf '%s\n' "$body" \
    | gh pr comment "$pr_num" --body-file - >>"$LOG" 2>&1 \
    || echo "  [review] WARNING: gh pr comment failed for PR #$pr_num" | tee -a "$LOG" >&2
}

# Run codex exec with retry on MCP transport failures.
# Uses $TMP_REVIEW (must be zeroed by caller) for the output-last-message file.
# Uses $TMP_CODEX_FULL for the combined codex output (used for telltale detection).
#
# Returns:
#   0 — codex completed cleanly; $TMP_REVIEW is non-empty.
#   1 — codex failed for a non-transport reason (prompt issue, crash, etc.).
#   2 — codex MCP transport failure; all retries exhausted.
codex_review_with_retry() {
  local codex_prompt="$1"
  local attempt
  local delays=(0 60 300)
  local mcp_re='Transport send error:|tool call error: tool call failed for `codex_apps/|error sending request for url \(https://chatgpt\.com/'

  for attempt in 1 2 3; do
    if [ "${delays[$((attempt - 1))]}" -gt 0 ]; then
      echo "  [codex] waiting ${delays[$((attempt - 1))]}s before retry (attempt $attempt of 3)..." | tee -a "$LOG" >&2
      sleep "${delays[$((attempt - 1))]}"
    fi
    : > "$TMP_REVIEW"
    : > "$TMP_CODEX_FULL"

    local rc=0
    set +e
    codex exec --output-last-message "$TMP_REVIEW" -s read-only "$codex_prompt" 2>&1 \
      | tee -a "$LOG" "$TMP_CODEX_FULL" >&2
    rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ] && [ -s "$TMP_REVIEW" ]; then
      return 0
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

# Run the Claude<->Codex review cycle for a PR number.
run_review_cycle() {
  local pr_num="$1"
  local cycle=0

  echo "=== review handoff: PR #$pr_num @ $(date -u +%FT%TZ) ===" | tee -a "$LOG" >&2

  # Make sure we're on the PR branch.
  if ! gh pr checkout "$pr_num" >>"$LOG" 2>&1; then
    echo "  [review] gh pr checkout $pr_num failed; skipping review cycle" | tee -a "$LOG" >&2
    fail_review_cycle "$pr_num" "gh pr checkout failed before review could run"
    return 0
  fi

  while [ "$cycle" -lt "$MAX_REVIEW_CYCLES" ]; do
    cycle=$((cycle + 1))
    echo "--- review cycle $cycle / $MAX_REVIEW_CYCLES (PR #$pr_num) @ $(date -u +%FT%TZ) ---" | tee -a "$LOG" >&2

    # ---- codex pass ----
    local codex_prompt
    codex_prompt="${CODEX_REVIEW_PROMPT_TEMPLATE//__PR_NUMBER__/$pr_num}"

    echo "  [codex] reviewing PR #$pr_num..." >&2
    local codex_rc=0
    codex_review_with_retry "$codex_prompt" || codex_rc=$?

    if [ "$codex_rc" -eq 2 ]; then
      fail_review_cycle_mcp "$pr_num" "codex MCP transport failure after 3 retries (cycle $cycle)"
      return 2
    elif [ "$codex_rc" -ne 0 ]; then
      echo "  [codex] non-MCP failure; bailing review cycle" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "codex exec failed (non-transport) during cycle $cycle"
      return 0
    fi

    local review
    review=$(cat "$TMP_REVIEW")

    post_codex_review "$pr_num" "$cycle" "$MAX_REVIEW_CYCLES" "$TMP_REVIEW"

    {
      echo "--- codex review (cycle $cycle) ---"
      printf '%s\n' "$review"
      echo "--- end codex review ---"
    } >> "$LOG"

    local n_blocking
    n_blocking=$(printf '%s\n' "$review" | count_blocking)
    echo "  [codex] $n_blocking blocking finding(s)" | tee -a "$LOG" >&2

    if [ "$n_blocking" -eq 0 ]; then
      echo "  [review] zero blocking findings; PR #$pr_num cleared after $cycle cycle(s)" | tee -a "$LOG" >&2
      return 0
    fi

    # ---- claude pass ----
    local claude_prompt
    claude_prompt="${CLAUDE_REVIEW_PROMPT_TEMPLATE//__PR_NUMBER__/$pr_num}"
    claude_prompt="${claude_prompt//__REVIEW__/$review}"

    local pre_sha post_sha
    pre_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

    echo "  [claude] addressing findings..." >&2
    if ! run_claude "$claude_prompt" "$TMP_REVIEW_RESULT"; then
      echo "  [claude] non-zero exit during review pass; bailing review cycle" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "claude exited non-zero while addressing review (cycle $cycle)"
      return 0
    fi

    local result trimmed last_line
    result=$(cat "$TMP_REVIEW_RESULT")
    trimmed=$(printf '%s' "$result" | sed -e 's/[[:space:]]*$//')
    last_line=$(printf '%s' "$trimmed" | tail -n 1)

    case "$last_line" in
      "STUCK_REVIEW"*)
        echo "  [claude] $last_line — bailing review cycle" | tee -a "$LOG" >&2
        fail_review_cycle "$pr_num" "claude reported STUCK_REVIEW (cycle $cycle)"
        return 0
        ;;
      "DONE_REVIEW")
        echo "  [claude] DONE_REVIEW — looping for another codex pass" | tee -a "$LOG" >&2
        ;;
      *)
        echo "  [claude] no review-cycle sentinel on last line; treating as DONE_REVIEW" | tee -a "$LOG" >&2
        ;;
    esac

    post_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$pre_sha" ] && [ "$pre_sha" = "$post_sha" ]; then
      echo "  [claude] HEAD unchanged (no commits made) — bailing review cycle to avoid infinite loop" | tee -a "$LOG" >&2
      fail_review_cycle "$pr_num" "claude reported DONE_REVIEW but made no commits (cycle $cycle)"
      return 0
    fi
  done

  echo "  [review] hit MAX_REVIEW_CYCLES=$MAX_REVIEW_CYCLES on PR #$pr_num; resuming outer loop" | tee -a "$LOG" >&2
  fail_review_cycle "$pr_num" "exhausted MAX_REVIEW_CYCLES=$MAX_REVIEW_CYCLES without clearing all blocking findings"
}

# ---------- log header ----------

{
  echo "=== babysit-with-review.sh @ $(date -u +%FT%TZ) ==="
  echo "project:           $PROJECT"
  echo "cwd:               $PWD"
  echo "max_iter:          $MAX_ITER"
  echo "sleep:             ${SLEEP_SEC}s"
  echo "stuck_n:           $STUCK_N"
  echo "max_review_cycles: $MAX_REVIEW_CYCLES"
  echo "--- base prompt ---"
  printf '%s\n' "$BASE_PROMPT"
  echo "--- end base prompt ---"
  echo "--- codex review prompt template ---"
  printf '%s\n' "$CODEX_REVIEW_PROMPT_TEMPLATE"
  echo "--- end codex review prompt template ---"
  echo "--- claude review prompt template ---"
  printf '%s\n' "$CLAUDE_REVIEW_PROMPT_TEMPLATE"
  echo "--- end claude review prompt template ---"
} >> "$LOG"

# ---------- outer loop ----------

declare -a HASHES=()

iter=0
while [ "$iter" -lt "$MAX_ITER" ]; do
  iter=$((iter + 1))
  HEADER="=== iter $iter @ $(date -u +%FT%TZ) ==="
  echo "$HEADER" | tee -a "$LOG" >&2
  echo "  [stop file: $STOP_FILE]" >&2
  if [ ! -f "$STOP_FILE" ]; then
    echo "Stop file removed; exiting before iter $iter." | tee -a "$LOG"
    break
  fi

  STATE=$(collect_state)
  PROMPT="${STATE}

${BASE_PROMPT}"

  {
    echo "--- state ---"
    printf '%s\n' "$STATE"
    echo "--- end state ---"
  } >> "$LOG"

  if ! run_claude "$PROMPT" "$TMP_RESULT"; then
    echo "claude exited non-zero on iter $iter; see $LOG" >&2
    break
  fi
  echo "---" >> "$LOG"

  RESULT=$(cat "$TMP_RESULT")
  TRIMMED=$(printf '%s' "$RESULT" | sed -e 's/[[:space:]]*$//')
  LAST_LINE=$(printf '%s' "$TRIMMED" | tail -n 1)

  # Sentinel detection. HANDOFF_REVIEW triggers a review cycle and falls
  # through to the next outer iteration; STOP terminates the loop.
  case "$LAST_LINE" in
    "HANDOFF_REVIEW "*)
      pr_num="${LAST_LINE#HANDOFF_REVIEW }"
      pr_num="${pr_num%% *}"
      if [[ "$pr_num" =~ ^[0-9]+$ ]]; then
        _rc=0
        run_review_cycle "$pr_num" || _rc=$?
        if [ "$_rc" -eq 2 ]; then
          echo "Halting: codex MCP transport outage on PR #$pr_num; retries exhausted. See $LOG" | tee -a "$LOG" >&2
          break
        fi
      else
        echo "  [outer] HANDOFF_REVIEW with non-numeric PR '$pr_num'; ignoring" | tee -a "$LOG" >&2
      fi
      ;;
    "STOP")
      echo "STOP signal received on iter $iter."
      break
      ;;
  esac

  # Stuck-loop guard.
  HASH=$(printf '%s' "$RESULT" | shasum -a 256 | awk '{print $1}')
  HASHES+=("$HASH")
  if [ "${#HASHES[@]}" -gt "$STUCK_N" ]; then
    HASHES=("${HASHES[@]: -$STUCK_N}")
  fi
  if [ "${#HASHES[@]}" -eq "$STUCK_N" ]; then
    STUCK=1
    for h in "${HASHES[@]}"; do
      [ "$h" = "${HASHES[0]}" ] || { STUCK=0; break; }
    done
    if [ "$STUCK" -eq 1 ]; then
      echo "Stuck: last $STUCK_N results identical. Bailing on iter $iter." | tee -a "$LOG"
      break
    fi
  fi

  sleep "$SLEEP_SEC"
done

if [ "$iter" -ge "$MAX_ITER" ]; then
  echo "Hit MAX_ITER=$MAX_ITER. Bailing." | tee -a "$LOG"
fi

echo "Done after $iter iterations. See $LOG"
