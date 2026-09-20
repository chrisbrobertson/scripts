#!/usr/bin/env bash
# Harness for lib/bazaar-common.sh: the role-independent controller contract
# (BZR-FEAT-CONTROLLER acceptance tests 1-5, 9-12, 14). gh is test-support/fake-gh.py
# over a JSON state file; workers are a stub script that writes a sentinel.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3' got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; fail "$1"; else pass "$1"; fi; }

mkdir -p "$TMP/bin"
ln -s "$ROOT/test-support/fake-gh.py" "$TMP/bin/gh"
cat > "$TMP/bin/claude" <<'S'
#!/usr/bin/env bash
printf 'CALL=claude %s\n' "$*" >> "$RECORD"; printf '%s' "${STUB_PICK:-}"
S
cat > "$TMP/bin/sleep" <<'S'
#!/usr/bin/env bash
printf 'CALL=sleep %s\n' "$*" >> "$RECORD"; /bin/sleep 0.05
S
# stub worker: posts nothing itself (bzr_spawn posts the claim), then writes the sentinel
cat > "$TMP/bin/stub-worker" <<'S'
#!/usr/bin/env bash
[ -n "${STUB_WORKER_SLEEP:-}" ] && /bin/sleep "$STUB_WORKER_SLEEP"
printf '%s\n' "${STUB_SENTINEL:-DONE}" > "$BZR_SENTINEL"
S
chmod +x "$TMP"/bin/*
export PATH="$TMP/bin:$PATH"

# a test role, sourced by each controller invocation
cat > "$TMP/role.sh" <<'R'
role_claim_label() { echo bzr-building; }
role_queue_label() { echo bzr-ready; }
role_release_label() { echo bzr-ready; }
role_sweeps() { :; }
role_candidates() { bzr_candidates '"bzr-ready" in i["labels"]'; }
role_worker_cmd() { echo "stub-worker"; }
role_on_worker_exit() {  # DONE → bzr-pr-ready ; FAIL → transient
  case "$3" in DONE) bzr_transition "$1" bzr-pr-ready bzr-building; return 0 ;; esac; return 1
}
R
run_ctl() {  # <case-name-for-readability> [args...]  — runs a controller with the test role
  shift
  ( source "$ROOT/lib/bazaar-common.sh"; source "$TMP/role.sh"; BZR_SCRIPT_VERSION=t
    bzr_init build --repo o/r "$@" && bzr_controller_main )
}
new_case() {  # <name> <python-expr building issues dict>
  CASE="$TMP/$1"; mkdir -p "$CASE"
  export FAKE_GH_STATE="$CASE/state.json" RECORD="$CASE/record" BZR_HOME="$CASE/home" BZR_HOST=testhost
  : > "$RECORD"
  python3 - "$FAKE_GH_STATE" "$2" <<'PY'
import json, sys
issues = eval(sys.argv[2])
for k, v in issues.items():
    v.setdefault("number", int(k)); v.setdefault("id", 1000 + int(k)); v.setdefault("title", "issue %s" % k)
    v.setdefault("body", ""); v.setdefault("state", "OPEN"); v.setdefault("createdAt", "2026-01-%02dT00:00:00Z" % int(k))
    v.setdefault("labels", []); v.setdefault("comments", []); v.setdefault("parent", None); v.setdefault("sub_issues", [])
json.dump({"repo": "o/r", "default_branch": "main", "login": "me", "issues": issues, "prs": {}, "statuses": []}, open(sys.argv[1], "w"))
PY
}
labels() { python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["labels"]))' "$FAKE_GH_STATE" "$1"; }
comments() { python3 -c 'import json,sys; [print(c["body"].split("\n")[0]) for c in json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["comments"]]' "$FAKE_GH_STATE" "$1"; }
add_comment() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["issues"][sys.argv[2]]["comments"].append({"author":sys.argv[3],"body":sys.argv[4],"createdAt":sys.argv[5]}); json.dump(s,open(sys.argv[1],"w"))' "$FAKE_GH_STATE" "$@"; }

# ---- AT1: priority wins, one slot, other skipped ----
new_case at1 '{"1":{"labels":["bzr-ready"]},"2":{"labels":["bzr-ready","P1"]}}'
run_ctl at1 --once --controller-model none >/dev/null 2>&1
assert_grep "AT1 P1 issue dispatched and finished" "bzr-pr-ready" <(labels 2)
assert_eq "AT1 other issue untouched" "$(labels 1)" "bzr-ready"
assert_grep "AT1 skip no-slot logged" "skip #1 no-slot" "$BZR_HOME/o-r/logs/ctl-build-$(date +%Y%m%d).log"
assert_grep "AT1 claim marker posted" "<!-- bzr-claim role=build host=testhost pid=" <(comments 2)
assert_not_grep "AT1 no model call with model=none" "CALL=claude" "$RECORD"

# ---- AT11: --workers 2 dispatches exactly two of three ----
new_case at11 '{"1":{"labels":["bzr-ready"]},"2":{"labels":["bzr-ready"]},"3":{"labels":["bzr-ready"]}}'
STUB_WORKER_SLEEP=0.3 run_ctl at11 --once --workers 2 --controller-model none >/dev/null 2>&1
assert_eq "AT11 two finished, one left" "$(labels 1)/$(labels 2)/$(labels 3)" "bzr-pr-ready/bzr-pr-ready/bzr-ready"

# ---- AT12: sub-issue skipped ----
new_case at12 '{"1":{"labels":["bzr-ready"],"parent":9},"9":{"labels":[]}}'
run_ctl at12 --once --controller-model none >/dev/null 2>&1
assert_eq "AT12 sub-issue never dispatched" "$(labels 1)" "bzr-ready"

# ---- AT2/3/4: claim liveness by pid, never by time ----
new_case at2 '{"1":{"labels":["bzr-building"],"comments":[{"author":"me","body":"<!-- bzr-claim role=build host=testhost pid=999999 start=\"never\" ts=t -->","createdAt":"2026-01-01T00:00:00Z"}]}}'
run_ctl at2 --once --controller-model none >/dev/null 2>&1
assert_grep "AT2 dead pid → released (then re-dispatched in the same tick)" "dead-pid-release #1" "$BZR_HOME/o-r/logs/ctl-build-$(date +%Y%m%d).log"
assert_eq "AT2 re-dispatch completed" "$(labels 1)" "bzr-pr-ready"
assert_grep "AT2 attempt marker posted" "<!-- bzr-attempt role=build n=1" <(comments 1)
/bin/sleep 30 & LIVE=$!; START=$(ps -o lstart= -p $LIVE | sed 's/^ *//; s/ *$//')
new_case at3 "{\"1\":{\"labels\":[\"bzr-building\"],\"comments\":[{\"author\":\"me\",\"body\":\"<!-- bzr-claim role=build host=testhost pid=$LIVE start=\\\"$START\\\" ts=t -->\",\"createdAt\":\"2020-01-01T00:00:00Z\"}]}}"
run_ctl at3 --once --controller-model none >/dev/null 2>&1
assert_eq "AT3 live pid, ancient claim → untouched" "$(labels 1)" "bzr-building"
kill $LIVE 2>/dev/null
new_case at4 '{"1":{"labels":["bzr-building"],"comments":[{"author":"me","body":"<!-- bzr-claim role=build host=otherhost pid=1 start=\"x\" ts=t -->","createdAt":"2026-01-01T00:00:00Z"}]}}'
run_ctl at4 --once --controller-model none >/dev/null 2>&1
assert_eq "AT4 foreign-host claim never released" "$(labels 1)" "bzr-building"
new_case at4b '{"1":{"labels":["bzr-building"]}}'
run_ctl at4b --once --controller-model none >/dev/null 2>&1
assert_grep "claim label with no marker (fresh controller) → released" "dead-pid-release #1" "$BZR_HOME/o-r/logs/ctl-build-$(date +%Y%m%d).log"

