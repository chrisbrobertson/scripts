#!/usr/bin/env bash
# Harness for bazaar-issue-worker.sh: real git origin + fake gh + scripted
# claude/codex stubs (@@SH runs a snippet in the worktree, @@COMMIT commits).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3' got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; fail "$1"; else pass "$1"; fi; }

mkdir -p "$TMP/bin"; ln -s "$ROOT/test-support/fake-gh.py" "$TMP/bin/gh"
cat > "$TMP/bin/_next" <<'S'
#!/usr/bin/env bash
tool="$1"; c="$STUB_DIR/$tool.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
f="$STUB_DIR/$tool.$n"; [ -f "$f" ] || f="$STUB_DIR/$tool.default"; echo "$f"
S
cat > "$TMP/bin/claude" <<'S'
#!/usr/bin/env bash
printf 'CALL=claude %s\n' "${*:0:300}" >> "$RECORD"
f=$("$(dirname "$0")/_next" claude)
rc=$(grep -m1 '^@@RC=' "$f" | cut -d= -f2); rc=${rc:-0}
if grep -q '^@@SH$' "$f"; then sed -n '/^@@SH$/,/^@@END$/p' "$f" | sed '1d;$d' | bash; fi
grep -q '^@@COMMIT' "$f" && git commit --allow-empty -q -m "stub remediation" >/dev/null 2>&1
body=$(sed '/^@@SH$/,/^@@END$/d' "$f" | grep -v '^@@')
printf '{"type":"system","subtype":"init","session_id":"stub"}\n'
python3 -c 'import json,sys; print(json.dumps({"type":"result","result":sys.stdin.read()}))' <<< "$body"
exit "$rc"
S
cat > "$TMP/bin/codex" <<'S'
#!/usr/bin/env bash
printf 'CALL=codex %s\n' "${*:0:200}" >> "$RECORD"
f=$("$(dirname "$0")/_next" codex)
rc=$(grep -m1 '^@@RC=' "$f" | cut -d= -f2); rc=${rc:-0}
out=""; while [ "$#" -gt 0 ]; do [ "$1" = "--output-last-message" ] && { out="$2"; shift 2; continue; }; shift; done
body=$(grep -v '^@@' "$f"); echo "codex noise"
grep -q '^@@STDOUT' "$f" && printf '%s\n' "$body"
[ -n "$out" ] && ! grep -q '^@@STDOUT' "$f" && printf '%s\n' "$body" > "$out"
exit "$rc"
S
chmod +x "$TMP"/bin/*; export PATH="$TMP/bin:$PATH" BABYSIT_TEST_MODE=1 BZR_HOST=testhost

CLEAN='## BLOCKING
- (none)

## RECOMMENDED
- (none)

## INFORMATION
- (none)'
ONE_BLOCKING='## BLOCKING
- [NEW] dangling parent_feature — specs/L4-a.md — no such L3

## RECOMMENDED
- (none)

## INFORMATION
- (none)'
VERIFY_OK_STUB='@@SH
cat > "$BZR_RUN_DIR/normalised.md" <<N
## Problem
Thing is broken.

## Desired outcome
Thing works.

## Acceptance criteria
- [ ] it works

## Scope
In: thing
Out: other

## Type
feature

## Links
Specs: none yet
N
printf "feature\nlabel enhancement\n" > "$BZR_RUN_DIR/classification.txt"
@@END
Verified.
VERIFY_OK'
draft_stub() {  # <n_l4> [extra-shell]
  local n="$1" i extra="${2:-}"
  printf '@@SH\nmkdir -p specs\n'
  printf 'printf -- "---\\nspec_type: feature\\nid: X-FEAT-THING\\nstatus: review\\n---\\n\\n## TL;DR\\nA thing. https://github.com/o/r/issues/7\\n" > specs/L3-thing.md\n'
  for i in $(seq 1 "$n"); do printf 'printf -- "---\\nspec_type: task\\nid: X-TASK-P%s\\nstatus: review\\nparent_feature: X-FEAT-THING\\n---\\n\\n## TL;DR\\nPart %s does the thing. More.\\n" > specs/L4-part%s.md\n' "$i" "$i" "$i"; done
  printf '%s\n' "$extra"
  printf 'printf "# index\\n- thing\\n" > specs/index.md\n'
  printf 'git add -A specs && git commit -q -m "draft"\n@@END\nDrafted.\nDRAFT_DONE\n'
}

new_case() {  # <name> <issue-body> [comments-py] [prs-py]
  CASE="$TMP/$1"; mkdir -p "$CASE"
  export FAKE_GH_STATE="$CASE/state.json" RECORD="$CASE/record" STUB_DIR="$CASE/stubs" BZR_HOME="$CASE/home" BZR_REPO_DIR="$CASE/home/o-r" BZR_LOG="$CASE/worker.log" BZR_SENTINEL="$CASE/sentinel"
  mkdir -p "$STUB_DIR" "$BZR_REPO_DIR/wt"; : > "$RECORD"; : > "$BZR_LOG"; rm -f "$BZR_SENTINEL"
  local comments="${3:-[]}" prs="${4:-}"; [ -n "$prs" ] || prs="{}"
  python3 - "$FAKE_GH_STATE" "$2" "$comments" "$prs" <<'PY'
import json, sys
body, comments, prs = sys.argv[2], eval(sys.argv[3]), eval(sys.argv[4])
for k, v in prs.items():
    v.setdefault("number", int(k)); v.setdefault("headRefName", "x"); v.setdefault("state", "OPEN"); v.setdefault("isDraft", True); v.setdefault("mergedAt", None)
    v.setdefault("body", ""); v.setdefault("comments", []); v.setdefault("reviews", []); v.setdefault("files", [])
json.dump({"repo": "o/r", "default_branch": "main", "login": "me", "statuses": [],
  "issues": {"7": {"number": 7, "id": 1007, "title": "Make the thing work", "body": body, "state": "OPEN", "createdAt": "2026-01-01T00:00:00Z",
                   "labels": ["enhancement", "bzr-drafting"], "comments": comments, "parent": None, "sub_issues": []}},
  "prs": prs}, open(sys.argv[1], "w"))
PY
  git init -q --bare "$CASE/origin.git"; git clone -q "$CASE/origin.git" "$CASE/clone" 2>/dev/null
  mkdir -p "$CASE/clone/specs"; printf -- '---\nspec_type: product\nid: X-PROD-R\nstatus: ready\n---\n' > "$CASE/clone/specs/L1-r.md"
  git -C "$CASE/clone" add -A; git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q -m init; git -C "$CASE/clone" push -q origin HEAD:main 2>/dev/null
}
stub() { printf '%s\n' "$2" > "$STUB_DIR/$1"; }
run_worker() { ( cd "$CASE/clone" && BZR_REPO=o/r DEFAULT_BRANCH=main SCRIPTS_DIR="$ROOT" BZR_APPROVERS=me IMPLEMENTER=claude REVIEWER=codex "$ROOT/bazaar-issue-worker.sh" 7 ) >>"$CASE/worker.out" 2>&1; echo $?; }
sentinel() { cat "$BZR_SENTINEL" 2>/dev/null; }
field() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); o=s; [o:=o[k] for k in sys.argv[2].split("/")]; print(o if isinstance(o,str) else json.dumps(o))' "$FAKE_GH_STATE" "$1"; }
comments() { python3 -c 'import json,sys; [print(c["body"]) for c in json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["comments"]]' "$FAKE_GH_STATE" "$1"; }

# ---- AT1: title-only → questions ----
new_case q1 ''
stub claude.1 '@@SH
printf "1. What is the desired outcome? (unblocks: acceptance criteria)\n2. Which component? (unblocks: scope)\n" > "$BZR_RUN_DIR/questions.md"
@@END
NEEDS_INFO 2'
rc=$(run_worker)
assert_eq "AT1 sentinel NEEDS_INFO 2" "$(sentinel)" "NEEDS_INFO 2"
assert_grep "AT1 questions posted with marker" "<!-- bzr-issue-worker phase=questions" <(comments 7)
assert_grep "AT1 questions numbered" "2. Which component?" <(comments 7)
assert_eq "AT1 body untouched" "$(field issues/7/body)" ""
assert_eq "AT1 no PR opened" "$(field prs)" "{}"

# ---- AT2/3/4/5/9: full path ----
new_case full 'plz make thing work, see #3'
stub claude.1 "$VERIFY_OK_STUB"; stub claude.2 "$(draft_stub 2)"
stub codex.1 "$ONE_BLOCKING"; stub claude.3 $'@@COMMIT\nfixed\nDONE_REVIEW'; stub codex.2 "$CLEAN"
rc=$(run_worker)
assert_eq "full: sentinel SPEC_REVIEW 101" "$(sentinel)" "SPEC_REVIEW 101"
assert_grep "AT9 body rewritten with template" "## Acceptance criteria" <(field issues/7/body)
assert_grep "AT9 original preserved verbatim in details block" "<details><summary>Original report</summary>" <(field issues/7/body)
assert_grep "AT9 original text present" "plz make thing work, see #3" <(field issues/7/body)
assert_eq "PR opened draft on bzr/spec-7 then made ready" "$(field prs/101/headRefName)/$(field prs/101/isDraft)" "bzr/spec-7/false"
assert_grep "PR body carries the marker" "<!-- bzr-spec issue=7 class=feature -->" <(field prs/101/body)
assert_grep "PR body carries Refs, not Closes" "Refs #7" <(field prs/101/body)
assert_not_grep "PR body spec list excludes index.md" "index.md" <(field prs/101/body | grep '^Specs:')
assert_eq "AT4 two draft-time sub-issues attached" "$(field issues/7/sub_issues)" "[8, 9]"
assert_grep "AT4 sub-issue marker" "<!-- bzr-sub-issue parent=7 spec=X-TASK-P1 -->" <(field issues/8/body)
assert_eq "AT5 two review cycles ran" "$(grep -c CALL=codex "$RECORD")" "2"
assert_eq "AT5 branch on origin has the specs" "$(git --git-dir="$CASE/origin.git" ls-tree --name-only bzr/spec-7 specs/ | grep -c L4)" "2"
assert_grep "AT5 converged comment links the PR" "pull/101" <(comments 7)
assert_grep "AT5 converged comment explains approval (allowed by marker)" "the word approved" <(comments 7)
assert_grep "AT5 converged comment carries the marker" "<!-- bzr-issue-worker phase=review" <(comments 7)
assert_eq "worktree removed after the run" "$([ -d "$BZR_REPO_DIR/wt/spec-7" ] && echo present || echo gone)" "gone"
assert_not_grep "worker never edits parent labels" "CALL=gh issue edit 7 --repo o/r --add-label" "$RECORD"

# ---- one L4 → no sub-issues ----
new_case one 'body'
stub claude.1 "$VERIFY_OK_STUB"; stub claude.2 "$(draft_stub 1)"; stub codex.1 "$CLEAN"
rc=$(run_worker)
assert_eq "single L4 → no sub-issues" "$(sentinel)/$(field issues/7/sub_issues)" "SPEC_REVIEW 101/[]"

# ---- AT11: no spec corpus ----
new_case nocorpus 'body'
git -C "$CASE/clone" rm -q -r specs; git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q -m "no specs"; git -C "$CASE/clone" push -q origin HEAD:main 2>/dev/null
rc=$(run_worker)
assert_eq "AT11 no corpus → NOT_ACTIONABLE" "$(sentinel | cut -d" " -f1)" "NOT_ACTIONABLE"
assert_grep "AT11 explains" "no spec corpus" <(comments 7)
assert_eq "AT11 no model call" "$(grep -c CALL=claude "$RECORD")" "0"

# ---- AT7: duplicate ----
new_case dup 'body'
stub claude.1 $'@@SH\necho "same as #4" > "$BZR_RUN_DIR/not_actionable.txt"\n@@END\nNOT_ACTIONABLE duplicate of #4'
rc=$(run_worker)
assert_eq "AT7 duplicate → NOT_ACTIONABLE duplicate of #4" "$(sentinel)" "NOT_ACTIONABLE duplicate of #4"

# ---- crash paths → STUCK ----
new_case crash 'body'; stub claude.1 $'@@RC=1\nboom'
rc=$(run_worker)
assert_eq "implementer failure → STUCK" "$(sentinel | cut -d" " -f1)" "STUCK"
new_case nosent 'body'; stub claude.1 'I did things but forgot the sentinel'
rc=$(run_worker)
assert_grep "no sentinel → STUCK" "STUCK verification ended without a sentinel" "$BZR_SENTINEL"
new_case killed 'body'; stub claude.1 $'@@SH\nkill -TERM $PPID\n@@END\nnever'
rc=$(run_worker)
assert_grep "killed mid-run → EXIT trap writes STUCK" "STUCK" "$BZR_SENTINEL"

# ---- two bounces → BLOCKED ----
new_case bounce2 'body' '[{"author":"me","body":"<!-- bzr-issue-worker phase=questions ts=a -->\n1. q","createdAt":"a"},{"author":"me","body":"ans","createdAt":"b"},{"author":"me","body":"<!-- bzr-issue-worker phase=questions ts=c -->\n1. q2","createdAt":"c"},{"author":"me","body":"ans2","createdAt":"d"}]'
stub claude.1 $'@@SH\necho "1. still?" > "$BZR_RUN_DIR/questions.md"\n@@END\nNEEDS_INFO 1'
rc=$(run_worker)
assert_grep "third NEEDS_INFO → BLOCKED" "BLOCKED needs a synchronous conversation" "$BZR_SENTINEL"

# ---- draft touching code → BLOCKED ----
new_case scope 'body'
stub claude.1 "$VERIFY_OK_STUB"; stub claude.2 "$(draft_stub 1 'echo x > hack.py; git add hack.py')"
rc=$(run_worker)
assert_grep "out-of-scope change → BLOCKED" "BLOCKED draft violated the spec-only contract" "$BZR_SENTINEL"
assert_eq "no PR when contract violated" "$(field prs)" "{}"

# ---- review cap → BLOCKED, PR comment ----
new_case cap 'body'
stub claude.1 "$VERIFY_OK_STUB"; stub claude.2 "$(draft_stub 1)"; stub codex.default "$ONE_BLOCKING"; stub claude.default $'@@COMMIT\nDONE_REVIEW'
export MAX_SPEC_REVIEW_CYCLES=1; rc=$(run_worker); unset MAX_SPEC_REVIEW_CYCLES
assert_grep "cap → BLOCKED" "BLOCKED spec review:" "$BZR_SENTINEL"
assert_eq "PR stays draft on cap" "$(field prs/101/isDraft)" "true"
assert_grep "cap explained on the PR" "spec review stopped" <(python3 -c 'import json,sys; [print(c["body"]) for c in json.load(open(sys.argv[1]))["prs"]["101"]["comments"]]' "$FAKE_GH_STATE")

# ---- AT10: re-entry with an existing branch and open PR → no second PR ----
new_case resume 'body' '[]' '{"101":{"headRefName":"bzr/spec-7","body":"<!-- bzr-spec issue=7 class=feature -->\nRefs #7"}}'
git -C "$CASE/clone" checkout -q -b bzr/spec-7; printf -- '---\nspec_type: feature\nid: X-FEAT-THING\nstatus: review\n---\n\n## TL;DR\nold draft\n' > "$CASE/clone/specs/L3-thing.md"; git -C "$CASE/clone" add -A; git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q -m old; git -C "$CASE/clone" push -q origin bzr/spec-7 2>/dev/null; git -C "$CASE/clone" checkout -q main
stub claude.1 "$VERIFY_OK_STUB"; stub claude.2 "$(draft_stub 1)"; stub codex.1 "$CLEAN"
rc=$(run_worker)
assert_eq "AT10 resume: sentinel SPEC_REVIEW on the existing PR" "$(sentinel)" "SPEC_REVIEW 101"
assert_eq "AT10 no second PR" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["prs"]))' "$FAKE_GH_STATE")" "1"
assert_grep "AT10 resume logged" "resuming existing branch" "$BZR_LOG"
assert_grep "AT10 draft prompt says continue" "already contains an earlier draft attempt" "$RECORD"

echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
