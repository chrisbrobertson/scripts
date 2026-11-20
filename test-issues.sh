#!/bin/bash
# test-issues.sh — recording-stub coverage for `issues`.
#
# `issues` had no test coverage at all, unlike its `specs`/`prs` gh-wrapper
# siblings. It's a short, linear script with a single `gh issue list` call,
# so this harness runs the real script end to end against a stubbed `gh` on
# PATH, feeding canned `--json` responses to assert on the priority sort
# (`extract_priority`/`_priority_sort_key`) and table rendering. No network.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/issues"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }
# line-order assertion: $2 must appear on an earlier line of $3 than $4
assert_before() {
  local f="$3"
  local l1 l2
  l1=$(grep -n -F -- "$2" "$f" | head -1 | cut -d: -f1)
  l2=$(grep -n -F -- "$4" "$f" | head -1 | cut -d: -f1)
  if [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ]; then
    pass "$1"
  else
    echo "  expected '$2' (line ${l1:-?}) before '$4' (line ${l2:-?}) in $f" >&2
    sed 's/^/    /' "$f" >&2
    fail "$1"
  fi
}

mkdir -p "$TMP/bin"

# gh: records every invocation to $RECORD, responds with the file at
# $STUB_JSON_FILE (or an empty array) for `gh issue list`, or fails with
# $STUB_RC/$STUB_ERR when set.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$1 $2" in
  "issue list")
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

# ---------- priority sort: p3/low-priority input order, highest priority first out ----------
cat > "$TMP/priority.json" <<'JSON'
[
  {"number": 1, "title": "Low prio", "labels": [{"name": "p3"}],
   "assignees": [], "createdAt": "2026-01-01T00:00:00Z", "url": "u1"},
  {"number": 2, "title": "No prio label", "labels": [{"name": "bug"}],
   "assignees": [{"login": "alice"}], "createdAt": "2026-01-02T00:00:00Z", "url": "u2"},
  {"number": 3, "title": "Critical one", "labels": [{"name": "priority:critical"}, {"name": "bug"}],
   "assignees": [{"login": "bob"}, {"login": "carol"}], "createdAt": "2026-01-03T00:00:00Z", "url": "u3"},
  {"number": 4, "title": "High prio", "labels": [{"name": "P1"}],
   "assignees": [], "createdAt": "2026-01-04T00:00:00Z", "url": "u4"}
]
JSON

r="$TMP/priority.record"
STUB_JSON_FILE="$TMP/priority.json" run "$r" --
assert_eq "priority: exit 0" "$(cat "$TMP/rc")" "0"
assert_before "priority: critical (#3) sorts ahead of high (#4)" "#3" "$TMP/out" "#4"
assert_before "priority: high (#4) sorts ahead of low (#1)" "#4" "$TMP/out" "#1"
assert_before "priority: low (#1) sorts ahead of unlabelled (#2, no match -> lowest rank)" "#1" "$TMP/out" "#2"
assert_grep "priority: label match is case-insensitive (P1 -> p1)" "p1" "$TMP/out"
assert_grep "priority: multiple assignees joined with comma" "bob, carol" "$TMP/out"
assert_grep "priority: multiple labels joined with comma" "priority:critical, bug" "$TMP/out"
assert_grep "priority: calls gh issue list with default limit 50, no --assignee" "CALL=gh issue list --json number,title,labels,assignees,createdAt,url --limit 50" "$r"
assert_not_grep "priority: --mine not passed by default" "--assignee @me" "$r"

# ---------- --mine forwards --assignee @me ----------
echo '[]' > "$TMP/empty.json"
r="$TMP/mine.record"
STUB_JSON_FILE="$TMP/empty.json" run "$r" -- --mine
assert_grep "mine: gh issue list called with --assignee @me" "CALL=gh issue list --json number,title,labels,assignees,createdAt,url --limit 50 --assignee @me" "$r"

# ---------- --json passthrough: raw JSON, no table rendering ----------
r="$TMP/json.record"
STUB_JSON_FILE="$TMP/priority.json" run "$r" -- --json
assert_eq "json: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "json: raw field present, unsorted order preserved" "\"title\": \"Low prio\"" "$TMP/out"
assert_not_grep "json: no table header rendered" "PRIORITY" "$TMP/out"

# ---------- no open issues ----------
r="$TMP/empty.record"
STUB_JSON_FILE="$TMP/empty.json" run "$r" --
assert_eq "empty: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "empty: reports no open issues" "No open issues." "$TMP/out"

# ---------- --limit N forwarded to gh ----------
r="$TMP/limit.record"
STUB_JSON_FILE="$TMP/empty.json" run "$r" -- --limit 5
assert_grep "limit: gh issue list called with --limit 5" "CALL=gh issue list --json number,title,labels,assignees,createdAt,url --limit 5" "$r"

# ---------- long title/labels truncated in table rendering ----------
python3 - "$TMP/long.json" <<'PY'
import json, sys
long_title = "x" * 80
long_labels = ["l" * 40]
data = [{"number": 9, "title": long_title, "labels": [{"name": l} for l in long_labels],
         "assignees": [], "createdAt": "2026-01-01T00:00:00Z", "url": "u9"}]
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY
r="$TMP/long.record"
STUB_JSON_FILE="$TMP/long.json" run "$r" --
assert_not_grep "truncation: 80-char title not rendered in full" "$(python3 -c 'print("x"*80)')" "$TMP/out"
assert_grep "truncation: title truncated to 60 chars" "$(python3 -c 'print("x"*60)')" "$TMP/out"
assert_not_grep "truncation: 40-char label not rendered in full" "$(python3 -c 'print("l"*40)')" "$TMP/out"
assert_grep "truncation: labels truncated to 35 chars" "$(python3 -c 'print("l"*35)')" "$TMP/out"

# ---------- gh failure propagates ----------
r="$TMP/gh-fail.record"
STUB_RC=1 STUB_ERR="rate limited" run "$r" --
assert_eq "gh failure: exit code propagated" "$(cat "$TMP/rc")" "1"
assert_grep "gh failure: stderr surfaced" "rate limited" "$TMP/err"

# ---------- --help ----------
r="$TMP/help.record"
run "$r" -- --help
assert_eq "help: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "help: documents usage" "usage: issues" "$TMP/out"
assert_grep "help: documents --mine" "--mine" "$TMP/out"
assert_not_grep "help: never touches gh" "CALL=gh" "$r"

# ---------- unknown argument ----------
r="$TMP/unknown-arg.record"
run "$r" -- --bogus
assert_eq "unknown argument: exit 2" "$(cat "$TMP/rc")" "2"
assert_grep "unknown argument: reports which flag was unrecognized" "unrecognized arguments: --bogus" "$TMP/err"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
