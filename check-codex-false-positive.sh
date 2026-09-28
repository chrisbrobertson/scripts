#!/bin/bash
# check-codex-false-positive.sh — verify a stale codex-review label against
# the actual printed review verdict.
#
# babysit-with-review.sh's codex_review_with_retry() used to scan the whole
# raw Codex transcript for backend-compatibility / no-credits telltales
# before checking whether the review itself had actually succeeded. Because
# Codex reviews agentically with full repo read access, it can surface those
# telltale strings as incidental exploration noise and get mislabelled even
# when the real review came back structurally clean. See CLAUDE.md's
# "MCP resilience and pre-flight" section for the full incident writeup and
# the fix (issue #82, PR #83).
#
# This script does not touch the wrapper or re-run a review — it only
# automates the manual check CLAUDE.md recommends: find the verdict the
# review actually printed to the driver log immediately before the halt,
# and report whether every section was empty.
#
# Usage:
#   check-codex-false-positive.sh <PR_NUMBER> [--repo OWNER/REPO] [--log-dir DIR]
#
#   --repo OWNER/REPO   Repo to query for the PR's labels (default: current repo).
#                       Also scopes the log search to this repo's project name
#                       (the REPO part), since babysit-with-review.sh names its
#                       logs after basename($PWD) at launch. Without --repo, the
#                       log search is scoped to basename($PWD) instead — run
#                       this script from the same repo directory the babysitter
#                       ran from.
#   --log-dir DIR       Babysit log directory to search (default: ~/sisyphus-logs)
#
# Exit code: 0 if a verdict was located and printed (clean or not clean);
# 1 if no matching local log entry could be found — a manual check is still
# required in that case.

set -uo pipefail

LOG_DIR="$HOME/sisyphus-logs"
REPO=""
PR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { echo "--repo requires a value" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    --log-dir)
      [ "$#" -ge 2 ] || { echo "--log-dir requires a value" >&2; exit 2; }
      LOG_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *)  PR="$1"; shift ;;
  esac
done

if [ -z "$PR" ]; then
  echo "Usage: check-codex-false-positive.sh <PR_NUMBER> [--repo OWNER/REPO] [--log-dir DIR]" >&2
  exit 2
fi

if [ -n "$REPO" ]; then
  labels="$(gh pr view "$PR" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null)"
else
  labels="$(gh pr view "$PR" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null)"
fi
if [ -z "$labels" ]; then
  echo "Could not read labels for PR #$PR (gh error or PR not found)." >&2
  exit 1
fi

case ",$labels," in
  *,review-codex-outdated,*|*,review-codex-no-credits,*) : ;;
  *)
    echo "PR #$PR does not carry review-codex-outdated or review-codex-no-credits — nothing to check." >&2
    exit 0
    ;;
esac

# babysit-with-review.sh names its log after basename($PWD) at launch
# (PROJECT=$(basename "$PWD")); PR numbers repeat across repos, so scope
# the log search to the project the requested PR actually belongs to.
if [ -n "$REPO" ]; then
  project="${REPO##*/}"
else
  project="$(basename "$PWD")"
fi

python3 - "$LOG_DIR" "$PR" "$project" <<'PYEOF'
import os
import re
import sys

log_dir, pr, project = sys.argv[1], sys.argv[2], sys.argv[3]

if not os.path.isdir(log_dir):
    print(f'Log directory {log_dir} does not exist.', file=sys.stderr)
    sys.exit(1)

# babysit-with-review.sh has two halt sites for these two failure classes:
# the main outer loop says "... on PR #N", the retry-exhausted-on-a-stalled-PR
# branch says "... for PR #N". Accept both.
halting_re = re.compile(
    r'^Halting: Codex (version incompatibility|workspace out of credits) (?:on|for) PR #'
    + re.escape(pr) + r';.*See (\S+)'
)

best = None  # (mtime, log_path, line_idx, halting_line, transcript_path)

