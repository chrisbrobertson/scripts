#!/usr/bin/env bash
# Recording-stub harness for lib/bazaar-review.sh (BZR-FEAT-REVIEW-LIB acceptance
# tests + the ASF QA-TEST-PLAN TC-3.x reviewer cases). No network: claude, codex,
# gh, and sleep are stubs on PATH; git runs against a throwaway local origin.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
LIB="$ROOT/lib/bazaar-review.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3' got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; fail "$1"; else pass "$1"; fi; }

# ---------- stubs ----------
# Each stub consumes $STUB_DIR/<tool>.<n> in order. A response file may carry
# directive lines: @@RC=<n> (exit code), @@COMMIT (claude: make an empty commit
# in cwd), @@STDOUT (codex: also echo the body to stdout, for telltale scans).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/_next" <<'S'
#!/usr/bin/env bash
tool="$1"; c="$STUB_DIR/$tool.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
f="$STUB_DIR/$tool.$n"; [ -f "$f" ] || f="$STUB_DIR/$tool.default"; echo "$f"
S
cat > "$TMP/bin/claude" <<'S'
#!/usr/bin/env bash
printf 'CALL=claude %s\n' "$*" >> "$RECORD"
f=$("$(dirname "$0")/_next" claude)
rc=$(grep -m1 '^@@RC=' "$f" | cut -d= -f2); rc=${rc:-0}
grep -q '^@@COMMIT' "$f" && git commit --allow-empty -q -m "stub remediation" >/dev/null 2>&1
body=$(grep -v '^@@' "$f")
printf '{"type":"system","subtype":"init","session_id":"stub"}\n'
python3 -c 'import json,sys; print(json.dumps({"type":"result","result":sys.stdin.read()}))' <<< "$body"
exit "$rc"
S
cat > "$TMP/bin/codex" <<'S'
#!/usr/bin/env bash
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
cat > "$TMP/bin/gh" <<'S'
#!/usr/bin/env bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$*" in
  *"pr comment"*) cat >/dev/null; exit 0 ;;
  *"--json reviews,comments"*) printf '%s' "${STUB_PR_JSON:-{\}}"; exit 0 ;;
  *"--json comments"*|*"--json reviews"*) echo ""; exit 0 ;;
  *"api "*"/comments"*) echo "[]"; exit 0 ;;
  *) exit 0 ;;
