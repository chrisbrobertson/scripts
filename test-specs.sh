#!/bin/bash
# test-specs.sh — coverage for the `specs` helper.
#
# `specs` shipped with no test coverage at all, unlike every other script in
# this repo's file table. It's a pure, dependency-free Python script (no
# gh/network calls to stub), so this harness runs the real script end to end
# against small fixture trees built fresh per case under a tmpdir — each case
# cds into its own fixture root (the script scans Path.cwd()) and asserts on
# stdout and exit code.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/specs"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else echo "  expected '$3', got '$2'" >&2; fail "$1"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }

# run <fixture-dir> -- <script args...>: cds into the fixture dir (`specs`
# scans Path.cwd()) and runs the real script there.
run() {
  local dir="$1"; shift; shift  # drop the literal --
  ( cd "$dir" && "$SCRIPT" "$@" ) >"$TMP/out" 2>"$TMP/err"
  echo "$?" > "$TMP/rc"
}

spec() {
  # spec <path> <frontmatter-body> <doc-body>: writes a spec file with a
  # "---\n<frontmatter-body>\n---\n<doc-body>" shape.
  local path="$1" fm="$2" body="$3"
  mkdir -p "$(dirname "$path")"
  { printf -- '---\n%s\n---\n%s\n' "$fm" "$body"; } > "$path"
}

# ---------- basic listing: status + components columns ----------
d="$TMP/basic"; mkdir -p "$d/specs"
spec "$d/specs/a.md" $'status: approved\ncomponents:\n  - foo/' "Spec body."
run "$d" --
assert_eq "basic: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "basic: lists the spec path" "specs/a.md" "$TMP/out"
assert_grep "basic: shows its status" "approved" "$TMP/out"
assert_grep "basic: shows its components" "foo/" "$TMP/out"

# ---------- *-specs/ suffix directories are also discovered ----------
d="$TMP/suffix"; mkdir -p "$d/foo-specs"
spec "$d/foo-specs/b.md" "status: draft" "Body."
run "$d" --
assert_eq "suffix dir: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "suffix dir: finds spec under foo-specs/" "foo-specs/b.md" "$TMP/out"

# ---------- --status filter ----------
d="$TMP/status-filter"; mkdir -p "$d/specs"
spec "$d/specs/approved.md" "status: approved" "Body."
spec "$d/specs/draft.md" "status: draft" "Body."
run "$d" -- --status approved
assert_eq "status filter: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "status filter: includes the matching spec" "approved.md" "$TMP/out"
assert_not_grep "status filter: excludes the non-matching spec" "draft.md" "$TMP/out"

# ---------- --status filter with no matches ----------
d="$TMP/status-filter-empty"; mkdir -p "$d/specs"
spec "$d/specs/draft.md" "status: draft" "Body."
run "$d" -- --status approved
assert_eq "status filter empty: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "status filter empty: reports no specs found with that status" "No specs found with status: approved." "$TMP/out"

# ---------- no specs at all ----------
d="$TMP/no-specs"; mkdir -p "$d/specs"
run "$d" --
assert_eq "no specs: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "no specs: reports no specs found" "No specs found." "$TMP/out"

# ---------- --check-impl: components dir exists with a qualifying source file -> yes ----------
d="$TMP/impl-yes"; mkdir -p "$d/specs" "$d/foo"
spec "$d/specs/a.md" $'status: approved\ncomponents:\n  - foo/' "Body."
printf '#!/bin/bash\n' > "$d/foo/run.sh"
run "$d" -- --check-impl
assert_eq "impl-yes: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "impl-yes: reports yes" "yes" "$TMP/out"

# ---------- --check-impl: components dir exists but has no qualifying files -> no ----------
d="$TMP/impl-no"; mkdir -p "$d/specs" "$d/foo"
spec "$d/specs/a.md" $'status: approved\ncomponents:\n  - foo/' "Body."
printf 'just docs\n' > "$d/foo/README.md"
run "$d" -- --check-impl
assert_eq "impl-no: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "impl-no: reports no" "  no " "$TMP/out"

# ---------- --check-impl: components dir doesn't exist on disk -> unknown ----------
d="$TMP/impl-unknown"; mkdir -p "$d/specs"
spec "$d/specs/a.md" $'status: approved\ncomponents:\n  - missing/' "Body."
run "$d" -- --check-impl
assert_eq "impl-unknown: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "impl-unknown: reports ?" "  ?   " "$TMP/out"

# ---------- --check-impl: no components, falls back to backtick file refs in body ----------
d="$TMP/impl-fallback-yes"; mkdir -p "$d/specs"
spec "$d/specs/a.md" "status: approved" 'See `run.sh` for details.'
printf '#!/bin/bash\n' > "$d/run.sh"
run "$d" -- --check-impl
assert_eq "impl-fallback-yes: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "impl-fallback-yes: resolves the backtick-quoted ref to an existing file" "yes" "$TMP/out"

# ---------- --check-impl: backtick ref with a line-number suffix still resolves ----------
d="$TMP/impl-fallback-line-ref"; mkdir -p "$d/specs"
spec "$d/specs/a.md" "status: approved" 'See `run.sh:42` for details.'
printf '#!/bin/bash\n' > "$d/run.sh"
run "$d" -- --check-impl
assert_eq "impl-fallback-line-ref: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "impl-fallback-line-ref: strips the :LINE suffix before checking existence" "yes" "$TMP/out"

# ---------- --check-impl: no components and no backtick refs -> unknown ----------
d="$TMP/impl-fallback-unknown"; mkdir -p "$d/specs"
spec "$d/specs/a.md" "status: approved" "Nothing but prose here."
run "$d" -- --check-impl
assert_eq "impl-fallback-unknown: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "impl-fallback-unknown: reports ?" "  ?   " "$TMP/out"

# ---------- hidden directories (e.g. .git) are never walked into ----------
d="$TMP/hidden-dir"; mkdir -p "$d/.git/specs"
spec "$d/.git/specs/a.md" "status: approved" "Body."
run "$d" --
assert_eq "hidden dir: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "hidden dir: reports no specs found" "No specs found." "$TMP/out"

# ---------- --json: valid JSON with expected fields ----------
d="$TMP/json"; mkdir -p "$d/specs"
spec "$d/specs/a.md" $'status: approved\ncomponents:\n  - foo/' "Body."
run "$d" -- --json
assert_eq "json: exit 0" "$(cat "$TMP/rc")" "0"
python3 -c "
import json
specs = json.load(open('$TMP/out'))
assert len(specs) == 1, specs
s = specs[0]
assert s['path'] == 'specs/a.md', s
assert s['status'] == 'approved', s
assert s['components'] == ['foo/'], s
assert s['impl'] is None, s
" && pass "json: output is valid JSON with the expected fields" || fail "json: output is valid JSON with the expected fields"

# ---------- --help ----------
d="$TMP/help"; mkdir -p "$d"
run "$d" -- --help
assert_eq "help: exit 0" "$(cat "$TMP/rc")" "0"
assert_grep "help: documents usage" "usage:" "$TMP/out"
assert_grep "help: documents --check-impl" "--check-impl" "$TMP/out"

# ---------- unknown argument ----------
d="$TMP/unknown-arg"; mkdir -p "$d"
run "$d" -- --bogus
assert_eq "unknown argument: exit 2 (argparse error)" "$(cat "$TMP/rc")" "2"
assert_grep "unknown argument: reports the unrecognized flag" "unrecognized arguments: --bogus" "$TMP/err"

echo ""
echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
