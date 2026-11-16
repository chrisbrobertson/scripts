#!/bin/bash
# test-babysit-review-false-positive.sh — recording-stub coverage for
# QA-TEST-PLAN.md TC-3.15 ("Clean Review Beats Incidental Telltale Match")
# against codex_review_with_retry() in babysit-with-review.sh.
#
# test-bazaar-review-lib.sh already covers this exact regression for the
# extracted lib/bazaar-review.sh copy (cases tc_fp_compat/tc_fp_credits), and
# test-babysit-mcp-resilience.sh (open PR #45) covers TC-3.1-3.6/3.9-3.14 for
# this script's own copy — but neither exercises TC-3.15 against
# babysit-with-review.sh's codex_review_with_retry() directly. This file
# closes that gap standalone, so it doesn't collide with #45's draft branch.
#
# No network: codex and sleep are stubs on PATH.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-with-review.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3' got '$2'" >&2; fail "$1"; fi; }

# ---------- stubs ----------
# Each stub consumes $STUB_DIR/codex.<n> in order. A response file may carry
# directive lines: @@RC=<n> (exit code), @@STDOUT (also echo the body to
# stdout), @@NOISE:<text> (print <text> to stdout only, independent of
# @@STDOUT — simulates transcript chatter that quotes compat_re/credits_re's
# own literal string values back verbatim, e.g. Codex reviewing this very
# function's source) — mirrors test-bazaar-review-lib.sh's stub exactly.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/_next" <<'S'
#!/bin/bash
tool="$1"; c="$STUB_DIR/$tool.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
f="$STUB_DIR/$tool.$n"; [ -f "$f" ] || f="$STUB_DIR/$tool.default"; echo "$f"
S
cat > "$TMP/bin/codex" <<'S'
#!/bin/bash
printf 'CALL=codex %s\n' "$*" >> "$RECORD"
f=$("$(dirname "$0")/_next" codex)
rc=$(grep -m1 '^@@RC=' "$f" | cut -d= -f2); rc=${rc:-0}
out=""; while [ "$#" -gt 0 ]; do [ "$1" = "--output-last-message" ] && { out="$2"; shift 2; continue; }; shift; done
body=$(grep -v '^@@' "$f")
echo "codex diagnostic noise"
grep '^@@NOISE:' "$f" | sed 's/^@@NOISE://'
grep -q '^@@STDOUT' "$f" && printf '%s\n' "$body"
[ -n "$out" ] && ! grep -q '^@@STDOUT' "$f" && printf '%s\n' "$body" > "$out"
exit "$rc"
S
cat > "$TMP/bin/sleep" <<'S'
#!/bin/bash
printf 'CALL=sleep %s\n' "$*" >> "$RECORD"
S
chmod +x "$TMP"/bin/*

# ---------- fixtures ----------
CLEAN='## BLOCKING
- (none)

## RECOMMENDED
- (none)

## INFORMATION
- (none)'

new_case() {  # <name> ; sets CASE STUB_DIR RECORD and a fresh HOME
  CASE="$TMP/$1"; mkdir -p "$CASE/stubs" "$CASE/home"
  export STUB_DIR="$CASE/stubs" RECORD="$CASE/record"
  : > "$RECORD"
}
stub() { printf '%s\n' "$2" > "$STUB_DIR/$1"; }   # stub codex.1 "$BODY"

run_reviewer() {  # forwards args to the script; caller captures $?
  ( cd "$ROOT" && HOME="$CASE/home" PATH="$TMP/bin:/usr/bin:/bin" \
      BABYSIT_TEST_MODE=reviewer "$SCRIPT" --reviewer codex "$@" \
  ) >"$CASE/stdout" 2>"$CASE/stderr"
}
calls() { grep -c "CALL=$1" "$RECORD"; }

# ---------- TC-3.15 ----------
# Regression (#82, 2026-09-27): a clean, structurally valid review must win
# over an incidental telltale match in transcript noise — before the fix,
# these false-positived as rc 3 / rc 4 and halted the babysitter on real PRs.

new_case tc315_compat
{ printf '@@RC=0\n@@NOISE:transcript excerpt: local compat_re='"'"'requires a newer version of Codex'"'"'\n'; printf '%s\n' "$CLEAN"; } > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.15 clean review beats incidental compat_re match -> rc 0" "$rc" "0"
assert_eq "TC-3.15 compat case: no retry" "$(calls codex)" "1"

new_case tc315_credits
{ printf '@@RC=0\n@@NOISE:transcript excerpt: local credits_re='"'"'Your workspace is out of credits'"'"'\n'; printf '%s\n' "$CLEAN"; } > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.15 clean review beats incidental credits_re match -> rc 0" "$rc" "0"
assert_eq "TC-3.15 credits case: no retry" "$(calls codex)" "1"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
