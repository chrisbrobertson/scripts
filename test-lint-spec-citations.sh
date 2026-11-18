#!/bin/bash
# test-lint-spec-citations.sh — coverage for lint-spec-citations.
#
# lint-spec-citations shipped in #196 with no test coverage at all. It's a
# pure, dependency-free Python script (no gh/network calls to stub), so this
# harness runs the real script end to end against small fixture trees built
# fresh per case under a tmpdir — each case cds into its own fixture root
# (the script scans Path.cwd()) and asserts on stdout, stderr, and exit code.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/lint-spec-citations"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }

# run <fixture-dir> -- <script args...>: cds into the fixture dir (lint-spec-
# citations scans Path.cwd()) and runs the real script there.
run() {
  local dir="$1"; shift; shift  # drop the literal --
  ( cd "$dir" && "$SCRIPT" "$@" ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# five-line fixture file, reused across cases
five_lines() { printf 'one\ntwo\nthree\nfour\nfive\n' > "$1"; }

# ---------- all citations valid ----------
d="$TMP/valid"; mkdir -p "$d"
five_lines "$d/a.sh"
printf 'See a.sh:2-4 and a.sh:1 for details.\n' > "$d/doc.md"
run "$d" --
assert_eq "valid: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "valid: reports all citations valid" "All citations valid." "$TMP/out"

# ---------- missing file ----------
d="$TMP/missing-file"; mkdir -p "$d"
printf 'Cites missing.sh:10 which was deleted.\n' > "$d/doc.md"
run "$d" --
assert_eq "missing-file: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "missing-file: reports the stale citation" "doc.md:1: missing.sh:10 -> 'missing.sh' does not exist" "$TMP/out"
assert_grep "missing-file: reports a count of 1" "1 stale citation(s) found." "$TMP/out"

# ---------- line out of range ----------
d="$TMP/out-of-range"; mkdir -p "$d"
five_lines "$d/b.sh"
printf 'Cites b.sh:8 past the end of the file.\n' > "$d/doc.md"
run "$d" --
assert_eq "out-of-range: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "out-of-range: reports the line-out-of-range detail" "doc.md:1: b.sh:8 -> cites line 8 but 'b.sh' has 5 lines" "$TMP/out"

# ---------- malformed range (end before start) ----------
d="$TMP/malformed-range"; mkdir -p "$d"
five_lines "$d/c.sh"
printf 'Cites c.sh:4-2 backwards.\n' > "$d/doc.md"
run "$d" --
assert_eq "malformed-range: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "malformed-range: reports the malformed-citation detail" "doc.md:1: c.sh:4-2 -> invalid range 4-2" "$TMP/out"

# ---------- comma-separated: one segment valid, one out of range ----------
d="$TMP/comma-mixed"; mkdir -p "$d"
five_lines "$d/d.sh"
printf 'Cites d.sh:2,9 — second segment is bad.\n' > "$d/doc.md"
run "$d" --
assert_eq "comma-mixed: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "comma-mixed: flags the whole citation once with the bad segment's detail" "doc.md:1: d.sh:2,9 -> cites line 9 but 'd.sh' has 5 lines" "$TMP/out"

# ---------- multiple findings across files: count and per-finding lines ----------
d="$TMP/multi"; mkdir -p "$d/sub"
five_lines "$d/e.sh"
printf 'Cites e.sh:9 here.\n' > "$d/top.md"
printf 'Also cites missing.py:1 here.\n' > "$d/sub/nested.md"
run "$d" --
assert_eq "multi: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "multi: finds the citation in a nested directory" "sub/nested.md:1: missing.py:1 -> 'missing.py' does not exist" "$TMP/out"
assert_grep "multi: finds the citation at the top level" "top.md:1: e.sh:9 -> cites line 9 but 'e.sh' has 5 lines" "$TMP/out"
assert_grep "multi: reports a count of 2" "2 stale citation(s) found." "$TMP/out"

# ---------- skip dirs: .git and node_modules are never scanned ----------
d="$TMP/skip-dirs"; mkdir -p "$d/.git" "$d/node_modules"
printf 'Cites missing.sh:1 but lives under .git.\n' > "$d/.git/doc.md"
printf 'Cites missing.sh:1 but lives under node_modules.\n' > "$d/node_modules/doc.md"
run "$d" --
assert_eq "skip-dirs: exit 0 (nothing scanned)" "$(cat "$TMP/rc")" "0"
assert_grep "skip-dirs: reports all citations valid" "All citations valid." "$TMP/out"

# ---------- --json: valid JSON with expected fields ----------
d="$TMP/json"; mkdir -p "$d"
printf 'Cites missing.sh:3 here.\n' > "$d/doc.md"
run "$d" -- --json
assert_eq "json: exit 1" "$(cat "$TMP/rc")" "1"
python3 -c "
import json, sys
findings = json.load(open('$TMP/out'))
assert len(findings) == 1, findings
f = findings[0]
assert f['doc'] == 'doc.md', f
assert f['line'] == 1, f
assert f['citation'] == 'missing.sh:3', f
assert f['issue'] == 'missing-file', f
assert \"does not exist\" in f['detail'], f
" && pass "json: output is valid JSON with the expected fields" || fail "json: output is valid JSON with the expected fields"

# ---------- --help ----------
d="$TMP/help"; mkdir -p "$d"
run "$d" -- --help
assert_eq "help: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "help: documents usage" "usage:" "$TMP/out"
assert_grep "help: documents --json" "--json" "$TMP/out"

# ---------- unknown argument ----------
d="$TMP/unknown-arg"; mkdir -p "$d"
run "$d" -- --bogus
assert_eq "unknown argument: exit 2 (argparse error)" "$(cat "$TMP/rc")" "2"
assert_grep "unknown argument: reports the unrecognized flag" "unrecognized arguments: --bogus" "$TMP/err"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