# Two distinct log-naming conventions exist, both written by processes
# related to this project's babysitter run:
#   - the babysitter itself: <project>-<timestamp>-<pid>.log
#   - staff-fleet's babysit-driver.sh wrapper (new-fleet.sh), which
#     redirects the babysitter's stdout/stderr (including its halt line)
#     into its own file with no PID suffix: <project>-driver-<timestamp>.log
# Match both rather than requiring a PID, and scope to the requested
# repo's project name so a same-numbered PR in another project's logs
# can't be picked up instead.
log_name_re = re.compile(
    r'^' + re.escape(project) + r'-(?:driver-)?\d{8}-\d{6}(?:-\d+)?\.log$'
)

for fn in os.listdir(log_dir):
    if not log_name_re.match(fn):
        continue
    path = os.path.join(log_dir, fn)
    try:
        with open(path, errors='replace') as f:
            lines = f.readlines()
    except OSError:
        continue
    for i, line in enumerate(lines):
        m = halting_re.match(line.strip())
        if m:
            mtime = os.path.getmtime(path)
            if best is None or mtime > best[0]:
                best = (mtime, path, i, line.strip(), m.group(2))

if best is None:
    print(f'No local "Halting: Codex ... on PR #{pr}" entry found under {log_dir}.', file=sys.stderr)
    print('Could not automatically verify — check the transcript manually per CLAUDE.md.', file=sys.stderr)
    sys.exit(1)

_, log_path, idx, halting_line, transcript_path = best

with open(log_path, errors='replace') as f:
    lines = f.readlines()

# One babysitter log can contain multiple PR review cycles, so an unbounded
# backward scan for "## BLOCKING" could select a clean verdict left over from
# a *different, earlier* PR — e.g. a pre-flight failure on this PR prints no
# review at all. babysit-with-review.sh tags the start of each cycle with
# "=== review handoff: PR #N @ ... ===" (see its run_review_cycle); bound the
# verdict search to the nearest such line for *this* PR before the halt so
# output from an earlier cycle can never be picked up.
handoff_re = re.compile(
    r'^=== review handoff: PR #' + re.escape(pr) + r' @ .* ===\s*$'
)

handoff_idx = None
for j in range(idx - 1, -1, -1):
    if handoff_re.match(lines[j].strip()):
        handoff_idx = j
        break

if handoff_idx is None:
    print(f'Found halt line in {log_path} but no "=== review handoff: PR #{pr} @ ..." '
          'line before it — no review verdict was printed for this handoff (e.g. a '
          'pre-flight failure before Codex ran). Cannot check for a false positive; '
          'a manual check is still required.', file=sys.stderr)
    print(f'Log referenced by halt line: {transcript_path}', file=sys.stderr)
    sys.exit(1)

# Walk backward from the halt to the nearest preceding "## BLOCKING" header —
# the start of the verdict block the review actually printed just before the
# telltale scan fired. Never cross the handoff boundary found above.
start = None
for j in range(idx - 1, handoff_idx, -1):
    if lines[j].strip() == '## BLOCKING':
        start = j
        break

if start is None:
    print(f'Found halt line in {log_path} and a review handoff for PR #{pr} before it, '
          'but no "## BLOCKING" verdict block between them.', file=sys.stderr)
    print(f'Log referenced by halt line: {transcript_path}', file=sys.stderr)
    sys.exit(1)

# The verdict block ends at the first bracketed wrapper log line
# ("  [codex] ..." / "  [review] ...") that follows it.
end = idx
for k in range(start, idx):
    if lines[k].startswith('  ['):
        end = k
        break

# `start` is only the *nearest* preceding "## BLOCKING" — if the same
# uninterrupted span of raw output (i.e. not separated by a wrapper bracket
# line) contains another "## BLOCKING" before `start` or between `start`
# and `end`, naively parsing from `start` would silently ignore or mask it
# (e.g. Codex quoting the review-format template earlier in its own
# output, or printing a verdict twice). Bound the span by the nearest
# bracket lines on both sides of `start` (never crossing this PR's handoff
# boundary) and refuse to guess which occurrence is the real verdict if
# more than one appears in it.
span_start = handoff_idx + 1
for j in range(start - 1, handoff_idx, -1):
    if lines[j].startswith('  ['):
        span_start = j + 1
        break

span = lines[span_start:end]
blocking_count = sum(1 for l in span if l.strip() == '## BLOCKING')

