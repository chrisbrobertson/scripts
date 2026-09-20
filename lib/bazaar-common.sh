#!/usr/bin/env bash
# lib/bazaar-common.sh — shared controller loop, GitHub label state machine,
# claim protocol, and attempt counter for bazaar-issues.sh / bazaar-build.sh.
# Spec: bazaar-builder-specs/L3-controller.md (BZR-FEAT-CONTROLLER).
#
# Sourcing has no side effects. A controller script:
#   1. defines role hooks (see "Role hooks" below),
#   2. calls  bzr_init <role> "$@"   (parses args, sets globals, takes the lock),
#   3. calls  bzr_controller_main    (ticks until stop / --once).
#
# Durable state lives only in GitHub labels and marker comments:
#   labels   bzr-drafting bzr-needs-info bzr-spec-review bzr-ready bzr-building bzr-pr-ready bzr-blocked
#   markers  <!-- bzr-claim role=R host=H pid=P start="S" ts=T -->
#            <!-- bzr-attempt role=R n=K reason="..." ts=T -->
#            <!-- bzr-escalated role=R attempts=K ts=T -->
#            <!-- bzr-issue-worker ... -->  <!-- bzr-sub-issue ... -->  <!-- bzr-build ... -->  (workers)
#
# Role hooks (functions the controller script defines before bzr_init):
#   role_parse_arg "$1" "${2:-}"   -> set BZR_ROLE_CONSUMED to the number of args consumed (0 = not mine);
#                                    runs in the caller's shell so it may set role globals
#   role_usage_extra                -> extra --help lines
#   role_claim_label                -> echo label held while a worker runs
#   role_queue_label                -> echo label a candidate carries ("" = intake: no bzr-* label)
#   role_release_label              -> echo label to restore on transient failure ("" = remove claim only)
#   role_sweeps                     -> run before the queue is read (may use bzr_* helpers)
#   role_candidates                 -> print candidate issue numbers, best first, from $BZR_ISSUES_JSON
#   role_worker_cmd <issue>         -> echo the command line to run (worker writes its sentinel to $BZR_SENTINEL)
#   role_on_worker_exit <issue> <rc> <sentinel-word> <sentinel-rest>  -> handle a non-transient outcome;
#                                    return 0 handled, 1 = treat as transient attempt
#   role_audit                      -> extra --audit checks
#   role_dry_sweeps                 -> (optional) print what role_sweeps would do; no writes
#
# Globals set by bzr_init: BZR_ROLE REPO OWNER NAME DEFAULT_BRANCH BZR_HOME BZR_REPO_DIR
#   LOG LOCK_FILE STOP_FILE WORKERS ONCE INTERVAL CONTROLLER_MODEL DRY_RUN AUDIT
#   IMPLEMENTER IMPLEMENTER_MODEL IMPLEMENTER_EFFORT REVIEWER REVIEWER_MODEL REVIEWER_EFFORT
#   BZR_APPROVERS MAX_ATTEMPTS SCRIPTS_DIR BZR_HOST BZR_ISSUES_JSON (per tick)

BZR_COMMON_VERSION="0.1.0"
BZR_LABELS="bzr-drafting bzr-needs-info bzr-spec-review bzr-ready bzr-building bzr-pr-ready bzr-blocked"

# ---------- tiny utils ----------

