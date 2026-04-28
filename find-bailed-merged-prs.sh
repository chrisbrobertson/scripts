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
#   --repo-map FILE     TSV file mapping project names to OWNER/REPO (default: ~/.config/babysit-audit/repo-map.tsv)
#   --repo OWNER/REPO   Override: query this repo for ALL bailed PRs found (useful for single-project runs)
#
# Repo map format (no header, tab-separated):
#   scripts	chrisrobertson/scripts
#   home-lab-monitor	chrisrobertson/home-lab-monitor
#
# Output: TSV to stdout. MERGED rows sorted first.
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

# ---------- parse one log file into TSV rows ----------
# Output: project<TAB>pr_num<TAB>outcome<TAB>reason
parse_log() {
  local log_path="$1"
  local project
  project=$(basename "$log_path" | sed -E 's/-[0-9]{8}-[0-9]{6}-[0-9]+\.log$//')

  awk -v project="$project" '
    BEGIN {
      is_review_log = 0
      pr = ""; outcome = ""; reason = ""
    }

    /^=== babysit-with-review\.sh @/ { is_review_log = 1 }
    !is_review_log { next }

    /^=== review handoff: PR #[0-9]+ @/ {
      if (pr != "") emit()
      match($0, /PR #([0-9]+)/, m)
      pr = m[1]
      outcome = "UNKNOWN"
      reason = "no terminal marker in block"
    }

    pr == "" { next }

    /cleared after/ && outcome != "CLEARED" {
      outcome = "CLEARED"; reason = substr($0, 1, 120)
    }

    /bailing review cycle/ && outcome != "CLEARED" {
      outcome = "BAILED"; reason = substr($0, 1, 120)
    }
    /hit MAX_REVIEW_CYCLES/ && outcome != "CLEARED" {
      outcome = "BAILED"; reason = substr($0, 1, 120)
    }
    /HEAD unchanged/ && outcome != "CLEARED" {
      outcome = "BAILED"; reason = substr($0, 1, 120)
    }
    /STUCK_REVIEW/ && outcome != "CLEARED" {
      outcome = "BAILED"; reason = substr($0, 1, 120)
    }
    /gh pr checkout.*failed/ && outcome != "CLEARED" {
      outcome = "BAILED"; reason = substr($0, 1, 120)
    }
    /marking PR.*incomplete/ && outcome != "CLEARED" {
      outcome = "BAILED"; reason = substr($0, 1, 120)
    }

    /^=== (review handoff|iter) / && FNR > 1 {
      if (pr != "") { emit(); pr = "" }
    }

    END { if (pr != "") emit() }

    function emit() {
      printf("%s\t%s\t%s\t%s\n", project, pr, outcome, reason)
    }
  ' "$log_path"
}

# ---------- collect all handoffs across all logs ----------

declare -A WORST_OUTCOME   # key: "project|pr" → BAILED > UNKNOWN > CLEARED
declare -A WORST_REASON
declare -A WORST_LOG

outcome_rank() {
  case "$1" in
    BAILED)  echo 2 ;;
    UNKNOWN) echo 1 ;;
    CLEARED) echo 0 ;;
    *)       echo 0 ;;
  esac
}

