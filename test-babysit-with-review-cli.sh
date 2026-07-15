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

make_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/bin/bash
printf '%s\n' 'CALL=claude' >> "$RECORD"
printf '<%s>\n' "$@" >> "$RECORD"
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

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
