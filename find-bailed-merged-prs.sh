#!/bin/bash
# find-bailed-merged-prs.sh — forensic audit for babysit-with-review.sh bails.
#
# Scans ~/sisyphus-logs/*.log for review-handoff blocks that bailed without
# clearing all blocking findings, then queries GitHub for each bailed PR to
# report which ones were subsequently merged (and are therefore unreviewed
# code on the default branch).
#
# Usage:
#   find-bailed-merged-prs.sh [--log-dir DIR] [--repo-map FILE] [--repo OWNER/REPO]
#
#   --log-dir DIR       Babysit log directory (default: ~/sisyphus-logs)
#   --repo-map FILE     TSV file: project<TAB>OWNER/REPO (default: ~/.config/babysit-audit/repo-map.tsv)
#   --repo OWNER/REPO   Override: query this repo for ALL bailed PRs found
#
# Repo map format (no header, tab-separated):
#   scripts	chrisrobertson/scripts
#   home-lab-monitor	chrisrobertson/home-lab-monitor
#
# Output: TSV to stdout (MERGED rows first). Summary to stderr.
# Exit code: 0 always (audit, not a gate).

set -uo pipefail

LOG_DIR="$HOME/sisyphus-logs"
REPO_MAP_FILE="$HOME/.config/babysit-audit/repo-map.tsv"
REPO_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-dir)   LOG_DIR="$2";         shift 2 ;;
    --repo-map)  REPO_MAP_FILE="$2";   shift 2 ;;
    --repo)      REPO_OVERRIDE="$2";   shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

python3 - "$LOG_DIR" "$REPO_MAP_FILE" "$REPO_OVERRIDE" <<'PYEOF'
import json
import os
import re
import subprocess
import sys

log_dir, repo_map_file, repo_override = sys.argv[1], sys.argv[2], sys.argv[3]

# ---- load repo map ----

repo_map = {}
if repo_override:
    pass  # applied per-row below
elif os.path.isfile(repo_map_file):
    with open(repo_map_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t', 1)
            if len(parts) == 2:
                repo_map[parts[0]] = parts[1]

# ---- parse logs ----

BAILED_PHRASES = [
    'bailing review cycle',
    'hit MAX_REVIEW_CYCLES',
    'HEAD unchanged',
    'STUCK_REVIEW',
    'gh pr checkout',   # "gh pr checkout N failed"
    'marking PR',       # fail_review_cycle log line (post-fix)
]

log_files = sorted(
    f for f in (
        os.path.join(log_dir, fn)
        for fn in os.listdir(log_dir)
        if fn.endswith('.log')
    )
    if os.path.isfile(f)
) if os.path.isdir(log_dir) else []

if not log_files:
    print(f'No log files found in {log_dir} — nothing to audit.', file=sys.stderr)
    sys.exit(0)

# key: (project, pr_num) → {'outcome': ..., 'reason': ..., 'log': ...}
# Worst outcome wins: BAILED > UNKNOWN > CLEARED
RANK = {'BAILED': 2, 'UNKNOWN': 1, 'CLEARED': 0}
results = {}

review_log_count = 0

for log_path in log_files:
    with open(log_path, errors='replace') as f:
        lines = f.readlines()

    # Check header
    if not any(line.startswith('=== babysit-with-review.sh @') for line in lines[:5]):
        continue
    review_log_count += 1

    # Extract filename → project name
    basename = os.path.basename(log_path)
    project = re.sub(r'-\d{8}-\d{6}-\d+\.log$', '', basename)

    # Parse handoff blocks
    pr_num = None
    outcome = 'UNKNOWN'
    reason = 'no terminal marker in block'

    def emit(project, pr_num, outcome, reason, log_path):
        key = (project, pr_num)
        cur_rank = RANK.get(results.get(key, {}).get('outcome', 'CLEARED'), 0)
        new_rank = RANK.get(outcome, 0)
        if new_rank >= cur_rank:
            results[key] = {'outcome': outcome, 'reason': reason[:200], 'log': log_path}

    for i, line in enumerate(lines):
        line_s = line.rstrip('\n')

        handoff_m = re.match(r'^=== review handoff: PR #(\d+) @', line_s)
        if handoff_m:
            if pr_num is not None:
                emit(project, pr_num, outcome, reason, log_path)
            pr_num = handoff_m.group(1)
            outcome = 'UNKNOWN'
            reason = 'no terminal marker in block'
            continue

        if pr_num is None:
            continue

        # Block boundary (new iter or next handoff handled above)
        if re.match(r'^=== iter \d+', line_s) and i > 0:
            emit(project, pr_num, outcome, reason, log_path)
            pr_num = None
            continue

        # Outcome detection
        if 'cleared after' in line_s:
            outcome = 'CLEARED'
            reason = line_s.strip()
        elif outcome != 'CLEARED':
            for phrase in BAILED_PHRASES:
                if phrase in line_s:
                    if 'gh pr checkout' in phrase and 'failed' not in line_s:
                        continue
                    outcome = 'BAILED'
                    reason = line_s.strip()
                    break

    if pr_num is not None:
        emit(project, pr_num, outcome, reason, log_path)

if review_log_count == 0:
    print(f'No babysit-with-review.sh logs found in {log_dir} — nothing to audit.', file=sys.stderr)
    sys.exit(0)

# ---- filter to BAILED/UNKNOWN ----

candidates = {k: v for k, v in results.items() if v['outcome'] in ('BAILED', 'UNKNOWN')}

if not candidates:
    print('No bailed handoffs found — no candidates to audit.', file=sys.stderr)
    sys.exit(0)

# ---- query GitHub ----

merged_rows = []
other_rows = []
no_map_rows = []
n_merged = 0

for (project, pr_num), info in sorted(candidates.items()):
    outcome = info['outcome']
    reason = info['reason']

    gh_repo = repo_override or repo_map.get(project, '')

    if not gh_repo:
        no_map_rows.append((project, pr_num, outcome, reason, 'UNKNOWN', '-', '-', '(no repo mapping)'))
        continue

    try:
        result = subprocess.run(
            ['gh', 'pr', 'view', pr_num, '--repo', gh_repo,
             '--json', 'number,state,mergedAt,mergedBy,url,headRefName,additions,deletions'],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip())
        d = json.loads(result.stdout)
        state = d.get('state', '?')
        merged_at = d.get('mergedAt') or '-'
        url = d.get('url', f'https://github.com/{gh_repo}/pull/{pr_num}')
    except Exception as e:
        other_rows.append((project, pr_num, outcome, reason[:80], 'UNKNOWN', '-',
                           f'https://github.com/{gh_repo}/pull/{pr_num}', f'gh query failed: {e}'))
        continue

    row = (project, pr_num, outcome, reason[:80], state, merged_at, url, '')
    if state == 'MERGED':
        n_merged += 1
        merged_rows.append(row)
    else:
        other_rows.append(row)

# ---- output ----

print('PROJECT\tPR\tOUTCOME\tREASON\tSTATE\tMERGED_AT\tURL\tNOTE')
for row in merged_rows + other_rows + no_map_rows:
    print('\t'.join(str(x) for x in row))

n_bailed = len(candidates)
print(f'\n{n_bailed} bailed handoff(s) across {n_bailed} unique PR(s) examined; {n_merged} already merged.',
      file=sys.stderr)
if n_merged > 0:
    print(f'ACTION REQUIRED: {n_merged} merged PR(s) contain unreviewed AI-generated commits.',
          file=sys.stderr)
PYEOF