bzr_log() { printf '[ctl:%s] %s\n' "${BZR_ROLE:-?}" "$*" | tee -a "${LOG:-/dev/null}" >&2; }
bzr_die() { echo "ERROR: $*" >&2; exit 1; }
bzr_die_usage() { echo "ERROR: $*" >&2; bzr_usage >&2; exit 2; }
bzr_now() { date -u +%FT%TZ; }
bzr_is_option() { case "${1:-}" in -*) return 0 ;; *) return 1 ;; esac; }
bzr_require_value() { [ -n "${2:-}" ] && ! bzr_is_option "${2:-}" || bzr_die_usage "$1 requires a value"; }
# bzr_json a.b.c  — print a dotted path from JSON on stdin ("" if missing)
bzr_json() { python3 -c '
import json, sys
o = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    o = o.get(k) if isinstance(o, dict) else None
    if o is None: break
print("" if o is None else o)' "$1"; }

bzr_usage() {
  cat <<USAGE
Usage: bazaar-${BZR_ROLE:-<role>}.sh [OPTIONS]

Run from inside the project repository (or pass --repo).

Common options:
  --repo OWNER/REPO          Default: gh repo view in cwd.
  --workers N                Concurrent workers (1-8). Default: 1.
  --once                     One tick, then exit. Default: loop every --interval.
  --interval SECONDS         Default: 60.
  --controller-model MODEL   Tie-break model (run with --effort low). Default:
                             claude-haiku-4-5-20251001. 'none' disables model calls.
  --implementer claude|codex --implementer-model M --implementer-effort E
  --reviewer claude|codex    --reviewer-model M    --reviewer-effort E
  --dry-run                  Print the dispatch decision; no writes.
  --audit                    Print state-machine inconsistencies; no writes.
  --stop                     Ask the running controller to stop after its workers finish.
  -h, --help                 Show help.
  --version                  Show version.
$(declare -F role_usage_extra >/dev/null && role_usage_extra)
Environment:
  BZR_HOME       State root. Default: ~/.bazaar
  BZR_APPROVERS  Comma-separated GitHub logins allowed to approve spec PRs.
                 Default: the authenticated gh user.
  MAX_ATTEMPTS   Automatic attempts before escalation to bzr-blocked. Default: 3.
  MAX_REVIEW_CYCLES (6), MAX_SPEC_REVIEW_CYCLES (6)  passed to workers.

Labels: $BZR_LABELS
Exit codes: 0 clean stop, 1 fatal, 2 usage.
USAGE
}

# ---------- init ----------

bzr_init() {
  BZR_ROLE="$1"; shift
  REPO=""; WORKERS=1; ONCE=0; INTERVAL=60; CONTROLLER_MODEL="claude-haiku-4-5-20251001"
  DRY_RUN=0; AUDIT=0; STOP_REQ=0
  IMPLEMENTER="claude"; IMPLEMENTER_MODEL=""; IMPLEMENTER_EFFORT=""
  REVIEWER="codex"; REVIEWER_MODEL=""; REVIEWER_EFFORT=""
  MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
  local n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) bzr_usage; exit 0 ;;
      --version) echo "bazaar-${BZR_ROLE}.sh ${BZR_SCRIPT_VERSION:-0.0.0} (common ${BZR_COMMON_VERSION})"; exit 0 ;;
      --repo) bzr_require_value "$1" "${2:-}"; REPO="$2"; shift 2 ;;
      --repo=*) REPO="${1#*=}"; [ -n "$REPO" ] || bzr_die_usage "--repo requires a value"; shift ;;
      --workers) bzr_require_value "$1" "${2:-}"; WORKERS="$2"; shift 2 ;;
      --workers=*) WORKERS="${1#*=}"; shift ;;
      --once) ONCE=1; shift ;;
      --interval) bzr_require_value "$1" "${2:-}"; INTERVAL="$2"; shift 2 ;;
      --interval=*) INTERVAL="${1#*=}"; shift ;;
      --controller-model) bzr_require_value "$1" "${2:-}"; CONTROLLER_MODEL="$2"; shift 2 ;;
      --controller-model=*) CONTROLLER_MODEL="${1#*=}"; shift ;;
      --implementer) bzr_require_value "$1" "${2:-}"; IMPLEMENTER="$2"; shift 2 ;;
      --implementer=*) IMPLEMENTER="${1#*=}"; [ -n "$IMPLEMENTER" ] || bzr_die_usage "--implementer requires a value"; shift ;;
      --implementer-model) bzr_require_value "$1" "${2:-}"; IMPLEMENTER_MODEL="$2"; shift 2 ;;
      --implementer-model=*) IMPLEMENTER_MODEL="${1#*=}"; [ -n "$IMPLEMENTER_MODEL" ] || bzr_die_usage "--implementer-model requires a value"; shift ;;
      --implementer-effort) bzr_require_value "$1" "${2:-}"; IMPLEMENTER_EFFORT="$2"; shift 2 ;;
      --implementer-effort=*) IMPLEMENTER_EFFORT="${1#*=}"; [ -n "$IMPLEMENTER_EFFORT" ] || bzr_die_usage "--implementer-effort requires a value"; shift ;;
      --reviewer) bzr_require_value "$1" "${2:-}"; REVIEWER="$2"; shift 2 ;;
      --reviewer=*) REVIEWER="${1#*=}"; [ -n "$REVIEWER" ] || bzr_die_usage "--reviewer requires a value"; shift ;;
      --reviewer-model) bzr_require_value "$1" "${2:-}"; REVIEWER_MODEL="$2"; shift 2 ;;
      --reviewer-model=*) REVIEWER_MODEL="${1#*=}"; [ -n "$REVIEWER_MODEL" ] || bzr_die_usage "--reviewer-model requires a value"; shift ;;
      --reviewer-effort) bzr_require_value "$1" "${2:-}"; REVIEWER_EFFORT="$2"; shift 2 ;;
      --reviewer-effort=*) REVIEWER_EFFORT="${1#*=}"; [ -n "$REVIEWER_EFFORT" ] || bzr_die_usage "--reviewer-effort requires a value"; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --audit) AUDIT=1; shift ;;
      --stop) STOP_REQ=1; shift ;;
      --) shift; [ "$#" -eq 0 ] || bzr_die_usage "unexpected positional arguments: $*" ;;
      *)
        # role_parse_arg runs in THIS shell (no command substitution) so it can set
        # its own globals; it reports how many args it consumed in BZR_ROLE_CONSUMED.
        BZR_ROLE_CONSUMED=0
        if declare -F role_parse_arg >/dev/null; then role_parse_arg "$1" "${2:-}" || exit 2; fi
        [ "${BZR_ROLE_CONSUMED:-0}" -gt 0 ] || bzr_die_usage "unknown argument: $1"
        shift "$BZR_ROLE_CONSUMED" ;;
    esac
  done
  case "$IMPLEMENTER" in claude|codex) ;; *) bzr_die_usage "invalid --implementer '$IMPLEMENTER'" ;; esac
  case "$REVIEWER" in claude|codex) ;; *) bzr_die_usage "invalid --reviewer '$REVIEWER'" ;; esac
  [[ "$WORKERS" =~ ^[1-8]$ ]] || bzr_die_usage "--workers must be 1-8"
  [[ "$INTERVAL" =~ ^[0-9]+$ ]] || bzr_die_usage "--interval must be an integer"
  [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || bzr_die_usage "MAX_ATTEMPTS must be an integer"

  # No --jq anywhere: the hosts have no jq and the test stub serves plain JSON; parse with python3.
  if [ -z "$REPO" ]; then REPO=$(gh repo view --json nameWithOwner 2>/dev/null | bzr_json nameWithOwner || true); fi
  [ -n "$REPO" ] || bzr_die "--repo OWNER/REPO is required (or run inside a GitHub repository)"
  OWNER="${REPO%/*}"; NAME="${REPO#*/}"
  gh auth status >/dev/null 2>&1 || bzr_die "gh authentication failed"
  DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef 2>/dev/null | bzr_json defaultBranchRef.name || true)
  [ -n "$DEFAULT_BRANCH" ] || bzr_die "could not determine the default branch for $REPO"
  BZR_APPROVERS="${BZR_APPROVERS:-$(gh api user 2>/dev/null | bzr_json login || true)}"
  BZR_HOST="${BZR_HOST:-$(hostname -s 2>/dev/null || hostname)}"

  SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  BZR_HOME="${BZR_HOME:-$HOME/.bazaar}"
  BZR_REPO_DIR="$BZR_HOME/${OWNER}-${NAME}"
  mkdir -p "$BZR_REPO_DIR/logs" "$BZR_REPO_DIR/wt" "$BZR_REPO_DIR/run"
  LOCK_FILE="$BZR_REPO_DIR/${BZR_ROLE}.lock"
  STOP_FILE="$BZR_REPO_DIR/${BZR_ROLE}.stop"
  LOG="$BZR_REPO_DIR/logs/ctl-${BZR_ROLE}-$(date +%Y%m%d).log"
  BZR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bazaar-${BZR_ROLE}.XXXXXX") || exit 1
  BZR_ISSUES_JSON="$BZR_TMP/issues.json"
  LOCK_HELD=0
  BZR_CHILDREN="$BZR_TMP/children"; mkdir -p "$BZR_CHILDREN"   # <issue> → pid (bash 3.2: no assoc arrays)

  if [ "$STOP_REQ" -eq 1 ]; then
    touch "$STOP_FILE"; echo "stop requested: $STOP_FILE (running workers finish; no new dispatch)"; exit 0
  fi

  trap bzr_cleanup EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

  if [ "$DRY_RUN" -eq 0 ] && [ "$AUDIT" -eq 0 ]; then
    if [ -f "$LOCK_FILE" ]; then
      local old; old=$(sed -n 1p "$LOCK_FILE" 2>/dev/null || true)
      if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then bzr_die "bazaar-${BZR_ROLE} already running (pid $old): $LOCK_FILE"; fi
      rm -f "$LOCK_FILE"
    fi
    (set -C; printf '%s\n' "$$" > "$LOCK_FILE") 2>/dev/null || bzr_die "another bazaar-${BZR_ROLE} took $LOCK_FILE"
    LOCK_HELD=1
    rm -f "$STOP_FILE"
    touch "$LOG"
    bzr_ensure_labels || bzr_die "could not create bzr-* labels on $REPO"
  else
    LOG="$BZR_TMP/log"; touch "$LOG"
  fi
  bzr_log "start repo=$REPO workers=$WORKERS once=$ONCE interval=$INTERVAL model=$CONTROLLER_MODEL implementer=$IMPLEMENTER reviewer=$REVIEWER dry_run=$DRY_RUN audit=$AUDIT"
}

