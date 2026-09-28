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
    --repo)    REPO="$2";    shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
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

halting_re = re.compile(
    r'^Halting: Codex (version incompatibility|workspace out of credits) on PR #'
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

# Walk backward from the halt to the nearest preceding "## BLOCKING" header —
# the start of the verdict block the review actually printed just before the
# telltale scan fired.
start = None
for j in range(idx - 1, max(idx - 200, -1), -1):
    if lines[j].strip() == '## BLOCKING':
        start = j
        break

if start is None:
    print(f'Found halt line in {log_path} but no "## BLOCKING" verdict block within 200 lines before it.',
          file=sys.stderr)
    print(f'Raw transcript: {transcript_path}', file=sys.stderr)
    sys.exit(1)

# The verdict block ends at the first bracketed wrapper log line
# ("  [codex] ..." / "  [review] ...") that follows it.
end = idx
for k in range(start, idx):
    if lines[k].startswith('  ['):
        end = k
        break

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
current = None
for l in block:
    stripped = l.strip()
    if stripped.startswith('## '):
        current = stripped[3:].strip()
        sections[current] = []
    elif current is not None and stripped:
        sections[current].append(stripped)

clean = all(sections.get(name) == ['- (none)'] for name in REQUIRED_SECTIONS)

print(f'PR #{pr} — {halting_line}')
print(f'Driver log:      {log_path}')
print(f'Raw transcript:  {transcript_path}')
print()
print(block_text)
print()
if clean:
    print('VERDICT: every section reads "(none)" — LIKELY FALSE POSITIVE. See CLAUDE.md '
          '"MCP resilience and pre-flight" for the incident this matches; the label probably '
          'does not reflect a real CLI/credits problem.')
else:
    print('VERDICT: non-empty findings present in the block above — do not assume the '
          'false-positive class applies without reading them; this may be a genuine review '
          'result or a different failure shape.')
PYEOF
