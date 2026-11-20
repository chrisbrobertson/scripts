#!/bin/bash
# test-prs.sh — recording-stub coverage for `prs`.
#
# `prs` had no test coverage at all, unlike its `specs`/`issues` gh-wrapper
# siblings. It's a short, linear script with a single `gh pr list` call, so
# this harness runs the real script end to end against a stubbed `gh` on
# PATH, feeding canned `--json` responses to assert on the rollup logic
# (`rollup_state`/`rollup_checks`) and table rendering. No network.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/prs"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }

mkdir -p "$TMP/bin"

# gh: records every invocation to $RECORD, responds with the file at
# $STUB_JSON_FILE (or an empty array) for `gh pr list`, or fails with
# $STUB_RC/$STUB_ERR when set.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$1 $2" in
  "pr list")
    if [ "${STUB_RC:-0}" -ne 0 ]; then
      echo "${STUB_ERR:-stub gh failure}" >&2
      exit "${STUB_RC}"
    fi
    cat "${STUB_JSON_FILE:-/dev/null}"
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

run() {  # <record> -- <script args...>
  local record="$1"; shift
  shift  # drop the literal --
  : > "$record"
  ( env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
      STUB_JSON_FILE="${STUB_JSON_FILE:-}" STUB_RC="${STUB_RC:-0}" \
      STUB_ERR="${STUB_ERR:-}" \
      "$SCRIPT" "$@" ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- mixed listing: state/checks/review rollup ----------
cat > "$TMP/mixed.json" <<'JSON'
[
  {"number": 1, "title": "Fix bug", "headRefName": "fix/bug", "isDraft": false,
   "labels": [], "statusCheckRollup": [{"state": "SUCCESS"}],
   "reviewDecision": "APPROVED", "author": {"login": "alice"}, "url": "u1"},
  {"number": 2, "title": "WIP feature", "headRefName": "feat/wip", "isDraft": true,
   "labels": [], "statusCheckRollup": [{"state": "PENDING"}],
   "reviewDecision": null, "author": {"login": "bob"}, "url": "u2"},
  {"number": 3, "title": "Blocked one", "headRefName": "fix/blocked", "isDraft": true,
   "labels": [{"name": "review-incomplete"}], "statusCheckRollup": [{"state": "FAILURE"}],
   "reviewDecision": "CHANGES_REQUESTED", "author": {"login": "carol"}, "url": "u3"},
  {"number": 4, "title": "No checks", "headRefName": "chore/x", "isDraft": false,
   "labels": [], "statusCheckRollup": [],
   "reviewDecision": "", "author": {"login": "dave"}, "url": "u4"}
]
JSON

r="$TMP/mixed.record"
STUB_JSON_FILE="$TMP/mixed.json" run "$r" --
assert_eq "mixed: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "mixed: clean PR renders with empty state, pass checks, approved review" "#1    Fix bug      fix/bug               pass     approved           alice" "$TMP/out"
assert_grep "mixed: draft PR shows draft state and pending checks" "draft" "$TMP/out"
assert_grep "mixed: review-incomplete label wins over isDraft (BLOCKED, not draft)" "BLOCKED" "$TMP/out"
assert_grep "mixed: failing checks show FAIL" "FAIL" "$TMP/out"
assert_grep "mixed: changes-requested review rendered with underscore replaced by space" "changes requested" "$TMP/out"
assert_grep "mixed: no-checks PR renders without crashing" "#4" "$TMP/out"
assert_grep "mixed: calls gh pr list with default limit 50" "CALL=gh pr list --json number,title,headRefName,isDraft,labels,statusCheckRollup,reviewDecision,author,url --limit 50" "$r"

# ---------- --json passthrough: raw JSON, no table rendering ----------
r="$TMP/json.record"
STUB_JSON_FILE="$TMP/mixed.json" run "$r" -- --json
assert_eq "json: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "json: raw field present" "\"headRefName\": \"fix/bug\"" "$TMP/out"
assert_not_grep "json: no table header rendered" "STATE" "$TMP/out"

# ---------- no open PRs ----------
echo '[]' > "$TMP/empty.json"
r="$TMP/empty.record"
STUB_JSON_FILE="$TMP/empty.json" run "$r" --
assert_eq "empty: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "empty: reports no open PRs" "No open PRs." "$TMP/out"

# ---------- --limit N forwarded to gh ----------
r="$TMP/limit.record"
STUB_JSON_FILE="$TMP/empty.json" run "$r" -- --limit 5
assert_grep "limit: gh pr list called with --limit 5" "CALL=gh pr list --json number,title,headRefName,isDraft,labels,statusCheckRollup,reviewDecision,author,url --limit 5" "$r"

# ---------- long title/branch truncated in table rendering ----------
python3 - "$TMP/long.json" <<'PY'
import json, sys
long_title = "x" * 80
long_branch = "y" * 60
data = [{"number": 9, "title": long_title, "headRefName": long_branch, "isDraft": False,
         "labels": [], "statusCheckRollup": [], "reviewDecision": "", "author": {"login": "eve"}, "url": "u9"}]
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY
r="$TMP/long.record"
STUB_JSON_FILE="$TMP/long.json" run "$r" --
assert_not_grep "truncation: 80-char title not rendered in full" "$(python3 -c 'print("x"*80)')" "$TMP/out"
assert_grep "truncation: title truncated to 52 chars" "$(python3 -c 'print("x"*52)')" "$TMP/out"

# ---------- gh failure propagates ----------
r="$TMP/gh-fail.record"
STUB_RC=1 STUB_ERR="rate limited" run "$r" --
assert_eq "gh failure: exit code propagated" "$(cat "$TMP/rc")" "1"
assert_grep "gh failure: stderr surfaced" "rate limited" "$TMP/err"

# ---------- --help ----------
r="$TMP/help.record"
run "$r" -- --help
assert_eq "help: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "help: documents usage" "usage: prs" "$TMP/out"
assert_grep "help: documents --json" "--json" "$TMP/out"
assert_not_grep "help: never touches gh" "CALL=gh" "$r"

# ---------- unknown argument ----------
r="$TMP/unknown-arg.record"
run "$r" -- --bogus
assert_eq "unknown argument: exit 2" "$(cat "$TMP/rc")" "2"
assert_grep "unknown argument: reports which flag was unrecognized" "unrecognized arguments: --bogus" "$TMP/err"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
