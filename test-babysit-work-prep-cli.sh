#!/bin/bash
# test-babysit-work-prep-cli.sh — recording-stub coverage for
# babysit-work-prep.sh's CLI/queue surface: the lock (live-PID collision vs
# stale-PID clearing, mirroring babysit-builder.sh's own AT4 coverage and
# babysit-with-review.sh's TC-1.3 AT3/AT3c), --dry-run (reads the PR/subticket
# records and ticket queue with no write calls and no lock file), and
# --max-tickets (caps new drafts started independent of queue size) — plus
# --help and unknown-argument handling.
#
# Before this file, babysit-work-prep.sh's only coverage was
# test-work-prep-citation-check.sh, which drives WORK_PREP_TEST_MODE=citation-check
# (a narrow sub-function hook) and never exercises the lock, --dry-run, or
# --max-tickets paths at the whole-script level — the same gap
# test-babysit-builder-cli.sh closed for babysit-builder.sh.
#
# Runs a real babysit-work-prep.sh invocation against a real disposable git
# repo, with `gh`/`claude`/`codex` stubbed on PATH. No Claude/Codex/GitHub
# network calls.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-work-prep.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }

mkdir -p "$TMP/bin"

# gh: records every invocation. Distinguishes the two `issue list` calls
# (fetch_subticket_records's --state all vs fetch_github_tickets's --state
# open, the ticket queue itself) and the one `pr list` call (fetch_pr_records,
# which runs unconditionally — even under --dry-run — to build the records
# approval_sweep reads).
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$*" in
  "auth status"*) exit 0 ;;
  "repo view "*"--json defaultBranchRef"*) echo main; exit 0 ;;
  "pr list --repo "*"--json number,state,title,body,url,headRefName,comments,isDraft"*) printf '%s' "${STUB_PRS:-[]}"; exit 0 ;;
  "issue list --repo "*"--state all "*"--json number,title,body,url,labels"*) printf '%s' "${STUB_SUBTICKETS:-[]}"; exit 0 ;;
  "issue list --repo "*"--state open "*"--json number,title,body,url,labels"*) printf '%s' "${STUB_QUEUE:-[]}"; exit 0 ;;
  "label create "*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# claude/codex: command existence is checked (and must succeed) before the
# lock is even claimed, whenever --dry-run is absent — so every non-dry-run
# scenario below needs both on PATH even though none of them reach an actual
# draft. codex additionally answers the startup reviewer_preflight probe
# ("Say 'ok'.") run only when the ticket queue is non-empty.
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

queue_json_n() {  # <count> — N dummy open github tickets, numbered 1..count
  local n="$1" i out="["
  for i in $(seq 1 "$n"); do
    [ "$i" = 1 ] || out+=","
    out+="{\"number\": $i, \"title\": \"ticket $i\", \"body\": \"\", \"url\": \"https://example.com/$i\", \"labels\": []}"
  done
  printf '%s]' "$out"
}