bzr_cleanup() {
  if [ "${LOCK_HELD:-0}" -eq 1 ] && [ -f "$LOCK_FILE" ]; then
    [ "$(sed -n 1p "$LOCK_FILE" 2>/dev/null)" = "$$" ] && rm -f "$LOCK_FILE"
  fi
  rm -rf "${BZR_TMP:-}"
}

bzr_label_meta() {  # <label> → "color<TAB>description"
  case "$1" in
    bzr-drafting)    printf 'c5def5\tIssue worker is drafting specs for this issue' ;;
    bzr-needs-info)  printf 'fbca04\tIssue worker asked questions; a human reply requeues it' ;;
    bzr-spec-review) printf '1d76db\tSpec PR is ready; awaiting human approval comment' ;;
    bzr-ready)       printf '0e8a16\tSpec approved; ready for the build worker' ;;
    bzr-building)    printf 'c5def5\tBuild worker is implementing this issue' ;;
    bzr-pr-ready)    printf '5319e7\tBuild PR converged; awaiting human merge' ;;
    bzr-blocked)     printf 'b60205\tEscalated to a human; remove this label to requeue' ;;
  esac
}
bzr_ensure_labels() {
  local l color desc
  for l in $BZR_LABELS; do
    IFS=$'\t' read -r color desc <<< "$(bzr_label_meta "$l")"
    gh label create "$l" --repo "$REPO" --color "$color" --description "$desc" --force >/dev/null 2>&1 || return 1
  done
}

