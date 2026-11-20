#!/bin/bash
# test-install-poolside-s21-mac.sh — coverage for install-poolside-s21-mac.sh
# (shipped with no test of its own until now — the only script left in
# CLAUDE.md's Files table without one). Unlike the gh-wrapper scripts this
# repo already covers, install-poolside-s21-mac.sh calls several real
# binaries by *absolute path* (`/usr/bin/curl`, `/bin/launchctl`,
# `/usr/sbin/sysctl`, `/usr/bin/sw_vers`) rather than searching PATH, so the
# usual PATH-stub trick can't intercept them — and some of those calls
# (`curl`-piped installers, `launchctl bootstrap`) would mutate the real
# machine if actually run. So this harness never executes the script as a
# process or runs its `main`; instead it `source`s the script (relying on
# the `[ "${BASH_SOURCE[0]}" = "${0}" ]` guard added alongside this test so
# sourcing never calls `main "$@"`) and calls individual functions directly,
# with HOME redirected to a disposable tmpdir per scenario. Every function
# exercised here only touches local files/env or invokes safe, read-only,
# offline real binaries (`df`, `uname`, `python3`, `openssl rand`, `plutil
# -lint`) — nothing that installs software, starts a service, or talks to
# the network.
#
# Covers: --help/usage, parse_args validation (bad/too-small/too-large
# --context, the --test-only/--skip-tests conflict, unknown options,
# --repoint-all expanding to both flags), quote_xml escaping, the managed-
# block helpers' idempotency (append replaces rather than duplicates;
# remove strips cleanly), configure_path's idempotent PATH block,
# find_executable's PATH/fallback/not-found paths, version_at_least across
# equal/greater/lesser/missing-patch versions, model_is_installed's
# true/false paths, check_disk_for_pull's pass/fatal paths (via a stubbed
# `df` on PATH) and its model-already-installed skip, ensure_dirs' 700
# perms, write_runtime_config/write_codex_profile/write_wrappers' file
# content and perms, write_ollama_launch_agent/write_litellm_launch_agent's
# plist content, perms, and real `plutil -lint` validation, the
# config_helper.py claude-apply/claude-restore and codex-apply/codex-restore
# round trips (including the "env was never present" and "file didn't
# exist" starting states), apply_repoints only touching the harness(es) its
# flags select, detect_existing_repoints reading the state file and config
# marker back, restore_harnesses' end-to-end revert, and print_summary's
# conditional repoint lines.
#
# Does NOT cover: check_platform (reads real hardware via absolute-path
# sysctl/sw_vers — asserting on it would mean asserting on whatever Mac
# happens to run this suite), the install_* functions, start_ollama/
# start_litellm/launch_agent (real launchctl), pull_and_create_model, or
# run_live_tests — all of those need a real Ollama/LiteLLM/launchd/network
# to exercise meaningfully and are exactly the parts a one-shot installer
# script can't safely fake.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/install-poolside-s21-mac.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; fail "$1"; else pass "$1"; fi; }
assert_file() { if [ -f "$2" ]; then pass "$1"; else echo "  missing file: $2" >&2; fail "$1"; fi; }
assert_exec() { if [ -x "$2" ]; then pass "$1"; else echo "  not executable: $2" >&2; fail "$1"; fi; }
assert_perm() {  # <label> <path> <expected-octal>
  local actual
  actual="$(stat -f '%Lp' "$2" 2>/dev/null)"
  assert_eq "$1" "${actual:-<missing>}" "$3"
}

