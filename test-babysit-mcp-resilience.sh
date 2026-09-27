#!/bin/bash
# test-babysit-mcp-resilience.sh — recording-stub coverage for
# codex_review_with_retry() in babysit-with-review.sh (ASF-FEAT-MCP-RESILIENCE,
# QA-TEST-PLAN.md TC-3.x). No network: codex and sleep are stubs on PATH, so the
# retry/backoff/telltale contract runs in milliseconds instead of requiring a
# firewall to simulate a Codex MCP outage. Mirrors the stub style already
# proven in test-bazaar-review-lib.sh for the extracted copy of this function.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-with-review.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3' got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; fail "$1"; else pass "$1"; fi; }

# ---------- stubs ----------
# Each stub consumes $STUB_DIR/codex.<n> in order (a response file may carry
# directive lines: @@RC=<n> exit code, @@STDOUT also echo the body to stdout
# so it lands in the script's TMP_CODEX_FULL for telltale scanning).
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
MISSING_REC='## BLOCKING
- (none)

## INFORMATION
- (none)'
BARE_HEADERS='## BLOCKING

## RECOMMENDED

## INFORMATION'

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

# ---------- TC-3.x ----------

new_case tc31; stub codex.1 "$CLEAN"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.1 success on attempt 1 -> rc 0" "$rc" "0"
assert_eq "TC-3.1 no retries" "$(calls codex)" "1"
assert_eq "TC-3.1 no sleep" "$(calls sleep)" "0"

new_case tc32
printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.1"
stub codex.2 "$CLEAN"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.2 transport then success -> rc 0" "$rc" "0"
assert_eq "TC-3.2 exactly 2 attempts" "$(calls codex)" "2"
assert_grep "TC-3.2 logs 60s wait" "waiting 60s before retry (attempt 2 of 3)" "$CASE/stderr"

new_case tc33
printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.1"
printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.2"
stub codex.3 "$CLEAN"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.3 transport, transport, success -> rc 0" "$rc" "0"
assert_grep "TC-3.3 logs 60s wait" "waiting 60s before retry (attempt 2 of 3)" "$CASE/stderr"
assert_grep "TC-3.3 logs 300s wait" "waiting 300s before retry (attempt 3 of 3)" "$CASE/stderr"

new_case tc34
for i in 1 2 3; do printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.$i"; done
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.4 three transport failures -> rc 2" "$rc" "2"
assert_eq "TC-3.4 exactly 3 attempts" "$(calls codex)" "3"
assert_grep "TC-3.4 logs 300s wait" "waiting 300s before retry (attempt 3 of 3)" "$CASE/stderr"
assert_grep "TC-3.4 logs attempt-3 transport failure" "MCP transport failure on attempt 3 of 3" "$CASE/stderr"

new_case tc35
printf '@@RC=1\nsomething else broke\n' > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.5 non-telltale failure -> rc 1" "$rc" "1"
assert_eq "TC-3.5 no retry" "$(calls codex)" "1"

new_case tc36
printf '@@RC=0\n' > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.6 exit 0 but empty review, no telltale -> rc 1" "$rc" "1"
assert_eq "TC-3.6 no retry" "$(calls codex)" "1"

new_case tc39
printf '@@STDOUT\n@@RC=1\nerror: requires a newer version of Codex\n' > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.9 compat telltale -> rc 3 immediately" "$rc" "3"
assert_eq "TC-3.9 no retry" "$(calls codex)" "1"
assert_eq "TC-3.9 no sleep" "$(calls sleep)" "0"

new_case tc310
printf '@@STDOUT\n@@RC=1\nTransport send error: x\nrequires a newer version of Codex\n' > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.10 compat beats mcp telltale -> rc 3" "$rc" "3"
assert_eq "TC-3.10 no retry" "$(calls codex)" "1"

new_case tc313
printf '@@STDOUT\n@@RC=1\nERROR: Your workspace is out of credits.\n' > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.13 credits telltale -> rc 4 immediately" "$rc" "4"
assert_eq "TC-3.13 no retry" "$(calls codex)" "1"

new_case tc314
printf '@@STDOUT\n@@RC=1\nTransport send error: x\nYour workspace is out of credits\n' > "$STUB_DIR/codex.1"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.14 credits beats mcp telltale -> rc 4" "$rc" "4"
assert_eq "TC-3.14 no retry" "$(calls codex)" "1"

new_case tc311
stub codex.1 "$MISSING_REC"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.11 missing RECOMMENDED header, no telltale -> rc 1" "$rc" "1"
assert_eq "TC-3.11 no retry" "$(calls codex)" "1"

new_case tc312
stub codex.1 "$CLEAN"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.12 all three headers with bullets -> rc 0" "$rc" "0"

new_case tc312b
stub codex.1 "$BARE_HEADERS"
rc=0; run_reviewer || rc=$?
assert_eq "TC-3.12b bare headers, no bullets -> rc 1" "$rc" "1"
assert_eq "TC-3.12b no retry" "$(calls codex)" "1"

# ---------- reviewer model/effort still forwarded on the retry path ----------

new_case forwarding
for i in 1 2; do printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.$i"; done
stub codex.3 "$CLEAN"
rc=0; run_reviewer --reviewer-model review-codex --reviewer-effort=medium || rc=$?
assert_eq "forwarding: converges on attempt 3 -> rc 0" "$rc" "0"
assert_grep "forwarding: every attempt carries the reviewer model" \
  "CALL=codex exec --output-last-message" "$RECORD"
model_calls=$(grep -c -- '--model review-codex' "$RECORD")
assert_eq "forwarding: reviewer model on all 3 attempts" "$model_calls" "3"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
