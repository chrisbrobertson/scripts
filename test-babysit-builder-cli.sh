#!/bin/bash
# test-babysit-builder-cli.sh — recording-stub coverage for babysit-builder.sh's
# CLI/queue surface: L3-builder.md's AT4 (lock collision), AT11 (--max-tickets
# caps builds started), and AT12 (--dry-run reads the queue with no write
# calls). Before this file, the only automated coverage for this script was
# test-babysit-builder-stalled-retry.sh, which exercises resume_stalled_prs()
# but never the lock, --max-tickets, or --dry-run paths.
#
# Runs a real babysit-builder.sh invocation (no test-mode hooks exist in that
# script) against a real disposable git repo, with `gh`/`claude`/`codex`
# stubbed on PATH. No Claude/Codex/GitHub network calls.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-builder.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }

mkdir -p "$TMP/bin"

# gh: records every invocation. `issue list --label build-ready` answers with
# the JSON issue array configured via STUB_QUEUE, or "[]" (empty queue). The
# three resumable-label `pr list` lookups resume_stalled_prs() runs on every
# non-dry-run startup must also answer valid JSON ("[]" — no scenario here
# exercises a resumed PR), or the sweep treats the malformed/empty response
# as a lookup failure and halts before the ticket queue is ever read.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$*" in
  "auth status"*) exit 0 ;;
  "repo view "*"--json defaultBranchRef"*) echo main; exit 0 ;;
  "issue list --repo "*"--label build-ready"*) printf '%s' "${STUB_QUEUE:-[]}"; exit 0 ;;
  "pr list --repo "*"--label build-mcp-outage"*) printf '%s' "${STUB_PR_MCP:-[]}"; exit 0 ;;
  "pr list --repo "*"--label build-codex-outdated"*) printf '%s' "${STUB_PR_OUTDATED:-[]}"; exit 0 ;;
  "pr list --repo "*"--label build-codex-no-credits"*) printf '%s' "${STUB_PR_CREDITS:-[]}"; exit 0 ;;
  "label list "*|"label create "*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# claude/codex: babysit-builder.sh checks both implementer/reviewer binaries
# are on PATH before doing anything else when not in --dry-run mode (lock
# collisions exit before that; --dry-run never checks for or runs either).
# codex is additionally invoked for the startup reviewer_preflight probe
# ("Say 'ok'.") whenever a non-dry-run scenario clears the lock — it must
# succeed there or the run halts before ever reading the build queue. No
# scenario below reaches an actual per-PR review or implementation call.
cat > "$TMP/bin/claude" <<'STUB'
#!/bin/bash
printf 'CALL=claude %s\n' "$*" >> "$RECORD"
exit 1
STUB
chmod +x "$TMP/bin/claude"

cat > "$TMP/bin/codex" <<'STUB'
#!/bin/bash
printf 'CALL=codex %s\n' "$*" >> "$RECORD"
case "$*" in
  *"Say 'ok'."*) echo ok; exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/codex"

make_repo() {
  local dir="$1"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/work" >/dev/null 2>&1
  (
    cd "$dir/work"
    git config user.email test@test.com
    git config user.name test
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo base > tracked.txt
    git add tracked.txt
    git commit -q -m init
    git push -q -u origin main
  )
}

queue_json_n() {  # <count> — N dummy build-ready issues, numbered 1..count
  local n="$1" i out="["
  for i in $(seq 1 "$n"); do
    [ "$i" = 1 ] || out+=","
    out+="{\"number\": $i, \"title\": \"ticket $i\", \"body\": \"\", \"url\": \"https://example.com/$i\", \"labels\": []}"
  done
  printf '%s]' "$out"
}

