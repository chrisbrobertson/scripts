#!/bin/bash
# test-setup-branch-protection.sh — recording-stub coverage for
# setup-branch-protection.sh.
#
# setup-branch-protection.sh had no test coverage at all. It's a short,
# linear script (no sourced functions to isolate), so this harness runs the
# real script end to end against a stubbed `gh` on PATH, using its own
# `--dry-run` flag to assert on the exact branch-protection payload without
# ever calling a real gh API. No network.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/setup-branch-protection.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }

mkdir -p "$TMP/bin"

# gh: records every invocation to $RECORD, responds per the STUB_* knobs each
# case sets.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf 'CALL=gh %s\n' "$*" >> "$RECORD"
case "$*" in
  "repo view --json nameWithOwner -q .nameWithOwner")
    [ -n "${STUB_NO_REPO:-}" ] && exit 1
    printf '%s' "${STUB_REPO:-o/r}"; exit 0 ;;
  "repo view "*" --json defaultBranchRef -q .defaultBranchRef.name")
    [ -n "${STUB_NO_BRANCH:-}" ] && exit 1
    printf '%s' "${STUB_BRANCH:-main}"; exit 0 ;;
  "api -X PUT repos/"*"/protection --input -")
    cat > /dev/null
    if [ "${STUB_PUT_RC:-0}" -ne 0 ]; then
      echo "stub PUT failure" >&2
      exit "${STUB_PUT_RC}"
    fi
    cat <<JSON
{"required_status_checks": {"contexts": ["${STUB_RESP_CHECK:-codex-review}"]}, "enforce_admins": {"enabled": true}}
JSON
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

run() {  # <record> -- <script args...>
  local record="$1"; shift
  shift  # drop the literal --
  : > "$record"
  # STUB_* vars are picked up from the caller's shell via a VAR=val prefix on
  # the `run` call itself (e.g. `STUB_NO_REPO=1 run "$r" -- --dry-run`) — bash
  # exports them for just this function invocation. Defaulting each with
  # ${VAR:-...} here keeps this safe under `set -u` whether or not a given
  # case set it.
  ( env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
      STUB_NO_REPO="${STUB_NO_REPO:-}" STUB_NO_BRANCH="${STUB_NO_BRANCH:-}" \
      STUB_REPO="${STUB_REPO:-}" STUB_BRANCH="${STUB_BRANCH:-}" \
      STUB_PUT_RC="${STUB_PUT_RC:-0}" STUB_RESP_CHECK="${STUB_RESP_CHECK:-}" \
      "$SCRIPT" "$@" ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- dry-run, repo/branch auto-detected ----------
r="$TMP/dryrun-auto.record"
run "$r" -- --dry-run
assert_eq "dry-run auto-detect: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "dry-run auto-detect: detected repo printed" "repo:    o/r" "$TMP/out"
assert_grep "dry-run auto-detect: detected branch printed" "branch:  main" "$TMP/out"
assert_grep "dry-run auto-detect: default check context printed" "check:   codex-review" "$TMP/out"
assert_grep "dry-run auto-detect: payload requires codex-review context" '    "contexts": ["codex-review"]' "$TMP/out"
assert_grep "dry-run auto-detect: payload sets enforce_admins true" '  "enforce_admins": true,' "$TMP/out"
assert_grep "dry-run auto-detect: payload sets required_approving_review_count 0" '    "required_approving_review_count": 0' "$TMP/out"
assert_grep "dry-run auto-detect: payload blocks direct pushes (restrictions null)" '  "restrictions": null' "$TMP/out"
assert_grep "dry-run auto-detect: reports no changes made" "[dry-run] no changes made." "$TMP/out"
assert_not_grep "dry-run auto-detect: never calls gh api PUT" "CALL=gh api -X PUT" "$r"

# ---------- dry-run with --repo/--branch given: skips detection calls ----------
r="$TMP/dryrun-explicit.record"
run "$r" -- --repo acme/widgets --branch release --dry-run
assert_grep "dry-run explicit: uses the given repo, not the detected one" "repo:    acme/widgets" "$TMP/out"
assert_grep "dry-run explicit: uses the given branch, not the detected one" "branch:  release" "$TMP/out"
assert_not_grep "dry-run explicit: never calls gh repo view for repo" "CALL=gh repo view --json nameWithOwner" "$r"
assert_not_grep "dry-run explicit: never calls gh repo view for branch" "CALL=gh repo view acme/widgets --json defaultBranchRef" "$r"

# ---------- --check overrides the default required context ----------
r="$TMP/dryrun-check.record"
run "$r" -- --check custom-check --dry-run
assert_grep "custom check: printed in summary" "check:   custom-check" "$TMP/out"
assert_grep "custom check: payload contexts uses it" '    "contexts": ["custom-check"]' "$TMP/out"

# ---------- repo cannot be detected and none given ----------
r="$TMP/no-repo.record"
STUB_NO_REPO=1 run "$r" -- --dry-run
assert_eq "no repo detected: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "no repo detected: corrective error on stderr" "ERROR: --repo OWNER/REPO is required" "$TMP/err"

# ---------- branch cannot be detected and none given ----------
r="$TMP/no-branch.record"
STUB_NO_BRANCH=1 run "$r" -- --repo acme/widgets --dry-run
assert_eq "no branch detected: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "no branch detected: corrective error on stderr" "ERROR: could not detect default branch for acme/widgets" "$TMP/err"

# ---------- real apply, success ----------
r="$TMP/apply-success.record"
run "$r" -- --repo acme/widgets --branch main
assert_eq "apply success: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "apply success: announces target" "Applying branch protection to acme/widgets:main ..." "$TMP/out"
assert_grep "apply success: reports success" "Branch protection applied successfully." "$TMP/out"
assert_grep "apply success: lists the required context from the response" "  - codex-review" "$TMP/out"
assert_grep "apply success: reports enforce_admins state" "enforce_admins: True" "$TMP/out"
assert_grep "apply success: prints next steps" "Next steps:" "$TMP/out"
assert_grep "apply success: calls gh api PUT exactly on the right endpoint" "CALL=gh api -X PUT repos/acme/widgets/branches/main/protection --input -" "$r"

# ---------- real apply, gh api PUT fails ----------
r="$TMP/apply-fail.record"
STUB_PUT_RC=1 run "$r" -- --repo acme/widgets --branch main
assert_eq "apply failure: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "apply failure: reports the PUT failure" "ERROR: gh api PUT failed:" "$TMP/err"
assert_grep "apply failure: surfaces the underlying gh error text" "stub PUT failure" "$TMP/err"

# ---------- --help ----------
r="$TMP/help.record"
run "$r" -- --help
assert_eq "help: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "help: documents usage" "Usage:" "$TMP/out"
assert_grep "help: documents --dry-run" "--dry-run" "$TMP/out"
assert_not_grep "help: never touches gh" "CALL=gh" "$r"

# ---------- unknown argument ----------
r="$TMP/unknown-arg.record"
run "$r" -- --bogus
assert_eq "unknown argument: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "unknown argument: reports which flag was unrecognized" "Unknown argument: --bogus" "$TMP/err"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
