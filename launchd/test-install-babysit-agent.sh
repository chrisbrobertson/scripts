#!/bin/bash
# test-install-babysit-agent.sh — recording-stub coverage for
# install-babysit-agent.sh.
#
# install-babysit-agent.sh had no test coverage at all. It's a short, linear
# script that writes under $HOME and shells out to launchctl/plutil, so this
# harness runs the real script end to end with HOME redirected to a
# disposable tmpdir and launchctl/plutil stubbed on PATH — no real
# LaunchAgent is ever written or loaded, and the real plist template under
# this directory is only ever read, never modified.
#
# Does not cover the plutil-absent skip path: plutil ships at a fixed
# absolute location on every macOS system this runs on, and excluding it
# from PATH without also breaking sed/mkdir/id (needed for the real run)
# isn't worth the complexity for one `command -v` guard.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/install-babysit-agent.sh"
TEMPLATE="$ROOT/com.chrisrobertson.babysit.PROJECT.plist.template"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/project"

# launchctl: records every invocation to $RECORD, responds per STUB_* knobs.
cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/bash
printf 'CALL=launchctl %s\n' "$*" >> "$RECORD"
case "$1" in
  bootstrap)
    [ -n "${STUB_BOOTSTRAP_FAIL:-}" ] && exit 1
    exit 0 ;;
  load)
    exit 0 ;;
  print)
    echo "stub launchctl print output"
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/launchctl"

# plutil: records every invocation to $RECORD, always "lints" clean.
cat > "$TMP/bin/plutil" <<'STUB'
#!/bin/bash
printf 'CALL=plutil %s\n' "$*" >> "$RECORD"
echo "${2:-}: OK"
exit 0
STUB
chmod +x "$TMP/bin/plutil"

run() {  # <record> -- <script args...>
  local record="$1"; shift
  shift  # drop the literal --
  : > "$record"
  ( env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" \
      STUB_BOOTSTRAP_FAIL="${STUB_BOOTSTRAP_FAIL:-}" \
      "$SCRIPT" "$@" ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- wrong argument count ----------
r="$TMP/usage.record"
run "$r" --
assert_eq "no args: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "no args: usage on stderr" "Usage: $SCRIPT <project_basename> <project_absolute_path>" "$TMP/err"

r="$TMP/usage-one-arg.record"
run "$r" -- myproj
assert_eq "one arg: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "one arg: usage on stderr" "Usage:" "$TMP/err"

# ---------- template missing ----------
rm -rf "$TMP/no-template"
mkdir -p "$TMP/no-template"
cp "$SCRIPT" "$TMP/no-template/install-babysit-agent.sh"
chmod +x "$TMP/no-template/install-babysit-agent.sh"
r="$TMP/no-template.record"
: > "$r"
( env RECORD="$r" PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" \
    "$TMP/no-template/install-babysit-agent.sh" myproj "$TMP/project" ) >"$TMP/out" 2>"$TMP/err"
echo "$?" > "$TMP/rc"
assert_eq "template missing: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "template missing: error names the missing path" "ERROR: template not found at $TMP/no-template/com.chrisrobertson.babysit.PROJECT.plist.template" "$TMP/err"

# ---------- project path does not exist ----------
r="$TMP/no-project.record"
run "$r" -- myproj "$TMP/does-not-exist"
assert_eq "project path missing: exit 1" "$(cat "$TMP/rc")" "1"
assert_grep "project path missing: error names the missing path" "ERROR: project path does not exist: $TMP/does-not-exist" "$TMP/err"

# ---------- happy path: bootstrap succeeds ----------
r="$TMP/happy.record"
run "$r" -- myproj "$TMP/project"
assert_eq "happy path: exit 0" "$(cat "$TMP/rc")" "0"
DEST="$TMP/home/Library/LaunchAgents/com.chrisrobertson.babysit.myproj.plist"
assert_grep "happy path: reports where it wrote the plist" "Wrote $DEST" "$TMP/out"
[ -f "$DEST" ] && pass "happy path: plist written to the expected path" || fail "happy path: plist written to the expected path"
assert_grep "happy path: plist has __PROJECT__ substituted into the Label" "<string>com.chrisrobertson.babysit.myproj</string>" "$DEST"
assert_grep "happy path: plist has __PROJECT_PATH__ substituted into WorkingDirectory" "<string>$TMP/project</string>" "$DEST"
assert_not_grep "happy path: no leftover __PROJECT__ placeholder" "__PROJECT__" "$DEST"
assert_not_grep "happy path: no leftover __PROJECT_PATH__ placeholder" "__PROJECT_PATH__" "$DEST"
[ -d "$TMP/home/sisyphus-logs" ] && pass "happy path: sisyphus-logs dir created" || fail "happy path: sisyphus-logs dir created"
assert_grep "happy path: plutil -lint invoked on the written plist" "CALL=plutil -lint $DEST" "$r"
assert_grep "happy path: launchctl bootstrap invoked with gui/<uid>" "CALL=launchctl bootstrap gui/$(id -u) $DEST" "$r"
assert_grep "happy path: reports successful bootstrap" "Bootstrapped com.chrisrobertson.babysit.myproj via launchctl bootstrap." "$TMP/out"
assert_not_grep "happy path: never falls back to launchctl load" "CALL=launchctl load" "$r"
assert_grep "happy path: launchctl print invoked to show final state" "CALL=launchctl print gui/$(id -u)/com.chrisrobertson.babysit.myproj" "$r"
assert_grep "happy path: launchctl print output surfaced" "stub launchctl print output" "$TMP/out"

# ---------- bootstrap fails: falls back to launchctl load ----------
r="$TMP/fallback.record"
STUB_BOOTSTRAP_FAIL=1 run "$r" -- otherproj "$TMP/project"
assert_eq "bootstrap failure: still exits 0 via the load fallback" "$(cat "$TMP/rc")" "0"
assert_grep "bootstrap failure: warns on stderr and falls back" "bootstrap failed or already loaded; falling back to launchctl load" "$TMP/err"
assert_grep "bootstrap failure: launchctl load invoked" "CALL=launchctl load $TMP/home/Library/LaunchAgents/com.chrisrobertson.babysit.otherproj.plist" "$r"
assert_not_grep "bootstrap failure: does not claim a successful bootstrap" "Bootstrapped com.chrisrobertson.babysit.otherproj via launchctl bootstrap." "$TMP/out"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