# run_builder: fresh repo + fresh HOME per call, so the lock file never leaks
# across scenarios. Extra args before "$SCRIPT" are env assignments (e.g. a
# pre-seeded HOME to control the stop-file path, or STUB_* env vars).
run_builder() {  # <record> [env assignments...] -- [script args...]
  local record="$1"; shift
  : > "$record"
  local repo_dir="$TMP/repo-$$-$RANDOM"
  mkdir -p "$repo_dir"
  make_repo "$repo_dir"
  local -a env_args=() script_args=()
  local in_script_args=0
  for arg in "$@"; do
    if [ "$in_script_args" = 1 ]; then script_args+=("$arg");
    elif [ "$arg" = "--" ]; then in_script_args=1
    else env_args+=("$arg"); fi
  done
  (
    cd "$repo_dir/work" && env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="${BUILDER_HOME:-$TMP/home-$$-$RANDOM}" \
      "${env_args[@]+"${env_args[@]}"}" "$SCRIPT" --repo owner/repo "${script_args[@]+"${script_args[@]}"}"
  ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- AT4: lock collision ----------
# A live PID in the stop file must block a second invocation immediately,
# before the build queue is ever read — mirrors babysit-with-review.sh's own
# live-PID collision coverage (TC-1.3 AT3).
sleep 30 &
live_pid=$!
home="$TMP/lock-home"
mkdir -p "$home/sisyphus-logs"
echo "$live_pid" > "$home/sisyphus-logs/work-builder.stop"
r="$TMP/lock-collision.record"
BUILDER_HOME="$home" run_builder "$r" STUB_QUEUE="$(queue_json_n 1)"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
assert_eq "lock collision (AT4): exits 1" "$(cat "$TMP/rc")" "1"
assert_grep "lock collision (AT4): error names the live PID and stop file" "ERROR: builder lock held by live PID $live_pid: $home/sisyphus-logs/work-builder.stop" "$TMP/err"
assert_not_grep "lock collision (AT4): build queue is never read" "CALL=gh issue list" "$r"
assert_not_grep "lock collision (AT4): implementer is never invoked" "CALL=claude" "$r"

# ---------- stale lock (regression guard): a dead PID is cleared and the run
# proceeds to read the queue, instead of being treated as a collision ----------
home="$TMP/stale-home"
mkdir -p "$home/sisyphus-logs"
echo 999999 > "$home/sisyphus-logs/work-builder.stop"
r="$TMP/stale-lock.record"
BUILDER_HOME="$home" run_builder "$r" STUB_QUEUE="$(queue_json_n 0)"
assert_eq "stale lock: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "stale lock: clearing is logged" "[lock] clearing stale builder lock: $home/sisyphus-logs/work-builder.stop" "$TMP/err"
assert_grep "stale lock: build queue is read once the lock clears" "CALL=gh issue list" "$r"
if [ -f "$home/sisyphus-logs/work-builder.stop" ]; then fail "stale lock: lock file removed after a clean exit"; else pass "stale lock: lock file removed after a clean exit"; fi

# ---------- AT12: --dry-run reads the queue with no write calls ----------
home="$TMP/dry-run-home"
r="$TMP/dry-run.record"
BUILDER_HOME="$home" run_builder "$r" STUB_QUEUE="$(queue_json_n 2)" -- --dry-run
assert_eq "dry-run (AT12): exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "dry-run (AT12): queue is read" "CALL=gh issue list" "$r"
assert_grep "dry-run (AT12): ticket 1 is listed as what-would-build" "[build] ticket 1 (github, spec: none referenced) → [dry-run] would build and open a PR" "$TMP/out"
assert_grep "dry-run (AT12): ticket 2 is listed as what-would-build" "[build] ticket 2 (github, spec: none referenced) → [dry-run] would build and open a PR" "$TMP/out"
assert_grep "dry-run (AT12): summary reports both queued tickets" "Dry run complete: 2 ticket(s) in the build queue." "$TMP/out"
assert_not_grep "dry-run (AT12): no pr/label write calls are made" "CALL=gh pr" "$r"
assert_not_grep "dry-run (AT12): labels are never ensured (no label write calls)" "CALL=gh label create" "$r"
assert_not_grep "dry-run (AT12): implementer is never invoked" "CALL=claude" "$r"
assert_not_grep "dry-run (AT12): reviewer is never invoked" "CALL=codex" "$r"
if [ -d "$home/sisyphus-logs" ]; then fail "dry-run (AT12): no lock file (or log dir) is ever created"; else pass "dry-run (AT12): no lock file (or log dir) is ever created"; fi

# ---------- AT11: --max-tickets caps builds started, independent of queue size ----------
r="$TMP/max-tickets.record"
run_builder "$r" STUB_QUEUE="$(queue_json_n 3)" -- --dry-run --max-tickets 1
assert_eq "max-tickets (AT11): exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "max-tickets (AT11): only the first queued ticket is considered" "[build] ticket 1 (github, spec: none referenced) → [dry-run] would build and open a PR" "$TMP/out"
assert_not_grep "max-tickets (AT11): the second queued ticket is left alone" "ticket 2 " "$TMP/out"
assert_not_grep "max-tickets (AT11): the third queued ticket is left alone" "ticket 3 " "$TMP/out"
assert_grep "max-tickets (AT11): summary reports exactly 1 ticket considered" "Dry run complete: 1 ticket(s) in the build queue." "$TMP/out"

# ---------- invalid --max-tickets (parse-time failure, no side effects) ----------
r="$TMP/bad-max-tickets.record"
run_builder "$r" -- --max-tickets 0
assert_eq "invalid --max-tickets: exits 2" "$(cat "$TMP/rc")" "2"
assert_not_grep "invalid --max-tickets: no gh call is ever made" "CALL=gh" "$r"

# ---------- --help / unknown argument ----------
r="$TMP/help.record"
run_builder "$r" -- --help
assert_eq "--help: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "--help: documents --dry-run" "--dry-run" "$TMP/out"
assert_grep "--help: documents --max-tickets" "--max-tickets" "$TMP/out"

r="$TMP/unknown.record"
run_builder "$r" -- --bogus-flag
assert_eq "unknown argument: exits 2" "$(cat "$TMP/rc")" "2"

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