# ---------- child registry (files, bash 3.2) ----------
bzr_child_pid() { cat "$BZR_CHILDREN/$1" 2>/dev/null; }
bzr_child_set() { printf '%s\n' "$2" > "$BZR_CHILDREN/$1"; }
bzr_child_unset() { rm -f "$BZR_CHILDREN/$1"; }
bzr_child_issues() { ls "$BZR_CHILDREN" 2>/dev/null; }

# ---------- comments and markers ----------

# bzr_comment issue|pr <number> <body-file>. Refuses an agent-authored body that
# contains the approval word unless the body carries a <!-- bzr- marker (marker
# comments are excluded from approval detection, so they may explain how to approve).
bzr_comment() {
  local kind="$1" num="$2" file="$3"
  if ! grep -qF '<!-- bzr-' "$file" && grep -qiE '(^|[^a-z])approved([^a-z]|$)' "$file"; then
    bzr_log "REFUSED comment on $kind #$num: agent comments may not contain the approval word"; return 2
  fi
  [ "$DRY_RUN" -eq 1 ] && { bzr_log "dry-run: would comment on $kind #$num"; return 0; }
  gh "$kind" comment "$num" --repo "$REPO" --body-file "$file" >> "$LOG" 2>&1
}

bzr_marker_comment() {  # <issue> <marker-line> [body-text]
  local f="$BZR_TMP/c-$1-$RANDOM.md"
  { printf '%s\n' "$2"; [ -n "${3:-}" ] && printf '\n%s\n' "$3"; } > "$f"
  bzr_comment issue "$1" "$f"
}

# All comments on an issue as TSV: createdAt<TAB>author<TAB>body-with-\n-escaped
bzr_issue_comments() {
  gh issue view "$1" --repo "$REPO" --json comments 2>/dev/null | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("comments", []):
    print("%s\t%s\t%s" % (c.get("createdAt", ""), (c.get("author") or {}).get("login", ""), (c.get("body") or "").replace("\n", "\\n")))'
}

bzr_issue_labels() { gh issue view "$1" --repo "$REPO" --json labels 2>/dev/null | python3 -c 'import json,sys; [print(l["name"]) for l in json.load(sys.stdin).get("labels", [])]'; }
bzr_has_label() { bzr_issue_labels "$1" | grep -qx "$2"; }

# add-then-remove, never the reverse (controller invariant 9)
bzr_transition() {  # <issue> <add-label|""> <remove-label|"">
  local issue="$1" add="$2" rm="$3"
  if [ "$DRY_RUN" -eq 1 ]; then bzr_log "dry-run: #$issue +${add:-∅} -${rm:-∅}"; return 0; fi
  if [ -n "$add" ]; then gh issue edit "$issue" --repo "$REPO" --add-label "$add" >> "$LOG" 2>&1 || return 1; fi
  if [ -n "$rm" ]; then gh issue edit "$issue" --repo "$REPO" --remove-label "$rm" >> "$LOG" 2>&1 || return 1; fi
}

# ---------- claims ----------

bzr_pid_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }
bzr_pid_alive() {  # <pid> <start-string>
  kill -0 "$1" 2>/dev/null || return 1
  [ -z "${2:-}" ] && return 0
  [ "$(bzr_pid_start "$1")" = "$2" ]
}

# Newest claim marker for this role on an issue: prints "host pid start" or nothing.
bzr_latest_claim() {
  bzr_issue_comments "$1" | grep -F "<!-- bzr-claim role=$BZR_ROLE " | tail -n 1 \
    | sed -E 's/.*<!-- bzr-claim role=[a-z]+ host=([^ ]+) pid=([0-9]+) start="([^"]*)".*/\1 \2 \3/'
}

bzr_post_claim() {  # <issue> <pid>   (called by the worker wrapper with its own pid)
  local start; start=$(bzr_pid_start "$2")
  bzr_marker_comment "$1" "<!-- bzr-claim role=$BZR_ROLE host=$BZR_HOST pid=$2 start=\"$start\" ts=$(bzr_now) -->"
}

# Is this claim held by a live process? 0 live, 1 dead-and-ours, 2 foreign host (leave alone)
bzr_claim_state() {  # <issue>
  local issue="$1" c host pid start
  [ -n "$(bzr_child_pid "$issue")" ] && return 0            # our registry: in flight (marker may not be posted yet)
  c=$(bzr_latest_claim "$issue")
  if [ -z "$c" ]; then return 1; fi                            # claim label, no marker, not ours → stale
  read -r host pid start <<< "$c"
  [ "$host" = "$BZR_HOST" ] || return 2
  bzr_pid_alive "$pid" "$start" && return 0
  return 1
}

# ---------- attempts ----------

bzr_attempt_count() {  # <issue> → number of bzr-attempt markers for this role after the last escalation
  bzr_issue_comments "$1" | awk -F'\t' -v role="$BZR_ROLE" '
    index($3, "<!-- bzr-escalated role=" role " ") { n = 0; next }
    index($3, "<!-- bzr-attempt role=" role " ")   { n++ }
    END { print n + 0 }'
}