# ---- AT9/10: three attempts escalate; escalation marker resets the count ----
new_case at9 '{"1":{"labels":["bzr-ready"]}}'
STUB_SENTINEL="STUCK boom" run_ctl at9 --once --controller-model none >/dev/null 2>&1
assert_eq "attempt 1 → back to bzr-ready" "$(labels 1)" "bzr-ready"
STUB_SENTINEL="STUCK boom" run_ctl at9 --once --controller-model none >/dev/null 2>&1
STUB_SENTINEL="STUCK boom" run_ctl at9 --once --controller-model none >/dev/null 2>&1
assert_eq "AT9 third failure → bzr-blocked, claim removed" "$(labels 1)" "bzr-blocked"
assert_grep "AT9 escalation marker" "<!-- bzr-escalated role=build attempts=3" <(comments 1)
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["issues"]["1"]["labels"]=["bzr-ready"]; json.dump(s,open(sys.argv[1],"w"))' "$FAKE_GH_STATE"
STUB_SENTINEL="STUCK again" run_ctl at9 --once --controller-model none >/dev/null 2>&1
assert_eq "AT10 after human requeue, count restarts at 1" "$(comments 1 | grep -c 'bzr-attempt role=build n=1')" "2"
assert_eq "AT10 still bzr-ready after one new failure" "$(labels 1)" "bzr-ready"
new_case blk '{"1":{"labels":["bzr-ready","bzr-blocked"]}}'
run_ctl blk --once --controller-model none >/dev/null 2>&1
assert_eq "bzr-blocked issue never dispatched" "$(labels 1)" "bzr-ready,bzr-blocked"

