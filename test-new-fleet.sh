#!/bin/bash
# test-new-fleet.sh — recording-stub coverage for new-fleet.sh (shipped with
# no test of its own until now, unlike every other script in this repo's
# Files table). new-fleet.sh hardcodes $HOME-rooted paths (staff-fleet/,
# .hermes/, .local/bin/) rather than taking them as flags, so every scenario
# below runs the real script with HOME redirected to a disposable tmpdir and
# `gh`/`hermes` stubbed on PATH — no real Hermes install, GitHub auth, or
# Telegram calls, and the real $HOME is never touched.
#
# Covers: prereq checks (gh missing, hermes missing, hermes not
# authenticated), arg validation, the full first-run file/directory
# scaffold (profiles, SOUL.md, config.yaml, .env templates, Hermes profile
# sync, auth.json symlinks, team-orchestrator.py + wrapper, babysit-driver.sh,
# team-dispatcher.sh + wrapper, offline-dev skill, spec-review-prompt.txt,
# bin wrappers incl. overwriting a pre-existing generic wrapper,
# start-gateways.sh), second-run idempotency (service-context.md and .env
# left alone, Hermes profile "already exists" path), cross-fleet .env value
# copying, and the gateway.py patch skip paths (not found / marker already
# present). Does NOT cover the python3 gateway.py patch actually applying
# against a real Hermes install, or start-gateways.sh's own runtime behavior
# (it only writes that file and checks it's well-formed) — both need a real
# Hermes checkout to exercise meaningfully.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/new-fleet.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; fail "$1"; else pass "$1"; fi; }
assert_file() { if [ -f "$2" ]; then pass "$1"; else echo "  missing file: $2" >&2; fail "$1"; fi; }
assert_dir() { if [ -d "$2" ]; then pass "$1"; else echo "  missing dir: $2" >&2; fail "$1"; fi; }
assert_exec() { if [ -x "$2" ]; then pass "$1"; else echo "  not executable: $2" >&2; fail "$1"; fi; }

mkdir -p "$TMP/bin"

# gh: new-fleet.sh itself only needs `command -v gh` to succeed (the real gh
# invocations live in the generated driver/dispatcher/orchestrator scripts,
# which this harness never executes).
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TMP/bin/gh"

# hermes: `auth status openai-codex` must print "logged in" (controlled by
# $STUB_HERMES_NOT_AUTHED) for the prereq check to pass; `profile create
# <name>` must materialize the profile directory the way the real CLI would,
# since the script immediately copies SOUL.md/config.yaml into it.
cat > "$TMP/bin/hermes" <<'STUB'
#!/bin/bash
printf 'CALL=hermes %s\n' "$*" >> "$RECORD"
case "$*" in
  "auth status openai-codex")
    [ -n "${STUB_HERMES_NOT_AUTHED:-}" ] && { echo "not authenticated"; exit 0; }
    echo "logged in"; exit 0 ;;
  "profile create "*)
    args="$*"; name="${args#profile create }"
    mkdir -p "${HERMES_HOME:?}/profiles/${name}"
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/hermes"