# Runs CODE in a fresh subprocess with the script sourced (never invoking
# main, thanks to the BASH_SOURCE guard) and HOME pointed at a scenario-local
# dir. Captures stdout/stderr/rc into $TMP/out, $TMP/err, $TMP/rc. CODE can
# rely on `set -euo pipefail` (inherited from sourcing the script), so a
# `fatal` call inside it terminates the whole subprocess with rc=1.
src_run() {  # <home_dir> <code> [extra PATH prefix dir]
  local home_dir="$1" code="$2" path_prefix="${3:-}"
  (
    HOME="$home_dir" PATH="${path_prefix:+$path_prefix:}$PATH" \
      bash -c "source '$SCRIPT'; $code"
  ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}
rc() { cat "$TMP/rc"; }

fresh_home() { local d="$TMP/home-$RANDOM-$RANDOM"; mkdir -p "$d"; printf '%s\n' "$d"; }

# --- usage / --help -------------------------------------------------------

out=$(cd "$ROOT" && ./install-poolside-s21-mac.sh --help)
assert_grep "help: usage banner" "Usage: install-poolside-s21-mac.sh" <(printf '%s' "$out")
rc_help=$(cd "$ROOT" && ./install-poolside-s21-mac.sh --help >/dev/null 2>&1; echo $?)
assert_eq "help: exits 0" "$rc_help" "0"

rc_unknown=$(cd "$ROOT" && ./install-poolside-s21-mac.sh --bogus >/dev/null 2>&1; echo $?)
assert_eq "direct invocation: unknown arg exits 1" "$rc_unknown" "1"

# --- parse_args ------------------------------------------------------------

h=$(fresh_home)
src_run "$h" 'parse_args --context abc'
assert_eq "parse_args: non-integer context exits 1" "$(rc)" "1"
assert_grep "parse_args: non-integer context message" "must be a positive integer" "$TMP/err"

h=$(fresh_home)
src_run "$h" 'parse_args --context 1024'
assert_eq "parse_args: too-small context exits 1" "$(rc)" "1"
assert_grep "parse_args: too-small context message" "must be at least 8192" "$TMP/err"

h=$(fresh_home)
src_run "$h" 'parse_args --context 100000; echo done'
assert_eq "parse_args: oversized context still succeeds" "$(rc)" "0"
assert_grep "parse_args: oversized context warns" "not recommended" "$TMP/err"

h=$(fresh_home)
src_run "$h" 'parse_args --test-only --skip-tests'
assert_eq "parse_args: --test-only + --skip-tests exits 1" "$(rc)" "1"
assert_grep "parse_args: mutual-exclusion message" "mutually exclusive" "$TMP/err"

h=$(fresh_home)
src_run "$h" 'parse_args --nope'
assert_eq "parse_args: unknown option exits 1" "$(rc)" "1"
assert_grep "parse_args: unknown option message" "Unknown option" "$TMP/err"

h=$(fresh_home)
src_run "$h" 'parse_args --repoint-all --context 16384; printf "opus=%s codex=%s ctx=%s\n" "$REPOINT_OPUS" "$REPOINT_CODEX" "$CONTEXT_LENGTH"'
assert_eq "parse_args: --repoint-all + --context exits 0" "$(rc)" "0"
assert_grep "parse_args: --repoint-all sets both flags" "opus=1 codex=1 ctx=16384" "$TMP/out"

h=$(fresh_home)
src_run "$h" 'parse_args --accept-poolside-eula; printf "eula=%s\n" "$ACCEPT_EULA"'
assert_grep "parse_args: --accept-poolside-eula sets flag" "eula=1" "$TMP/out"

# --- quote_xml --------------------------------------------------------------

h=$(fresh_home)
src_run "$h" 'quote_xml "a & b < c > d \"e\" f'"'"'g"'
assert_eq "quote_xml: escapes all five special chars" "$(cat "$TMP/out")" 'a &amp; b &lt; c &gt; d &quot;e&quot; f&apos;g'

# --- managed-block helpers ---------------------------------------------------

h=$(fresh_home)
src_run "$h" '
f="'"$TMP"'/block-test"
printf "line1\nline2\n" > "$f"
append_managed_block "$f" "# BEGIN" "# END" "hello"
append_managed_block "$f" "# BEGIN" "# END" "world"
printf "begin-count=%s\n" "$(grep -c "^# BEGIN\$" "$f")"
cat "$f"
'
assert_eq "append_managed_block: idempotent, one block" "$(rc)" "0"
assert_grep "append_managed_block: single begin marker" "begin-count=1" "$TMP/out"
assert_grep "append_managed_block: latest content wins" "world" "$TMP/out"
assert_not_grep "append_managed_block: stale content gone" "hello" "$TMP/out"

h=$(fresh_home)
src_run "$h" '
f="'"$TMP"'/block-test2"
printf "keep1\n" > "$f"
append_managed_block "$f" "# BEGIN" "# END" "managed"
printf "keep2\n" >> "$f"
remove_managed_block "$f" "# BEGIN" "# END"
cat "$f"
'
assert_grep "remove_managed_block: surrounding content kept" "keep1" "$TMP/out"
assert_grep "remove_managed_block: surrounding content kept (2)" "keep2" "$TMP/out"
assert_not_grep "remove_managed_block: block content removed" "managed" "$TMP/out"

# --- configure_path idempotency ---------------------------------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
configure_path
configure_path
configure_path
printf "count=%s\n" "$(grep -c "^# >>> poolside-s21 PATH >>>\$" "$ZPROFILE")"
'
assert_grep "configure_path: single block after repeated calls" "count=1" "$TMP/out"

# --- find_executable ---------------------------------------------------------

h=$(fresh_home)
mkdir -p "$h/bin"
cat > "$h/bin/foo-tool" <<'STUB'
#!/bin/bash
echo hi
STUB
chmod +x "$h/bin/foo-tool"
src_run "$h" 'find_executable foo-tool /nonexistent' "$h/bin"
assert_eq "find_executable: resolves via PATH" "$(rc)" "0"
assert_grep "find_executable: prints the PATH hit" "$h/bin/foo-tool" "$TMP/out"

src_run "$h" 'find_executable missing-tool "'"$h"'/bin/foo-tool"'
assert_eq "find_executable: falls back to candidate" "$(rc)" "0"
assert_grep "find_executable: prints the fallback candidate" "$h/bin/foo-tool" "$TMP/out"

src_run "$h" 'find_executable missing-tool /nonexistent/also-missing'
assert_eq "find_executable: not found returns 1" "$(rc)" "1"

# --- version_at_least ---------------------------------------------------------

h=$(fresh_home)
src_run "$h" '
version_at_least 1.2.3 1.2.3 && echo eq-ok
version_at_least 1.3.0 1.2.9 && echo gt-ok
version_at_least 1.2 1.2.0 && echo missing-patch-ok
lt_rc=0
version_at_least 1.1.0 1.2.0 || lt_rc=$?
printf "lt-rc=%s\n" "$lt_rc"
'
assert_grep "version_at_least: equal versions" "eq-ok" "$TMP/out"
assert_grep "version_at_least: greater major/minor" "gt-ok" "$TMP/out"
assert_grep "version_at_least: missing patch treated as 0" "missing-patch-ok" "$TMP/out"
assert_grep "version_at_least: lesser version returns 1" "lt-rc=1" "$TMP/out"

# --- model_is_installed -------------------------------------------------------

h=$(fresh_home)
mkdir -p "$h/bin"
cat > "$h/bin/ollama-stub-present" <<'STUB'
#!/bin/bash
echo "NAME ID SIZE"
echo "laguna-s-2.1:latest abc123 1GB"
STUB
chmod +x "$h/bin/ollama-stub-present"
src_run "$h" 'OLLAMA_BIN="'"$h"'/bin/ollama-stub-present"; model_is_installed'
assert_eq "model_is_installed: true when listed" "$(rc)" "0"

cat > "$h/bin/ollama-stub-absent" <<'STUB'
#!/bin/bash
echo "NAME ID SIZE"
echo "some-other-model:latest def456 1GB"
STUB
chmod +x "$h/bin/ollama-stub-absent"
src_run "$h" 'OLLAMA_BIN="'"$h"'/bin/ollama-stub-absent"; model_is_installed'
assert_eq "model_is_installed: false when not listed" "$(rc)" "1"

src_run "$h" 'OLLAMA_BIN=""; model_is_installed'
assert_eq "model_is_installed: false when OLLAMA_BIN unset" "$(rc)" "1"

# --- check_disk_for_pull -------------------------------------------------------

h=$(fresh_home)
mkdir -p "$h/dfbin"
cat > "$h/dfbin/df" <<'STUB'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/disk1 1 1 500 1% /"
STUB
chmod +x "$h/dfbin/df"
src_run "$h" 'OLLAMA_BIN=""; check_disk_for_pull' "$h/dfbin"
assert_eq "check_disk_for_pull: fatal when free space too low" "$(rc)" "1"
assert_grep "check_disk_for_pull: low-space message" "reserve at least 90 GiB" "$TMP/err"

mkdir -p "$h/dfbin2"
cat > "$h/dfbin2/df" <<'STUB'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/disk1 1 1 999999999 1% /"
STUB
chmod +x "$h/dfbin2/df"
src_run "$h" 'OLLAMA_BIN=""; check_disk_for_pull; echo done' "$h/dfbin2"
assert_eq "check_disk_for_pull: passes with ample free space" "$(rc)" "0"

mkdir -p "$h/bin"
cat > "$h/bin/ollama-stub-present" <<'STUB'
#!/bin/bash
echo "NAME ID SIZE"
echo "laguna-s-2.1:latest abc123 1GB"
STUB
chmod +x "$h/bin/ollama-stub-present"
src_run "$h" 'OLLAMA_BIN="'"$h"'/bin/ollama-stub-present"; check_disk_for_pull' "$h/dfbin"
assert_eq "check_disk_for_pull: skips disk check when model already installed" "$(rc)" "0"

# --- ensure_dirs perms --------------------------------------------------------

h=$(fresh_home)
src_run "$h" 'ensure_dirs; printf "%s\n" "$CONFIG_DIR" "$STATE_DIR"'
assert_eq "ensure_dirs: exits 0" "$(rc)" "0"
config_dir=$(sed -n '1p' "$TMP/out")
state_dir=$(sed -n '2p' "$TMP/out")
assert_perm "ensure_dirs: CONFIG_DIR is 700" "$config_dir" "700"
assert_perm "ensure_dirs: STATE_DIR is 700" "$state_dir" "700"

# --- write_runtime_config -----------------------------------------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
CONTEXT_LENGTH=16384
LITELLM_MASTER_KEY="sk-test-key"
write_runtime_config
printf "%s\n" "$MODELFILE" "$LITELLM_CONFIG" "$CLAUDE_LOCAL_SETTINGS"
'
assert_eq "write_runtime_config: exits 0" "$(rc)" "0"
modelfile=$(sed -n '1p' "$TMP/out")
litellm_config=$(sed -n '2p' "$TMP/out")
claude_local=$(sed -n '3p' "$TMP/out")
assert_grep "write_runtime_config: Modelfile base model" "FROM laguna-s-2.1:latest" "$modelfile"
assert_grep "write_runtime_config: Modelfile context" "PARAMETER num_ctx 16384" "$modelfile"
assert_grep "write_runtime_config: litellm.yaml model name" "model_name: poolside-s2.1" "$litellm_config"
assert_grep "write_runtime_config: litellm.yaml api_base" "api_base: http://127.0.0.1:11434/v1" "$litellm_config"
assert_grep "write_runtime_config: claude settings base url" "\"ANTHROPIC_BASE_URL\": \"http://127.0.0.1:4000\"" "$claude_local"
assert_grep "write_runtime_config: claude settings key" "\"ANTHROPIC_AUTH_TOKEN\": \"sk-test-key\"" "$claude_local"
assert_perm "write_runtime_config: Modelfile is 600" "$modelfile" "600"
assert_perm "write_runtime_config: litellm.yaml is 600" "$litellm_config" "600"
assert_perm "write_runtime_config: claude local settings is 600" "$claude_local" "600"

# load_or_create_key: generates once, persists across reloads
h=$(fresh_home)
src_run "$h" '
ensure_dirs
load_or_create_key
k1="$LITELLM_MASTER_KEY"
LITELLM_MASTER_KEY=""
load_or_create_key
printf "k1=%s\nk2=%s\n" "$k1" "$LITELLM_MASTER_KEY"
printf "perm=%s\n" "$(stat -f "%Lp" "$RUNTIME_ENV")"
'
k1=$(sed -n '1s/^k1=//p' "$TMP/out"); k2=$(sed -n '2s/^k2=//p' "$TMP/out")
assert_eq "load_or_create_key: key persists across reloads" "$k1" "$k2"
assert_grep "load_or_create_key: runtime.env is 600" "perm=600" "$TMP/out"

# --- write_codex_profile -----------------------------------------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
CONTEXT_LENGTH=8192
write_codex_profile
printf "%s\n" "$CODEX_PROFILE"
'
profile=$(cat "$TMP/out")
assert_grep "write_codex_profile: model name" 'model = "poolside-s2.1"' "$profile"
assert_grep "write_codex_profile: context window" "model_context_window = 8192" "$profile"
assert_grep "write_codex_profile: base_url" 'base_url = "http://127.0.0.1:4000/v1"' "$profile"
assert_perm "write_codex_profile: profile is 600" "$profile" "600"

# --- write_wrappers -----------------------------------------------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
LITELLM_MASTER_KEY="sk-test"
POOL_BIN="/opt/pool"; CLAUDE_BIN="/opt/claude"; CODEX_BIN="/opt/codex"
write_wrappers
printf "%s\n" "$BIN_DIR/pool-poolside" "$BIN_DIR/claude-poolside" "$BIN_DIR/codex-poolside" "$STATE_DIR/print-litellm-key.sh"
'
pool_w=$(sed -n '1p' "$TMP/out"); claude_w=$(sed -n '2p' "$TMP/out")
codex_w=$(sed -n '3p' "$TMP/out"); key_w=$(sed -n '4p' "$TMP/out")
for f in "$pool_w" "$claude_w" "$codex_w" "$key_w"; do
  assert_exec "write_wrappers: $(basename "$f") is executable" "$f"
  assert_perm "write_wrappers: $(basename "$f") is 700" "$f" "700"
done
assert_grep "write_wrappers: pool wrapper execs POOL_BIN" "exec /opt/pool" "$pool_w"
assert_grep "write_wrappers: claude wrapper execs CLAUDE_BIN" "exec /opt/claude" "$claude_w"
assert_grep "write_wrappers: codex wrapper execs CODEX_BIN" "exec /opt/codex" "$codex_w"
assert_grep "write_wrappers: claude wrapper sets auth token" 'ANTHROPIC_AUTH_TOKEN="sk-test"' "$claude_w"

# --- launch agent plists (file content + real plutil -lint, no launchctl) ---

h=$(fresh_home)
src_run "$h" '
ensure_dirs
OLLAMA_BIN="/usr/local/bin/ollama"
write_ollama_launch_agent
echo plist-written-and-linted-ok
'
assert_eq "write_ollama_launch_agent: plutil -lint accepts generated plist" "$(rc)" "0"
assert_grep "write_ollama_launch_agent: lint confirmation printed" "plist-written-and-linted-ok" "$TMP/out"

h=$(fresh_home)
src_run "$h" '
ensure_dirs
LITELLM_BIN="/usr/local/bin/litellm"
write_litellm_launch_agent
printf "%s\n" "$LITELLM_PLIST"
'
litellm_plist=$(cat "$TMP/out")
assert_grep "write_litellm_launch_agent: label present" "ai.poolside.s21.litellm" "$litellm_plist"
assert_perm "write_litellm_launch_agent: plist is 600" "$litellm_plist" "600"

# --- config_helper.py: claude-apply / claude-restore round trip -------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
write_config_helper
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
printf "%s" "{\"model\": \"sonnet\", \"env\": {\"FOO\": \"bar\"}, \"other\": 1}" > "$CLAUDE_SETTINGS"
run_python_helper claude-apply "$CLAUDE_SETTINGS" "$CLAUDE_STATE" "sk-test-key" "http://127.0.0.1:4000" "poolside-s2.1"
python3 -c "import json; d = json.load(open(\"$CLAUDE_SETTINGS\")); print(d[\"model\"]); print(d[\"env\"][\"ANTHROPIC_AUTH_TOKEN\"]); print(d[\"env\"][\"FOO\"]); print(d[\"other\"])"
'
assert_eq "claude-apply: exits 0" "$(rc)" "0"
assert_eq "claude-apply: model set to opus" "$(sed -n '1p' "$TMP/out")" "opus"
assert_eq "claude-apply: auth token wired in" "$(sed -n '2p' "$TMP/out")" "sk-test-key"
assert_eq "claude-apply: unrelated env key preserved" "$(sed -n '3p' "$TMP/out")" "bar"
assert_eq "claude-apply: unrelated top-level key preserved" "$(sed -n '4p' "$TMP/out")" "1"

src_run "$h" '
run_python_helper claude-restore "$CLAUDE_SETTINGS" "$CLAUDE_STATE"
python3 -c "import json; d = json.load(open(\"$CLAUDE_SETTINGS\")); print(d[\"model\"]); print(d[\"env\"][\"FOO\"]); print(\"ANTHROPIC_AUTH_TOKEN\" in d[\"env\"]); print(d[\"other\"])"
printf "state-exists=%s\n" "$([ -f "$CLAUDE_STATE" ] && echo yes || echo no)"
'
assert_eq "claude-restore: exits 0" "$(rc)" "0"
assert_eq "claude-restore: model restored to sonnet" "$(sed -n '1p' "$TMP/out")" "sonnet"
assert_eq "claude-restore: unrelated env key still present" "$(sed -n '2p' "$TMP/out")" "bar"
assert_eq "claude-restore: injected auth token removed" "$(sed -n '3p' "$TMP/out")" "False"
assert_eq "claude-restore: unrelated top-level key preserved" "$(sed -n '4p' "$TMP/out")" "1"
assert_grep "claude-restore: state file removed" "state-exists=no" "$TMP/out"

# claude-apply when settings.json has no "env" key at all: restore should
# drop the env key again rather than leaving an empty {} behind.
h=$(fresh_home)
src_run "$h" '
ensure_dirs
write_config_helper
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
printf "%s" "{\"model\": \"sonnet\"}" > "$CLAUDE_SETTINGS"
run_python_helper claude-apply "$CLAUDE_SETTINGS" "$CLAUDE_STATE" "sk-test-key" "http://127.0.0.1:4000" "poolside-s2.1"
run_python_helper claude-restore "$CLAUDE_SETTINGS" "$CLAUDE_STATE"
python3 -c "import json; d = json.load(open(\"$CLAUDE_SETTINGS\")); print(\"env\" in d)"
'
assert_eq "claude-restore: env key removed when never present originally" "$(cat "$TMP/out")" "False"

# --- config_helper.py: codex-apply / codex-restore round trip ----------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
write_config_helper
mkdir -p "$CODEX_CONFIG_DIR"
printf "model = \"o3\"\nmodel_provider = \"openai\"\n\n[other_section]\nfoo = \"bar\"\n" > "$CODEX_CONFIG"
run_python_helper codex-apply "$CODEX_CONFIG" "/path/to/auth.sh" "http://127.0.0.1:4000" "poolside-s2.1" 32768
cat "$CODEX_CONFIG"
'
assert_grep "codex-apply: managed root block present" 'model = "poolside-s2.1"' "$TMP/out"
assert_grep "codex-apply: original model line preserved commented" '# poolside-s21-original: model = "o3"' "$TMP/out"
assert_grep "codex-apply: provider block present" "[model_providers.poolside_s21_local]" "$TMP/out"
assert_grep "codex-apply: unrelated section preserved" "[other_section]" "$TMP/out"

src_run "$h" '
run_python_helper codex-restore "$CODEX_CONFIG"
cat "$CODEX_CONFIG"
'
assert_eq "codex-restore: exits 0" "$(rc)" "0"
assert_grep "codex-restore: original model restored" 'model = "o3"' "$TMP/out"
assert_grep "codex-restore: unrelated section still present" "[other_section]" "$TMP/out"
assert_not_grep "codex-restore: managed markers removed" "poolside-s21 managed Codex" "$TMP/out"

# codex-apply against a file that doesn't exist yet
h=$(fresh_home)
src_run "$h" '
ensure_dirs
write_config_helper
run_python_helper codex-apply "$CODEX_CONFIG" "/path/to/auth.sh" "http://127.0.0.1:4000" "poolside-s2.1" 32768
cat "$CODEX_CONFIG"
'
assert_grep "codex-apply: creates config.toml when absent" 'model = "poolside-s2.1"' "$TMP/out"

# --- apply_repoints only touches the harness(es) selected -------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
configure_path
LITELLM_MASTER_KEY="sk-test"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
printf "%s" "{\"model\": \"sonnet\"}" > "$CLAUDE_SETTINGS"
REPOINT_OPUS=1
REPOINT_CODEX=0
apply_repoints
python3 -c "import json; print(json.load(open(\"$CLAUDE_SETTINGS\"))[\"model\"])"
printf "codex-config-exists=%s\n" "$([ -f "$CODEX_CONFIG" ] && echo yes || echo no)"
'
assert_eq "apply_repoints: opus-only exits 0" "$(rc)" "0"
assert_grep "apply_repoints: opus-only sets claude model to opus" "opus" "$TMP/out"
assert_grep "apply_repoints: opus-only leaves codex config untouched" "codex-config-exists=no" "$TMP/out"

# --- detect_existing_repoints -------------------------------------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
configure_path
LITELLM_MASTER_KEY="sk-test"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
printf "%s" "{\"model\": \"sonnet\"}" > "$CLAUDE_SETTINGS"
REPOINT_OPUS=1; REPOINT_CODEX=1
apply_repoints
'
assert_eq "detect_existing_repoints setup: exits 0" "$(rc)" "0"
src_run "$h" '
ensure_dirs
REPOINT_OPUS=0; REPOINT_CODEX=0
detect_existing_repoints
printf "opus=%s codex=%s\n" "$REPOINT_OPUS" "$REPOINT_CODEX"
'
assert_grep "detect_existing_repoints: reads both repoints back" "opus=1 codex=1" "$TMP/out"

# --- restore_harnesses end-to-end --------------------------------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
configure_path
LITELLM_MASTER_KEY="sk-test"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
printf "%s" "{\"model\": \"sonnet\"}" > "$CLAUDE_SETTINGS"
mkdir -p "$CODEX_CONFIG_DIR"
printf "model = \"o3\"\n" > "$CODEX_CONFIG"
REPOINT_OPUS=1; REPOINT_CODEX=1
apply_repoints
'
assert_eq "restore_harnesses setup: exits 0" "$(rc)" "0"
src_run "$h" '
restore_harnesses
python3 -c "import json; print(json.load(open(\"$CLAUDE_SETTINGS\"))[\"model\"])"
cat "$CODEX_CONFIG"
printf "state-exists=%s\n" "$([ -f "$CLAUDE_STATE" ] && echo yes || echo no)"
'
assert_eq "restore_harnesses: exits 0" "$(rc)" "0"
assert_grep "restore_harnesses: claude model restored" "sonnet" "$TMP/out"
assert_grep "restore_harnesses: codex config restored" 'model = "o3"' "$TMP/out"
assert_not_grep "restore_harnesses: codex managed markers gone" "poolside-s21 managed" "$TMP/out"
assert_grep "restore_harnesses: claude state file removed" "state-exists=no" "$TMP/out"

# --- print_summary conditional lines -----------------------------------------

h=$(fresh_home)
src_run "$h" '
ensure_dirs
REPOINT_OPUS=0; REPOINT_CODEX=0
print_summary
'
assert_grep "print_summary: lists local commands" "claude-poolside" "$TMP/out"
assert_not_grep "print_summary: no repoint line when neither is set" "persistently routed" "$TMP/out"

h=$(fresh_home)
src_run "$h" '
ensure_dirs
REPOINT_OPUS=1; REPOINT_CODEX=1
print_summary
'
assert_grep "print_summary: mentions opus repoint when set" "Claude Code Opus is persistently routed" "$TMP/out"
assert_grep "print_summary: mentions codex repoint when set" "Codex CLI defaults are persistently routed" "$TMP/out"
assert_grep "print_summary: mentions --restore-harnesses when any repoint set" "restore-harnesses" "$TMP/out"

# --- summary -------------------------------------------------------------

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
