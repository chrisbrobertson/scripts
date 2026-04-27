#!/bin/bash
# babysit.sh — run from inside any project root.
# Loops `claude -p` against the specs in ./specs/ until Claude says STOP,
# the loop gets stuck, or MAX_ITER is reached.
#
# Env vars:
#   MAX_ITER   default 50   hard cap on iterations
#   SLEEP_SEC  default 10   pause between iterations
#   STUCK_N    default 3    consecutive identical results that count as "stuck"

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: babysit.sh [-h|--help]

Run from inside a project root. Loops `claude -p` against ./specs/
until Claude outputs STOP, the loop gets stuck, or MAX_ITER is hit.

Env vars:
  MAX_ITER   default 50   hard cap on iterations
  SLEEP_SEC  default 10   pause between iterations (seconds)
  STUCK_N    default 3    consecutive identical results that count as "stuck"

Logs land in ~/sisyphus-logs/<project>-<timestamp>-<pid>.log.

Examples:
  babysit.sh
  MAX_ITER=20 STUCK_N=2 babysit.sh
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

PROJECT=$(basename "$PWD")
LOG_DIR="$HOME/sisyphus-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${PROJECT}-$(date +%Y%m%d-%H%M%S)-$$.log"
STOP_FILE="$LOG_DIR/${PROJECT}.stop"

if [ -f "$STOP_FILE" ]; then
  cat >&2 <<EOF
ERROR: $STOP_FILE already exists.

Another babysit.sh may already be running for '$PROJECT'.

To check:
  pgrep -af babysit

If no other instance is running (e.g. a previous run crashed), remove the
lock file and try again:
  rm $STOP_FILE
EOF
  exit 1
fi

TMP_RESULT=$(mktemp)
TMP_STDERR=$(mktemp)
touch "$LOG" "$STOP_FILE"
trap 'rm -f "$STOP_FILE" "$TMP_RESULT" "$TMP_STDERR"' EXIT

echo "Babysitting $PROJECT (max=$MAX_ITER, stuck=$STUCK_N) → $LOG"
echo "  graceful stop: rm $STOP_FILE"

# ---------------------------------------------------------------------------
# Exponential backoff for usage/rate limits
# ---------------------------------------------------------------------------
BACKOFF_SEC=0
BACKOFF_INITIAL=$((15 * 60))  # 15 minutes
BACKOFF_MAX=$((4 * 60 * 60))  # 4 hours

is_rate_limited() {
  printf '%s' "$*" | grep -qiE \
    'usage.?limit|rate.?limit|monthly.?limit|too.?many.?request|overloaded|try.?again.?(in|after|later)|529|capacity.?exceed'
}

backoff_sleep() {
  local secs=$1
  local mins=$(( secs / 60 ))
  local resume
  resume=$(date -v "+${secs}S" '+%H:%M' 2>/dev/null \
        || date -d "+${secs} seconds" '+%H:%M' 2>/dev/null \
        || echo "?")
  printf 'Usage limit — backing off %dm (resuming ~%s)\n' "$mins" "$resume" \
    | tee -a "$LOG" >&2
  local elapsed=0
  while [ "$elapsed" -lt "$secs" ]; do
    local remaining=$(( secs - elapsed ))
    local step=$(( remaining < 60 ? remaining : 60 ))
    sleep "$step"
    elapsed=$(( elapsed + step ))
    if [ "$elapsed" -lt "$secs" ]; then
      local left=$(( secs - elapsed ))
      printf '  [backoff] %dm%ds remaining...\n' \
        "$(( left / 60 ))" "$(( left % 60 ))" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------
BASE_PROMPT=$(cat <<'PROMPT_EOF'
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

1. Open PRs you can advance. See open PRs in the project state above. Address review comments or CI failures on any PR you (or a previous iteration) opened.
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

End your final message with the literal token STOP on its own line ONLY if BOTH of the following are true:
- Every spec under ./specs/ (recursively) with `status: approved` has a corresponding implementation that compiles and passes its tests, AND
- There are no open PRs or issues you can act on.

If you hit a transient obstacle (failing test, missing dependency, ambiguous spec section) — DO NOT output STOP. Work around it: pick a different item from the priority list, scaffold the missing dependency first, file an issue capturing the ambiguity for a later iteration, or commit what you have with a clear note on what is blocked. Outputting STOP terminates the entire loop, so reserve it for genuine completion. Do not output STOP in code, quotes, or as part of a sentence.
PROMPT_EOF
)

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

{
  echo "=== babysit.sh @ $(date -u +%FT%TZ) ==="
  echo "project:  $PROJECT"
  echo "cwd:      $PWD"
  echo "max_iter: $MAX_ITER"
  echo "sleep:    ${SLEEP_SEC}s"
  echo "stuck_n:  $STUCK_N"
  echo "--- base prompt ---"
  printf '%s\n' "$BASE_PROMPT"
  echo "--- end base prompt ---"
} >> "$LOG"

# Ring buffer of recent result hashes for stuck detection.
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

  echo "--- state ---" >> "$LOG"
  printf '%s\n' "$STATE" >> "$LOG"
  echo "--- end state ---" >> "$LOG"

  # Stream NDJSON events from claude → tee stdout into log →
  # parse in python for live human-readable summary on stderr and final result on stdout.
  # Stderr is captured separately so we can inspect it for rate-limit signals.
  > "$TMP_STDERR"
  claude -p "$PROMPT" \
    --model opusplan \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --verbose 2>"$TMP_STDERR" \
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
' > "$TMP_RESULT"
  RC=${PIPESTATUS[0]}

  # Flush stderr capture to log regardless of outcome.
  cat "$TMP_STDERR" >> "$LOG"
  echo "---" >> "$LOG"

  STDERR_CONTENT=$(cat "$TMP_STDERR")
  RESULT=$(cat "$TMP_RESULT")

  # Rate-limit / usage-limit check — backoff and retry without consuming an iteration.
  if is_rate_limited "$STDERR_CONTENT" || is_rate_limited "$RESULT"; then
    iter=$(( iter - 1 ))
    if [ "$BACKOFF_SEC" -eq 0 ]; then
      BACKOFF_SEC=$BACKOFF_INITIAL
    else
      BACKOFF_SEC=$(( BACKOFF_SEC * 2 ))
      [ "$BACKOFF_SEC" -gt "$BACKOFF_MAX" ] && BACKOFF_SEC=$BACKOFF_MAX
    fi
    backoff_sleep "$BACKOFF_SEC"
    continue
  fi

  # Non-rate-limit failure — bail out.
  if [ "$RC" -ne 0 ]; then
    echo "claude exited $RC on iter $iter; see $LOG" >&2
    break
  fi

  # Successful response — reset backoff.
  BACKOFF_SEC=0

  # STOP only if the trimmed result ends with the literal token on its own line.
  TRIMMED=$(printf '%s' "$RESULT" | sed -e 's/[[:space:]]*$//')
  LAST_LINE=$(printf '%s' "$TRIMMED" | tail -n 1)
  if [ "$LAST_LINE" = "STOP" ]; then
    echo "STOP signal received on iter $iter."
    break
  fi

  # Stuck-loop guard: hash result, exit if last STUCK_N hashes all match.
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
