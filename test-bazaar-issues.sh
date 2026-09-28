#!/usr/bin/env bash
# Harness for bazaar-issues.sh: sentinel handling, bounce, approval sweep (real
# git origin + fake gh), resume-after-merge, rejected spec.
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
cat > "$TMP/bin/stub-worker" <<'S'
#!/usr/bin/env bash
printf '%s\n' "${STUB_SENTINEL:-SPEC_REVIEW 12}" > "$BZR_SENTINEL"
S
chmod +x "$TMP"/bin/*; export PATH="$TMP/bin:$PATH" BZR_WORKER_OVERRIDE="stub-worker" BZR_HOST=testhost
new_case() {  # <name> <issues-py> [prs-py]
  CASE="$TMP/$1"; mkdir -p "$CASE"; export FAKE_GH_STATE="$CASE/state.json" RECORD="$CASE/record" BZR_HOME="$CASE/home"; : > "$RECORD"
  local prs="${3:-}"; [ -n "$prs" ] || prs="{}"
  python3 - "$FAKE_GH_STATE" "$2" "$prs" <<'PY'
import json, sys
issues = eval(sys.argv[2]); prs = eval(sys.argv[3])
for k, v in issues.items():
    v.setdefault("number", int(k)); v.setdefault("id", 1000 + int(k)); v.setdefault("title", "issue %s" % k); v.setdefault("body", "## Problem\nx\n\n## Links\nSpecs: none yet\n")
    v.setdefault("state", "OPEN"); v.setdefault("createdAt", "2026-01-%02dT00:00:00Z" % int(k)); v.setdefault("labels", [])
    v.setdefault("comments", []); v.setdefault("parent", None); v.setdefault("sub_issues", [])
for k, v in prs.items():
    v.setdefault("number", int(k)); v.setdefault("headRefName", "x"); v.setdefault("state", "OPEN"); v.setdefault("isDraft", False); v.setdefault("mergedAt", None)
    v.setdefault("body", ""); v.setdefault("comments", []); v.setdefault("reviews", []); v.setdefault("files", [])
json.dump({"repo": "o/r", "default_branch": "main", "login": "me", "issues": issues, "prs": prs, "statuses": []}, open(sys.argv[1], "w"))
PY
  # a real repo: origin + clone (the controller runs from inside the clone)
  git init -q --bare "$CASE/origin.git"; git clone -q "$CASE/origin.git" "$CASE/clone" 2>/dev/null
  git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; git -C "$CASE/clone" push -q origin HEAD:main 2>/dev/null
}
spec_branch() {  # <issue> <n_l4>  — creates bzr/spec-<issue> with one L3 + n L4 specs, pushes
  local issue="$1" n="$2" i
  git -C "$CASE/clone" checkout -q -b "bzr/spec-$issue" main; mkdir -p "$CASE/clone/specs"
  printf -- '---\nspec_type: feature\nid: X-FEAT-THING\nstatus: review\n---\n\n## TL;DR\nA thing.\n' > "$CASE/clone/specs/L3-thing.md"
  for i in $(seq 1 "$n"); do printf -- '---\nspec_type: task\nid: X-TASK-P%s\nstatus: review\nparent_feature: X-FEAT-THING\n---\n\n## TL;DR\nPart %s does the %s-th thing. More detail.\n' "$i" "$i" "$i" > "$CASE/clone/specs/L4-part$i.md"; done
  printf '# index\n' > "$CASE/clone/specs/index.md"
  git -C "$CASE/clone" add -A; git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q -m "spec draft"; git -C "$CASE/clone" push -q origin "bzr/spec-$issue" 2>/dev/null
  git -C "$CASE/clone" checkout -q main
}
labels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["labels"]))' "$FAKE_GH_STATE" "$1"; }
field() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); o=s; [o:=o[k] for k in sys.argv[2].split("/")]; print(o if isinstance(o,str) else json.dumps(o))' "$FAKE_GH_STATE" "$1"; }
comments() { python3 -c 'import json,sys; [print(c["body"].split("\n")[0]) for c in json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["comments"]]' "$FAKE_GH_STATE" "$1"; }
run() { ( cd "$CASE/clone" && "$ROOT/bazaar-issues.sh" --repo o/r --controller-model none "$@" ); }
LOGF() { echo "$BZR_HOME/o-r/logs/ctl-issues-$(date +%Y%m%d).log"; }

# ---- intake + sentinels ----
new_case s1 '{"1":{"labels":[]},"2":{"labels":["bug"]},"3":{"labels":["bzr-ready"]}}'
run --once --workers 2 >/dev/null 2>&1
assert_eq "intake: unlabelled and non-bzr-labelled issues dispatched; bzr-labelled skipped" "$(labels 1)/$(labels 2)/$(labels 3)" "bzr-spec-review/bug,bzr-spec-review/bzr-ready"
new_case s2 '{"1":{}}'; STUB_SENTINEL="NEEDS_INFO 3" run --once >/dev/null 2>&1
assert_eq "NEEDS_INFO → bzr-needs-info" "$(labels 1)" "bzr-needs-info"
new_case s3 '{"1":{}}'; STUB_SENTINEL="NOT_ACTIONABLE no spec corpus" run --once >/dev/null 2>&1
assert_eq "AT11(issue) NOT_ACTIONABLE → bzr-blocked" "$(labels 1)" "bzr-blocked"
new_case s4 '{"1":{}}'; STUB_SENTINEL="BLOCKED spec review cap" run --once >/dev/null 2>&1
assert_eq "BLOCKED → bzr-blocked" "$(labels 1)" "bzr-blocked"
new_case s5 '{"1":{}}'; STUB_SENTINEL="STUCK model down" run --once >/dev/null 2>&1
assert_eq "STUCK → intake again (claim removed)" "$(labels 1)" ""
assert_grep "STUCK counted as attempt" "bzr-attempt role=issues n=1" <(comments 1)

new_case s6 '{"1":{"body":"<!-- bzr-sub-issue parent=9 spec=X-TASK-A -->\nRefs #9"}}'
run --once >/dev/null 2>&1
assert_eq "sub-issue body marker with no parent link yet → never intake" "$(labels 1)" ""

new_case s7 '{"1":{},"2":{},"3":{"labels":["bzr-ready"]}}'
run --issue 2 >/dev/null 2>&1
assert_eq "--issue N dispatches only that issue" "$(labels 1)/$(labels 2)" "/bzr-spec-review"
rc=0; run --issue 3 >/dev/null 2>&1 || rc=$?
assert_eq "--issue on a bzr-labelled issue → exit 2 without --force" "$rc/$(labels 3)" "2/bzr-ready"
run --issue 3 --force >/dev/null 2>&1
assert_eq "--issue --force redrafts (label replaced)" "$(labels 3)" "bzr-spec-review"

# ---- bounce ----
new_case b1 '{"1":{"labels":["bzr-needs-info"],"comments":[{"author":"me","body":"<!-- bzr-issue-worker phase=questions ts=x -->\n1. what?","createdAt":"2026-02-01T00:00:00Z"},{"author":"me","body":"answer: this","createdAt":"2026-02-02T00:00:00Z"}]}}'
run --once >/dev/null 2>&1
assert_eq "AT5 human reply newer than marker → requeued and dispatched" "$(labels 1)" "bzr-spec-review"
new_case b2 '{"1":{"labels":["bzr-needs-info"],"comments":[{"author":"me","body":"older human note","createdAt":"2026-02-01T00:00:00Z"},{"author":"me","body":"<!-- bzr-issue-worker phase=questions ts=x -->\n1. what?","createdAt":"2026-02-02T00:00:00Z"}]}}'
run --once >/dev/null 2>&1
assert_eq "no newer human comment → stays bzr-needs-info" "$(labels 1)" "bzr-needs-info"

# ---- approval sweep: full path ----
new_case a1 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","body":"Refs #7","files":["specs/L3-thing.md","specs/L4-part1.md","specs/L4-part2.md","specs/index.md"],"comments":[{"author":"me","body":"Looks good, approved","createdAt":"t"}]}}'
spec_branch 7 2
run --once >/dev/null 2>&1
assert_eq "AT6 approved → bzr-ready" "$(labels 7)" "bzr-ready"
assert_eq "AT6 PR merged" "$(field prs/12/state)" "MERGED"
assert_eq "AT6 every merged spec flipped to ready on the branch" "$(git --git-dir="$CASE/origin.git" show bzr/spec-7:specs/L3-thing.md | grep -c '^status: ready$')/$(git --git-dir="$CASE/origin.git" show bzr/spec-7:specs/L4-part2.md | grep -c '^status: ready$')" "1/1"
head=$(git --git-dir="$CASE/origin.git" rev-parse bzr/spec-7)
assert_eq "AT6 codex-review status on the new head" "$(field statuses | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s[0]["sha"]==sys.argv[1] and s[0]["context"]=="codex-review")' "$head")" "True"
assert_eq "AT6 two sub-issues created with markers" "$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(sum(1 for i in s["issues"].values() if "<!-- bzr-sub-issue parent=7 spec=X-TASK-P" in i["body"]))' "$FAKE_GH_STATE")" "2"
assert_eq "AT6 sub-issues attached to the parent" "$(field issues/7/sub_issues)" "[8, 9]"
assert_grep "AT6 sub-issue title from the L4 TL;DR" "Part 1 does the 1-th thing." <(field issues/8/title)
assert_grep "AT6 parent Specs: line rewritten" 'Specs: `specs/L3-thing.md`, `specs/L4-part1.md`, `specs/L4-part2.md`' <(field issues/7/body)
assert_not_grep "AT6 Specs: line excludes index.md (no frontmatter)" "index.md" <(field issues/7/body | grep '^Specs:')
assert_grep "AT6 approval marker comment" "<!-- bzr-spec-merged pr=12" <(comments 7)
assert_not_grep "AT6 agent never says the approval word" "CALL=gh issue comment 7" <(grep -i "approved" "$RECORD" | grep -v "would\|bzr-spec-merged" || true)

# ---- approval: negative phrase, draft, non-approver ----
new_case a2 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md"],"comments":[{"author":"me","body":"not approved yet","createdAt":"t"}]}}'
spec_branch 7 0; run --once >/dev/null 2>&1
assert_eq "AT8 'not approved yet' → nothing changes" "$(labels 7)/$(field prs/12/state)" "bzr-spec-review/OPEN"
new_case a3 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","isDraft":True,"files":["specs/L3-thing.md"],"comments":[{"author":"me","body":"approved","createdAt":"t"}]}}'
spec_branch 7 0; run --once >/dev/null 2>&1
assert_eq "draft PR ignored even with approval" "$(labels 7)" "bzr-spec-review"
new_case a4 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md"],"comments":[{"author":"stranger","body":"approved","createdAt":"t"}]}}'
spec_branch 7 0; run --once >/dev/null 2>&1
assert_eq "non-approver comment ignored" "$(labels 7)" "bzr-spec-review"
new_case a5 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md"],"reviews":[{"author":"me","state":"APPROVED"}]}}'
spec_branch 7 0; run --once >/dev/null 2>&1
assert_eq "GitHub review APPROVED counts; single L3 → no sub-issues" "$(labels 7)/$(field issues/7/sub_issues)" "bzr-ready/[]"
new_case a6 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md","specs/L4-part1.md"],"comments":[{"author":"me","body":"approved","createdAt":"t"}]}}'
spec_branch 7 1; run --once >/dev/null 2>&1
assert_eq "one L4 → no sub-issues" "$(field issues/7/sub_issues)" "[]"

# ---- approval: reviewer comment containing the word never approves ----
new_case a2b '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md"],"comments":[{"author":"me","body":"**Codex review — PR #12 cycle 1 of 4**\n- clarify which changes are approved by the owner","createdAt":"t"},{"author":"me","body":"<!-- bzr-review reviewer=codex cycle=2 of=4 -->\napproved wording is fine","createdAt":"t2"}]}}'
spec_branch 7 0; run --once >/dev/null 2>&1
assert_eq "reviewer/pipeline comments containing 'approved' never approve" "$(labels 7)/$(field prs/12/state)" "bzr-spec-review/OPEN"

# ---- approval: merge fails → stays, comment; resume after merge ----
new_case a7 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md"],"comments":[{"author":"me","body":"approved","createdAt":"t"}]}}'
spec_branch 7 0; FAKE_GH_MERGE_FAIL=1 run --once >/dev/null 2>&1
assert_eq "merge failure → stays bzr-spec-review" "$(labels 7)" "bzr-spec-review"
assert_grep "merge failure commented" "merge failed" <(comments 7)
new_case a8 '{"7":{"labels":["bzr-spec-review"],"sub_issues":[8]},"8":{"parent":7,"body":"<!-- bzr-sub-issue parent=7 spec=X-TASK-P1 -->"}}' '{"12":{"headRefName":"bzr/spec-7","state":"MERGED","mergedAt":"t","files":["specs/L3-thing.md","specs/L4-part1.md","specs/L4-part2.md"]}}'
spec_branch 7 2; git -C "$CASE/clone" push -q origin "bzr/spec-7:main" 2>/dev/null   # merged state: main holds the specs
run --once >/dev/null 2>&1
assert_eq "AT7 already-merged PR → resume: parent bzr-ready" "$(labels 7)" "bzr-ready"
assert_eq "AT7 resume creates only the missing sub-issue" "$(field issues/7/sub_issues)" "[8, 9]"
assert_eq "AT7 no duplicate for the existing one" "$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(sum(1 for i in s["issues"].values() if "spec=X-TASK-P1" in i["body"]))' "$FAKE_GH_STATE")" "1"
# resume after merge with the head branch already deleted: sub-issues must survive
new_case a8b '{"7":{"labels":["bzr-spec-review"],"sub_issues":[8,9]},"8":{"parent":7,"body":"<!-- bzr-sub-issue parent=7 spec=X-TASK-P1 -->"},"9":{"parent":7,"body":"<!-- bzr-sub-issue parent=7 spec=X-TASK-P2 -->"}}' '{"12":{"headRefName":"bzr/spec-7","state":"MERGED","mergedAt":"t","files":["specs/L3-thing.md","specs/L4-part1.md","specs/L4-part2.md"]}}'
spec_branch 7 2; git -C "$CASE/clone" push -q origin "bzr/spec-7:main" 2>/dev/null; git -C "$CASE/clone" push -q origin --delete "bzr/spec-7" 2>/dev/null
run --once >/dev/null 2>&1
assert_eq "resume with deleted head branch: L4s read from main, both sub-issues kept" "$(field issues/8/state)/$(field issues/9/state)/$(labels 7)" "OPEN/OPEN/bzr-ready"
new_case a8c '{"7":{"labels":["bzr-spec-review"],"sub_issues":[8]},"8":{"parent":7,"body":"<!-- bzr-sub-issue parent=7 spec=X-TASK-P1 -->"}}' '{"12":{"headRefName":"bzr/spec-7","state":"MERGED","mergedAt":"t","files":["specs/L3-thing.md","specs/L4-part1.md","specs/L4-part2.md"]}}'
git -C "$CASE/clone" remote set-url origin /nonexistent; run --once >/dev/null 2>&1
assert_eq "resume with unreachable origin: nothing closed, issue untouched" "$(field issues/8/state)/$(labels 7)" "OPEN/bzr-spec-review"

# dropped L4 → its sub-issue closed
new_case a9 '{"7":{"labels":["bzr-spec-review"],"sub_issues":[8,9]},"8":{"parent":7,"body":"<!-- bzr-sub-issue parent=7 spec=X-TASK-P1 -->"},"9":{"parent":7,"body":"<!-- bzr-sub-issue parent=7 spec=X-TASK-GONE -->"}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md","specs/L4-part1.md","specs/L4-part2.md"],"comments":[{"author":"me","body":"approved","createdAt":"t"}]}}'
spec_branch 7 2; run --once >/dev/null 2>&1
assert_eq "dropped L4 → its sub-issue closed" "$(field issues/9/state)" "CLOSED"

# ---- rejected spec PR ----
new_case r1 '{"7":{"labels":["bzr-spec-review"],"sub_issues":[8]},"8":{"parent":7,"body":"<!-- bzr-sub-issue parent=7 spec=X-TASK-P1 -->"}}' '{"12":{"headRefName":"bzr/spec-7","state":"CLOSED"}}'
run --once >/dev/null 2>&1
assert_eq "closed-unmerged spec PR → bzr-blocked" "$(labels 7)" "bzr-blocked"
assert_eq "…and draft-time sub-issues closed" "$(field issues/8/state)" "CLOSED"

# ---- dry-run approval prints, writes nothing ----
new_case d1 '{"7":{"labels":["bzr-spec-review"]}}' '{"12":{"headRefName":"bzr/spec-7","files":["specs/L3-thing.md"],"comments":[{"author":"me","body":"approved","createdAt":"t"}]}}'
spec_branch 7 0; out=$(run --dry-run 2>/dev/null)
assert_grep "dry-run reports the approval it would act on" "would approve #7 via PR #12" <(echo "$out")
assert_eq "dry-run merges nothing" "$(field prs/12/state)" "OPEN"

echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