# Record a transient failure. Returns the issue to its queue state, or escalates
# on the MAX_ATTEMPTS-th failure. Prints the new attempt count.
bzr_record_attempt() {  # <issue> <reason>
  local issue="$1" reason="$2" n
  n=$(( $(bzr_attempt_count "$issue") + 1 ))
  bzr_marker_comment "$issue" "<!-- bzr-attempt role=$BZR_ROLE n=$n reason=\"${reason//\"/\'}\" ts=$(bzr_now) -->" \
    "bazaar-${BZR_ROLE}: attempt $n of $MAX_ATTEMPTS failed: $reason"
  bzr_log "attempt #$issue n=$n reason=$reason"
  if [ "$n" -ge "$MAX_ATTEMPTS" ]; then
    bzr_escalate "$issue" "$n automatic attempts failed; last: $reason"
  else
    bzr_transition "$issue" "$(role_release_label)" "$(role_claim_label)"
  fi
  echo "$n"
}

bzr_escalate() {  # <issue> <reason>   → bzr-blocked replaces every other bzr-* state label; escalation marker
  local issue="$1" reason="$2" requeue l
  requeue="$(role_release_label)"; [ -n "$requeue" ] || requeue="no bzr-* label (intake)"
  bzr_transition "$issue" bzr-blocked ""
  for l in $(bzr_issue_labels "$issue" | grep '^bzr-' | grep -vx bzr-blocked || true); do bzr_transition "$issue" "" "$l"; done
  bzr_marker_comment "$issue" "<!-- bzr-escalated role=$BZR_ROLE attempts=$(bzr_attempt_count "$issue") ts=$(bzr_now) -->" \
    "bazaar-${BZR_ROLE}: escalated to a human. $reason

To requeue: fix the cause, remove \`bzr-blocked\`, and make sure the issue carries $requeue."
  bzr_log "escalate #$issue reason=$reason"
}

# ---------- queue ----------

# Fetch every open issue (GraphQL excludes PRs) into $BZR_ISSUES_JSON as an array of
# {number,title,createdAt,labels:[...],parent:<n|null>}.
bzr_fetch_issues() {
  local raw="$BZR_TMP/issues.raw"
  gh api graphql --paginate -F owner="$OWNER" -F name="$NAME" -f query='
    query($owner:String!,$name:String!,$endCursor:String){
      repository(owner:$owner,name:$name){
        issues(first:100, states:OPEN, after:$endCursor, orderBy:{field:CREATED_AT,direction:ASC}){
          pageInfo{hasNextPage endCursor}
          nodes{ number title createdAt body labels(first:50){nodes{name}} parent{number} }
        } } }' > "$raw" 2>>"$LOG" || { : > "$BZR_ISSUES_JSON"; return 1; }
  python3 - "$raw" > "$BZR_ISSUES_JSON" <<'PY2' 2>>"$LOG" || { : > "$BZR_ISSUES_JSON"; return 1; }
import json, sys
out = []
dec = json.JSONDecoder(); buf = open(sys.argv[1]).read(); i = 0
while i < len(buf):
    while i < len(buf) and buf[i].isspace(): i += 1
    if i >= len(buf): break
    obj, j = dec.raw_decode(buf, i); i = j
    for n in obj["data"]["repository"]["issues"]["nodes"]:
        out.append({"number": n["number"], "title": n["title"], "createdAt": n["createdAt"],
                    "labels": [l["name"] for l in n["labels"]["nodes"]],
                    "parent": (n.get("parent") or {}).get("number"),
                    "sub_marker": "<!-- bzr-sub-issue" in (n.get("body") or "")})
json.dump(out, sys.stdout)
PY2
}

# Issue-list queries run through python3 (no jq on the hosts). $1 is a python
# expression over `i` (an issue dict) used as a filter; priority mirrors the
# `issues` helper's label rank, lower is better.
BZR_PY_PRIO='
RANK = ["p0","priority:critical","p1","priority:high","high","p2","priority:medium","medium","p3","priority:low","low"]
def prio(i):
    l = {x.lower() for x in i["labels"]}
    for k, p in enumerate(RANK):
        if p in l: return k
    return 99
'
bzr_candidates() {  # <python-filter-expr over i>
  python3 - "$BZR_ISSUES_JSON" "$1" <<PY2 2>>"$LOG"
import json, sys
$BZR_PY_PRIO
issues = json.load(open(sys.argv[1])); expr = sys.argv[2]
c = [i for i in issues if i["parent"] is None and eval(expr, {}, {"i": i})]
c.sort(key=lambda i: (prio(i), i["createdAt"]))
print("\n".join(str(i["number"]) for i in c))
PY2
}
bzr_issue_field() {  # <number> <key>
  python3 -c 'import json,sys; n=int(sys.argv[2]); print(next((str(i[sys.argv[3]]) for i in json.load(open(sys.argv[1])) if i["number"]==n), ""))' "$BZR_ISSUES_JSON" "$1" "$2" 2>/dev/null
}
bzr_issue_prio() {
  python3 - "$BZR_ISSUES_JSON" "$1" <<PY2 2>/dev/null
import json, sys
$BZR_PY_PRIO
n = int(sys.argv[2]); print(next((prio(i) for i in json.load(open(sys.argv[1])) if i["number"] == n), 99))
PY2
}
bzr_issues_with_label() {  # <label> → numbers
  python3 - "$BZR_ISSUES_JSON" "$1" <<'PY2' 2>/dev/null
import json, sys
for i in json.load(open(sys.argv[1])):
    if sys.argv[2] in i["labels"]: print(i["number"])
PY2
}

# Model tie-break among equal-top-priority candidates. Prints one number from the list.
bzr_pick() {  # <numbers...>
  [ "$#" -gt 0 ] || return 1
  local first="$1" top; top=$(bzr_issue_prio "$first")
  local -a tied=(); local n
  for n in "$@"; do [ "$(bzr_issue_prio "$n")" = "$top" ] && tied+=("$n"); done
  if [ "${#tied[@]}" -le 1 ] || [ "$CONTROLLER_MODEL" = none ]; then echo "$first"; return 0; fi
  local list="" ans
  for n in "${tied[@]}"; do list="$list- #$n: $(bzr_issue_field "$n" title)"$'\n'; done
  ans=$(claude -p "Pick the single most valuable issue to work on next from this list. Reply with ONLY the issue number, digits only, nothing else.
$list" --model "$CONTROLLER_MODEL" --effort low --output-format text 2>>"$LOG" < /dev/null | tr -dc '0-9' | head -c 12)
  for n in "${tied[@]}"; do [ "$ans" = "$n" ] && { bzr_log "tie-break model chose #$n of ${tied[*]}"; echo "$n"; return 0; }; done
  bzr_log "tie-break model answer '$ans' not in candidates; using sort order"
  echo "$first"
}

# ---------- workers ----------

bzr_reap() {  # collect finished children, hand outcomes to the role
  local issue pid rc sentinel word rest
  for issue in $(bzr_child_issues); do
    pid=$(bzr_child_pid "$issue")
    kill -0 "$pid" 2>/dev/null && continue
    rc=0; wait "$pid" 2>/dev/null || rc=$?
    bzr_child_unset "$issue"
    sentinel=$(tail -n 1 "$BZR_REPO_DIR/run/$issue.sentinel" 2>/dev/null || true)
    word="${sentinel%% *}"; rest="${sentinel#"$word"}"; rest="${rest# }"
    bzr_log "worker-exit #$issue rc=$rc sentinel=${word:-none}"
    if [ -z "$word" ] || [ "$word" = STUCK ]; then
      bzr_record_attempt "$issue" "${rest:-worker exited rc=$rc without a sentinel}" >/dev/null
    elif ! role_on_worker_exit "$issue" "$rc" "$word" "$rest"; then
      bzr_record_attempt "$issue" "$word $rest" >/dev/null
    fi
  done
}

bzr_live_workers() { local n=0 i; for i in $(bzr_child_issues); do kill -0 "$(bzr_child_pid "$i")" 2>/dev/null && n=$((n+1)); done; echo "$n"; }

bzr_spawn() {  # <issue>
  local issue="$1" cmd wt branch log
  cmd=$(role_worker_cmd "$issue")
  log="$BZR_REPO_DIR/logs/${BZR_ROLE}-${issue}-$(date +%Y%m%d-%H%M%S).log"
  rm -f "$BZR_REPO_DIR/run/$issue.sentinel"
  (
    export BZR_ROLE BZR_ISSUE="$issue" BZR_REPO="$REPO" BZR_REPO_DIR BZR_HOME BZR_HOST BZR_LOG="$log" DEFAULT_BRANCH \
           BZR_SENTINEL="$BZR_REPO_DIR/run/$issue.sentinel" SCRIPTS_DIR BZR_APPROVERS \
           IMPLEMENTER IMPLEMENTER_MODEL IMPLEMENTER_EFFORT REVIEWER REVIEWER_MODEL REVIEWER_EFFORT \
           MAX_REVIEW_CYCLES="${MAX_REVIEW_CYCLES:-6}" MAX_SPEC_REVIEW_CYCLES="${MAX_SPEC_REVIEW_CYCLES:-6}"
    bzr_post_claim "$issue" "$(bash -c 'echo $PPID')" || true   # bash 3.2 has no BASHPID
    exec $cmd >> "$log" 2>&1
  ) &
  bzr_child_set "$issue" "$!"
  bzr_log "dispatch #$issue worker=$! log=$log"
}

# Dead-pid release for this role's claim label. Foreign-host claims are skipped.
bzr_sweep_dead_claims() {
  local issue st
  for issue in $(bzr_issues_with_label "$(role_claim_label)"); do
    st=0; bzr_claim_state "$issue" || st=$?
    case "$st" in
      1) bzr_log "dead-pid-release #$issue"; bzr_record_attempt "$issue" "worker process died" >/dev/null ;;
      2) bzr_log "skip #$issue foreign-host-claim" ;;
    esac
  done
}

# ---------- audit ----------

bzr_audit_common() {
  local issue labels n st
  python3 -c 'import json,sys
for i in json.load(open(sys.argv[1])):
    if i["parent"] is None: print("%d\t%s" % (i["number"], ",".join(l for l in i["labels"] if l.startswith("bzr-"))))' "$BZR_ISSUES_JSON" \
  | while IFS=$'\t' read -r issue labels; do
      n=$(printf '%s' "$labels" | tr ',' '\n' | grep -c . || true)
      [ "$n" -gt 1 ] && echo "AUDIT #$issue carries $n bzr labels: $labels"
      case ",$labels," in *",$(role_claim_label),"*)
        st=0; bzr_claim_state "$issue" || st=$?; [ "$st" -eq 1 ] && echo "AUDIT #$issue claim names a dead pid" ;;
      esac
    done
  declare -F role_audit >/dev/null && role_audit
  return 0
}


# ---------- repo checkout, spec files, sub-issues (shared by controllers and workers) ----------

# The git repo we run in, else a clone kept under BZR_REPO_DIR.
bzr_project_root() {
  local top; top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$top" ]; then echo "$top"; return 0; fi
  local clone="$BZR_REPO_DIR/clone"
  [ -d "$clone/.git" ] || gh repo clone "$REPO" "$clone" -- --quiet >>"$LOG" 2>&1 || return 1
  echo "$clone"
}

# Repo-relative spec directory at a git ref: WORK_PREP_SPEC_DIR, else specs/, else the
# first *-specs/ directory. Prints nothing (rc 1) when the repo has no corpus.
bzr_spec_dir_at() {  # <repo-root> <ref>
  local root="$1" ref="$2" d
  if [ -n "${WORK_PREP_SPEC_DIR:-}" ]; then echo "${WORK_PREP_SPEC_DIR%/}"; return 0; fi
  if git -C "$root" cat-file -e "$ref:specs" 2>/dev/null; then echo specs; return 0; fi
  d=$(git -C "$root" ls-tree --name-only "$ref" 2>/dev/null | grep -- '-specs$' | head -n 1)
  [ -n "$d" ] && { echo "$d"; return 0; }
  return 1
}

# Append "id<TAB>relpath<TAB>title" to <tsv> when <file> is a spec_type: task spec.
bzr_l4_from_file() {  # <file> <relpath> <tsv>
  python3 - "$1" "$2" "$3" <<'PY' 2>/dev/null || true
import re, sys
s = open(sys.argv[1]).read(); rel, l4out = sys.argv[2], sys.argv[3]
m = re.match(r"^---\n(.*?)\n---\n", s, re.S)
if not m: sys.exit(0)
fm = m.group(1)
st = re.search(r"^spec_type:\s*(\S+)", fm, re.M)
if not st or st.group(1) != "task": sys.exit(0)
sid = (re.search(r"^id:\s*(\S+)", fm, re.M) or [None, ""])[1]
t = re.search(r"^## TL;DR\s*\n+(.+)", s, re.M)
title = re.split(r"(?<=[.!?])\s", t.group(1).strip())[0][:120] if t else rel
open(l4out, "a").write("%s\t%s\t%s\n" % (sid, rel, title))
PY
}

# status: review → status: ready in a spec file's frontmatter. rc 0 changed, 1 not.
bzr_flip_status_ready() {  # <file>
  python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?)\n---\n", s, re.S)
if not m or not re.search(r"^spec_type:", m.group(1), re.M): sys.exit(1)
new = re.sub(r"^status:\s*review\s*$", "status: ready", m.group(1), count=1, flags=re.M)
if new == m.group(1): sys.exit(1)
open(sys.argv[1], "w").write(s[:m.start(1)] + new + s[m.end(1):])
PY
}

bzr_sub_issue_markers() {  # <parent> → lines "number state spec-id"
  gh api "repos/$REPO/issues/$1/sub_issues" 2>>"$LOG" | python3 -c '
import json, sys, re
for c in json.load(sys.stdin):
    m = re.search(r"<!-- bzr-sub-issue parent=\d+ spec=(\S+) -->", c.get("body") or "")
    print(c["number"], c.get("state", "open").upper(), m.group(1) if m else "-")'
}

bzr_create_sub_issue() {  # <parent> <spec-id> <path> <title> → number
  local parent="$1" sid="$2" path="$3" title="$4" url num id body
  body="$BZR_TMP/sub-$parent-$RANDOM.md"
  printf '<!-- bzr-sub-issue parent=%s spec=%s -->\nImplements %s (`%s`), part of #%s.\n\nRefs #%s\n' "$parent" "$sid" "$sid" "$path" "$parent" "$parent" > "$body"
  url=$(gh issue create --repo "$REPO" --title "$title" --body-file "$body" 2>>"$LOG") || return 1
  num="${url##*/}"
  # The attach call needs the numeric REST id; `gh issue view --json id` returns the
  # GraphQL node id (I_kw…) and GitHub answers 422. Verified 2026-09-20.
  id=$(gh api "repos/$REPO/issues/$num" 2>>"$LOG" | bzr_json id)
  gh api -X POST "repos/$REPO/issues/$parent/sub_issues" -F "sub_issue_id=$id" >>"$LOG" 2>&1 \
    || bzr_log "WARNING: created #$num but could not attach it as a sub-issue of #$parent"
  echo "$num"
}

# Reconcile marker sub-issues with an L4 list (tsv: id, path, title): create
# missing, close dropped. Zero or one L4 → no sub-issues wanted. A missing tsv
# means "unknown", never "empty": nothing is touched. Prints kept/created numbers.
bzr_reconcile_sub_issues() {  # <parent> <tsv>
  local parent="$1" tsv="$2" sid path title num st want="" n_l4 existing
  [ -f "$tsv" ] || { bzr_log "reconcile #$parent: no L4 list available; leaving sub-issues untouched"; return 0; }
  n_l4=$(grep -c . "$tsv" || true)
  if [ "$n_l4" -ge 2 ]; then while IFS=$'\t' read -r sid path title; do [ -n "$sid" ] && want="$want $sid"; done < "$tsv"; fi
  existing=$(bzr_sub_issue_markers "$parent")
  if [ -n "$want" ]; then
    while IFS=$'\t' read -r sid path title; do
      [ -n "$sid" ] || continue
      if printf '%s\n' "$existing" | awk -v s="$sid" '$2=="OPEN" && $3==s {f=1} END{exit !f}'; then
        printf '%s\n' "$existing" | awk -v s="$sid" '$2=="OPEN" && $3==s {print $1}'
      else
        num=$(bzr_create_sub_issue "$parent" "$sid" "$path" "$title") && { bzr_log "sub-issue #$num created for $sid"; echo "$num"; }
      fi
    done < "$tsv"
  fi
  while read -r num st sid; do
    [ -n "$num" ] && [ "$st" = OPEN ] || continue
    case " $want " in *" $sid "*) ;; *)
      bzr_log "sub-issue #$num ($sid) not in the current spec set → closing"
      printf 'bazaar: the current spec set no longer contains %s; closing this sub-issue.\n' "$sid" > "$BZR_TMP/close-$num.md"
      bzr_comment issue "$num" "$BZR_TMP/close-$num.md"; gh issue close "$num" --repo "$REPO" >>"$LOG" 2>&1 || true ;;
    esac
  done <<< "$existing"
}

# ---------- main loop ----------

bzr_tick() {
  bzr_reap
  if ! bzr_fetch_issues; then
    BZR_GH_FAILS=$(( ${BZR_GH_FAILS:-0} + 1 )); bzr_log "gh read failed ($BZR_GH_FAILS consecutive)"
    [ "$BZR_GH_FAILS" -ge 3 ] && bzr_die "gh unavailable for 3 consecutive ticks"
    return 0
  fi
  BZR_GH_FAILS=0
  if [ "$AUDIT" -eq 1 ]; then bzr_audit_common; return 0; fi
  if [ "$DRY_RUN" -eq 1 ]; then declare -F role_dry_sweeps >/dev/null && role_dry_sweeps
  else bzr_sweep_dead_claims; role_sweeps; bzr_fetch_issues || return 0; fi
  [ -f "$STOP_FILE" ] && { bzr_log "stop file present; no dispatch"; return 0; }

  local free; free=$(( WORKERS - $(bzr_live_workers) ))
  [ "$free" -le 0 ] && return 0
  local -a cands=(); local n
  for n in $(role_candidates); do
    [ -n "$(bzr_child_pid "$n")" ] && continue
    cands+=("$n")
  done
  [ "${#cands[@]}" -eq 0 ] && { bzr_log "tick: queue empty"; return 0; }

  while [ "$free" -gt 0 ] && [ "${#cands[@]}" -gt 0 ]; do
    local pick; pick=$(bzr_pick "${cands[@]}")
    local -a rest=(); for n in "${cands[@]}"; do [ "$n" != "$pick" ] && rest+=("$n"); done; cands=("${rest[@]+"${rest[@]}"}")
    if [ "$DRY_RUN" -eq 1 ]; then echo "would dispatch #$pick"; free=$((free-1)); continue; fi
    # re-read labels immediately before claiming (invariant 4)
    local live; live=$(bzr_issue_labels "$pick" | grep '^bzr-' || true)
    local q; q=$(role_queue_label)
    if [ "${BZR_SKIP_LABEL_CHECK:-0}" -ne 1 ] && { { [ -z "$q" ] && [ -n "$live" ]; } || { [ -n "$q" ] && [ "$live" != "$q" ]; }; }; then
      bzr_log "skip #$pick labels-changed ($(printf '%s' "$live" | tr '\n' ','))"; continue
    fi
    [ "${BZR_SKIP_LABEL_CHECK:-0}" -eq 1 ] && q=$(printf '%s' "$live" | head -n 1)   # --force: drop whatever bzr label it has
    if ! bzr_transition "$pick" "$(role_claim_label)" "$q"; then
      bzr_log "claim-failed #$pick"; gh issue edit "$pick" --repo "$REPO" --remove-label "$(role_claim_label)" >>"$LOG" 2>&1 || true; continue
    fi
    bzr_spawn "$pick"; free=$((free-1))
  done
  for n in "${cands[@]+"${cands[@]}"}"; do bzr_log "skip #$n no-slot"; done
}

bzr_controller_main() {
  while :; do
    bzr_tick
    if [ "$ONCE" -eq 1 ] || [ "$AUDIT" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then break; fi
    if [ -f "$STOP_FILE" ] && [ "$(bzr_live_workers)" -eq 0 ]; then bzr_log "stopped"; break; fi
    sleep "$INTERVAL"
  done
  # --once still waits for its workers so the sentinel is handled in this process
  while [ "$(bzr_live_workers)" -gt 0 ]; do sleep 1; done
  bzr_reap
  return 0
}
