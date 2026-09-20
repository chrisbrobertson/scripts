#!/usr/bin/env bash
# Harness for bazaar-build-worker.sh: real git origin + fake gh + scripted stubs.
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
printf 'CALL=claude %s\n' "${*:0:400}" >> "$RECORD"
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
printf 'CALL=codex %s\n' "${*:0:120}" >> "$RECORD"
f=$("$(dirname "$0")/_next" codex)
rc=$(grep -m1 '^@@RC=' "$f" | cut -d= -f2); rc=${rc:-0}
out=""; while [ "$#" -gt 0 ]; do [ "$1" = "--output-last-message" ] && { out="$2"; shift 2; continue; }; shift; done
body=$(grep -v '^@@' "$f"); echo "codex noise"
grep -q '^@@STDOUT' "$f" && printf '%s\n' "$body"
[ -n "$out" ] && ! grep -q '^@@STDOUT' "$f" && printf '%s\n' "$body" > "$out"
exit "$rc"
S
chmod +x "$TMP"/bin/*; export PATH="$TMP/bin:$PATH" BABYSIT_TEST_MODE=1 BZR_HOST=testhost
CLEAN=$'## BLOCKING\n- (none)\n\n## RECOMMENDED\n- (none)\n\n## INFORMATION\n- (none)'
ONE_BLOCKING=$'## BLOCKING\n- [NEW] bug — a.py:1 — wrong\n\n## RECOMMENDED\n- (none)\n\n## INFORMATION\n- (none)'
TRANSPORT=$'@@STDOUT\n@@RC=1\nTransport send error: x'
unit_stub() { printf '@@SH\necho "impl %s" >> src_%s.txt; git add -A; git commit -q -m "feat: unit %s" -m "Refs #%s"\n@@END\nUNIT_DONE\n' "$1" "$1" "$1" "$1"; }
SPECS_LINE='Specs: `specs/L3-thing.md`, `specs/L4-part1.md`, `specs/L4-part2.md`, `specs/L4-part3.md`'

new_case() {  # <name> [status] [subs-py] [prs-py] [body]
  CASE="$TMP/$1"; mkdir -p "$CASE"; local status="${2:-ready}" subs="${3:-}" prs="${4:-}" body="${5:-$SPECS_LINE}"
  export FAKE_GH_STATE="$CASE/state.json" RECORD="$CASE/record" STUB_DIR="$CASE/stubs" BZR_HOME="$CASE/home" BZR_REPO_DIR="$CASE/home/o-r" BZR_LOG="$CASE/worker.log" BZR_SENTINEL="$CASE/sentinel"
  mkdir -p "$STUB_DIR" "$BZR_REPO_DIR/wt"; : > "$RECORD"; : > "$BZR_LOG"; rm -f "$BZR_SENTINEL"
  [ -n "$subs" ] || subs='{"8":{"spec":"X-TASK-P1"},"9":{"spec":"X-TASK-P2"},"10":{"spec":"X-TASK-P3"}}'
  [ -n "$prs" ] || prs="{}"
  python3 - "$FAKE_GH_STATE" "$subs" "$prs" "$body" <<'PY'
import json, sys
subs, prs, body = eval(sys.argv[2]), eval(sys.argv[3]), sys.argv[4]
issues = {"7": {"number": 7, "id": 1007, "title": "Make the thing work", "body": "## Problem\nx\n\n## Links\n" + body + "\n", "state": "OPEN",
                "createdAt": "2026-01-01T00:00:00Z", "labels": ["bzr-building"], "comments": [], "parent": None, "sub_issues": [int(k) for k in subs]}}
for k, v in subs.items():
    issues[k] = {"number": int(k), "id": 1000 + int(k), "title": v.get("title", "Part " + k), "body": v.get("body", "<!-- bzr-sub-issue parent=7 spec=%s -->\nRefs #7" % v["spec"]),
                 "state": v.get("state", "OPEN"), "createdAt": "2026-01-%02dT00:00:00Z" % int(k), "labels": v.get("labels", []), "comments": [], "parent": 7, "sub_issues": []}
for k, v in prs.items():
    v.setdefault("number", int(k)); v.setdefault("headRefName", "x"); v.setdefault("state", "OPEN"); v.setdefault("isDraft", True); v.setdefault("mergedAt", None)
    v.setdefault("body", ""); v.setdefault("comments", []); v.setdefault("reviews", []); v.setdefault("files", [])
json.dump({"repo": "o/r", "default_branch": "main", "login": "me", "statuses": [], "issues": issues, "prs": prs}, open(sys.argv[1], "w"))
PY
  git init -q --bare "$CASE/origin.git"; git clone -q "$CASE/origin.git" "$CASE/clone" 2>/dev/null; mkdir -p "$CASE/clone/specs"
  printf -- '---\nspec_type: feature\nid: X-FEAT-THING\nstatus: %s\n---\n\n## TL;DR\nA thing.\n' "$status" > "$CASE/clone/specs/L3-thing.md"
  local i; for i in 1 2 3; do printf -- '---\nspec_type: task\nid: X-TASK-P%s\nstatus: %s\nparent_feature: X-FEAT-THING\ndepends_on: [%s]\n---\n\n## TL;DR\nPart %s does the thing.\n' "$i" "$status" "$([ "$i" = 3 ] && echo X-TASK-P2)" "$i" > "$CASE/clone/specs/L4-part$i.md"; done
  git -C "$CASE/clone" add -A; git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q -m init; git -C "$CASE/clone" push -q origin HEAD:main 2>/dev/null
}
stub() { printf '%s\n' "$2" > "$STUB_DIR/$1"; }
run_worker() { ( cd "$CASE/clone" && BZR_REPO=o/r DEFAULT_BRANCH=main SCRIPTS_DIR="$ROOT" IMPLEMENTER=claude REVIEWER=codex "$ROOT/bazaar-build-worker.sh" 7 ) >>"$CASE/worker.out" 2>&1; echo $?; }
sentinel() { cat "$BZR_SENTINEL" 2>/dev/null; }
field() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); o=s; [o:=o[k] for k in sys.argv[2].split("/")]; print(o if isinstance(o,str) else json.dumps(o))' "$FAKE_GH_STATE" "$1"; }
comments() { python3 -c 'import json,sys; [print(c["body"]) for c in json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["comments"]]' "$FAKE_GH_STATE" "$1"; }
pr_comments() { python3 -c 'import json,sys; [print(c["body"]) for c in json.load(open(sys.argv[1]))["prs"][sys.argv[2]]["comments"]]' "$FAKE_GH_STATE" "$1"; }
PLAN_OK=$'PLAN #8 depends=none — data model first\nPLAN #9 depends=8 — api\nPLAN #10 depends=9 — ui\nPLAN_POSTED'

# ---- AT1: precheck fails on status: review, no model call ----
new_case pre review
rc=$(run_worker)
assert_eq "AT1 status review → SPEC_GAP" "$(sentinel | cut -d' ' -f1)" "SPEC_GAP"
assert_grep "AT1 reason names the spec" "specs/L3-thing.md is status: review" <(comments 7)
assert_eq "AT1 no model call" "$(grep -c CALL=claude "$RECORD" | tr -d ' ')" "0"
new_case pre2 ready '' '' 'Specs: none yet'
rc=$(run_worker); assert_grep "precheck: missing Specs: line → SPEC_GAP" "no \`Specs:\` line" <(comments 7)

# ---- AT6 + AT2/3 + AT8-ish: full success across three units ----
new_case full
stub claude.1 "$PLAN_OK"; stub claude.2 "$(unit_stub 8)"; stub codex.1 "$CLEAN"; stub claude.3 "$(unit_stub 9)"; stub codex.2 "$CLEAN"; stub claude.4 "$(unit_stub 10)"; stub codex.3 "$CLEAN"
rc=$(run_worker)
assert_eq "AT6 sentinel PR_READY 101" "$(sentinel)" "PR_READY 101"
assert_grep "AT2 plan comment posted with order" "1. #8" <(comments 7)
assert_grep "AT2 plan shows dependency" "3. #10 — \`specs/L4-part3.md\` (after #9)" <(comments 7)
assert_grep "AT3 PR body marker with round" "<!-- bzr-build issue=7 round=1 -->" <(field prs/101/body)
assert_grep "AT6 PR closes parent" $'\nCloses #7' <(field prs/101/body)
assert_grep "AT6 PR closes sub-issue" "Closes #9" <(field prs/101/body)
assert_eq "AT6 PR ready" "$(field prs/101/isDraft)" "false"
head=$(git --git-dir="$CASE/origin.git" rev-parse "bzr/7-make-the-thing-work")
assert_eq "AT6 codex-review status on the head" "$(field statuses | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[-1]["sha"]==sys.argv[1] and s[-1]["context"]=="codex-review")' "$head")" "True"
assert_eq "AT6 three review cycles (one per unit)" "$(grep -c CALL=codex "$RECORD")" "3"
assert_eq "AT6 branch has three unit commits" "$(git --git-dir="$CASE/origin.git" log --oneline bzr/7-make-the-thing-work | grep -c 'feat: unit')" "3"
assert_grep "AT6 finish comment" "round 1 finished" <(comments 7)
assert_not_grep "worker never merges" "CALL=gh pr merge" "$RECORD"
assert_not_grep "worker never edits parent labels" "CALL=gh issue edit 7 " "$RECORD"

# ---- AT4/7b: unit 2 fails review → reverted + labelled; unit 3 (depends on 2) skipped; finish partial ----
new_case skip
stub claude.1 "$PLAN_OK"; stub claude.2 "$(unit_stub 8)"; stub codex.1 "$CLEAN"
stub claude.3 "$(unit_stub 9)"; stub codex.default "$ONE_BLOCKING"; stub claude.default $'@@COMMIT\nDONE_REVIEW'
export MAX_REVIEW_CYCLES=2; rc=$(run_worker); unset MAX_REVIEW_CYCLES
assert_eq "AT4 partial success → PR_READY" "$(sentinel)" "PR_READY 101"
assert_grep "AT4 sub-issue 9 labelled bzr-blocked" "bzr-blocked" <(field issues/9/labels)
assert_grep "AT4 sub-issue 9 told why with last review" "review did not converge" <(comments 9)
assert_grep "AT4 sub-issue 9 comment carries the review" "## BLOCKING" <(comments 9)
assert_eq "AT4 unit 9's commits reverted off the branch" "$(git --git-dir="$CASE/origin.git" show "bzr/7-make-the-thing-work:src_9.txt" 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "AT4 unit 8's work kept" "$(git --git-dir="$CASE/origin.git" show "bzr/7-make-the-thing-work:src_8.txt" | wc -l | tr -d ' ')" "1"
assert_grep "7b unit 10 skipped as dependent" "depends on #9, which was skipped" <(comments 10)
assert_grep "AT4 PR body: Refs not Closes parent when skipped" $'\nRefs #7' <(field prs/101/body)
assert_grep "AT4 PR body state records skip" '"skipped": {"10"' <(field prs/101/body)
assert_grep "AT4 finish lists skipped" "Skipped units: #9 #10" <(comments 7)

# ---- AT5: round 2 after merge builds only the remaining unit on -r2 ----
new_case r2 ready '{"8":{"spec":"X-TASK-P1","state":"CLOSED"},"9":{"spec":"X-TASK-P2"},"10":{"spec":"X-TASK-P3","state":"CLOSED"}}' '{"50":{"state":"MERGED","mergedAt":"t","headRefName":"bzr/7-make-the-thing-work","body":"<!-- bzr-build issue=7 round=1 -->"}}'
stub claude.1 "$(unit_stub 9)"; stub codex.1 "$CLEAN"
rc=$(run_worker)
assert_eq "AT5 round 2 → PR_READY" "$(sentinel)" "PR_READY 101"
assert_grep "AT5 round-2 marker" "<!-- bzr-build issue=7 round=2 -->" <(field prs/101/body)
assert_eq "AT5 branch suffix -r2" "$(field prs/101/headRefName)" "bzr/7-make-the-thing-work-r2"
assert_eq "AT5 single unit → no plan pass, one implement" "$(grep -c CALL=claude "$RECORD")" "1"

# ---- AT7: reviewer transport failure → STUCK, PR draft with pending state ----
new_case outage
stub claude.1 "$PLAN_OK"; stub claude.2 "$(unit_stub 8)"; stub codex.default "$TRANSPORT"
rc=$(run_worker)
assert_grep "AT7 STUCK reviewer unavailable" "STUCK reviewer unavailable on unit #8" "$BZR_SENTINEL"
assert_eq "AT7 PR exists and stays draft" "$(field prs/101/isDraft)" "true"
assert_grep "AT7 state has no converged units" '"converged": {}' <(field prs/101/body)
# resume that outage: state read from PR body, unit 8 re-reviewed (not re-implemented)
new_case resume ready '' '{"101":{"headRefName":"bzr/7-make-the-thing-work","body":"<!-- bzr-build issue=7 round=1 -->\n<!-- bzr-build-state {\"converged\": {\"8\": \"a..b\"}, \"skipped\": {}} -->\nRefs #7"}}'
git -C "$CASE/clone" checkout -q -b bzr/7-make-the-thing-work; echo impl8 > "$CASE/clone/src_8.txt"; git -C "$CASE/clone" add -A; git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q -m "feat: unit 8"; git -C "$CASE/clone" push -q origin bzr/7-make-the-thing-work 2>/dev/null; git -C "$CASE/clone" checkout -q main
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["issues"]["7"]["comments"].append({"author":"me","body":"<!-- bzr-build-plan issue=7 round=1 -->\n1. #8\n2. #9\n3. #10","createdAt":"t"}); json.dump(s,open(sys.argv[1],"w"))' "$FAKE_GH_STATE"
stub claude.1 "$(unit_stub 9)"; stub codex.1 "$CLEAN"; stub claude.2 "$(unit_stub 10)"; stub codex.2 "$CLEAN"
rc=$(run_worker)
assert_eq "resume: converged unit skipped, plan not re-posted, remaining built" "$(sentinel)/$(grep -c CALL=claude "$RECORD")" "PR_READY 101/2"
assert_grep "resume logged" "resuming branch" "$BZR_LOG"

# ---- AT8: no sub-issues, one L4 → single unit, no plan ----
new_case single ready '{}' '' 'Specs: `specs/L3-thing.md`, `specs/L4-part1.md`'
stub claude.1 "$(unit_stub 7)"; stub codex.1 "$CLEAN"
rc=$(run_worker)
assert_eq "AT8 single unit → PR_READY, one implement call" "$(sentinel)/$(grep -c CALL=claude "$RECORD")" "PR_READY 101/1"
assert_grep "AT8 PR closes parent" $'\nCloses #7' <(field prs/101/body)

# ---- SPEC_GAP from implementer → nothing left on the branch ----
new_case gap
stub claude.1 "$PLAN_OK"; stub claude.2 $'@@SH\necho junk > junk.txt\n@@END\nSPEC_GAP acceptance criteria missing'
rc=$(run_worker)
assert_eq "implementer SPEC_GAP → sentinel" "$(sentinel)" "SPEC_GAP unit #8: acceptance criteria missing"
assert_eq "no PR opened" "$(field prs)" "{}"

# ---- all units skipped → PR closed, BLOCKED ----
new_case allskip ready '{"8":{"spec":"X-TASK-P1"}}'
stub claude.1 "$(unit_stub 8)"; stub codex.default "$ONE_BLOCKING"; stub claude.default $'@@COMMIT\nDONE_REVIEW'
export MAX_REVIEW_CYCLES=1; rc=$(run_worker); unset MAX_REVIEW_CYCLES
assert_grep "all skipped → BLOCKED" "BLOCKED no unit converged" "$BZR_SENTINEL"
assert_eq "PR closed" "$(field prs/101/state)" "CLOSED"

# ---- only blocked sub-issues remain → BLOCKED, no model ----
new_case onlyblocked ready '{"8":{"spec":"X-TASK-P1","labels":["bzr-blocked"]}}'
rc=$(run_worker)
assert_grep "only blocked subs → BLOCKED" "BLOCKED every remaining sub-issue is bzr-blocked" "$BZR_SENTINEL"

# ---- bad plan output → deterministic order kept ----
new_case badplan
stub claude.1 $'PLAN #8 depends=none — x\nPLAN_POSTED'; stub claude.2 "$(unit_stub 8)"; stub codex.1 "$CLEAN"; stub claude.3 "$(unit_stub 9)"; stub codex.2 "$CLEAN"; stub claude.4 "$(unit_stub 10)"; stub codex.3 "$CLEAN"
rc=$(run_worker)
assert_eq "bad plan → still builds all in default order" "$(sentinel)" "PR_READY 101"
assert_grep "default order respects L4 depends_on (#10 after #9)" "3. #10" <(comments 7)

echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
