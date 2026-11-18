#!/bin/bash
# test-work-prep-citation-check.sh — recording-stub coverage for
# citation_check_block() in babysit-work-prep.sh: the deterministic
# lint-spec-citations pre-check wired into the spec-review-cycle prompts
# (cycle 1-3) as the __CITATION_CHECK__ placeholder. Verifies the function
# reports a clean verdict for a spec with only in-range citations, reports
# the stale citation(s) for a spec with a missing-file or line-out-of-range
# citation, and scopes its findings to the spec under review only (ignoring
# stale citations in an unrelated doc in the same tree).
#
# No network: gh is a stub on PATH; --dry-run plus HOME="$TMP" keeps the real
# lock file and sisyphus-logs untouched.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-work-prep.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else echo "  missing '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; fi; }
assert_not_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then echo "  unexpected '$2' in $3" >&2; sed 's/^/    /' "$3" >&2; fail "$1"; else pass "$1"; fi; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  case "$*" in *defaultBranchRef*) echo "main" ;; *) echo "o/r" ;; esac
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "user" ]; then echo "testuser"; exit 0; fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

run_citation_check() {
  local review_dir="$1" spec_path="$2" out="$3"
  ( PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
      WORK_PREP_TEST_MODE=citation-check \
      TEST_REVIEW_DIR="$review_dir" TEST_SPEC_PATH="$spec_path" \
      "$SCRIPT" --repo o/r --repo-base "$(dirname "$ROOT")" --dry-run ) > "$out" 2>/dev/null
}

# ---------- fixture tree ----------
# Deliberately does NOT contain a copy of lint-spec-citations: the target
# repository citation_check_block() runs against is the ticket's own repo,
# which has no reason to bundle this script's linter. --repo-base points
# SCRIPTS_DIR at the real $ROOT so the helper is found there instead.
REVIEW_DIR="$TMP/review"
mkdir -p "$REVIEW_DIR/specs"
printf '#!/bin/bash\necho one\necho two\necho three\n' > "$REVIEW_DIR/target.sh"

# ---------- clean spec: in-range citation ----------
cat > "$REVIEW_DIR/specs/clean.md" <<'EOF'
See target.sh:2 for the relevant line.
EOF
run_citation_check "$REVIEW_DIR" "specs/clean.md" "$TMP/clean.out"
assert_grep "clean spec reports no stale citations" \
  "lint-spec-citations: no stale file:line citations found in specs/clean.md." \
  "$TMP/clean.out"

# ---------- stale spec: line past end-of-file ----------
cat > "$REVIEW_DIR/specs/stale.md" <<'EOF'
See target.sh:50 for the relevant line.
EOF
run_citation_check "$REVIEW_DIR" "specs/stale.md" "$TMP/stale.out"
assert_grep "stale spec is flagged" \
  "lint-spec-citations flagged these file:line citations in specs/stale.md as stale" \
  "$TMP/stale.out"
assert_grep "stale finding names the offending citation" \
  "target.sh:50 -> cites line 50 but 'target.sh' has 4 lines" \
  "$TMP/stale.out"

# ---------- missing-file citation ----------
cat > "$REVIEW_DIR/specs/missing.md" <<'EOF'
See ghost.sh:1 for the relevant line.
EOF
run_citation_check "$REVIEW_DIR" "specs/missing.md" "$TMP/missing.out"
assert_grep "missing-file citation is flagged" \
  "ghost.sh:1 -> 'ghost.sh' does not exist" \
  "$TMP/missing.out"

# ---------- scoping: a stale citation in an unrelated doc must not leak in ----------
run_citation_check "$REVIEW_DIR" "specs/clean.md" "$TMP/scoped.out"
assert_not_grep "unrelated stale.md finding does not leak into clean.md's check" \
  "specs/stale.md" "$TMP/scoped.out"

# ---------- missing/broken linter: must report a failure, never a false "clean" ----------
( PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
    WORK_PREP_TEST_MODE=citation-check \
    TEST_REVIEW_DIR="$REVIEW_DIR" TEST_SPEC_PATH="specs/clean.md" \
    "$SCRIPT" --repo o/r --repo-base "$TMP/no-such-repo-base" --dry-run \
) > "$TMP/no-linter.out" 2>/dev/null
assert_grep "missing lint-spec-citations binary is reported as a failure, not clean" \
  "lint-spec-citations: execution failed" \
  "$TMP/no-linter.out"
assert_not_grep "missing-linter failure is never misreported as a clean verdict" \
  "no stale file:line citations found" \
  "$TMP/no-linter.out"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
