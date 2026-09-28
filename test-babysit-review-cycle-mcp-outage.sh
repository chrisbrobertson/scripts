#!/bin/bash
# test-babysit-review-cycle-mcp-outage.sh — recording-stub coverage for
# run_review_cycle()'s MCP-outage terminal path in babysit-with-review.sh
# (QA-TEST-PLAN.md TC-2.8). test-babysit-mcp-resilience.sh already covers
# codex_review_with_retry() returning 2 after 3 transport failures; this file
# covers the layer above it — that run_review_cycle() turns that rc=2 into
# fail_review_cycle_mcp() (label review-mcp-outage, draft, comment, return 2)
# rather than falling through to the generic fail_review_cycle()
# (review-incomplete) path used for every other non-zero reviewer_rc. No
# network: codex, sleep, and gh are stubs on PATH.
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
# codex/sleep follow the same numbered-response-file protocol as
# test-babysit-mcp-resilience.sh: each call consumes $STUB_DIR/codex.<n> in
# call order (a response file may carry @@RC=<n> and @@STDOUT directives).
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
cat > "$TMP/bin/gh" <<'S'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
# Only commands that actually receive a body (--body-file -) read stdin.
# `gh pr checkout` and friends inherit the caller's stdin, which is the
# terminal in interactive use; draining it here would hang waiting for EOF.
for a in "$@"; do
  if [ "$prev" = "--body-file" ] && [ "$a" = "-" ]; then
    cat >>"$STUB_DIR/gh-comment-body" 2>/dev/null || true
    break
  fi
  prev="$a"
done
exit 0
S
chmod +x "$TMP"/bin/*

new_case() {  # <name> ; sets CASE STUB_DIR RECORD and a fresh HOME
  CASE="$TMP/$1"; mkdir -p "$CASE/stubs" "$CASE/home"
  export STUB_DIR="$CASE/stubs" RECORD="$CASE/record"
  : > "$RECORD"
}
stub() { printf '%s\n' "$2" > "$STUB_DIR/$1"; }
calls() { grep -c "CALL=$1" "$RECORD"; }

run_review_cycle_mode() {  # forwards args to the script; caller captures $?
  ( cd "$ROOT" && HOME="$CASE/home" PATH="$TMP/bin:/usr/bin:/bin" TEST_PR_NUM=7 \
      BABYSIT_TEST_MODE=review-cycle-mcp-outage "$SCRIPT" --reviewer codex "$@" \
  ) >"$CASE/stdout" 2>"$CASE/stderr"
}

# ---------- TC-2.8: Codex MCP Transport Failure (3 Retries) ----------
# Response order: codex.1 is reviewer_preflight()'s probe (must stay clean so
# it doesn't short-circuit into the codex-outdated/no-credits paths);
# codex.2-4 are the three review attempts inside codex_review_with_retry(),
# each a transport failure so the retry loop exhausts and returns 2.
new_case tc28
stub codex.1 "@@RC=0"
for i in 2 3 4; do printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.$i"; done
run_review_cycle_mode
assert_grep "TC-2.8 run_review_cycle returns 2 after 3 transport failures" "run_review_cycle_rc=2" "$CASE/stdout"
assert_eq "TC-2.8 codex called 4 times (1 preflight + 3 attempts)" "$(calls codex)" "4"
assert_grep "TC-2.8 backs off 60s then 300s" "CALL=sleep 60" "$RECORD"
assert_grep "TC-2.8 backs off 300s" "CALL=sleep 300" "$RECORD"
assert_grep "TC-2.8 checks out the PR" "CALL=gh pr checkout 7" "$RECORD"
assert_grep "TC-2.8 labels the PR review-mcp-outage" "CALL=gh label create review-mcp-outage" "$RECORD"
assert_grep "TC-2.8 adds the review-mcp-outage label" "CALL=gh pr edit 7 --add-label review-mcp-outage" "$RECORD"
assert_grep "TC-2.8 drafts the PR" "CALL=gh pr ready 7 --undo" "$RECORD"
assert_grep "TC-2.8 posts an outage comment" "CALL=gh pr comment 7 --body-file -" "$RECORD"
assert_grep "TC-2.8 outage comment names the MCP transport failure" \
  "codex MCP transport failure — review pending" "$CASE/stubs/gh-comment-body"
assert_grep "TC-2.8 outage comment states the reason" \
  "Reason: codex MCP transport failure after 3 retries (cycle 1)" "$CASE/stubs/gh-comment-body"
assert_not_grep "TC-2.8 does not take the generic review-incomplete path" "review-incomplete" "$RECORD"
assert_grep "TC-2.8 logs the MCP outage reason" \
  "codex MCP outage for PR #7: codex MCP transport failure after 3 retries (cycle 1)" "$CASE/stderr"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