if blocking_count > 1:
    print(f'PR #{pr} — {halting_line}')
    print(f'Log scanned:                 {log_path}')
    print(f'Log referenced by halt line: {transcript_path}')
    print()
    print(f'VERDICT: malformed — found {blocking_count} "## BLOCKING" headers in the same '
          'uninterrupted review output preceding the halt, so which one is the real final '
          'verdict is ambiguous. Cannot automatically determine clean/not-clean; read the '
          'log directly.')
    sys.exit(0)

block = lines[start:end]
block_text = ''.join(block).rstrip('\n')

# babysit-with-review.sh's review format requires all three section
# headers, each with a single literal "- (none)" bullet when empty
# (see CLAUDE.md / babysit-with-review.sh's own is_none check). Match
# that exactly rather than testing for the substring "(none)" anywhere
# in the block, and require every section to be present — a finding
# whose text happens to mention "(none)", or a truncated block missing
# a section, must not be reported as a clean verdict.
REQUIRED_SECTIONS = ('BLOCKING', 'RECOMMENDED', 'INFORMATION')
sections = {}
header_counts = {}
unexpected_headers = []
headers_in_order = []
current = None
for l in block:
    stripped = l.strip()
    if stripped.startswith('## '):
        current = stripped[3:].strip()
        header_counts[current] = header_counts.get(current, 0) + 1
        if current not in REQUIRED_SECTIONS:
            unexpected_headers.append(current)
        else:
            headers_in_order.append(current)
        sections[current] = []
    elif current is not None and stripped:
        sections[current].append(stripped)

# A well-formed verdict block has each required header exactly once and no
# other "## " headers. Duplicate "## BLOCKING" was already ruled out by the
# span check above; this also catches a duplicate RECOMMENDED/INFORMATION
# header (which would otherwise silently overwrite the first occurrence's
# findings in `sections`), a missing header, or an unrelated "## " heading
# swept in by the start/end scan — none of which should be reported as a
# likely false positive.
duplicate_headers = sorted({name for name, count in header_counts.items()
                             if name in REQUIRED_SECTIONS and count > 1})
missing_headers = [name for name in REQUIRED_SECTIONS if name not in sections]
# babysit-with-review.sh's valid_review_structure() rejects the required
# headers appearing out of order, not just missing/duplicated/extra ones —
# a verdict block with three exact "- (none)" bullets under reordered
# section headers is still malformed to the wrapper. duplicate/missing
# headers already make headers_in_order differ in length from
# REQUIRED_SECTIONS, but check order explicitly so a same-length reordering
# (e.g. RECOMMENDED, BLOCKING, INFORMATION) is also caught.
out_of_order = headers_in_order != list(REQUIRED_SECTIONS)
malformed = bool(duplicate_headers) or bool(unexpected_headers) or bool(missing_headers) or out_of_order

clean = (not malformed) and all(sections.get(name) == ['- (none)'] for name in REQUIRED_SECTIONS)

print(f'PR #{pr} — {halting_line}')
print(f'Log scanned:                 {log_path}')
print(f'Log referenced by halt line: {transcript_path}')
print()
print(block_text)
print()
if malformed:
    reasons = []
    if duplicate_headers:
        reasons.append(f'duplicate section header(s): {", ".join(duplicate_headers)}')
    if unexpected_headers:
        reasons.append(f'unexpected section header(s): {", ".join(sorted(set(unexpected_headers)))}')
    if missing_headers:
        reasons.append(f'missing section header(s): {", ".join(missing_headers)}')
    if out_of_order and not duplicate_headers and not missing_headers:
        reasons.append(f'section headers out of order: found {", ".join(headers_in_order)} '
                        f'(expected {", ".join(REQUIRED_SECTIONS)})')
    print('VERDICT: malformed verdict block (' + '; '.join(reasons) + ') — cannot '
          'automatically determine clean/not-clean from this. Do NOT treat this as a '
          'confirmed false positive; read the block above and the log directly.')
elif clean:
    print('VERDICT: every section reads "(none)" — LIKELY FALSE POSITIVE. See CLAUDE.md '
          '"MCP resilience and pre-flight" for the incident this matches; the label probably '
          'does not reflect a real CLI/credits problem.')
else:
    print('VERDICT: non-empty findings present in the block above — do not assume the '
          'false-positive class applies without reading them; this may be a genuine review '
          'result or a different failure shape.')
PYEOF
