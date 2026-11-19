#!/bin/bash
# test-find-bailed-merged-prs.sh — coverage for find-bailed-merged-prs.sh.
#
# find-bailed-merged-prs.sh shipped with no test coverage of its own (its
# sibling CLAUDE.md entry notes the BAILED_PHRASES/CREDITS_RE parity gap it
# was built to catch, but nothing exercised the detection logic itself).
# Its log-parsing/outcome-ranking core is pure and dependency-free, so most
# cases here run it end to end against small fixture log files under a
# tmpdir with only `gh` stubbed on PATH (for the PR-state lookup).
#
# Regressions this guards against:
#   1. All 13 BAILED_PHRASES are recognized, not just the original compat
#      telltale — in particular the credits and MCP-transport phrases added
#      after the fact (mirrors the parity gap this script's own CLAUDE.md
#      entry describes).
#   2. The "gh pr checkout" phrase only counts as a bail when "failed" is
#      also present on the same line (a bare "gh pr checkout N" log line is
#      routine, not a bail).
#   3. Worst-outcome-wins ranking (BAILED > UNKNOWN > CLEARED) holds in both
#      directions: a later milder result never downgrades an already-BAILED
#      PR, and a later worse result does upgrade an already-CLEARED one.
#   4. A log file missing the "=== babysit-with-review.sh @" header is
#      skipped entirely, not misparsed.
#   5. Output ordering puts every MERGED row ahead of non-merged rows.
#   6. Repo-map lookup, --repo override, and the no-mapping fallback each
#      produce the right NOTE/STATE without crashing.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/find-bailed-merged-prs.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
# field <file> <pr_num> <col>: TSV column value (1-indexed) for the row whose
# PR column matches pr_num. Avoids tab-sensitive string grepping.
field() { awk -F'\t' -v pr="$2" -v col="$3" '$2==pr{print $col}' "$1"; }
assert_order() {
  local first last
  first=$(grep -nF -- "$2" "$4" 2>/dev/null | head -n1 | cut -d: -f1)
  last=$(grep -nF -- "$3" "$4" 2>/dev/null | head -n1 | cut -d: -f1)
  if [ -z "$first" ] || [ -z "$last" ]; then
    echo "  one or both of '$2' / '$3' missing in $4" >&2; fail "$1"
  elif [ "$first" -lt "$last" ]; then
    pass "$1"
  else
    echo "  expected '$2' before '$3' in $4" >&2; sed 's/^/    /' "$4" >&2; fail "$1"
  fi
}

mkdir -p "$TMP/bin"
export RECORD="$TMP/gh-calls.log"

# gh: stubs `gh pr view N --repo R --json ...`. Lookup table at
# $GH_LOOKUP (TSV: pr_num<TAB>state<TAB>mergedAt) controls the response per
# PR number; a looked-up state of "FAIL" forces a non-zero exit instead of
# a JSON response, simulating a transient gh/network error.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=%s\n' "$*" >> "$RECORD"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  pr_num="$3"
  state="OPEN"; merged_at="null"
  if [ -n "${GH_LOOKUP:-}" ] && [ -f "$GH_LOOKUP" ]; then
    line=$(awk -F'\t' -v pr="$pr_num" '$1==pr{print; exit}' "$GH_LOOKUP")
    if [ -n "$line" ]; then
      state=$(echo "$line" | cut -f2)
      merged_at_raw=$(echo "$line" | cut -f3)
      if [ -n "$merged_at_raw" ]; then merged_at="\"$merged_at_raw\""; fi
    fi
  fi
  if [ "$state" = "FAIL" ]; then
    echo "gh: pull request not found" >&2
    exit 1
  fi
  printf '{"number":%s,"state":"%s","mergedAt":%s,"mergedBy":null,"url":"https://github.com/o/r/pull/%s","headRefName":"x","additions":1,"deletions":1}\n' \
    "$pr_num" "$state" "$merged_at" "$pr_num"
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

