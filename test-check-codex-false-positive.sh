#!/bin/bash
# test-check-codex-false-positive.sh — offline coverage for
# check-codex-false-positive.sh's verdict-block parser. No network: a `gh` stub
# on PATH returns a canned label string, and each case writes a fixture babysit
# log into a throwaway --log-dir, then asserts the VERDICT line the script
# prints. Fixtures mirror the two review-flow shapes flagged in PR #94:
#   - Codex rendering its verdict twice, separated by a "tokens used" marker
#   - a cycle-5 review that opens with a "## ADJUDICATION" section
# plus regressions for indented headers/bullets and genuine duplicate verdicts.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/check-codex-false-positive.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; FAIL=$((FAIL + 1)); }

# gh stub: the script calls `gh pr view N --repo O/R --json labels -q ...`.
# We ignore the jq expression and just print the label list the case wants.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf '%s' "${STUB_LABELS:-review-codex-outdated}"
STUB
chmod +x "$TMP/bin/gh"

REPO="acme/widget"
PR=123
HALT="Halting: Codex version incompatibility on PR #${PR}; add credits. See /tmp/codex-run.log"
HANDOFF="=== review handoff: PR #${PR} @ 2026-09-28T00:00:00Z ==="

# run_case <name> <expected-substring> <log-body-file>
# Writes the log into a fresh log-dir named after the repo project, runs the
# script with --repo (so project = "widget"), and greps the output.
run_case() {
  local name="$1" expect="$2" body="$3"
  local logdir; logdir=$(mktemp -d "$TMP/logs.XXXXXX")
  cp "$body" "$logdir/widget-20260928-000000-4242.log"
  local out
  out=$(PATH="$TMP/bin:$PATH" STUB_LABELS="review-codex-outdated" \
        "$SCRIPT" "$PR" --repo "$REPO" --log-dir "$logdir" 2>&1)
  if printf '%s' "$out" | grep -qF -- "$expect"; then
    pass "$name"
  else
    echo "  expected substring: $expect" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail "$name"
  fi
}

# ---------- Case 1: Codex renders the verdict twice, split by "tokens used" ----------
# The mid-run copy and the final message are identical clean verdicts. Only the
# "tokens used" marker separates them, so the span guard must scope to the final
# rendering and report LIKELY FALSE POSITIVE, not "malformed / ambiguous".
cat > "$TMP/case1.log" <<EOF
  [codex] starting review
$HANDOFF
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
[2026-09-28T00:00:01] tokens used: 12345
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "repeated verdict split by 'tokens used' reads as false positive" \
  "LIKELY FALSE POSITIVE" "$TMP/case1.log"

# ---------- Case 2: cycle-5 review opening with ## ADJUDICATION ----------
# The wrapper accepts an ADJUDICATION section first (valid_review_structure()).
# A clean cycle-5 verdict must still read as a false positive, not "unexpected
# section header".
cat > "$TMP/case2.log" <<EOF
  [codex] starting review
$HANDOFF
## ADJUDICATION
- BLOCKING earlier finding: ACCEPTED — fix is sound
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "cycle-5 ADJUDICATION-first clean verdict reads as false positive" \
  "LIKELY FALSE POSITIVE" "$TMP/case2.log"

# ---------- Case 3: indented "- (none)" bullets are NOT a clean verdict ----------
# The wrapper anchors bullets at column 0; an indented "  - (none)" is not the
# literal empty-section bullet it accepts, so it must not read as a confirmed
# false positive. Before the fix, stripping the line made it look clean.
cat > "$TMP/case3.log" <<EOF
  [codex] starting review
$HANDOFF
## BLOCKING
  - (none)
## RECOMMENDED
  - (none)
## INFORMATION
  - (none)
$HALT
EOF
run_case "indented '- (none)' bullets do not read as false positive" \
  "non-empty findings present" "$TMP/case3.log"