# run_new_fleet: fresh HOME per call so state never leaks across scenarios.
# Extra args before "--" are env assignments; everything after is forwarded
# to new-fleet.sh. Stdin is always /dev/null so the interactive bot-token
# prompt path is never hit by accident.
run_new_fleet() {  # <record> [env assignments...] -- [script args...]
  local record="$1"; shift
  : > "$record"
  local -a env_args=() script_args=()
  local in_script_args=0
  for arg in "$@"; do
    if [ "$in_script_args" = 1 ]; then script_args+=("$arg");
    elif [ "$arg" = "--" ]; then in_script_args=1
    else env_args+=("$arg"); fi
  done
  (
    env RECORD="$record" PATH="$TMP/bin:/usr/bin:/bin" HOME="${FLEET_HOME:-$TMP/home-$$-$RANDOM}" \
      "${env_args[@]+"${env_args[@]}"}" "$SCRIPT" "${script_args[@]+"${script_args[@]}"}" < /dev/null
  ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

# ---------- arg validation ----------
r="$TMP/no-args.record"
run_new_fleet "$r" --
assert_eq "no args: exits 1" "$(cat "$TMP/rc")" "1"
assert_grep "no args: usage message" "usage:" "$TMP/err"

r="$TMP/extra-arg.record"
run_new_fleet "$r" -- myfleet /tmp/some-repo extra
assert_eq "extra argument: exits 1" "$(cat "$TMP/rc")" "1"
assert_grep "extra argument: error names it" "unknown argument: extra" "$TMP/err"

# ---------- prereq checks ----------
mkdir -p "$TMP/bin-no-gh"
cp "$TMP/bin/hermes" "$TMP/bin-no-gh/hermes"
r="$TMP/no-gh.record"
run_new_fleet "$r" PATH="$TMP/bin-no-gh:/usr/bin:/bin" -- myfleet /tmp/some-repo
assert_eq "missing gh: exits 1" "$(cat "$TMP/rc")" "1"
assert_grep "missing gh: error names it" "error: 'gh' not found in PATH" "$TMP/err"

mkdir -p "$TMP/bin-no-hermes"
cp "$TMP/bin/gh" "$TMP/bin-no-hermes/gh"
r="$TMP/no-hermes.record"
run_new_fleet "$r" PATH="$TMP/bin-no-hermes:/usr/bin:/bin" -- myfleet /tmp/some-repo
assert_eq "missing hermes: exits 1" "$(cat "$TMP/rc")" "1"
assert_grep "missing hermes: error names it" "error: 'hermes' not found in PATH" "$TMP/err"

r="$TMP/not-authed.record"
run_new_fleet "$r" STUB_HERMES_NOT_AUTHED=1 -- myfleet /tmp/some-repo
assert_eq "hermes not authenticated: exits 1" "$(cat "$TMP/rc")" "1"
assert_grep "hermes not authenticated: error message" "error: Hermes is not authenticated with openai-codex." "$TMP/err"
assert_not_grep "hermes not authenticated: never reaches profile create" "CALL=hermes profile create" "$r"

# ---------- first run: full scaffold ----------
REPO_DIR="$TMP/repo-under-fleet"
mkdir -p "$REPO_DIR"
home="$TMP/fresh-home"
r="$TMP/fresh.record"
FLEET_HOME="$home" run_new_fleet "$r" -- acme "$REPO_DIR"
assert_eq "fresh fleet: exits 0" "$(cat "$TMP/rc")" "0"

FLEET_DIR="$home/staff-fleet/acme"
HERMES_HOME="$FLEET_DIR/.hermes"

assert_dir "fresh fleet: profiles/staff-swe created" "$FLEET_DIR/profiles/staff-swe"
assert_dir "fresh fleet: profiles/staff-sre created" "$FLEET_DIR/profiles/staff-sre"
assert_dir "fresh fleet: profiles/staff-pm created" "$FLEET_DIR/profiles/staff-pm"
assert_dir "fresh fleet: bin/ created" "$FLEET_DIR/bin"

assert_file "fresh fleet: service-context.md created" "$FLEET_DIR/service-context.md"
assert_grep "fresh fleet: service-context.md has the template header" "# Service Context" "$FLEET_DIR/service-context.md"

assert_file "fresh fleet: staff-swe SOUL.md created" "$FLEET_DIR/profiles/staff-swe/SOUL.md"
assert_grep "fresh fleet: SOUL.md names the fleet" "Staff Software Engineer — acme" "$FLEET_DIR/profiles/staff-swe/SOUL.md"
assert_grep "fresh fleet: SOUL.md names the repo path" "$REPO_DIR" "$FLEET_DIR/profiles/staff-swe/SOUL.md"

assert_file "fresh fleet: staff-swe config.yaml created" "$FLEET_DIR/profiles/staff-swe/config.yaml"
assert_grep "fresh fleet: config.yaml uses the openai-codex provider" "provider: openai-codex" "$FLEET_DIR/profiles/staff-swe/config.yaml"
assert_grep "fresh fleet: config.yaml has the daily-code-review cron" "daily-code-review" "$FLEET_DIR/profiles/staff-swe/config.yaml"

for role in swe sre pm; do
  assert_file "fresh fleet: staff-$role .env template created" "$FLEET_DIR/profiles/staff-$role/.env"
  assert_grep "fresh fleet: staff-$role .env has an empty TELEGRAM_BOT_TOKEN" "TELEGRAM_BOT_TOKEN=" "$FLEET_DIR/profiles/staff-$role/.env"
done

assert_grep "fresh fleet: non-interactive note printed (no token prompt)" "running non-interactively" "$TMP/out"
assert_not_grep "fresh fleet: no interactive prompt text was printed" "Enter bot tokens" "$TMP/out"

for role in swe sre pm; do
  assert_grep "fresh fleet: hermes profile create called for staff-$role" "CALL=hermes profile create staff-$role" "$r"
  assert_dir "fresh fleet: Hermes profile dir exists for staff-$role" "$HERMES_HOME/profiles/staff-$role"
  assert_file "fresh fleet: SOUL.md synced into Hermes profile for staff-$role" "$HERMES_HOME/profiles/staff-$role/SOUL.md"
  assert_file "fresh fleet: config.yaml synced into Hermes profile for staff-$role" "$HERMES_HOME/profiles/staff-$role/config.yaml"
  if [ -L "$HERMES_HOME/profiles/staff-$role/auth.json" ]; then pass "fresh fleet: auth.json symlinked for staff-$role"; else fail "fresh fleet: auth.json symlinked for staff-$role"; fi
done

assert_exec "fresh fleet: team-orchestrator.py is executable" "$FLEET_DIR/team-orchestrator.py"
assert_grep "fresh fleet: team-orchestrator.py defines main()" "def main()" "$FLEET_DIR/team-orchestrator.py"
assert_exec "fresh fleet: orchestrator cron wrapper is executable" "$HERMES_HOME/profiles/staff-pm/scripts/team-orchestrator-acme.sh"

assert_exec "fresh fleet: babysit-driver.sh is executable" "$FLEET_DIR/babysit-driver.sh"
assert_exec "fresh fleet: team-dispatcher.sh is executable" "$FLEET_DIR/team-dispatcher.sh"
assert_exec "fresh fleet: dispatcher cron wrapper is executable" "$HERMES_HOME/profiles/staff-pm/scripts/team-dispatcher-acme.sh"

for role in swe sre pm; do
  assert_file "fresh fleet: offline-dev skill deployed to staff-$role" "$HERMES_HOME/profiles/staff-$role/skills/offline-dev.md"
done

assert_file "fresh fleet: spec-review-prompt.txt written" "$FLEET_DIR/profiles/staff-pm/spec-review-prompt.txt"

for role in swe sre pm; do
  assert_exec "fresh fleet: fleet-local bin wrapper for staff-$role" "$FLEET_DIR/bin/acme-$role"
  assert_exec "fresh fleet: global bin wrapper for staff-$role" "$home/.local/bin/acme-$role"
  assert_grep "fresh fleet: global bin wrapper execs hermes -p staff-$role" "exec hermes -p \"staff-$role\"" "$home/.local/bin/acme-$role"
done

assert_exec "fresh fleet: start-gateways.sh is executable" "$FLEET_DIR/start-gateways.sh"
assert_grep "fresh fleet: start-gateways.sh is scoped to this fleet" 'FLEET_NAME="acme"' "$FLEET_DIR/start-gateways.sh"

assert_grep "fresh fleet: gateway.py patch reports skipped (file not found)" "already patched (or not found" "$TMP/out"

# ---------- generic wrapper gets overwritten, not left pointing at a stale fleet ----------
home2="$TMP/overwrite-home"
mkdir -p "$home2/.local/bin"
cat > "$home2/.local/bin/staff-swe" <<'EOF'
#!/usr/bin/env bash
echo "stale wrapper from a different fleet"
EOF
chmod +x "$home2/.local/bin/staff-swe"
r="$TMP/overwrite.record"
FLEET_HOME="$home2" run_new_fleet "$r" -- beta "$REPO_DIR"
assert_eq "generic wrapper overwrite: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "generic wrapper overwrite: redirects to the fleet-qualified command" "use a fleet-qualified wrapper" "$home2/.local/bin/staff-swe"
assert_not_grep "generic wrapper overwrite: stale content is gone" "stale wrapper from a different fleet" "$home2/.local/bin/staff-swe"

# ---------- cross-fleet .env value copying ----------
home3="$TMP/copy-home"
mkdir -p "$home3/staff-fleet/existing/.hermes/profiles/staff-pm"
cat > "$home3/staff-fleet/existing/.hermes/profiles/staff-pm/.env" <<'EOF'
TELEGRAM_BOT_TOKEN=should-not-copy
TELEGRAM_ALLOWED_USERS=12345
TELEGRAM_HOME_CHANNEL=67890
GH_TOKEN=ghp_shared_token
EOF
r="$TMP/copy.record"
FLEET_HOME="$home3" run_new_fleet "$r" -- newfleet "$REPO_DIR"
assert_eq "cross-fleet env copy: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "cross-fleet env copy: reports the copy" "copied TELEGRAM_ALLOWED_USERS" "$TMP/out"
for role in swe sre pm; do
  env_file="$home3/staff-fleet/newfleet/profiles/staff-$role/.env"
  assert_grep "cross-fleet env copy: TELEGRAM_ALLOWED_USERS copied into staff-$role" "TELEGRAM_ALLOWED_USERS=12345" "$env_file"
  assert_grep "cross-fleet env copy: TELEGRAM_HOME_CHANNEL copied into staff-$role" "TELEGRAM_HOME_CHANNEL=67890" "$env_file"
  assert_grep "cross-fleet env copy: GH_TOKEN copied into staff-$role" "GH_TOKEN=ghp_shared_token" "$env_file"
  assert_grep "cross-fleet env copy: TELEGRAM_BOT_TOKEN is NOT copied (per-bot, not shared)" "TELEGRAM_BOT_TOKEN=" "$env_file"
  assert_not_grep "cross-fleet env copy: the other fleet's bot token never leaks across" "should-not-copy" "$env_file"
done

# ---------- second run: idempotency ----------
home4="$TMP/idempotent-home"
r="$TMP/idempotent-first.record"
FLEET_HOME="$home4" run_new_fleet "$r" -- repeat "$REPO_DIR"
assert_eq "idempotent: first run exits 0" "$(cat "$TMP/rc")" "0"

fleet4="$home4/staff-fleet/repeat"
# Simulate the operator having filled in a bot token and edited the context doc.
sed -i.bak 's/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=manually-set-token/' "$fleet4/profiles/staff-swe/.env"
rm -f "$fleet4/profiles/staff-swe/.env.bak"
printf '\nedited by operator\n' >> "$fleet4/service-context.md"

r2="$TMP/idempotent-second.record"
FLEET_HOME="$home4" run_new_fleet "$r2" -- repeat "$REPO_DIR"
assert_eq "idempotent: second run exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "idempotent: service-context.md reports already-exists" "service-context.md already exists, skipping" "$TMP/out"
assert_grep "idempotent: service-context.md edits are preserved" "edited by operator" "$fleet4/service-context.md"
assert_grep "idempotent: manually-set .env token is preserved" "TELEGRAM_BOT_TOKEN=manually-set-token" "$fleet4/profiles/staff-swe/.env"
assert_grep "idempotent: Hermes profile reports already-exists on second run" "Hermes profile staff-swe already exists, updating config" "$TMP/out"

# ---------- gateway.py patch: marker already present is a no-op ----------
home5="$TMP/patched-home"
mkdir -p "$home5/.hermes/hermes-agent/hermes_cli"
cat > "$home5/.hermes/hermes-agent/hermes_cli/gateway.py" <<'EOF'
# HERMES_FLEET_ENV_INJECTION_PATCH already applied
EOF
r="$TMP/already-patched.record"
FLEET_HOME="$home5" run_new_fleet "$r" -- patched "$REPO_DIR"
assert_eq "gateway.py already patched: exits 0" "$(cat "$TMP/rc")" "0"
assert_grep "gateway.py already patched: reports already patched" "already patched (or not found" "$TMP/out"
if ls "$home5/.hermes/hermes-agent/hermes_cli/"gateway.py.bak.* >/dev/null 2>&1; then
  fail "gateway.py already patched: no backup file written (patch was skipped)"
else
  pass "gateway.py already patched: no backup file written (patch was skipped)"
fi

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
