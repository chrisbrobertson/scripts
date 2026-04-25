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
touch "$LOG"

echo "Babysitting $PROJECT (max=$MAX_ITER, stuck=$STUCK_N) → $LOG"

PROMPT=$(cat <<'PROMPT_EOF'
You are working autonomously on this project as one iteration of a long-running babysitter loop. Each invocation should ship ONE well-scoped unit of progress. Over many iterations, the project gets built.

Start by reading ./CLAUDE.md and the spec(s) relevant to whatever you decide to work on. Specs live under ./specs/ at the root and recursively under component directories; each has YAML frontmatter with a `status` field (draft|review|approved|deprecated) and a `components` field naming the directories it governs.

Pick the next unit of work in this priority order — stop at the first level that yields an actionable item:

1. Open PRs you can advance. Run `gh pr list`. Address review comments or CI failures on any PR you (or a previous iteration) opened.
2. Open issues you can complete in one iteration. Run `gh issue list`. Pick the highest-priority one that fits the scope discipline below.
3. Approved specs with no implementation. Find specs with `status: approved` in frontmatter whose `components` directories contain no source code yet. Scaffold the next missing piece — project skeleton, an interface stub, the first integration test, etc.
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

{
  echo "=== babysit.sh @ $(date -u +%FT%TZ) ==="
  echo "project:  $PROJECT"
  echo "cwd:      $PWD"
  echo "max_iter: $MAX_ITER"
  echo "sleep:    ${SLEEP_SEC}s"
  echo "stuck_n:  $STUCK_N"
  echo "--- prompt ---"
  printf '%s\n' "$PROMPT"
  echo "--- end prompt ---"
} >> "$LOG"

# Ring buffer of recent result hashes for stuck detection.
declare -a HASHES=()

# Tmp file for capturing the final .result of each iteration without
# losing claude's exit code (which $(...) would hide behind the pipeline).
TMP_RESULT=$(mktemp)
trap 'rm -f "$TMP_RESULT"' EXIT

iter=0
while [ "$iter" -lt "$MAX_ITER" ]; do
  iter=$((iter + 1))
  HEADER="=== iter $iter @ $(date -u +%FT%TZ) ==="
  echo "$HEADER" | tee -a "$LOG" >&2

  # Stream NDJSON events from claude → tee them verbatim into the log →
  # parse them in python to print a live human-readable summary on stderr
  # and emit the final .result on stdout.
  claude -p "$PROMPT" \
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
' > "$TMP_RESULT"
  RC=${PIPESTATUS[0]}
  echo "---" >> "$LOG"

  if [ "$RC" -ne 0 ]; then
    echo "claude exited $RC on iter $iter; see $LOG" >&2
    break
  fi

  RESULT=$(cat "$TMP_RESULT")

  # STOP only if the trimmed result ends with the literal token on its own line
  # (or the whole result is just "STOP"). Avoids false positives from STOP appearing in code blocks.
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