# ---------- Case 4: genuine duplicate verdict with no boundary is ambiguous ----------
# Two BLOCKING renderings in one uninterrupted span (no bracket line and no
# "tokens used" between them) remain ambiguous — the guard must still fire.
cat > "$TMP/case4.log" <<EOF
  [codex] starting review
$HANDOFF
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "duplicate verdict with no boundary stays ambiguous" \
  "which one is the real final verdict is ambiguous" "$TMP/case4.log"

# ---------- Case 5: ADJUDICATION present but empty is malformed ----------
cat > "$TMP/case5.log" <<EOF
  [codex] starting review
$HANDOFF
## ADJUDICATION
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "empty ADJUDICATION section reads as malformed" \
  "ADJUDICATION section violates the wrapper" "$TMP/case5.log"

# ---------- Case 6: real BLOCKING finding is not a false positive ----------
cat > "$TMP/case6.log" <<EOF
  [codex] starting review
$HANDOFF
## BLOCKING
- [NEW] real bug — foo.sh:10 — breaks on empty input
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "real BLOCKING finding is not a false positive" \
  "non-empty findings present" "$TMP/case6.log"

# ---------- Case 7: an INDENTED ## ADJUDICATION header is malformed ----------
# The backward span scan matches "## ADJUDICATION" on a left-stripped line, so an
# indented header can anchor `start`. The column-0 parser discards it, leaving the
# clean sections to look like a false positive on a verdict the wrapper rejects.
# The leading-content guard must catch it. (PR #94 cycle-5 DISAGREED re-address.)
cat > "$TMP/case7.log" <<EOF
  [codex] starting review
$HANDOFF
  ## ADJUDICATION
- BLOCKING earlier finding: ACCEPTED — fix is sound
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "indented ## ADJUDICATION header does not read as false positive" \
  "nonblank content before the first column-0 section header" "$TMP/case7.log"

# ---------- Case 8: ADJUDICATION bullet-rule violation is malformed ----------
# "- (none)" alongside a real bullet violates the wrapper's exclusivity rule
# (valid_review_structure() current=4). A nonempty-but-invalid ADJUDICATION must
# not read as a clean verdict. (PR #94 cycle-5 NEW finding.)
cat > "$TMP/case8.log" <<EOF
  [codex] starting review
$HANDOFF
## ADJUDICATION
- (none)
- BLOCKING earlier finding: ACCEPTED — fix is sound
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "ADJUDICATION with '- (none)' plus a real bullet is malformed" \
  "ADJUDICATION section violates the wrapper" "$TMP/case8.log"

# ---------- Case 9: valid ADJUDICATION bullet + continuation still clean ----------
# A real bullet followed by an indented continuation line is valid to the wrapper,
# so a clean cycle-5 verdict must still read as a false positive — the bullet-rule
# check must not over-reject.
cat > "$TMP/case9.log" <<EOF
  [codex] starting review
$HANDOFF
## ADJUDICATION
- BLOCKING earlier finding: ACCEPTED — fix is sound
  and the anchor now scopes to the final rendering
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "valid ADJUDICATION bullet with continuation reads as false positive" \
  "LIKELY FALSE POSITIVE" "$TMP/case9.log"

# ---------- Case 10: prose before an otherwise clean verdict is malformed ----------
# Codex can emit prose in the final rendering before "## BLOCKING". The wrapper's
# awk sets valid=0 on any content before the first column-0 header, so parsing must
# begin at span_start (the boundary), not at the header — otherwise the trailing
# clean sections read as a false positive on a verdict the wrapper rejects.
# (PR #94 cycle-6 NEW finding.)
cat > "$TMP/case10.log" <<EOF
  [codex] starting review
$HANDOFF
Reviewing the diff now; here is what I found before the structured verdict.
## BLOCKING
- (none)
## RECOMMENDED
- (none)
## INFORMATION
- (none)
$HALT
EOF
run_case "prose before a clean verdict does not read as false positive" \
  "nonblank content before the first column-0 section header" "$TMP/case10.log"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