shopt -s nullglob
logs=("$LOG_DIR"/*.log)
if [ "${#logs[@]}" -eq 0 ]; then
  echo "No log files found in $LOG_DIR — nothing to audit." >&2
  exit 0
fi

review_log_count=0
for log in "${logs[@]}"; do
  # Skip logs that don't have the babysit-with-review.sh header.
  if ! grep -q "^=== babysit-with-review\.sh @" "$log" 2>/dev/null; then
    continue
  fi
  review_log_count=$((review_log_count + 1))

  while IFS=$'\t' read -r proj pr outcome reason; do
    key="${proj}|${pr}"
    cur_rank=$(outcome_rank "${WORST_OUTCOME[$key]:-CLEARED}")
    new_rank=$(outcome_rank "$outcome")
    if [ "$new_rank" -ge "$cur_rank" ]; then
      WORST_OUTCOME[$key]="$outcome"
      WORST_REASON[$key]="$reason"
      WORST_LOG[$key]="$log"
    fi
  done < <(parse_log "$log")
done

if [ "$review_log_count" -eq 0 ]; then
  echo "No babysit-with-review.sh logs found in $LOG_DIR — nothing to audit." >&2
  exit 0
fi

# ---------- filter to BAILED/UNKNOWN only ----------

declare -a CANDIDATES=()
for key in "${!WORST_OUTCOME[@]}"; do
  o="${WORST_OUTCOME[$key]}"
  if [ "$o" = "BAILED" ] || [ "$o" = "UNKNOWN" ]; then
    CANDIDATES+=("$key")
  fi
done

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "No bailed handoffs found — no candidates to audit." >&2
  exit 0
fi

# ---------- load repo map ----------

declare -A REPO_MAP
if [ -n "$REPO_OVERRIDE" ]; then
  : # will use override per-row
elif [ -f "$REPO_MAP_FILE" ]; then
  while IFS=$'\t' read -r proj repo; do
    [[ "$proj" =~ ^# ]] && continue
    REPO_MAP["$proj"]="$repo"
  done < "$REPO_MAP_FILE"
fi

# ---------- query GitHub and build output rows ----------

declare -a MERGED_ROWS=()
declare -a OTHER_ROWS=()
declare -a NO_MAP_ROWS=()

n_bailed=0
n_merged=0

for key in "${CANDIDATES[@]}"; do
  proj="${key%%|*}"
  pr="${key##*|}"
  outcome="${WORST_OUTCOME[$key]}"
  reason="${WORST_REASON[$key]}"

  n_bailed=$((n_bailed + 1))

  # Resolve repo.
  local_repo="$REPO_OVERRIDE"
  if [ -z "$local_repo" ]; then
    local_repo="${REPO_MAP[$proj]:-}"
  fi

  if [ -z "$local_repo" ]; then
    NO_MAP_ROWS+=("$(printf '%s\t%s\t%s\t%s\tUNKNOWN\t-\t-\t(no repo mapping)' "$proj" "$pr" "$outcome" "$reason")")
    continue
  fi

  # Query GitHub.
  pr_json=$(gh pr view "$pr" --repo "$local_repo" \
    --json number,state,mergedAt,mergedBy,url,headRefName,additions,deletions 2>/dev/null) || {
    OTHER_ROWS+=("$(printf '%s\t%s\t%s\t%s\tUNKNOWN\t-\thttps://github.com/%s/pull/%s\t(gh query failed)' \
      "$proj" "$pr" "$outcome" "$reason" "$local_repo" "$pr")")
    continue
  }

  state=$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state','?'))")
  merged_at=$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('mergedAt') or '-')")
  url=$(printf '%s' "$pr_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('url','?'))")

  row="$(printf '%s\t%s\t%s\t%.100s\t%s\t%s\t%s' "$proj" "$pr" "$outcome" "$reason" "$state" "$merged_at" "$url")"

  if [ "$state" = "MERGED" ]; then
    n_merged=$((n_merged + 1))
    MERGED_ROWS+=("$row")
  else
    OTHER_ROWS+=("$row")
  fi
done

# ---------- output ----------

printf 'PROJECT\tPR\tOUTCOME\tREASON\tSTATE\tMERGED_AT\tURL\tNOTE\n'
for row in "${MERGED_ROWS[@]+"${MERGED_ROWS[@]}"}"; do
  printf '%s\t\n' "$row"
done
for row in "${OTHER_ROWS[@]+"${OTHER_ROWS[@]}"}"; do
  printf '%s\t\n' "$row"
done
for row in "${NO_MAP_ROWS[@]+"${NO_MAP_ROWS[@]}"}"; do
  printf '%s\n' "$row"
done

printf '\n%d bailed handoff(s) across %d unique PR(s) examined; %d already merged.\n' \
  "$n_bailed" "$n_bailed" "$n_merged" >&2

if [ "$n_merged" -gt 0 ]; then
  printf 'ACTION REQUIRED: %d merged PR(s) contain unreviewed AI-generated commits.\n' "$n_merged" >&2
fi
