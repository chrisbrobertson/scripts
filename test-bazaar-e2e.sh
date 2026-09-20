#!/usr/bin/env bash
# End-to-end smoke: both controllers spawn the REAL workers against a fake gh,
# a real git origin, and scripted claude/codex stubs. Exercises the env contract
# of bzr_spawn and every hand-off: intake → spec PR → approval → sub-issues →
# build → PR ready. No network, no model spend.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3' got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
mkdir -p "$TMP/bin"; ln -s "$ROOT/test-support/fake-gh.py" "$TMP/bin/gh"
cat > "$TMP/bin/_next" <<'S'
#!/usr/bin/env bash
tool="$1"; c="$STUB_DIR/$tool.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
f="$STUB_DIR/$tool.$n"; [ -f "$f" ] || f="$STUB_DIR/$tool.default"; echo "$f"
S
cat > "$TMP/bin/claude" <<'S'
#!/usr/bin/env bash
printf 'CALL=claude %s\n' "${*:0:200}" >> "$RECORD"
f=$("$(dirname "$0")/_next" claude)
if grep -q '^@@SH$' "$f"; then sed -n '/^@@SH$/,/^@@END$/p' "$f" | sed '1d;$d' | bash; fi
body=$(sed '/^@@SH$/,/^@@END$/d' "$f" | grep -v '^@@')
printf '{"type":"system","subtype":"init","session_id":"stub"}\n'
python3 -c 'import json,sys; print(json.dumps({"type":"result","result":sys.stdin.read()}))' <<< "$body"
S
cat > "$TMP/bin/codex" <<'S'
#!/usr/bin/env bash
printf 'CALL=codex %s\n' "${*:0:80}" >> "$RECORD"
f=$("$(dirname "$0")/_next" codex)
out=""; while [ "$#" -gt 0 ]; do [ "$1" = "--output-last-message" ] && { out="$2"; shift 2; continue; }; shift; done
echo "codex noise"; [ -n "$out" ] && grep -v '^@@' "$f" > "$out"
S
chmod +x "$TMP"/bin/*; export PATH="$TMP/bin:$PATH" BABYSIT_TEST_MODE=1 BZR_HOST=testhost
CASE="$TMP/e2e"; mkdir -p "$CASE"
export FAKE_GH_STATE="$CASE/state.json" RECORD="$CASE/record" STUB_DIR="$CASE/stubs" BZR_HOME="$CASE/home"
mkdir -p "$STUB_DIR"; : > "$RECORD"
python3 - "$FAKE_GH_STATE" <<'PY'
import json, sys
json.dump({"repo": "o/r", "default_branch": "main", "login": "me", "statuses": [], "prs": {},
  "issues": {"7": {"number": 7, "id": 1007, "title": "Make the thing work", "body": "the thing should work", "state": "OPEN",
                   "createdAt": "2026-01-01T00:00:00Z", "labels": ["enhancement"], "comments": [], "parent": None, "sub_issues": []}}}, open(sys.argv[1], "w"))
PY
git init -q --bare "$CASE/origin.git"; git clone -q "$CASE/origin.git" "$CASE/clone" 2>/dev/null
mkdir -p "$CASE/clone/specs"; printf -- '---\nspec_type: product\nid: X-PROD-R\nstatus: ready\n---\n' > "$CASE/clone/specs/L1-r.md"; printf '# index\n' > "$CASE/clone/specs/index.md"
git -C "$CASE/clone" add -A; git -C "$CASE/clone" -c user.name=t -c user.email=t@t commit -q -m init; git -C "$CASE/clone" push -q origin HEAD:main 2>/dev/null
CLEAN=$'## BLOCKING\n- (none)\n\n## RECOMMENDED\n- (none)\n\n## INFORMATION\n- (none)'
stub() { printf '%s\n' "$2" > "$STUB_DIR/$1"; }
labels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["labels"]))' "$FAKE_GH_STATE" "$1"; }
field() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); o=s; [o:=o[k] for k in sys.argv[2].split("/")]; print(o if isinstance(o,str) else json.dumps(o))' "$FAKE_GH_STATE" "$1"; }
run_ctl() { local s="$1"; shift; ( cd "$CASE/clone" && "$ROOT/$s" --repo o/r --controller-model none --once "$@" ) >>"$CASE/ctl.out" 2>&1; }
guard() { "$@" & local pid=$!; for i in $(seq 1 240); do kill -0 $pid 2>/dev/null || break; /bin/sleep 1; done; kill -0 $pid 2>/dev/null && { echo "HUNG: $*"; pkill -f bazaar-; return 1; }; wait $pid; }

# --- stage 1: intake → issue worker → spec PR ---
stub claude.1 '@@SH
printf "## Problem\nthing broken\n\n## Desired outcome\nthing works\n\n## Acceptance criteria\n- [ ] works\n\n## Scope\nIn: thing\nOut: rest\n\n## Type\nfeature\n\n## Links\nSpecs: none yet\n" > "$BZR_RUN_DIR/normalised.md"
printf "feature\nlabel\n" > "$BZR_RUN_DIR/classification.txt"
@@END
VERIFY_OK'
stub claude.2 '@@SH
printf -- "---\nspec_type: feature\nid: X-FEAT-THING\nstatus: review\n---\n\n## TL;DR\nA thing.\n" > specs/L3-thing.md
printf -- "---\nspec_type: task\nid: X-TASK-P1\nstatus: review\nparent_feature: X-FEAT-THING\n---\n\n## TL;DR\nPart one.\n" > specs/L4-part1.md
printf -- "---\nspec_type: task\nid: X-TASK-P2\nstatus: review\nparent_feature: X-FEAT-THING\n---\n\n## TL;DR\nPart two.\n" > specs/L4-part2.md
printf "# index\n- L3-thing\n" > specs/index.md
git add -A specs && git commit -q -m draft
@@END
DRAFT_DONE'
stub codex.1 "$CLEAN"
guard run_ctl bazaar-issues.sh
assert_eq "stage 1: issue → bzr-spec-review" "$(labels 7)" "enhancement,bzr-spec-review"
assert_eq "stage 1: spec PR ready (non-draft) on bzr/spec-7" "$(field prs/101/headRefName)/$(field prs/101/isDraft)" "bzr/spec-7/false"
assert_eq "stage 1: two draft-time sub-issues" "$(field issues/7/sub_issues)" "[8, 9]"
assert_grep "stage 1: body normalised with original kept" "Original report" <(field issues/7/body)

# --- stage 2: human approves → controller merges, flips ready, writes Specs: line ---
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["prs"]["101"]["comments"].append({"author":"me","body":"approved","createdAt":"z"}); s["prs"]["101"]["files"]=["specs/L3-thing.md","specs/L4-part1.md","specs/L4-part2.md","specs/index.md"]; json.dump(s,open(sys.argv[1],"w"))' "$FAKE_GH_STATE"
guard run_ctl bazaar-issues.sh
assert_eq "stage 2: issue → bzr-ready" "$(labels 7)" "enhancement,bzr-ready"
assert_eq "stage 2: spec PR merged" "$(field prs/101/state)" "MERGED"
assert_grep "stage 2: Specs: line lists spec files only" 'Specs: `specs/L3-thing.md`, `specs/L4-part1.md`, `specs/L4-part2.md`' <(field issues/7/body)
assert_eq "stage 2: sub-issues untouched (already matched)" "$(field issues/7/sub_issues)" "[8, 9]"
# simulate GitHub's merge landing on main (the fake gh does not touch git)
git -C "$CASE/clone" fetch -q origin bzr/spec-7 && git -C "$CASE/clone" push -q origin FETCH_HEAD:main 2>/dev/null
assert_eq "stage 2: merged specs are status: ready on main" "$(git --git-dir="$CASE/origin.git" show main:specs/L4-part2.md | grep -c '^status: ready$')" "1"
assert_eq "stage 2: sub-issues never entered intake" "$(labels 8)/$(labels 9)" "/"

# --- stage 3: build controller → build worker → PR ready ---
stub claude.3 $'PLAN #8 depends=none — first\nPLAN #9 depends=8 — second\nPLAN_POSTED'
stub claude.4 $'@@SH\necho one > one.txt; git add -A; git commit -q -m "feat: one" -m "Refs #8"\n@@END\nUNIT_DONE'
stub codex.2 "$CLEAN"
stub claude.5 $'@@SH\necho two > two.txt; git add -A; git commit -q -m "feat: two" -m "Refs #9"\n@@END\nUNIT_DONE'
stub codex.3 "$CLEAN"
guard run_ctl bazaar-build.sh
assert_eq "stage 3: parent → bzr-pr-ready" "$(labels 7)" "enhancement,bzr-pr-ready"
assert_eq "stage 3: build PR ready on bzr/7-make-the-thing-work" "$(field prs/102/headRefName)/$(field prs/102/isDraft)" "bzr/7-make-the-thing-work/false"
assert_grep "stage 3: build PR closes parent and both sub-issues" "Closes #9" <(field prs/102/body)
assert_grep "stage 3: plan comment on parent" "bzr-build-plan issue=7 round=1" <(python3 -c 'import json,sys; [print(c["body"]) for c in json.load(open(sys.argv[1]))["issues"]["7"]["comments"]]' "$FAKE_GH_STATE")
head=$(git --git-dir="$CASE/origin.git" rev-parse bzr/7-make-the-thing-work)
assert_eq "stage 3: codex-review status on the build head" "$(field statuses | python3 -c 'import json,sys; s=json.load(sys.stdin); print(any(x["sha"]==sys.argv[1] for x in s))' "$head")" "True"
assert_eq "stage 3: exactly 5 implementer + 3 reviewer calls across the run" "$(grep -c CALL=claude "$RECORD")/$(grep -c CALL=codex "$RECORD")" "5/3"

# --- stage 4: human merges → build controller closes the parent ---
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); p=s["prs"]["102"]; p["state"]="MERGED"; p["mergedAt"]="z"; s["issues"]["8"]["state"]="CLOSED"; s["issues"]["9"]["state"]="CLOSED"; json.dump(s,open(sys.argv[1],"w"))' "$FAKE_GH_STATE"
guard run_ctl bazaar-build.sh
assert_eq "stage 4: merged sweep closes the parent" "$(field issues/7/state)" "CLOSED"
grep -q "REFUSED" "$CASE/ctl.out" "$BZR_HOME"/o-r/logs/* 2>/dev/null && fail "no comment was refused by the approval-word guard" || pass "no comment was refused by the approval-word guard"

echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