# run_work_prep: fresh repo + fresh HOME per call, so the lock file never
# leaks across scenarios. Extra args before "$SCRIPT" are env assignments
# (e.g. a pre-seeded HOME to control the stop-file path, or STUB_* env vars).
# WORK_PREP_APPROVERS is always set so the script never needs to probe
# `gh api user` for the authenticated login.
run_work_prep() {  # <record> [env assignments...] -- [script args...]
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
    cd "$repo_dir/work" && env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" \
      HOME="${WORKPREP_HOME:-$TMP/home-$$-$RANDOM}" WORK_PREP_APPROVERS="tester" \
      "${env_args[@]+"${env_args[@]}"}" "$SCRIPT" --repo owner/repo "${script_args[@]+"${script_args[@]}"}"
  ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- lock collision: a live PID in the stop file blocks a second
# invocation immediately, before the PR/subticket records or ticket queue are
# ever read ----------
sleep 30 &
live_pid=$!
home="$TMP/lock-home"
mkdir -p "$home/sisyphus-logs"
echo "$live_pid" > "$home/sisyphus-logs/work-work-prep.stop"
r="$TMP/lock-collision.record"
WORKPREP_HOME="$home" run_work_prep "$r" STUB_QUEUE="$(queue_json_n 1)"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
assert_eq "lock collision: exits 1" "$(cat "$TMP/rc")" "1"
assert_grep "lock collision: error names the live PID and stop file" "ERROR: work-prep lock held by live PID $live_pid: $home/sisyphus-logs/work-work-prep.stop" "$TMP/err"
assert_not_grep "lock collision: PR records are never read" "CALL=gh pr list" "$r"
assert_not_grep "lock collision: ticket queue is never read" "CALL=gh issue list" "$r"

# ---------- stale lock (regression guard): a dead PID is cleared and the run
# proceeds to read the queue, instead of being treated as a collision ----------
home="$TMP/stale-home"
mkdir -p "$home/sisyphus-logs"
echo 999999 > "$home/sisyphus-logs/work-work-prep.stop"
r="$TMP/stale-lock.record"
WORKPREP_HOME="$home" run_work_prep "$r" STUB_QUEUE="$(queue_json_n 0)"
assert_eq "stale lock: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "stale lock: clearing is logged" "[lock] clearing stale work-prep lock: $home/sisyphus-logs/work-work-prep.stop" "$TMP/err"
assert_grep "stale lock: ticket queue is read once the lock clears" "--state open " "$r"
if [ -f "$home/sisyphus-logs/work-work-prep.stop" ]; then fail "stale lock: lock file removed after a clean exit"; else pass "stale lock: lock file removed after a clean exit"; fi

# ---------- --dry-run reads the PR/subticket records and ticket queue with no
# write calls and no lock file ----------
home="$TMP/dry-run-home"
r="$TMP/dry-run.record"
WORKPREP_HOME="$home" run_work_prep "$r" STUB_QUEUE="$(queue_json_n 2)" -- --dry-run
assert_eq "dry-run: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "dry-run: ticket queue is read" "--state open " "$r"
assert_grep "dry-run: ticket 1 is listed as what-would-draft" "[draft] ticket 1 (github) → [dry-run] would draft spec and open PR" "$TMP/out"
assert_grep "dry-run: ticket 2 is listed as what-would-draft" "[draft] ticket 2 (github) → [dry-run] would draft spec and open PR" "$TMP/out"
assert_grep "dry-run: summary reports both queued tickets" "Work prep complete: 2 new ticket(s) considered for drafting." "$TMP/out"
assert_not_grep "dry-run: no PR merge calls are made" "CALL=gh pr merge" "$r"
assert_not_grep "dry-run: no PR comment calls are made" "CALL=gh pr comment" "$r"
assert_not_grep "dry-run: no PR create calls are made" "CALL=gh pr create" "$r"
assert_not_grep "dry-run: no issue create/edit calls are made" "CALL=gh issue create" "$r"
assert_not_grep "dry-run: labels are never ensured (no label write calls)" "CALL=gh label create" "$r"
assert_not_grep "dry-run: implementer is never invoked" "CALL=claude" "$r"
assert_not_grep "dry-run: reviewer is never invoked" "CALL=codex" "$r"
if [ -d "$home/sisyphus-logs" ]; then fail "dry-run: no lock file (or log dir) is ever created"; else pass "dry-run: no lock file (or log dir) is ever created"; fi

# ---------- --max-tickets caps drafts started, independent of queue size ----------
r="$TMP/max-tickets.record"
run_work_prep "$r" STUB_QUEUE="$(queue_json_n 3)" -- --dry-run --max-tickets 1
assert_eq "max-tickets: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "max-tickets: only the first queued ticket is considered" "[draft] ticket 1 (github) → [dry-run] would draft spec and open PR" "$TMP/out"
assert_not_grep "max-tickets: the second queued ticket is left alone" "ticket 2 " "$TMP/out"
assert_not_grep "max-tickets: the third queued ticket is left alone" "ticket 3 " "$TMP/out"
assert_grep "max-tickets: summary reports exactly 1 ticket considered" "Work prep complete: 1 new ticket(s) considered for drafting." "$TMP/out"

# ---------- invalid --max-tickets (parse-time failure, no side effects) ----------
r="$TMP/bad-max-tickets.record"
run_work_prep "$r" -- --max-tickets 0
assert_eq "invalid --max-tickets: exits 2" "$(cat "$TMP/rc")" "2"
assert_not_grep "invalid --max-tickets: no gh call is ever made" "CALL=gh" "$r"

# ---------- --help / unknown argument ----------
r="$TMP/help.record"
run_work_prep "$r" -- --help
assert_eq "--help: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "--help: documents --dry-run" "--dry-run" "$TMP/out"
assert_grep "--help: documents --max-tickets" "--max-tickets" "$TMP/out"

r="$TMP/unknown.record"
run_work_prep "$r" -- --bogus-flag
assert_eq "unknown argument: exits 2" "$(cat "$TMP/rc")" "2"

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