run() {  # run <log-dir> [extra args...]
  : > "$RECORD"
  "$SCRIPT" --log-dir "$1" --repo-map "${GLOBAL_REPO_MAP:-$TMP/empty-map.tsv}" "${@:2}" \
    >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

: > "$TMP/empty-map.tsv"

header_line='=== babysit-with-review.sh @ 2026-01-01T00:00:00Z ==='

# ---------- no log dir ----------
run "$TMP/does-not-exist"
assert_eq "no-log-dir: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "no-log-dir: reports nothing to audit" "nothing to audit" "$TMP/err"

# ---------- log dir with no .log files ----------
d="$TMP/empty-dir"; mkdir -p "$d"
run "$d"
assert_eq "empty-dir: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "empty-dir: reports nothing to audit" "No log files found" "$TMP/err"

# ---------- log file missing the review header is skipped entirely ----------
d="$TMP/no-header"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
not a babysit-with-review log
=== review handoff: PR #1 @ 2026-01-01T00:00:00Z ===
bailing review cycle: whatever
EOF
run "$d"
assert_eq "no-header: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "no-header: reports no babysit-with-review.sh logs found" "No babysit-with-review.sh logs found" "$TMP/err"
assert_eq "no-header: emits no data rows" "$(cat "$TMP/out")" ""

# ---------- CLEARED handoff produces no candidate ----------
d="$TMP/cleared"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #10 @ 2026-01-01T00:00:00Z ===
cleared after 2 cycles
EOF
run "$d"
assert_eq "cleared: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "cleared: reports no candidates" "No bailed handoffs found" "$TMP/err"
assert_eq "cleared: emits no data rows" "$(cat "$TMP/out")" ""

# ---------- each BAILED_PHRASES telltale is recognized ----------
# Exercises the compat/credits/MCP phrases together, mirroring the parity
# gap this script's CLAUDE.md entry describes (only the compat phrase was
# originally present).
d="$TMP/phrases"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #20 @ 2026-01-01T00:00:00Z ===
requires a newer version of Codex for this model
=== iter 2 @ 2026-01-01T00:00:00Z ===
=== review handoff: PR #21 @ 2026-01-01T00:00:00Z ===
Your workspace is out of credits
=== iter 3 @ 2026-01-01T00:00:00Z ===
=== review handoff: PR #22 @ 2026-01-01T00:00:00Z ===
Transport send error: connection reset
EOF
run "$d"
assert_eq "phrases: compat telltale detected" "$(field "$TMP/out" 20 3)" "BAILED"
assert_eq "phrases: credits telltale detected" "$(field "$TMP/out" 21 3)" "BAILED"
assert_eq "phrases: mcp telltale detected" "$(field "$TMP/out" 22 3)" "BAILED"

# ---------- "gh pr checkout" only bails when "failed" is on the same line ----------
d="$TMP/checkout"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #30 @ 2026-01-01T00:00:00Z ===
gh pr checkout 30
=== iter 2 @ 2026-01-01T00:00:00Z ===
=== review handoff: PR #31 @ 2026-01-01T00:00:00Z ===
gh pr checkout 31 failed with exit code 1
EOF
run "$d"
assert_eq "checkout: bare checkout line is not a bail" "$(field "$TMP/out" 30 3)" "UNKNOWN"
assert_eq "checkout: checkout-failed line is a bail" "$(field "$TMP/out" 31 3)" "BAILED"
assert_eq "checkout: bail_reason recorded for the failed case" "$(field "$TMP/out" 31 4)" "gh pr checkout"

# ---------- UNKNOWN: no terminal marker in the block ----------
d="$TMP/unknown"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #40 @ 2026-01-01T00:00:00Z ===
some unrelated log line
EOF
run "$d"
assert_eq "unknown: outcome is UNKNOWN" "$(field "$TMP/out" 40 3)" "UNKNOWN"

# ---------- worst-outcome-wins ranking, both directions ----------
d="$TMP/ranking"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #50 @ 2026-01-01T00:00:00Z ===
cleared after 2 cycles
=== iter 2 @ 2026-01-01T00:00:00Z ===
=== review handoff: PR #50 @ 2026-01-01T00:00:00Z ===
bailing review cycle: second pass bailed
=== iter 3 @ 2026-01-01T00:00:00Z ===
=== review handoff: PR #51 @ 2026-01-01T00:00:00Z ===
bailing review cycle: first pass bailed
=== iter 4 @ 2026-01-01T00:00:00Z ===
=== review handoff: PR #51 @ 2026-01-01T00:00:00Z ===
cleared after 1 cycles
EOF
run "$d"
assert_eq "ranking: CLEARED-then-BAILED upgrades to BAILED" "$(field "$TMP/out" 50 3)" "BAILED"
assert_eq "ranking: BAILED-then-CLEARED is not downgraded" "$(field "$TMP/out" 51 3)" "BAILED"

# ---------- project name is extracted from the log filename ----------
d="$TMP/projname"; mkdir -p "$d"
cat > "$d/home-lab-monitor-20260101-120000-999.log" <<EOF
$header_line
=== review handoff: PR #60 @ 2026-01-01T00:00:00Z ===
bailing review cycle: x
EOF
run "$d"
assert_eq "projname: strips the trailing timestamp suffix only" "$(field "$TMP/out" 60 1)" "home-lab-monitor"

# ---------- merged rows sort ahead of non-merged rows ----------
d="$TMP/merged-order"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #70 @ 2026-01-01T00:00:00Z ===
bailing review cycle: still open
=== iter 2 @ 2026-01-01T00:00:00Z ===
=== review handoff: PR #71 @ 2026-01-01T00:00:00Z ===
bailing review cycle: already merged
EOF
printf 'proj\to/r\n' > "$TMP/map.tsv"
printf '70\tOPEN\t\n71\tMERGED\t2026-02-01T00:00:00Z\n' > "$TMP/gh-lookup.tsv"
GLOBAL_REPO_MAP="$TMP/map.tsv" GH_LOOKUP="$TMP/gh-lookup.tsv" run "$d"
assert_eq "merged-order: PR 70 resolved OPEN" "$(field "$TMP/out" 70 6)" "OPEN"
assert_eq "merged-order: PR 71 resolved MERGED" "$(field "$TMP/out" 71 6)" "MERGED"
assert_order "merged-order: MERGED row (71) precedes the OPEN row (70)" $'\t71\t' $'\t70\t' "$TMP/out"
assert_grep "merged-order: ACTION REQUIRED summary fires" "ACTION REQUIRED: 1 merged PR" "$TMP/err"

# ---------- repo-map lookup resolves a real gh call ----------
d="$TMP/repo-map"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #80 @ 2026-01-01T00:00:00Z ===
bailing review cycle: x
EOF
printf 'proj\to/r\n' > "$TMP/map2.tsv"
GLOBAL_REPO_MAP="$TMP/map2.tsv" run "$d"
assert_grep "repo-map: issues a real gh pr view call" "pr view 80 --repo o/r" "$RECORD"
assert_eq "repo-map: resolves a state" "$(field "$TMP/out" 80 6)" "OPEN"

# ---------- no mapping found: no gh call, NOTE explains why ----------
d="$TMP/no-map"; mkdir -p "$d"
cat > "$d/unmapped-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #90 @ 2026-01-01T00:00:00Z ===
bailing review cycle: x
EOF
: > "$RECORD"
run "$d"
assert_eq "no-map: exit 0" "$(cat "$TMP/rc")" "0"
assert_eq "no-map: STATE is UNKNOWN" "$(field "$TMP/out" 90 6)" "UNKNOWN"
assert_eq "no-map: NOTE explains the missing mapping" "$(field "$TMP/out" 90 9)" "(no repo mapping)"
assert_eq "no-map: issues no gh pr view call" "$(grep -c 'pr view' "$RECORD" 2>/dev/null)" "0"

# ---------- --repo override applies even with no repo-map entry ----------
d="$TMP/override"; mkdir -p "$d"
cat > "$d/unmapped-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #95 @ 2026-01-01T00:00:00Z ===
bailing review cycle: x
EOF
run "$d" --repo o/override-r
assert_grep "override: uses the overridden repo for the gh call" "pr view 95 --repo o/override-r" "$RECORD"

# ---------- gh query failure lands in other_rows with a NOTE, not a crash ----------
d="$TMP/gh-fail"; mkdir -p "$d"
cat > "$d/proj-20260101-000000-1.log" <<EOF
$header_line
=== review handoff: PR #99 @ 2026-01-01T00:00:00Z ===
bailing review cycle: x
EOF
printf 'proj\to/r\n' > "$TMP/map3.tsv"
printf '99\tFAIL\t\n' > "$TMP/gh-lookup-fail.tsv"
GLOBAL_REPO_MAP="$TMP/map3.tsv" GH_LOOKUP="$TMP/gh-lookup-fail.tsv" run "$d"
assert_eq "gh-fail: exit 0 despite the gh error" "$(cat "$TMP/rc")" "0"
assert_grep "gh-fail: NOTE records the gh failure" "gh query failed" "$TMP/out"

# ---------- --help ----------
run "$TMP/empty-dir" --help
assert_eq "help: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "help: documents usage" "Usage:" "$TMP/out"
assert_grep "help: documents --log-dir" "--log-dir" "$TMP/out"

# ---------- unknown argument ----------
run "$TMP/empty-dir" --bogus
assert_eq "unknown-arg: exit 2" "$(cat "$TMP/rc")" "2"
assert_grep "unknown-arg: reports the unrecognized flag" "Unknown argument: --bogus" "$TMP/err"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
