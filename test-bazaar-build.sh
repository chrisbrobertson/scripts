#!/usr/bin/env bash
# Harness for bazaar-build.sh (controller only; the worker is a stub).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3' got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
mkdir -p "$TMP/bin"; ln -s "$ROOT/test-support/fake-gh.py" "$TMP/bin/gh"
cat > "$TMP/bin/stub-worker" <<'S'
#!/usr/bin/env bash
printf '%s\n' "${STUB_SENTINEL:-PR_READY 101}" > "$BZR_SENTINEL"
S
chmod +x "$TMP"/bin/*; export PATH="$TMP/bin:$PATH" BZR_WORKER_OVERRIDE="stub-worker" BZR_HOST=testhost
new_case() {
  CASE="$TMP/$1"; mkdir -p "$CASE"; export FAKE_GH_STATE="$CASE/state.json" RECORD="$CASE/record" BZR_HOME="$CASE/home"; : > "$RECORD"
  local prs="${3:-}"; [ -n "$prs" ] || prs="{}"
  python3 - "$FAKE_GH_STATE" "$2" "$prs" <<'PY'
import json, sys
issues = eval(sys.argv[2]); prs = eval(sys.argv[3])
for k, v in issues.items():
    v.setdefault("number", int(k)); v.setdefault("id", 1000 + int(k)); v.setdefault("title", "issue %s" % k); v.setdefault("body", "")
    v.setdefault("state", "OPEN"); v.setdefault("createdAt", "2026-01-%02dT00:00:00Z" % int(k)); v.setdefault("labels", [])
    v.setdefault("comments", []); v.setdefault("parent", None); v.setdefault("sub_issues", [])
for k, v in prs.items():
    v.setdefault("number", int(k)); v.setdefault("headRefName", "x"); v.setdefault("state", "OPEN"); v.setdefault("isDraft", False); v.setdefault("mergedAt", None)
    v.setdefault("body", ""); v.setdefault("comments", []); v.setdefault("reviews", []); v.setdefault("files", [])
json.dump({"repo": "o/r", "default_branch": "main", "login": "me", "issues": issues, "prs": prs, "statuses": []}, open(sys.argv[1], "w"))
PY
}
labels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["labels"]))' "$FAKE_GH_STATE" "$1"; }
state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["state"])' "$FAKE_GH_STATE" "$1"; }
run() { "$ROOT/bazaar-build.sh" --repo o/r --controller-model none "$@"; }

new_case ready '{"1":{"labels":["bzr-ready"]}}'
run --once >/dev/null 2>&1
assert_eq "PR_READY → bzr-pr-ready" "$(labels 1)" "bzr-pr-ready"

new_case gap '{"1":{"labels":["bzr-ready"]}}'
STUB_SENTINEL="SPEC_GAP spec not ready" run --once >/dev/null 2>&1
assert_eq "SPEC_GAP → bzr-blocked, claim removed" "$(labels 1)" "bzr-blocked"

new_case blocked '{"1":{"labels":["bzr-ready"]}}'
STUB_SENTINEL="BLOCKED every sub-issue skipped" run --once >/dev/null 2>&1
assert_eq "BLOCKED → bzr-blocked" "$(labels 1)" "bzr-blocked"

new_case stuck '{"1":{"labels":["bzr-ready"]}}'
STUB_SENTINEL="STUCK rebase-needed" run --once >/dev/null 2>&1
assert_eq "STUCK → back to bzr-ready (attempt 1)" "$(labels 1)" "bzr-ready"

new_case only '{"1":{"labels":["bzr-ready"]},"2":{"labels":[]}}'
run --issue 1 >/dev/null 2>&1
assert_eq "--issue N dispatches that issue" "$(labels 1)" "bzr-pr-ready"
rc=0; run --issue 2 >/dev/null 2>&1 || rc=$?
assert_eq "AT9 --issue on non-ready without --force → exit 2" "$rc" "2"
assert_eq "…and touches nothing" "$(labels 2)" ""
run --issue 2 --force >/dev/null 2>&1
assert_eq "--issue --force dispatches anyway" "$(labels 2)" "bzr-pr-ready"

# merged sweep: all sub-issues closed → parent closed
new_case m1 '{"1":{"labels":["bzr-pr-ready"],"sub_issues":[2,3]},"2":{"state":"CLOSED","parent":1},"3":{"state":"CLOSED","parent":1}}' '{"50":{"state":"MERGED","mergedAt":"t","body":"<!-- bzr-build issue=1 round=1 -->\nCloses #1"}}'
run --once >/dev/null 2>&1
assert_eq "merged + all subs closed → parent closed" "$(state 1)" "CLOSED"
# merged sweep: unblocked sub-issue remains → bzr-ready
new_case m2 '{"1":{"labels":["bzr-pr-ready"],"sub_issues":[2,3]},"2":{"state":"CLOSED","parent":1},"3":{"state":"OPEN","parent":1,"labels":[]}}' '{"50":{"state":"MERGED","mergedAt":"t","body":"<!-- bzr-build issue=1 round=1 -->"}}'
STUB_SENTINEL="PR_READY 51" run --once >/dev/null 2>&1
assert_grep "AT13 merged + unblocked sub remains → requeued" "merged-sweep #1 pr=50 1 unblocked" "$BZR_HOME/o-r/logs/ctl-build-$(date +%Y%m%d).log"
assert_eq "AT13 requeued parent dispatched in the same tick" "$(labels 1)" "bzr-pr-ready"
# merged sweep: only blocked sub remains → wait
new_case m3 '{"1":{"labels":["bzr-pr-ready"],"sub_issues":[3]},"3":{"state":"OPEN","parent":1,"labels":["bzr-blocked"]}}' '{"50":{"state":"MERGED","mergedAt":"t","body":"<!-- bzr-build issue=1 -->"}}'
run --once >/dev/null 2>&1
assert_eq "merged + only blocked subs → untouched" "$(labels 1)/$(state 1)" "bzr-pr-ready/OPEN"
# not merged yet → untouched
new_case m4 '{"1":{"labels":["bzr-pr-ready"]}}' '{"50":{"state":"OPEN","body":"<!-- bzr-build issue=1 -->"}}'
run --once >/dev/null 2>&1
assert_eq "open PR → parent stays bzr-pr-ready" "$(labels 1)" "bzr-pr-ready"
# sub-issue with bzr-ready is never a candidate
new_case sub '{"1":{"labels":["bzr-ready"],"parent":9},"9":{}}'
run --once >/dev/null 2>&1
assert_eq "sub-issue never dispatched" "$(labels 1)" "bzr-ready"

out=$(run --version); case "$out" in bazaar-build.sh*) pass "--version" ;; *) fail "--version ($out)" ;; esac
run --help 2>/dev/null | grep -q -- "--force" && pass "--help lists --force" || fail "--help lists --force"
echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
