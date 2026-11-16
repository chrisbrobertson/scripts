#!/bin/bash
# test-babysit-review-retry-log-format.sh — recording-stub coverage for
# QA-TEST-PLAN.md TC-3.7 ("Retry Log Message Format") and TC-3.8 ("MCP
# Failure Log Message Format") against codex_review_with_retry() in
# babysit-with-review.sh.
#
# Open PR #45 (test-babysit-mcp-resilience.sh) covers TC-3.1-3.6/3.9-3.14 for
# this script's own copy but its own commit text says it explicitly excludes
# TC-3.15 by number; TC-3.7/TC-3.8 (the exact log-message-format assertions)
# are also absent from that list and from every other existing test file —
# QA-TEST-PLAN.md's own "Partially done" notes for Suite 3 only mention
# TC-3.1-3.6/3.9-3.14 as closed by #45 and TC-3.15 as closed standalone by
# test-babysit-review-false-positive.sh. This file closes that remaining gap
# standalone, mirroring test-babysit-review-false-positive.sh's stub pattern,
# so it doesn't collide with #45's draft branch.
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
assert_contains() { if grep -qF "$3" "$2"; then pass "$1"; else echo "  expected to find: $3" >&2; fail "$1"; fi; }

# ---------- stubs ----------
# Mirrors test-babysit-review-false-positive.sh's stub pattern exactly.
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
[ -n "$out" ] && [ -n "$body" ] && ! grep -q '^@@STDOUT' "$f" && printf '%s\n' "$body" > "$out"
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
MCP_ERR='Transport send error: connection reset'

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

# ---------- TC-3.7: Retry Log Message Format ----------
# Attempt 1 fails with an MCP transport telltale, attempt 2 succeeds cleanly.

new_case tc37_retry_message
printf '@@RC=1\n@@NOISE:%s\n' "$MCP_ERR" > "$STUB_DIR/codex.1"
{ printf '@@RC=0\n'; printf '%s\n' "$CLEAN"; } > "$STUB_DIR/codex.2"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.7 succeeds on attempt 2 -> rc 0" "$rc" "0"
assert_contains "TC-3.7 attempt 1 failure logged" "$CASE/stderr" "MCP transport failure on attempt 1 of 3 (rc=1, review=empty)"
assert_contains "TC-3.7 retry message logged before attempt 2" "$CASE/stderr" "waiting 60s before retry (attempt 2 of 3)"
assert_eq "TC-3.7 slept once (60s, before attempt 2)" "$(calls sleep)" "1"

# ---------- TC-3.8: MCP Failure Log Message Format ----------
# All 3 attempts fail with an MCP transport telltale.

new_case tc38_exhausted_message
printf '@@RC=1\n@@NOISE:%s\n' "$MCP_ERR" > "$STUB_DIR/codex.1"
printf '@@RC=1\n@@NOISE:%s\n' "$MCP_ERR" > "$STUB_DIR/codex.2"
printf '@@RC=1\n@@NOISE:%s\n' "$MCP_ERR" > "$STUB_DIR/codex.3"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.8 all 3 attempts fail -> rc 2" "$rc" "2"
assert_contains "TC-3.8 final failure message logged" "$CASE/stderr" "MCP transport failure on attempt 3 of 3 (rc=1, review=empty)"
assert_eq "TC-3.8 slept twice (60s then 300s)" "$(calls sleep)" "2"
if grep -q 'CALL=sleep 300' "$RECORD"; then pass "TC-3.8 second delay was 300s"; else fail "TC-3.8 second delay was 300s"; fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
