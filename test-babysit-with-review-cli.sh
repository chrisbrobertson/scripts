#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/babysit-with-review.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

fail() {
  echo "not ok - $1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  echo "ok - $1"
  PASS=$((PASS + 1))
}

assert_contains() {
  local file="$1" expected="$2" name="$3"
  if grep -Fqx -- "$expected" "$file"; then pass "$name"; else
    echo "  expected line: $expected" >&2
    echo "  actual:" >&2
    sed 's/^/    /' "$file" >&2
    fail "$name"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2" name="$3"
  if grep -Fqx -- "$unexpected" "$file"; then
    echo "  unexpected line: $unexpected" >&2
    sed 's/^/    /' "$file" >&2
    fail "$name"
  else pass "$name"; fi
}

assert_review_rejected() {
  local name="$1" review="$2"
  set +e
  STUB_FINAL_RESULT="$review" run_script reviewer "$TMP/structure-rejected.record" "$TMP/home" --reviewer claude >/dev/null 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then pass "$name"; else fail "$name"; fi
}

assert_review_accepted() {
  local name="$1" review="$2"
  set +e
  STUB_FINAL_RESULT="$review" run_script reviewer "$TMP/structure-accepted.record" "$TMP/home" --reviewer claude >/dev/null 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name"; fi
}

make_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/bin/bash
printf '%s\n' 'CALL=claude' >> "$RECORD"
printf '<%s>\n' "$@" >> "$RECORD"
if [ -n "${STUB_RENAME_BRANCH:-}" ]; then
  git branch -m "$STUB_RENAME_BRANCH" 2>>"$RECORD" || true