# ---- worker crash without sentinel counts as an attempt ----
new_case crash '{"1":{"labels":["bzr-ready"]}}'
cat > "$TMP/bin/stub-worker" <<'S'
#!/usr/bin/env bash
exit 7
S
run_ctl crash --once --controller-model none >/dev/null 2>&1
assert_eq "no sentinel → transient attempt" "$(labels 1)" "bzr-ready"
assert_grep "crash reason recorded" "without a sentinel" <(comments 1)
cat > "$TMP/bin/stub-worker" <<'S'
#!/usr/bin/env bash
[ -n "${STUB_WORKER_SLEEP:-}" ] && /bin/sleep "$STUB_WORKER_SLEEP"
printf '%s\n' "${STUB_SENTINEL:-DONE}" > "$BZR_SENTINEL"
S

# ---- dry-run: decision printed, nothing written ----
new_case dry '{"1":{"labels":["bzr-ready"]}}'
out=$(run_ctl dry --dry-run --controller-model none 2>/dev/null)
assert_grep "dry-run prints decision" "would dispatch #1" <(echo "$out")
assert_eq "dry-run writes nothing" "$(labels 1)" "bzr-ready"
assert_not_grep "dry-run issues no edits" "CALL=gh issue edit" "$RECORD"

# ---- AT14: stop file → no dispatch ----
new_case stop '{"1":{"labels":["bzr-ready"]}}'
mkdir -p "$BZR_HOME/o-r"; ( source "$ROOT/lib/bazaar-common.sh"; source "$TMP/role.sh"; bzr_init build --repo o/r --stop ) >/dev/null 2>&1
assert_eq "--stop creates the stop file" "$([ -f "$BZR_HOME/o-r/build.stop" ] && echo yes)" "yes"
# bzr_init clears a pre-existing stop file on a fresh start; simulate one appearing mid-run instead
( source "$ROOT/lib/bazaar-common.sh"; source "$TMP/role.sh"; bzr_init build --repo o/r --once --controller-model none; touch "$STOP_FILE"; bzr_controller_main ) >/dev/null 2>&1
assert_eq "AT14 stop file present → no dispatch" "$(labels 1)" "bzr-ready"

# ---- model tie-break: valid answer used, garbage falls back ----
new_case tie '{"1":{"labels":["bzr-ready"]},"2":{"labels":["bzr-ready"]}}'
STUB_PICK="2" run_ctl tie --once --controller-model haiku >/dev/null 2>&1
assert_eq "model picks #2 among equals" "$(labels 2)" "bzr-pr-ready"
assert_grep "model called with --effort low" "--effort low" "$RECORD"
new_case tie2 '{"1":{"labels":["bzr-ready"]},"2":{"labels":["bzr-ready"]}}'
STUB_PICK="42" run_ctl tie2 --once --controller-model haiku >/dev/null 2>&1
assert_eq "garbage answer → sort order (#1)" "$(labels 1)" "bzr-pr-ready"
new_case tie3 '{"1":{"labels":["bzr-ready"]},"2":{"labels":["bzr-ready","P0"]}}'
run_ctl tie3 --once --controller-model haiku >/dev/null 2>&1
assert_not_grep "no model call when priorities differ" "CALL=claude" "$RECORD"

# ---- comment guard ----
new_case guard '{"1":{"labels":[]}}'
printf 'This looks approved to me\n' > "$TMP/bad.md"
rc=0; ( source "$ROOT/lib/bazaar-common.sh"; source "$TMP/role.sh"; bzr_init build --repo o/r --once; bzr_comment issue 1 "$TMP/bad.md" ) >/dev/null 2>&1 || rc=$?
assert_eq "agent comment containing the approval word is refused" "$(comments 1 | wc -l | tr -d ' ')" "0"
printf '<!-- bzr-issue-worker phase=review ts=t -->\nTo accept, comment a line containing the word approved.\n' > "$TMP/ok.md"
( source "$ROOT/lib/bazaar-common.sh"; source "$TMP/role.sh"; bzr_init build --repo o/r --once; bzr_comment issue 1 "$TMP/ok.md" ) >/dev/null 2>&1
assert_eq "marker comment may explain how to approve" "$(comments 1 | wc -l | tr -d ' ')" "1"

# ---- usage ----
rc=0; run_ctl u --workers 9 >/dev/null 2>&1 || rc=$?; assert_eq "--workers 9 → usage exit 2" "$rc" "2"
rc=0; run_ctl u --bogus >/dev/null 2>&1 || rc=$?; assert_eq "unknown flag → exit 2" "$rc" "2"

echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