esac
S
cat > "$TMP/bin/sleep" <<'S'
#!/usr/bin/env bash
printf 'CALL=sleep %s\n' "$*" >> "$RECORD"
S
chmod +x "$TMP"/bin/*
export PATH="$TMP/bin:$PATH"

# ---------- fixtures ----------
CLEAN='## BLOCKING
- (none)

## RECOMMENDED
- (none)

## INFORMATION
- (none)'
ONE_BLOCKING='## BLOCKING
- [NEW] off-by-one — a.sh:3 — loop bound

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

new_case() {  # <name> ; sets STUB_DIR RECORD LOG TMP_* and a repo with origin
  CASE="$TMP/$1"; mkdir -p "$CASE"
  export STUB_DIR="$CASE/stubs" RECORD="$CASE/record" LOG="$CASE/log"
  mkdir -p "$STUB_DIR"; : > "$RECORD"; : > "$LOG"
  export TMP_REVIEW="$CASE/review" TMP_CODEX_FULL="$CASE/codex-full" TMP_REVIEW_RESULT="$CASE/result"
  export REPO="o/r" IMPLEMENTER=claude REVIEWER=codex
  unset IMPLEMENTER_MODEL IMPLEMENTER_EFFORT REVIEWER_MODEL REVIEWER_EFFORT
  git init -q --bare "$CASE/origin.git"
  git init -q "$CASE/wt"; git -C "$CASE/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$CASE/wt" remote add origin "$CASE/origin.git"; git -C "$CASE/wt" push -q origin HEAD:refs/heads/feat 2>/dev/null
  git -C "$CASE/wt" config user.name t; git -C "$CASE/wt" config user.email t@t
  export REVIEW_WORKDIR="$CASE/wt" BABYSIT_TEST_MODE=1
}
stub() { printf '%s\n' "$2" > "$STUB_DIR/$1"; }   # stub codex.1 "$BODY"

# ---------- AT1: sourcing is side-effect free under set -u ----------
out=$(bash -c 'set -u; source "'"$LIB"'" && echo sourced && ls' 2>&1 | grep -c "sourced")
assert_eq "AT1 source under set -u" "$out" "1"
before=$(ls "$TMP" | wc -l); bash -c 'cd "'"$TMP"'" && source "'"$LIB"'"'; after=$(ls "$TMP" | wc -l)
assert_eq "AT1 sourcing creates no files" "$after" "$before"

# ---------- AT7: missing global exits 2 naming it ----------
new_case at7; unset LOG
rc=0; msg=$(bash -c 'source "'"$LIB"'"; review_with_retry x' 2>&1) || rc=$?
assert_eq "AT7 missing LOG exits 2" "$rc" "2"
case "$msg" in *"'LOG'"*) pass "AT7 names LOG" ;; *) fail "AT7 names LOG ($msg)" ;; esac

# ---------- AT6: parser functions byte-identical to the builder ----------
for f in valid_review_structure count_blocking; do
  a=$(awk "/^$f\(\) *\{/,/^\}/" "$LIB" | md5); b=$(awk "/^$f\(\) *\{/,/^\}/" "$ROOT/babysit-builder.sh" | md5)
  assert_eq "AT6 $f md5 matches babysit-builder.sh" "$a" "$b"
done

# ---------- TC-3.x reviewer cases via review_with_retry ----------
run_reviewer() { ( source "$LIB"; review_with_retry "prompt" ); }

new_case tc31; stub codex.1 "$CLEAN"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.1 success on attempt 1 → rc 0" "$rc" "0"
assert_eq "TC-3.1 no retries" "$(grep -c CALL=codex "$RECORD")" "1"

new_case tc32; printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.1"; stub codex.2 "$CLEAN"
rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.2 transport then success → rc 0" "$rc" "0"
assert_grep "TC-3.2 logs 60s wait" "waiting 60s before retry (attempt 2 of 3)" "$LOG"

new_case at2; for i in 1 2 3; do printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.$i"; done
rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "AT2/TC-3.4 three transport failures → rc 2" "$rc" "2"
assert_eq "AT2 exactly 3 attempts" "$(grep -c CALL=codex "$RECORD")" "3"
assert_grep "AT2 logs 300s wait" "waiting 300s before retry (attempt 3 of 3)" "$LOG"
assert_grep "AT2 logs attempt-3 transport failure" "MCP transport failure on attempt 3 of 3" "$LOG"

new_case tc33; for i in 1 2; do printf '@@STDOUT\n@@RC=1\nTransport send error: boom\n' > "$STUB_DIR/codex.$i"; done; stub codex.3 "$CLEAN"
rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.3 transport, transport, success → rc 0" "$rc" "0"
assert_grep "TC-3.3 logs 60s wait" "waiting 60s before retry (attempt 2 of 3)" "$LOG"
assert_grep "TC-3.3 logs 300s wait" "waiting 300s before retry (attempt 3 of 3)" "$LOG"

new_case tc310; printf '@@STDOUT\n@@RC=1\nTransport send error: x\nrequires a newer version of Codex\n' > "$STUB_DIR/codex.1"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.10 compat beats mcp telltale → rc 3" "$rc/$(grep -c CALL=codex "$RECORD")" "3/1"

new_case tc314; printf '@@STDOUT\n@@RC=1\nTransport send error: x\nYour workspace is out of credits\n' > "$STUB_DIR/codex.1"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.14 credits beats mcp telltale → rc 4" "$rc/$(grep -c CALL=codex "$RECORD")" "4/1"

new_case tc35; printf '@@RC=1\nsomething else broke\n' > "$STUB_DIR/codex.1"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.5 non-telltale failure → rc 1, no retry" "$rc/$(grep -c CALL=codex "$RECORD")" "1/1"

new_case tc39; printf '@@STDOUT\n@@RC=1\nerror: requires a newer version of Codex\n' > "$STUB_DIR/codex.1"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.9 compat telltale → rc 3 immediately" "$rc/$(grep -c CALL=codex "$RECORD")" "3/1"

new_case tc313; printf '@@STDOUT\n@@RC=1\nERROR: Your workspace is out of credits.\n' > "$STUB_DIR/codex.1"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.13 credits telltale → rc 4 immediately" "$rc/$(grep -c CALL=codex "$RECORD")" "4/1"

new_case tc311; stub codex.1 "$MISSING_REC"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.11 missing RECOMMENDED → rc 1" "$rc" "1"

new_case tc312b; stub codex.1 "$BARE_HEADERS"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.12b bare headers → rc 1" "$rc" "1"

new_case tc36; printf '@@STDOUT\n@@RC=0\n' > "$STUB_DIR/codex.1"; printf '@@STDOUT\n@@RC=0\n' > "$STUB_DIR/codex.2"; printf '@@STDOUT\n@@RC=0\n' > "$STUB_DIR/codex.3"
rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "TC-3.6 exit 0 with empty review, no telltale → rc 1" "$rc" "1"

# claude reviewer path
new_case clrev; REVIEWER=claude; stub claude.1 "$CLEAN"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "claude reviewer accepts valid structure" "$rc" "0"
assert_grep "claude reviewer uses plan permission mode" "--permission-mode plan" "$RECORD"
new_case clrev2; REVIEWER=claude; stub claude.1 "$MISSING_REC"; rc=0; run_reviewer >/dev/null 2>&1 || rc=$?
assert_eq "claude reviewer rejects invalid structure" "$rc" "1"

# ---------- prompt registry: AT4 ----------
p=$( source "$LIB"; review_prompt spec 5 )
case "$p" in *"Suggested wording:"*) pass "AT4 spec cycle 5 is prescriptive spec prompt" ;; *) fail "AT4 spec cycle 5 prompt" ;; esac
case "$p" in *"ADJUDICATION"*) fail "AT4 spec never adjudicates" ;; *) pass "AT4 spec never adjudicates" ;; esac
p=$( source "$LIB"; review_prompt code 5 ); case "$p" in *"## ADJUDICATION"*) pass "code cycle 5 adjudicates" ;; *) fail "code cycle 5 adjudicates" ;; esac
rc=0; ( source "$LIB"; review_prompt bogus 1 ) >/dev/null 2>&1 || rc=$?; assert_eq "unknown prompt key fails loudly" "$rc" "2"
assert_eq "remediation model staged" "$( source "$LIB"; echo "$(remediation_model code 3)/$(remediation_model code 4)" )" "claude-sonnet-5/claude-opus-4-8"
# prompt text byte-identical to sources
for pair in "BZR_CODE_REVIEW_C1:REVIEW_PROMPT_CYCLE1:babysit-builder.sh" "BZR_CODE_REM_C5_6:REMEDIATION_PROMPT_CYCLE5_6:babysit-builder.sh" "BZR_SPEC_REVIEW_C3:SPEC_REVIEW_PROMPT_CYCLE3:babysit-work-prep.sh" "BZR_SPEC_REM:SPEC_REVISION_PROMPT:babysit-work-prep.sh"; do
  IFS=: read -r ours theirs src <<< "$pair"
  a=$(sed -n "/^IFS= read -r -d .. $ours /,/^PROMPT_EOF$/p" "$LIB" | sed 1d | md5)
  b=$(sed -n "/^IFS= read -r -d .. $theirs /,/^PROMPT_EOF$/p" "$ROOT/$src" | sed 1d | md5)
  assert_eq "prompt $ours verbatim from $src" "$a" "$b"
done

# ---------- the cycle: AT3, AT5 ----------
run_cycle() { ( source "$LIB"; run_review_cycle "$@" ); }

new_case at3; stub codex.1 "$ONE_BLOCKING"; stub codex.2 "$CLEAN"; printf '@@COMMIT\nfixed it\nDONE_REVIEW\n' > "$STUB_DIR/claude.1"
rc=0; run_cycle --mode code --pr 7 --worktree "$CASE/wt" --branch feat >/dev/null 2>&1 || rc=$?
assert_eq "AT3 1 BLOCKING then 0 → rc 0" "$rc" "0"
assert_eq "AT3 two reviewer calls" "$(grep -c CALL=codex "$RECORD")" "2"
assert_eq "AT3 two PR comments recorded" "$(grep -c 'CALL=gh pr comment' "$RECORD")" "2"
assert_eq "AT3 one remediation pass" "$(grep -c CALL=claude "$RECORD")" "1"
assert_grep "AT3 remediation uses stage model" "--model claude-sonnet-5" "$RECORD"
assert_eq "AT3 worktree pushed to origin/feat" "$(git -C "$CASE/wt" rev-parse HEAD)" "$(git --git-dir="$CASE/origin.git" rev-parse feat)"
assert_not_grep "AT3 lib never posts commit status" "CALL=gh api -X POST repos/o/r/statuses" "$RECORD"
assert_not_grep "AT3 lib never labels" "CALL=gh pr edit" "$RECORD"
assert_not_grep "AT3 lib never toggles draft" "CALL=gh pr ready" "$RECORD"
assert_not_grep "AT3 lib never merges" "CALL=gh pr merge" "$RECORD"

new_case fb; stub codex.1 "$ONE_BLOCKING"; stub codex.2 "$CLEAN"; printf '@@COMMIT\nDONE_REVIEW\n' > "$STUB_DIR/claude.1"
STUB_PR_JSON='{"reviews":[],"comments":[{"author":{"login":"me"},"body":"<!-- bzr-review reviewer=codex cycle=1 of=6 -->\n**Codex review — PR #7 cycle 1 of 6**\nOLD_REVIEW_TEXT"},{"author":{"login":"human"},"body":"please also rename foo"}]}' \
  run_cycle --mode code --pr 7 --worktree "$CASE/wt" --branch feat >/dev/null 2>&1
assert_not_grep "prior reviewer comment not fed back as PR feedback" "Comment by me" "$RECORD"
assert_grep "human PR comment is fed back" "please also rename foo" "$RECORD"

new_case at5; stub codex.default "$ONE_BLOCKING"; printf '@@COMMIT\nDONE_REVIEW\n' > "$STUB_DIR/claude.default"
rc=0; run_cycle --mode code --pr 7 --worktree "$CASE/wt" --branch feat --max-cycles 2 >/dev/null 2>&1 || rc=$?
assert_eq "AT5 cap 2 never converging → rc 10" "$rc" "10"
assert_eq "AT5 exactly 2 reviewer calls" "$(grep -c CALL=codex "$RECORD")" "2"

new_case bail; stub codex.1 "$ONE_BLOCKING"; printf 'STUCK_REVIEW cannot\n' > "$STUB_DIR/claude.1"
rc=0; run_cycle --mode code --pr 7 --worktree "$CASE/wt" --branch feat >/dev/null 2>&1 || rc=$?
assert_eq "STUCK_REVIEW → rc 20" "$rc" "20"

new_case noprog; stub codex.1 "$ONE_BLOCKING"; printf 'DONE_REVIEW\n' > "$STUB_DIR/claude.1"
rc=0; run_cycle --mode code --pr 7 --worktree "$CASE/wt" --branch feat >/dev/null 2>&1 || rc=$?
assert_eq "no commits after remediation → rc 20" "$rc" "20"

new_case lastfile; stub codex.1 "$ONE_BLOCKING"; printf '@@RC=1\nboom\n' > "$STUB_DIR/codex.2"; printf '@@COMMIT\nDONE_REVIEW\n' > "$STUB_DIR/claude.1"
rc=0; last=$( source "$LIB"; run_review_cycle --mode code --pr 7 --worktree "$CASE/wt" --branch feat >/dev/null 2>&1; echo "$?:$REVIEW_LAST_FILE" )
assert_eq "reviewer fails in cycle 2 → rc 20" "${last%%:*}" "20"
assert_grep "REVIEW_LAST_FILE still holds cycle-1 review" "off-by-one" "${last#*:}"

new_case outage; for i in 1 2 3; do printf '@@STDOUT\n@@RC=1\nTransport send error: x\n' > "$STUB_DIR/codex.$i"; done
rc=0; run_cycle --mode code --pr 7 --worktree "$CASE/wt" --branch feat >/dev/null 2>&1 || rc=$?
assert_eq "cycle propagates reviewer outage → rc 2" "$rc" "2"

new_case specmode; stub codex.1 "$ONE_BLOCKING"; stub codex.2 "$CLEAN"; printf '@@COMMIT\nDONE_REVIEW\n' > "$STUB_DIR/claude.1"
rc=0; run_cycle --mode spec --pr 9 --worktree "$CASE/wt" --branch feat --spec-path specs/L3-x.md --spec-dir specs --spec-guide /g.md \
  --ticket 42 --ticket-url u --ticket-title T --ticket-body B --validate-cmd 'true' >/dev/null 2>&1 || rc=$?
assert_eq "spec mode converges → rc 0" "$rc" "0"
assert_grep "spec mode substitutes spec path into prompt" "specs/L3-x.md" "$RECORD"
assert_not_grep "spec mode does not collect PR feedback" "--json reviews" "$RECORD"

new_case specval; stub codex.1 "$ONE_BLOCKING"; printf '@@COMMIT\nDONE_REVIEW\n' > "$STUB_DIR/claude.1"
rc=0; run_cycle --mode spec --pr 9 --worktree "$CASE/wt" --branch feat --validate-cmd 'false' >/dev/null 2>&1 || rc=$?
assert_eq "spec mode validate-cmd failure → rc 20" "$rc" "20"

rc=0; ( source "$LIB"; LOG=/dev/null TMP_REVIEW=x TMP_REVIEW_RESULT=x REPO=o/r IMPLEMENTER=claude REVIEWER=claude run_review_cycle --mode nope --pr 1 --worktree . --branch b ) >/dev/null 2>&1 || rc=$?
assert_eq "bad --mode → rc 2" "$rc" "2"

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