fi
printf '{"type":"system","subtype":"init","session_id":"test-session"}\n'
result="${STUB_FINAL_RESULT:-FINAL_RESULT}"
result=${result//\\/\\\\}
result=${result//\"/\\\"}
result=${result//$'\n'/\\n}
printf '{"type":"result","result":"%s"}\n' "$result"
exit "${STUB_RC:-0}"
STUB
  cat > "$bin/codex" <<'STUB'
#!/bin/bash
printf '%s\n' 'CALL=codex' >> "$RECORD"
printf '<%s>\n' "$@" >> "$RECORD"
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then out="${2:-}"; shift 2; else shift; fi
done
echo "codex diagnostic output that must not become the final result"
if [ -n "$out" ]; then printf '%s\n' "${STUB_FINAL_RESULT:-FINAL_RESULT}" > "$out"; fi
exit "${STUB_RC:-0}"
STUB
  chmod +x "$bin/claude" "$bin/codex"
}

run_script() {
  local mode="$1" record="$2" home="$3"
  shift 3
  RECORD="$record" HOME="$home" PATH="$TMP/bin:/usr/bin:/bin" \
    BABYSIT_TEST_MODE="$mode" "$SCRIPT" "$@"
}

# Isolated repo with a bare "origin" remote and one commit on branch "main",
# already pushed (not ahead/behind). gh is not on PATH in these tests, so the
# pre-flight default-branch lookup falls back to its "main" default, matching
# this fixture's branch name.
make_preflight_repo() {
  local dir="$1"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/work" >/dev/null 2>&1
  (
    cd "$dir/work"
    git config user.email test@test.com
    git config user.name test
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo base > tracked.txt
    git add tracked.txt
    git commit -q -m init
    git push -q -u origin main
  )
}

# Runs the outer pre-flight checks (BABYSIT_TEST_MODE=outer-preflight) against
# a real repo directory, capturing stdout/stderr/rc for assertions.
run_preflight() {
  local repo_dir="$1" home="$2" out="$3" err="$4"
  set +e
  ( cd "$repo_dir" && HOME="$home" PATH="$TMP/bin:/usr/bin:/bin" \
      BABYSIT_TEST_MODE=outer-preflight "$SCRIPT" ) >"$out" 2>"$err"
  local rc=$?
  set -e
  return $rc
}

# Runs the real outer loop (no BABYSIT_TEST_MODE — an empty value skips the
# test-hook dispatch the same as unset) against a real repo directory, with
# claude/codex/gh stubbed on PATH. Used for QA-TEST-PLAN.md TC-1.1, which
# needs the actual per-iteration worktree/branch-rename mechanics, not a
# pure-function extraction. MAX_ITER/SLEEP_SEC are set by the caller via env.
run_single_iteration() {
  local repo_dir="$1" home="$2" record="$3" out="$4" err="$5"
  set +e
  ( cd "$repo_dir" && HOME="$home" PATH="$TMP/bin:/usr/bin:/bin" RECORD="$record" \
      BABYSIT_TEST_MODE="" "$SCRIPT" ) >"$out" 2>"$err"
  local rc=$?
  set -e
  return $rc
}

make_stubs "$TMP/bin"
mkdir -p "$TMP/home"

# Defaults remain Claude implementation and Codex review, with no explicit overrides.
run_script config "$TMP/default.record" "$TMP/home" > "$TMP/default.out"
assert_contains "$TMP/default.out" 'implementer=claude' 'default implementer is Claude'
assert_contains "$TMP/default.out" 'implementer_model=' 'default implementer model is implicit'
assert_contains "$TMP/default.out" 'implementer_effort=' 'default implementer effort is implicit'
assert_contains "$TMP/default.out" 'reviewer=codex' 'default reviewer is Codex'
assert_contains "$TMP/default.out" 'reviewer_model=' 'default reviewer model is implicit'
assert_contains "$TMP/default.out" 'reviewer_effort=' 'default reviewer effort is implicit'

# Both accepted value syntaxes parse and retain role isolation.
run_script config "$TMP/parse.record" "$TMP/home" \
  --implementer=codex --implementer-model impl-model --implementer-effort=high \
  --reviewer claude --reviewer-model=review-model --reviewer-effort low > "$TMP/parse.out"
assert_contains "$TMP/parse.out" 'implementer=codex' 'equals syntax parses implementer'
assert_contains "$TMP/parse.out" 'implementer_model=impl-model' 'separate syntax parses implementer model'
assert_contains "$TMP/parse.out" 'implementer_effort=high' 'equals syntax parses implementer effort'
assert_contains "$TMP/parse.out" 'reviewer=claude' 'separate syntax parses reviewer'
assert_contains "$TMP/parse.out" 'reviewer_model=review-model' 'equals syntax parses reviewer model'
assert_contains "$TMP/parse.out" 'reviewer_effort=low' 'separate syntax parses reviewer effort'

# Invalid harnesses and every missing/empty value fail before runtime side effects.
for args in \
  '--implementer nope' '--reviewer nope' \
  '--implementer' '--implementer-model' '--implementer-effort' \
  '--reviewer' '--reviewer-model' '--reviewer-effort' \
  '--implementer=' '--implementer-model=' '--implementer-effort=' \
  '--reviewer=' '--reviewer-model=' '--reviewer-effort='
do
  case_dir="$TMP/invalid-$PASS-$FAIL-${args//[^a-zA-Z0-9]/_}"
  mkdir -p "$case_dir/home"
  set +e
  # shellcheck disable=SC2086
  run_script config "$case_dir/record" "$case_dir/home" $args >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && [ ! -e "$case_dir/home/sisyphus-logs" ]; then
    pass "parse failure exits 2 without side effects: $args"
  else
    echo "  rc=$rc; log_dir=$([ -e "$case_dir/home/sisyphus-logs" ] && echo present || echo absent)" >&2
    fail "parse failure exits 2 without side effects: $args"
  fi
done

# A recognized wrapper option cannot be consumed as a separate-form value.
for args in \
  '--repo-base --help' \
  '--implementer --help' '--implementer-model --version' '--implementer-effort --reviewer' \
  '--reviewer --version' '--reviewer-model --implementer' '--reviewer-effort --repo-base=/tmp'
do
  case_dir="$TMP/option-as-value-${args//[^a-zA-Z0-9]/_}"
  mkdir -p "$case_dir/home"
  set +e
  # shellcheck disable=SC2086
  run_script config "$case_dir/record" "$case_dir/home" $args >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && [ ! -e "$case_dir/home/sisyphus-logs" ]; then
    pass "recognized option is rejected as a missing value: $args"
  else
    echo "  rc=$rc; log_dir=$([ -e "$case_dir/home/sisyphus-logs" ] && echo present || echo absent)" >&2
    fail "recognized option is rejected as a missing value: $args"
  fi
done

# Arbitrary model/effort strings beginning with '-' remain valid unless they
# are recognized wrapper options.
run_script config "$TMP/dash-values.record" "$TMP/home" \
  --implementer-model --provider-native-model --reviewer-effort=-provider-native-effort > "$TMP/dash-values.out"
assert_contains "$TMP/dash-values.out" 'implementer_model=--provider-native-model' 'unrecognized dash-prefixed model remains valid'
assert_contains "$TMP/dash-values.out" 'reviewer_effort=-provider-native-effort' 'unrecognized dash-prefixed effort remains valid'

# Default outer and remediation Claude models stay stage/cycle dependent.
: > "$TMP/impl-default.record"
run_script implementer-outer "$TMP/impl-default.record" "$TMP/home" > "$TMP/impl-default.out"
assert_contains "$TMP/impl-default.record" '<--model>' 'default outer implementer passes a model'
assert_contains "$TMP/impl-default.record" '<claude-sonnet-5>' 'default outer implementer retains Sonnet 5'
assert_contains "$TMP/impl-default.record" '<--dangerously-skip-permissions>' 'Claude implementer remains autonomous'
assert_not_contains "$TMP/impl-default.record" '<--effort>' 'default Claude implementer does not force effort'
assert_contains "$TMP/impl-default.out" 'FINAL_RESULT' 'Claude final stream result is captured'

: > "$TMP/impl-cycle.record"
BABYSIT_TEST_STAGE_MODEL=claude-opus-4-8 run_script implementer-remediation "$TMP/impl-cycle.record" "$TMP/home" > /dev/null
assert_contains "$TMP/impl-cycle.record" '<claude-opus-4-8>' 'default remediation keeps cycle-selected model'

# Explicit Claude implementation settings override stage defaults and forward effort.
: > "$TMP/impl-claude.record"
run_script implementer-remediation "$TMP/impl-claude.record" "$TMP/home" \
  --implementer claude --implementer-model custom-impl --implementer-effort=max > /dev/null
assert_contains "$TMP/impl-claude.record" '<custom-impl>' 'explicit Claude model overrides cycle default'
assert_not_contains "$TMP/impl-claude.record" '<claude-sonnet-5>' 'explicit Claude model excludes stage default'
assert_contains "$TMP/impl-claude.record" '<--effort>' 'Claude implementation forwards effort flag'
assert_contains "$TMP/impl-claude.record" '<max>' 'Claude implementation forwards effort value'

# Codex implementation is autonomous and captures only --output-last-message.
: > "$TMP/impl-codex.record"
run_script implementer-outer "$TMP/impl-codex.record" "$TMP/home" \
  --implementer=codex --implementer-model=codex-impl --implementer-effort=xhigh > "$TMP/impl-codex.out"
assert_contains "$TMP/impl-codex.record" '<exec>' 'Codex implementer uses exec'
assert_contains "$TMP/impl-codex.record" '<--dangerously-bypass-approvals-and-sandbox>' 'Codex implementer gets full autonomous access'
assert_contains "$TMP/impl-codex.record" '<--model>' 'Codex implementation forwards model flag'
assert_contains "$TMP/impl-codex.record" '<codex-impl>' 'Codex implementation forwards model value'
assert_contains "$TMP/impl-codex.record" '<model_reasoning_effort="xhigh">' 'Codex implementation maps reasoning effort'
assert_contains "$TMP/impl-codex.out" 'FINAL_RESULT' 'Codex final message is captured'
if grep -q 'diagnostic output' "$TMP/impl-codex.out"; then fail 'Codex logging does not corrupt final capture'; else pass 'Codex logging does not corrupt final capture'; fi

# Codex review stays read-only, forwards only reviewer settings, including preflight.
STRICT=$'## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
: > "$TMP/review-codex.record"
STUB_FINAL_RESULT="$STRICT" run_script reviewer "$TMP/review-codex.record" "$TMP/home" \
  --implementer claude --implementer-model=do-not-leak --implementer-effort=max \
  --reviewer codex --reviewer-model review-codex --reviewer-effort=medium > "$TMP/review-codex.out"
assert_contains "$TMP/review-codex.record" '<-s>' 'Codex reviewer sets sandbox'
assert_contains "$TMP/review-codex.record" '<read-only>' 'Codex reviewer remains read-only'
assert_contains "$TMP/review-codex.record" '<review-codex>' 'Codex reviewer forwards reviewer model'
assert_contains "$TMP/review-codex.record" '<model_reasoning_effort="medium">' 'Codex reviewer maps reviewer effort'
assert_not_contains "$TMP/review-codex.record" '<do-not-leak>' 'implementer model does not leak to reviewer'
assert_not_contains "$TMP/review-codex.record" '<--dangerously-bypass-approvals-and-sandbox>' 'reviewer never gets implementation permissions'
assert_contains "$TMP/review-codex.out" '## BLOCKING' 'Codex strict review final output is captured'

: > "$TMP/review-codex-default.record"
STUB_FINAL_RESULT="$STRICT" run_script reviewer "$TMP/review-codex-default.record" "$TMP/home" > /dev/null
assert_not_contains "$TMP/review-codex-default.record" '<--model>' 'default Codex reviewer does not override configured model'
assert_not_contains "$TMP/review-codex-default.record" '<-c>' 'default Codex reviewer does not override configured effort'

: > "$TMP/preflight.record"
run_script reviewer-preflight "$TMP/preflight.record" "$TMP/home" \
  --reviewer=codex --reviewer-model=review-codex --reviewer-effort=medium > /dev/null
assert_contains "$TMP/preflight.record" '<review-codex>' 'Codex preflight forwards reviewer model'
assert_contains "$TMP/preflight.record" '<model_reasoning_effort="medium">' 'Codex preflight forwards reviewer effort'
assert_contains "$TMP/preflight.record" '<read-only>' 'Codex preflight remains read-only'

# Claude review is non-mutating, role-isolated, and subject to strict validation.
: > "$TMP/review-claude.record"
STUB_FINAL_RESULT="$STRICT" run_script reviewer "$TMP/review-claude.record" "$TMP/home" \
  --implementer codex --implementer-model=do-not-leak \
  --reviewer=claude --reviewer-model=review-claude --reviewer-effort=high > "$TMP/review-claude.out"
assert_contains "$TMP/review-claude.record" '<--permission-mode>' 'Claude reviewer sets permission mode'
assert_contains "$TMP/review-claude.record" '<plan>' 'Claude reviewer uses non-mutating plan mode'
assert_contains "$TMP/review-claude.record" '<review-claude>' 'Claude reviewer forwards reviewer model'
assert_contains "$TMP/review-claude.record" '<--effort>' 'Claude reviewer forwards effort flag'
assert_contains "$TMP/review-claude.record" '<high>' 'Claude reviewer forwards effort value'
assert_not_contains "$TMP/review-claude.record" '<do-not-leak>' 'implementer settings do not leak to Claude reviewer'
assert_not_contains "$TMP/review-claude.record" '<--dangerously-skip-permissions>' 'Claude reviewer is not given implementation bypass'
assert_contains "$TMP/review-claude.out" '## INFORMATION' 'Claude strict review final output is captured'

set +e
STUB_FINAL_RESULT='not a strict review' run_script reviewer "$TMP/review-invalid.record" "$TMP/home" --reviewer claude >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then pass 'Claude review fails closed on invalid structure'; else fail 'Claude review fails closed on invalid structure'; fi

# Strict structure is fail-closed: each core section appears exactly once, in
# order, and has at least one explicit top-level bullet.
assert_review_rejected 'review rejects headings with no bullets' \
  $'## BLOCKING\n## RECOMMENDED\n## INFORMATION'
assert_review_rejected 'review rejects bulletless BLOCKING section' \
  $'## BLOCKING\nexplanation without a finding bullet\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects bulletless RECOMMENDED section' \
  $'## BLOCKING\n- (none)\n## RECOMMENDED\ncontext only\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects bulletless INFORMATION section' \
  $'## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\n## INFORMATION\ncontext only'
assert_review_rejected 'review rejects duplicate core heading' \
  $'## BLOCKING\n- (none)\n## BLOCKING\n- duplicate\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects out-of-order core headings' \
  $'## RECOMMENDED\n- (none)\n## BLOCKING\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects critical prose inside BLOCKING' \
  $'## BLOCKING\n- (none)\nCRITICAL: this must be fixed\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects critical trailing prose after INFORMATION' \
  $'## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)\nCRITICAL: do not merge'
assert_review_rejected 'review rejects prose before core headings' \
  $'Review follows.\n## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects prose between core sections' \
  $'## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\nThis warning is not a bullet.\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects unknown top-level heading' \
  $'## SUMMARY\n- not part of the contract\n## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects indented critical continuation after BLOCKING none' \
  $'## BLOCKING\n- (none)\n  CRITICAL: this must be fixed\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects additional BLOCKING bullet after none' \
  $'## BLOCKING\n- (none)\n- CRITICAL: this must be fixed\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects none after a real RECOMMENDED bullet' \
  $'## BLOCKING\n- (none)\n## RECOMMENDED\n- real recommendation\n- (none)\n## INFORMATION\n- (none)'
assert_review_rejected 'review rejects indented continuation after INFORMATION none' \
  $'## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)\n  CRITICAL: do not merge'
assert_review_rejected 'review rejects indented continuation after ADJUDICATION none' \
  $'## ADJUDICATION\n- (none)\n  hidden adjudication\n## BLOCKING\n- (none)\n## RECOMMENDED\n- (none)\n## INFORMATION\n- (none)'

assert_review_accepted 'review accepts prescriptive multiline blocking finding' \
  $'## BLOCKING\n- [NEW] fail closed — script:1 — unsafe parser\n  Suggested fix: validate sections\n  Root cause: header-only validation\n  Architectural context: merge gate\n  Impact: unsafe merge\n## RECOMMENDED\n- (none)\n## INFORMATION\n- useful context'
assert_review_accepted 'review accepts leading ADJUDICATION section' \
  $'## ADJUDICATION\n- BLOCKING old issue: ACCEPTED — fixed\n  Evidence: commit abc123 resolves it\n\n## BLOCKING\n- (none)\n\n## RECOMMENDED\n- (none)\n\n## INFORMATION\n- (none)'
assert_review_accepted 'review accepts multiple real findings with indented details' \
  $'## BLOCKING\n- first finding\n  Suggested fix: first fix\n- second finding\n  Suggested fix: second fix\n## RECOMMENDED\n- first recommendation\n- second recommendation\n## INFORMATION\n- context'

# Same-provider roles are allowed and still independently configured.
run_script config "$TMP/same-role.record" "$TMP/home" \
  --implementer=codex --implementer-model=implementation-only \
  --reviewer=codex --reviewer-model=review-only > "$TMP/same-role.out"
assert_contains "$TMP/same-role.out" 'implementer=codex' 'same harness is allowed for implementer'
assert_contains "$TMP/same-role.out" 'reviewer=codex' 'same harness is allowed for reviewer'
assert_contains "$TMP/same-role.out" 'implementer_model=implementation-only' 'same-harness implementer model remains isolated'
assert_contains "$TMP/same-role.out" 'reviewer_model=review-only' 'same-harness reviewer model remains isolated'

: > "$TMP/codex-remediation.record"
run_script implementer-remediation "$TMP/codex-remediation.record" "$TMP/home" \
  --implementer codex --implementer-model remediation-codex > /dev/null
assert_contains "$TMP/codex-remediation.record" '<remediation-codex>' 'Codex selection also applies to remediation passes'

# Graceful review availability checks the selected reviewer, not always Codex.
mv "$TMP/bin/codex" "$TMP/bin/codex.off"
run_script reviewer-availability "$TMP/availability.record" "$TMP/home" --reviewer codex > "$TMP/availability.out"
run_script reviewer-availability "$TMP/availability-claude.record" "$TMP/home" --reviewer claude > "$TMP/availability-claude.out"
mv "$TMP/bin/codex.off" "$TMP/bin/codex"
assert_contains "$TMP/availability.out" 'missing_reviewer=codex' 'missing selected reviewer is detected gracefully'
assert_contains "$TMP/availability-claude.out" 'available_reviewer=claude' 'available selected reviewer is used even when Codex is missing'

# QA-TEST-PLAN.md TC-2.9: run_review_cycle's own graceful-degradation path
# (not just the reviewer_binary_available() predicate above) — verifies the
# exact skip message and that the cycle returns 0 (PR left open) rather than
# erroring, with no gh call attempted (none stubbed on PATH here).
mv "$TMP/bin/codex" "$TMP/bin/codex.off"
run_script review-cycle-missing-reviewer "$TMP/missing-reviewer.record" "$TMP/home" \
  --reviewer codex > "$TMP/missing-reviewer.out" 2>"$TMP/missing-reviewer.err"
mv "$TMP/bin/codex.off" "$TMP/bin/codex"
assert_contains "$TMP/missing-reviewer.out" 'run_review_cycle_rc=0' \
  'run_review_cycle returns 0 when reviewer CLI is missing'
assert_contains "$TMP/missing-reviewer.err" \
  '  [review] codex CLI not found; skipping review cycle (PR #7 remains open for external review)' \
  'run_review_cycle logs the graceful-degradation skip message'

# Displayed/logged model policy distinguishes Claude stage defaults from Codex
# configured defaults, including remediation passes.
run_script model-policy "$TMP/policy-claude.record" "$TMP/home" --implementer claude > "$TMP/policy-claude.out"
assert_contains "$TMP/policy-claude.out" 'startup_model=stage-default' 'default Claude startup model policy is stage-default'
assert_contains "$TMP/policy-claude.out" 'remediation_model=claude-opus-4-8' 'default Claude remediation log uses cycle model'
run_script model-policy "$TMP/policy-codex.record" "$TMP/home" --implementer codex > "$TMP/policy-codex.out"
assert_contains "$TMP/policy-codex.out" 'startup_model=configured-default' 'default Codex startup model policy is configured-default'
assert_contains "$TMP/policy-codex.out" 'remediation_model=configured-default' 'default Codex remediation log uses configured-default'
run_script model-policy "$TMP/policy-explicit.record" "$TMP/home" --implementer codex --implementer-model explicit-model > "$TMP/policy-explicit.out"
assert_contains "$TMP/policy-explicit.out" 'startup_model=explicit-model' 'explicit implementer model appears in startup policy'
assert_contains "$TMP/policy-explicit.out" 'remediation_model=explicit-model' 'explicit implementer model appears in remediation policy'

if "$SCRIPT" --help | grep -q -- '--implementer MODEL'; then fail 'help labels harness as model'; else pass 'help does not confuse harness with model'; fi
for option in implementer implementer-model implementer-effort reviewer reviewer-model reviewer-effort; do
  if "$SCRIPT" --help | grep -q -- "--$option"; then pass "help documents --$option"; else fail "help documents --$option"; fi
done

# Pre-flight checks: converts QA-TEST-PLAN.md Suite 1 manual smoke tests
# (clean-tree/branch/ahead-behind gating) into deterministic coverage. No
# Claude/Codex/gh involved; gh is intentionally absent from PATH so the
# default-branch lookup falls back to "main", matching make_preflight_repo.
mkdir -p "$TMP/preflight/home"

mkdir -p "$TMP/preflight/clean"
make_preflight_repo "$TMP/preflight/clean" >/dev/null 2>&1
rc=0
run_preflight "$TMP/preflight/clean/work" "$TMP/preflight/home" \
  "$TMP/preflight/clean.out" "$TMP/preflight/clean.err" || rc=$?
[ "$rc" -eq 0 ] && pass 'preflight: clean repo on default branch exits 0' || fail 'preflight: clean repo on default branch exits 0'
assert_contains "$TMP/preflight/clean.out" 'PREFLIGHT_OK branch=main' 'preflight: reports resolved default branch'

mkdir -p "$TMP/preflight/unstaged"
make_preflight_repo "$TMP/preflight/unstaged" >/dev/null 2>&1
echo modified >> "$TMP/preflight/unstaged/work/tracked.txt"
rc=0
run_preflight "$TMP/preflight/unstaged/work" "$TMP/preflight/home" \
  "$TMP/preflight/unstaged.out" "$TMP/preflight/unstaged.err" || rc=$?
[ "$rc" -eq 1 ] && pass 'preflight: unstaged modification exits 1' || fail 'preflight: unstaged modification exits 1'
if grep -q 'unstaged modifications' "$TMP/preflight/unstaged.err"; then pass 'preflight: unstaged modification error names the cause'; else fail 'preflight: unstaged modification error names the cause'; fi

mkdir -p "$TMP/preflight/staged"
make_preflight_repo "$TMP/preflight/staged" >/dev/null 2>&1
echo modified >> "$TMP/preflight/staged/work/tracked.txt"
(cd "$TMP/preflight/staged/work" && git add tracked.txt)
rc=0
run_preflight "$TMP/preflight/staged/work" "$TMP/preflight/home" \
  "$TMP/preflight/staged.out" "$TMP/preflight/staged.err" || rc=$?
[ "$rc" -eq 1 ] && pass 'preflight: staged uncommitted change exits 1' || fail 'preflight: staged uncommitted change exits 1'
if grep -q 'staged but uncommitted changes' "$TMP/preflight/staged.err"; then pass 'preflight: staged change error names the cause'; else fail 'preflight: staged change error names the cause'; fi

mkdir -p "$TMP/preflight/untracked"
make_preflight_repo "$TMP/preflight/untracked" >/dev/null 2>&1
echo new > "$TMP/preflight/untracked/work/extra.txt"
rc=0
run_preflight "$TMP/preflight/untracked/work" "$TMP/preflight/home" \
  "$TMP/preflight/untracked.out" "$TMP/preflight/untracked.err" || rc=$?
[ "$rc" -eq 1 ] && pass 'preflight: untracked non-ignored file exits 1' || fail 'preflight: untracked non-ignored file exits 1'
if grep -q 'untracked non-ignored file' "$TMP/preflight/untracked.err"; then pass 'preflight: untracked file error names the cause'; else fail 'preflight: untracked file error names the cause'; fi

mkdir -p "$TMP/preflight/otherbranch"
make_preflight_repo "$TMP/preflight/otherbranch" >/dev/null 2>&1
(cd "$TMP/preflight/otherbranch/work" && git checkout -q -b wip/other)
rc=0
run_preflight "$TMP/preflight/otherbranch/work" "$TMP/preflight/home" \
  "$TMP/preflight/otherbranch.out" "$TMP/preflight/otherbranch.err" || rc=$?
[ "$rc" -eq 0 ] && pass 'preflight: clean non-default branch auto-switches and exits 0' || fail 'preflight: clean non-default branch auto-switches and exits 0'
assert_contains "$TMP/preflight/otherbranch.out" 'PREFLIGHT_OK branch=main' 'preflight: auto-switch lands back on default branch'
if grep -q "switching from 'wip/other' to default branch 'main'" "$TMP/preflight/otherbranch.err"; then pass 'preflight: auto-switch is logged'; else fail 'preflight: auto-switch is logged'; fi

mkdir -p "$TMP/preflight/ahead"
make_preflight_repo "$TMP/preflight/ahead" >/dev/null 2>&1
(cd "$TMP/preflight/ahead/work" && git commit -q --allow-empty -m "local only, unpushed")
rc=0
run_preflight "$TMP/preflight/ahead/work" "$TMP/preflight/home" \
  "$TMP/preflight/ahead.out" "$TMP/preflight/ahead.err" || rc=$?
[ "$rc" -eq 1 ] && pass 'preflight: ahead of origin exits 1' || fail 'preflight: ahead of origin exits 1'
if grep -q 'ahead of origin/main' "$TMP/preflight/ahead.err"; then pass 'preflight: ahead-of-origin error names the cause'; else fail 'preflight: ahead-of-origin error names the cause'; fi

mkdir -p "$TMP/preflight/behind"
make_preflight_repo "$TMP/preflight/behind" >/dev/null 2>&1
mkdir -p "$TMP/preflight/behind/pusher"
git clone -q "$TMP/preflight/behind/origin.git" "$TMP/preflight/behind/pusher/work" >/dev/null 2>&1
(
  cd "$TMP/preflight/behind/pusher/work"
  git config user.email test@test.com
  git config user.name test
  git checkout -q main
  echo remote-change >> tracked.txt
  git add tracked.txt
  git commit -q -m "remote-only commit"
  git push -q origin main
)
rc=0
run_preflight "$TMP/preflight/behind/work" "$TMP/preflight/home" \
  "$TMP/preflight/behind.out" "$TMP/preflight/behind.err" || rc=$?
[ "$rc" -eq 0 ] && pass 'preflight: behind origin fast-forwards and exits 0' || fail 'preflight: behind origin fast-forwards and exits 0'
if grep -q "is 1 commit(s) behind origin; fast-forwarding" "$TMP/preflight/behind.err"; then pass 'preflight: fast-forward is logged'; else fail 'preflight: fast-forward is logged'; fi
if [ "$(cd "$TMP/preflight/behind/work" && git log --format=%s -1)" = "remote-only commit" ]; then pass 'preflight: fast-forward actually advances local branch'; else fail 'preflight: fast-forward actually advances local branch'; fi

mkdir -p "$TMP/preflight/diverged"
make_preflight_repo "$TMP/preflight/diverged" >/dev/null 2>&1
mkdir -p "$TMP/preflight/diverged/pusher"
git clone -q "$TMP/preflight/diverged/origin.git" "$TMP/preflight/diverged/pusher/work" >/dev/null 2>&1
(
  cd "$TMP/preflight/diverged/pusher/work"
  git config user.email test@test.com
  git config user.name test
  git checkout -q main
  git commit -q --allow-empty -m "remote-only commit"
  git push -q origin main
)
(cd "$TMP/preflight/diverged/work" && git commit -q --allow-empty -m "local-only commit")
rc=0
run_preflight "$TMP/preflight/diverged/work" "$TMP/preflight/home" \
  "$TMP/preflight/diverged.out" "$TMP/preflight/diverged.err" || rc=$?
[ "$rc" -eq 1 ] && pass 'preflight: diverged from origin exits 1' || fail 'preflight: diverged from origin exits 1'
if grep -q 'diverged from origin/main' "$TMP/preflight/diverged.err"; then pass 'preflight: diverged error names the cause'; else fail 'preflight: diverged error names the cause'; fi

# Lock file collision: converts QA-TEST-PLAN.md TC-1.3 (lock file semantics)
# into deterministic coverage. The STOP_FILE collision check runs unconditionally
# before argument-mode dispatch and before any git/pre-flight work, so it needs
# neither a git repo nor claude/codex/gh stubs — a bare cwd is enough. Covers
# both AT3 (pre-existing stop file is a collision, exit 1) and AT3b (no
# pre-existing stop file lets startup proceed) from
# L3-autonomous-outer-loop.md.
mkdir -p "$TMP/lockfile/proj" "$TMP/lockfile/home/sisyphus-logs"
touch "$TMP/lockfile/home/sisyphus-logs/proj.stop"
rc=0
( cd "$TMP/lockfile/proj" && HOME="$TMP/lockfile/home" PATH="$TMP/bin:/usr/bin:/bin" \
    BABYSIT_TEST_MODE=outer-preflight "$SCRIPT" ) \
  >"$TMP/lockfile/collision.out" 2>"$TMP/lockfile/collision.err" || rc=$?
[ "$rc" -eq 1 ] && pass 'lock file: pre-existing stop file is a collision, exits 1 (TC-1.3 AT3)' || fail 'lock file: pre-existing stop file is a collision, exits 1 (TC-1.3 AT3)'
assert_contains "$TMP/lockfile/collision.err" "ERROR: $TMP/lockfile/home/sisyphus-logs/proj.stop already exists." 'lock file: collision error names the existing lock path (TC-1.3 AT3)'

mkdir -p "$TMP/lockfile/nocollision" "$TMP/lockfile/home2"
make_preflight_repo "$TMP/lockfile/nocollision" >/dev/null 2>&1
rc=0
run_preflight "$TMP/lockfile/nocollision/work" "$TMP/lockfile/home2" \
  "$TMP/lockfile/nocollision.out" "$TMP/lockfile/nocollision.err" || rc=$?
[ "$rc" -eq 0 ] && pass 'lock file: no pre-existing stop file lets startup proceed (TC-1.3 AT3b)' || fail 'lock file: no pre-existing stop file lets startup proceed (TC-1.3 AT3b)'
assert_contains "$TMP/lockfile/nocollision.out" 'PREFLIGHT_OK branch=main' 'lock file: first iteration setup reaches pre-flight (TC-1.3 AT3b)'

# Sentinel detection: converts QA-TEST-PLAN.md Suite 1 TC-1.5 (STOP halts the
# loop) and TC-1.6 (HANDOFF_REVIEW <PR> triggers a review cycle) into
# deterministic coverage. outer-sentinel feeds one simulated iteration's
# implementer RESULT via stdin through the real parse_sentinel() function
# extracted from the outer loop; no Claude/Codex/gh involved.
: > "$TMP/sentinel-stop.record"
printf 'did some work\nSTOP' | run_script outer-sentinel "$TMP/sentinel-stop.record" "$TMP/home" > "$TMP/sentinel-stop.out"
assert_contains "$TMP/sentinel-stop.out" 'STOP' 'sentinel: bare STOP on last line is detected'

: > "$TMP/sentinel-handoff.record"
printf 'opened a PR\nHANDOFF_REVIEW 123' | run_script outer-sentinel "$TMP/sentinel-handoff.record" "$TMP/home" > "$TMP/sentinel-handoff.out"
assert_contains "$TMP/sentinel-handoff.out" 'HANDOFF_REVIEW 123' 'sentinel: HANDOFF_REVIEW <PR> extracts the bare PR number'

: > "$TMP/sentinel-handoff-space.record"
printf 'HANDOFF_REVIEW 42 \n' | run_script outer-sentinel "$TMP/sentinel-handoff-space.record" "$TMP/home" > "$TMP/sentinel-handoff-space.out"
assert_contains "$TMP/sentinel-handoff-space.out" 'HANDOFF_REVIEW 42' 'sentinel: trailing whitespace after the PR number is trimmed'

: > "$TMP/sentinel-invalid.record"
printf 'HANDOFF_REVIEW abc' | run_script outer-sentinel "$TMP/sentinel-invalid.record" "$TMP/home" > "$TMP/sentinel-invalid.out"
assert_contains "$TMP/sentinel-invalid.out" 'HANDOFF_REVIEW_INVALID abc' 'sentinel: non-numeric PR is classified invalid, not acted on'

: > "$TMP/sentinel-none.record"
printf 'still working, no sentinel yet' | run_script outer-sentinel "$TMP/sentinel-none.record" "$TMP/home" > "$TMP/sentinel-none.out"
assert_contains "$TMP/sentinel-none.out" 'NONE' 'sentinel: ordinary output with no sentinel line is classified NONE'

: > "$TMP/sentinel-mid-text.record"
printf 'STOP\nbut then kept talking' | run_script outer-sentinel "$TMP/sentinel-mid-text.record" "$TMP/home" > "$TMP/sentinel-mid-text.out"
assert_contains "$TMP/sentinel-mid-text.out" 'NONE' 'sentinel: STOP is only honored on the final line, not mid-output'

# MAX_ITER exhaustion: converts QA-TEST-PLAN.md Suite 1 TC-1.8 (loop exits
# with "Hit MAX_ITER" after MAX_ITER iterations without an earlier STOP) into
# deterministic coverage. outer-maxiter feeds simulated post-iteration
# counters through the real maxiter_exhausted() function extracted from the
# outer loop; no Claude/Codex/gh involved.
: > "$TMP/maxiter-reached.record"
printf '1\n2\n3\n4\n5\n' | MAX_ITER=5 run_script outer-maxiter "$TMP/maxiter-reached.record" "$TMP/home" > "$TMP/maxiter-reached.out"
assert_contains "$TMP/maxiter-reached.out" 'iter=5 exhausted=1' 'max-iter: exhaustion fires once iter reaches MAX_ITER'
assert_not_contains "$TMP/maxiter-reached.out" 'iter=4 exhausted=1' 'max-iter: exhaustion does not fire before MAX_ITER'

: > "$TMP/maxiter-not-reached.record"
printf '4\n' | MAX_ITER=5 run_script outer-maxiter "$TMP/maxiter-not-reached.record" "$TMP/home" > "$TMP/maxiter-not-reached.out"
assert_contains "$TMP/maxiter-not-reached.out" 'iter=4 exhausted=0' 'max-iter: an early break (iter < MAX_ITER) is not exhaustion'

: > "$TMP/maxiter-past.record"
printf '6\n' | MAX_ITER=5 run_script outer-maxiter "$TMP/maxiter-past.record" "$TMP/home" > "$TMP/maxiter-past.out"
assert_contains "$TMP/maxiter-past.out" 'iter=6 exhausted=1' 'max-iter: uses >= so a counter past MAX_ITER still counts as exhausted'

# Lock file removal mid-run: converts QA-TEST-PLAN.md Suite 1 TC-1.4 (removing
# the stop file mid-run causes the loop to exit gracefully) into deterministic
# coverage. outer-lockfile-removed feeds stop-file paths through the real
# stop_file_removed() function extracted from the outer loop's per-iteration
# check; no Claude/Codex/gh involved.
lockfile_path="$TMP/lockfile-removed-mid-run.stop"
touch "$lockfile_path"
: > "$TMP/lockfile-removed.record"
printf '%s\n' "$lockfile_path" | run_script outer-lockfile-removed "$TMP/lockfile-removed.record" "$TMP/home" > "$TMP/lockfile-removed.before.out"
assert_contains "$TMP/lockfile-removed.before.out" "path=$lockfile_path removed=0" 'lock file removal: still present mid-run is not treated as removed (TC-1.4)'

rm -f "$lockfile_path"
printf '%s\n' "$lockfile_path" | run_script outer-lockfile-removed "$TMP/lockfile-removed.record" "$TMP/home" > "$TMP/lockfile-removed.after.out"
assert_contains "$TMP/lockfile-removed.after.out" "path=$lockfile_path removed=1" 'lock file removal: removing the stop file mid-run is detected (TC-1.4)'

# Blocking-finding count: converts the branch point behind QA-TEST-PLAN.md
# TC-2.1 (Codex review with N>0 BLOCKING findings triggers the
# addressing-findings path) and TC-2.2 (zero BLOCKING findings triggers
# auto-merge) into deterministic coverage. review-blocking-count feeds a
# review markdown document on stdin through the real count_blocking()
# function used by run_review_cycle; no Claude/Codex/gh involved.
: > "$TMP/blocking-count-none-bullet.record"
printf '## BLOCKING\n- (none)\n\n## RECOMMENDED\n- (none)\n' \
  | run_script review-blocking-count "$TMP/blocking-count-none-bullet.record" "$TMP/home" > "$TMP/blocking-count-none-bullet.out"
assert_contains "$TMP/blocking-count-none-bullet.out" '0' 'blocking count: a sole "- (none)" bullet under BLOCKING counts as zero (TC-2.2)'

: > "$TMP/blocking-count-one.record"
printf '## BLOCKING\n- undefined variable used at line 42\n\n## RECOMMENDED\n- (none)\n' \
  | run_script review-blocking-count "$TMP/blocking-count-one.record" "$TMP/home" > "$TMP/blocking-count-one.out"
assert_contains "$TMP/blocking-count-one.out" '1' 'blocking count: a single real BLOCKING bullet counts as one (TC-2.1)'

: > "$TMP/blocking-count-multi.record"
printf '## BLOCKING\n- finding one\n  indented continuation detail\n- finding two\n\n## RECOMMENDED\n- (none)\n' \
  | run_script review-blocking-count "$TMP/blocking-count-multi.record" "$TMP/home" > "$TMP/blocking-count-multi.out"
assert_contains "$TMP/blocking-count-multi.out" '2' 'blocking count: multiple BLOCKING bullets count once each, ignoring indented continuation lines (TC-2.1)'

: > "$TMP/blocking-count-other-sections.record"
printf '## BLOCKING\n- (none)\n\n## RECOMMENDED\n- non-blocking finding\n- another one\n' \
  | run_script review-blocking-count "$TMP/blocking-count-other-sections.record" "$TMP/home" > "$TMP/blocking-count-other-sections.out"
assert_contains "$TMP/blocking-count-other-sections.out" '0' 'blocking count: bullets under RECOMMENDED are not counted as BLOCKING'

: > "$TMP/blocking-count-no-section.record"
printf '## RECOMMENDED\n- (none)\n\n## INFORMATION\n- (none)\n' \
  | run_script review-blocking-count "$TMP/blocking-count-no-section.record" "$TMP/home" > "$TMP/blocking-count-no-section.out"
assert_contains "$TMP/blocking-count-no-section.out" '0' 'blocking count: a review with no BLOCKING heading at all counts as zero'

# Review-cycle sentinel detection: converts QA-TEST-PLAN.md Suite 2 TC-2.4
# (STUCK_REVIEW bails the review cycle) into deterministic coverage.
# review-sentinel feeds one simulated implementer RESULT via stdin through
# the real parse_review_sentinel() function extracted from run_review_cycle;
# no Claude/Codex/gh involved.
: > "$TMP/review-sentinel-stuck.record"
printf 'tried a few things\nSTUCK_REVIEW cannot fix without external API change' \
  | run_script review-sentinel "$TMP/review-sentinel-stuck.record" "$TMP/home" > "$TMP/review-sentinel-stuck.out"
assert_contains "$TMP/review-sentinel-stuck.out" 'STUCK_REVIEW cannot fix without external API change' 'review sentinel: STUCK_REVIEW on last line is detected with its reason (TC-2.4)'

: > "$TMP/review-sentinel-done.record"
printf 'addressed the findings\nDONE_REVIEW' \
  | run_script review-sentinel "$TMP/review-sentinel-done.record" "$TMP/home" > "$TMP/review-sentinel-done.out"
assert_contains "$TMP/review-sentinel-done.out" 'DONE_REVIEW' 'review sentinel: bare DONE_REVIEW on last line is detected'

: > "$TMP/review-sentinel-none.record"
printf 'still working, no sentinel yet' \
  | run_script review-sentinel "$TMP/review-sentinel-none.record" "$TMP/home" > "$TMP/review-sentinel-none.out"
assert_contains "$TMP/review-sentinel-none.out" 'NONE' 'review sentinel: ordinary output with no sentinel line is classified NONE, treated as DONE_REVIEW by the caller'

: > "$TMP/review-sentinel-mid-text.record"
printf 'STUCK_REVIEW blocked\nbut then kept talking' \
  | run_script review-sentinel "$TMP/review-sentinel-mid-text.record" "$TMP/home" > "$TMP/review-sentinel-mid-text.out"
assert_contains "$TMP/review-sentinel-mid-text.out" 'NONE' 'review sentinel: STUCK_REVIEW is only honored on the final line, not mid-output'

# HEAD-unchanged defensive check: converts QA-TEST-PLAN.md Suite 2 TC-2.5
# (DONE_REVIEW with no commits made bails the review cycle) into
# deterministic coverage. review-head-unchanged feeds "pre_sha post_sha"
# pairs on stdin through the real review_head_unchanged() function extracted
# from run_review_cycle; no Claude/Codex/gh involved.
: > "$TMP/review-head-unchanged.record"
printf 'abc123 abc123\n' \
  | run_script review-head-unchanged "$TMP/review-head-unchanged.record" "$TMP/home" > "$TMP/review-head-unchanged.out"
assert_contains "$TMP/review-head-unchanged.out" 'pre=abc123 post=abc123 unchanged=1' 'HEAD unchanged: identical pre/post SHA is detected as no commits made (TC-2.5)'

: > "$TMP/review-head-changed.record"
printf 'abc123 def456\n' \
  | run_script review-head-unchanged "$TMP/review-head-changed.record" "$TMP/home" > "$TMP/review-head-changed.out"
assert_contains "$TMP/review-head-changed.out" 'pre=abc123 post=def456 unchanged=0' 'HEAD unchanged: differing pre/post SHA is not flagged (commits were made)'

: > "$TMP/review-head-empty-pre.record"
printf ' \n' \
  | run_script review-head-unchanged "$TMP/review-head-empty-pre.record" "$TMP/home" > "$TMP/review-head-empty-pre.out"
assert_contains "$TMP/review-head-empty-pre.out" 'pre= post= unchanged=0' 'HEAD unchanged: an empty pre-SHA (e.g. detached HEAD lookup failure) never counts as unchanged'

# Full single-iteration outer-loop run: converts QA-TEST-PLAN.md Suite 1
# TC-1.1 (one MAX_ITER=1 pass, including the real per-iteration git worktree
# and the implementer's branch rename) into deterministic coverage. Unlike
# the pure-function extractions above, this drives the actual outer loop
# end to end against a real repo fixture with no BABYSIT_TEST_MODE (an empty
# value skips the test-hook dispatch the same as unset — see
# run_single_iteration): claude is stubbed to rename the worktree's
# placeholder branch (as the real implementer prompt instructs) and return a
# sentinel-free result, so the loop completes iter 1 cleanly and stops on
# MAX_ITER without ever touching gh.
make_preflight_repo "$TMP/single-iter" >/dev/null 2>&1
mkdir -p "$TMP/single-iter/home"
: > "$TMP/single-iter.record"
set +e
MAX_ITER=1 SLEEP_SEC=0 \
  STUB_FINAL_RESULT='Investigated the project state; nothing actionable surfaced this iteration.' \
  STUB_RENAME_BRANCH='chore/tc-1-1-test' \
  run_single_iteration "$TMP/single-iter/work" "$TMP/single-iter/home" \
    "$TMP/single-iter.record" "$TMP/single-iter.out" "$TMP/single-iter.err"
single_iter_rc=$?
set -e
[ "$single_iter_rc" -eq 0 ] && pass 'single iteration: exits 0 (TC-1.1)' || fail 'single iteration: exits 0 (TC-1.1)'

single_iter_log=$(find "$TMP/single-iter/home/sisyphus-logs" -maxdepth 1 -name '*.log' | head -1)
if [ -n "$single_iter_log" ]; then
  pass 'single iteration: log file created'
else
  fail 'single iteration: log file created'
  single_iter_log="$TMP/single-iter.err"
fi

if [ "$(grep -c '^=== iter ' "$single_iter_log")" -eq 1 ]; then
  pass 'single iteration: exactly one iteration header logged (TC-1.1)'
else
  echo "  actual iter headers:" >&2
  grep '^=== iter ' "$single_iter_log" | sed 's/^/    /' >&2
  fail 'single iteration: exactly one iteration header logged (TC-1.1)'
fi
if grep -Eq '^=== iter 1 @ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ===$' "$single_iter_log"; then
  pass 'single iteration: header matches "=== iter 1 @ <timestamp> ===" (TC-1.1)'
else
  fail 'single iteration: header matches "=== iter 1 @ <timestamp> ===" (TC-1.1)'
fi
assert_not_contains "$single_iter_log" 'STOP signal received on iter 1.' 'single iteration: no STOP sentinel output (TC-1.1)'
if grep -Eq '^  \[outer\] worktree: /tmp/babysit-work-iter1-[0-9]+ \(branch: wip/work/iter-1\)$' "$single_iter_log"; then
  pass 'single iteration: per-iteration worktree created on the placeholder branch (TC-1.1)'
else
  fail 'single iteration: per-iteration worktree created on the placeholder branch (TC-1.1)'
fi
assert_contains "$single_iter_log" '  [outer] iter 1 branch: chore/tc-1-1-test' \
  "single iteration: implementer's branch rename is reflected before worktree teardown (TC-1.1)"
assert_contains "$TMP/single-iter.out" 'Done after 1 iterations. See '"$single_iter_log" \
  'single iteration: loop reports exactly 1 completed iteration'

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
