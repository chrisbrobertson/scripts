#!/usr/bin/env bash
# bazaar-build-worker.sh <issue> — one bzr-ready parent issue: precheck → plan →
# implement each unit (sub-issue) sequentially on one branch → code review cycle
# per unit (skip and revert non-converging units) → PR ready → sentinel.
# Spawned by bazaar-build.sh. Never merges.
# Spec: bazaar-builder-specs/L3-build-worker.md (BZR-FEAT-BUILD-WORKER).
#
# Env from the controller: BZR_ISSUE BZR_REPO BZR_REPO_DIR BZR_HOME BZR_HOST BZR_LOG
#   DEFAULT_BRANCH BZR_SENTINEL SCRIPTS_DIR IMPLEMENTER* REVIEWER* MAX_REVIEW_CYCLES
# Sentinel: PR_READY <pr> | SPEC_GAP <reason> | BLOCKED <reason> | STUCK <reason>
# Labels: the worker never touches the parent's labels; it may add bzr-blocked to a
# SKIPPED SUB-ISSUE (the one worker exception, see the controller L3).
#
# PR body markers (all wrapper-owned):
#   <!-- bzr-build issue=N round=R -->
#   <!-- bzr-build-state {"converged":{"<unit>":"<from>..<to>"},"skipped":{"<unit>":"<reason>"}} -->
#   Closes #<unit> per converged unit; Closes #N only when nothing was skipped.
set -uo pipefail
BZR_SCRIPT_VERSION="0.1.0"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ISSUE="${1:-${BZR_ISSUE:-}}"; [ -n "$ISSUE" ] || { echo "usage: bazaar-build-worker.sh <issue>" >&2; exit 2; }
BZR_ROLE=build; BZR_LOG_TAG="build-worker"; REPO="${BZR_REPO:?}"; LOG="${BZR_LOG:?}"; DRY_RUN=0
BZR_REPO_DIR="${BZR_REPO_DIR:?}"; DEFAULT_BRANCH="${DEFAULT_BRANCH:?}"; BZR_SENTINEL="${BZR_SENTINEL:?}"
IMPLEMENTER="${IMPLEMENTER:-claude}"; REVIEWER="${REVIEWER:-codex}"
MAX_REVIEW_CYCLES="${MAX_REVIEW_CYCLES:-6}"
. "$SCRIPTS_DIR/lib/bazaar-common.sh"
. "$SCRIPTS_DIR/lib/bazaar-review.sh"

BZR_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bzr-build-worker.XXXXXX") || exit 1
TMP_REVIEW="$BZR_TMP/review"; TMP_CODEX_FULL="$BZR_TMP/codex-full"; TMP_REVIEW_RESULT="$BZR_TMP/review-result"
RUN_DIR="$BZR_TMP/run"; mkdir -p "$RUN_DIR"; export BZR_RUN_DIR="$RUN_DIR"
STATE="$BZR_TMP/state.json"; printf '{"converged":{},"skipped":{}}' > "$STATE"
SENTINEL_WRITTEN=0; ROOT=""; WT=""; BRANCH=""; PR=""

sentinel() { printf '%s %s\n' "$1" "${2:-}" | sed 's/ $//' > "$BZR_SENTINEL"; SENTINEL_WRITTEN=1; bzr_log "#$ISSUE sentinel=$1 ${2:-}"; }
finish() {
  local rc=$?
  [ "$SENTINEL_WRITTEN" -eq 1 ] || sentinel STUCK "worker exited rc=$rc before reaching a decision"
  if [ -n "$WT" ] && { [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; }; then
    git -C "$WT" push --quiet origin "HEAD:refs/heads/$BRANCH" >>"$LOG" 2>&1 || true
    [ -n "$ROOT" ] && git -C "$ROOT" worktree remove --force "$WT" >>"$LOG" 2>&1 || true
  fi
  rm -rf "$BZR_TMP"
}
trap finish EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
marker() { printf '<!-- bzr-build-worker phase=%s ts=%s -->' "$1" "$(bzr_now)"; }
comment_issue() { local f="$BZR_TMP/ci-$RANDOM.md"; { marker "$1"; printf '\n'; cat "$2"; } > "$f"; bzr_comment issue "$ISSUE" "$f"; }
last_line() { sed -e 's/[[:space:]]*$//' "$1" | grep -v '^$' | tail -n 1; }

# ---------- gather ----------
ROOT=$(bzr_project_root) || { sentinel STUCK "no local checkout of $REPO"; exit 1; }
git -C "$ROOT" fetch --quiet origin "$DEFAULT_BRANCH" >>"$LOG" 2>&1 || { sentinel STUCK "fetch origin/$DEFAULT_BRANCH failed"; exit 1; }
BASE_SHA=$(git -C "$ROOT" rev-parse "origin/$DEFAULT_BRANCH")
gh issue view "$ISSUE" --repo "$REPO" --json title,body,state > "$BZR_TMP/issue.json" 2>>"$LOG" || { sentinel STUCK "gh issue view failed"; exit 1; }
TITLE=$(bzr_json title < "$BZR_TMP/issue.json"); BODY=$(bzr_json body < "$BZR_TMP/issue.json")
[ "$(bzr_json state < "$BZR_TMP/issue.json")" = OPEN ] || { sentinel BLOCKED "issue is not open"; exit 0; }
gh api "repos/$REPO/issues/$ISSUE/sub_issues" > "$BZR_TMP/subs.json" 2>>"$LOG" || echo "[]" > "$BZR_TMP/subs.json"

# ---------- precheck (bash, no model) ----------
# Writes $RUN_DIR/specs.tsv (path, spec_type, id, status) and $RUN_DIR/units.tsv
# (unit, l4-path, l4-id, title, blocked-by-csv). Prints gap reasons.
python3 - "$BZR_TMP/issue.json" "$BZR_TMP/subs.json" "$ROOT" "$DEFAULT_BRANCH" "$RUN_DIR" "$ISSUE" > "$BZR_TMP/gaps" <<'PY'
import json, re, subprocess, sys, os
issue, subs, root, base, run, num = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
gaps = []
m = re.search(r"^Specs:\s*(.+)$", issue.get("body") or "", re.M)
paths = re.findall(r"`([^`]+)`", m.group(1)) if m else []
if not paths: gaps.append("the issue body has no `Specs:` line naming spec files (the approval sweep writes it)")
specs = {}
for p in paths:
    if p.startswith("/") or ".." in p.split("/"): gaps.append("unsafe spec path %s" % p); continue
    r = subprocess.run(["git", "-C", root, "show", "origin/%s:%s" % (base, p)], capture_output=True, text=True)
    if r.returncode != 0: gaps.append("spec %s does not exist on origin/%s" % (p, base)); continue
    fm = re.match(r"^---\n(.*?)\n---\n", r.stdout, re.S)
    if not fm or not re.search(r"^spec_type:", fm.group(1), re.M):
        print("precheck: %s has no spec frontmatter; ignored" % p, file=sys.stderr); continue
    f = fm.group(1)
    g = lambda k: (re.search(r"^%s:\s*(\S+)" % k, f, re.M) or [None, ""])[1]
    st, sid, status = g("spec_type"), g("id"), g("status")
    if status != "ready": gaps.append("spec %s is status: %s, not ready" % (p, status or "?"))
    t = re.search(r"^## TL;DR\s*\n+(.+)", r.stdout, re.M)
    specs[p] = {"type": st, "id": sid, "status": status, "title": (re.split(r"(?<=[.!?])\s", t.group(1).strip())[0][:120] if t else p),
                "depends": re.findall(r"[A-Z][A-Z0-9]+-TASK-[A-Z0-9-]+", (re.search(r"^depends_on:\s*\[(.*?)\]", f, re.M) or [None, ""])[1])}
with open(os.path.join(run, "specs.tsv"), "w") as out:
    for p, s in specs.items(): out.write("%s\t%s\t%s\t%s\n" % (p, s["type"], s["id"], s["status"]))
l4_by_id = {s["id"]: p for p, s in specs.items() if s["type"] == "task"}
units = []
open_subs = [c for c in subs if (c.get("state") or "open").lower() == "open"]
for c in open_subs:
    labels = [l["name"] if isinstance(l, dict) else l for l in c.get("labels", [])]
    mk = re.search(r"<!-- bzr-sub-issue parent=\d+ spec=(\S+) -->", c.get("body") or "")
    if not mk: gaps.append("sub-issue #%s has no bzr-sub-issue marker" % c["number"]); continue
    if mk.group(1) not in l4_by_id: gaps.append("sub-issue #%s references %s, which is not an L4 in the Specs: line" % (c["number"], mk.group(1))); continue
    if "bzr-blocked" in labels: continue
    p = l4_by_id[mk.group(1)]
    blocked_by = re.findall(r"[Bb]locked by #(\d+)", c.get("body") or "")
    dep_ids = specs[p]["depends"]; dep_nums = [str(d["number"]) for d in open_subs if re.search(r"spec=(%s) -->" % "|".join(map(re.escape, dep_ids)), d.get("body") or "")] if dep_ids else []
    units.append((str(c["number"]), p, mk.group(1), c.get("title") or p, ",".join(sorted(set(blocked_by + dep_nums)))))
if not open_subs:
    l4s = [p for p, s in specs.items() if s["type"] == "task"]
    if not l4s: gaps.append("no sub-issues and no L4 task spec in the Specs: line")
    else: units.append((num, " ".join(l4s), " ".join(specs[p]["id"] for p in l4s), issue.get("title") or "", ""))
with open(os.path.join(run, "units.tsv"), "w") as out:
    for u in units: out.write("\t".join(u) + "\n")
if gaps: print("\n".join(gaps))
PY
if [ -s "$BZR_TMP/gaps" ]; then
  { printf 'bazaar-build: precheck failed, nothing was built.\n\n'; sed 's/^/- /' "$BZR_TMP/gaps"; printf '\nFix the above and remove `bzr-blocked`.\n'; } > "$BZR_TMP/gap.md"
  comment_issue precheck "$BZR_TMP/gap.md"; sentinel SPEC_GAP "$(head -n 1 "$BZR_TMP/gaps")"; exit 0
fi
[ -s "$RUN_DIR/units.tsv" ] || { sentinel BLOCKED "every remaining sub-issue is bzr-blocked; nothing to build"; exit 0; }
L3_PATHS=$(awk -F'\t' '$2=="feature"{print $1}' "$RUN_DIR/specs.tsv" | tr '\n' ' ')

# ---------- round, branch, resume ----------
SLUG=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-30); [ -n "$SLUG" ] || SLUG=issue
gh pr list --repo "$REPO" --state all --limit 200 --json number,state,body,headRefName,isDraft > "$BZR_TMP/prs.json" 2>>"$LOG" || echo "[]" > "$BZR_TMP/prs.json"
read -r ROUND PR BRANCH_EXISTING <<< "$(python3 - "$BZR_TMP/prs.json" "$ISSUE" <<'PY'
import json, re, sys
prs = json.load(open(sys.argv[1])); n = sys.argv[2]
mine = [(int((re.search(r"<!-- bzr-build issue=%s round=(\d+) -->" % n, p.get("body") or "") or [None, "0"])[1]), p) for p in prs]
mine = [(r, p) for r, p in mine if r]
merged = [r for r, p in mine if p["state"] == "MERGED"]
open_ = [(r, p) for r, p in mine if p["state"] == "OPEN"]
if open_:
    r, p = max(open_, key=lambda x: x[0]); print(r, p["number"], p["headRefName"])
else:
    print((max(merged) + 1) if merged else 1, "", "")
PY
)"
if [ -n "$BRANCH_EXISTING" ]; then BRANCH="$BRANCH_EXISTING"; else BRANCH="bzr/$ISSUE-$SLUG"; [ "$ROUND" -gt 1 ] && BRANCH="$BRANCH-r$ROUND"; fi
WT="$BZR_REPO_DIR/wt/$ISSUE"
git -C "$ROOT" worktree prune >>"$LOG" 2>&1 || true; rm -rf "$WT"
if git -C "$ROOT" fetch --quiet origin "$BRANCH" >>"$LOG" 2>&1; then
  git -C "$ROOT" worktree add --quiet --detach "$WT" FETCH_HEAD >>"$LOG" 2>&1 || { sentinel STUCK "worktree add (resume) failed"; exit 1; }
  bzr_log "#$ISSUE round=$ROUND resuming branch $BRANCH (PR ${PR:-none})"
else
  git -C "$ROOT" worktree add --quiet --detach "$WT" "$BASE_SHA" >>"$LOG" 2>&1 || { sentinel STUCK "worktree add failed"; exit 1; }
  bzr_log "#$ISSUE round=$ROUND new branch $BRANCH"
fi
git -C "$WT" config user.name "bazaar-build-worker" >/dev/null; git -C "$WT" config user.email "bazaar@localhost" >/dev/null
if [ -n "$PR" ]; then
  gh pr view "$PR" --repo "$REPO" --json body 2>>"$LOG" | python3 -c '
import json, re, sys
b = json.load(sys.stdin).get("body") or ""
m = re.search(r"<!-- bzr-build-state (\{.*?\}) -->", b, re.S)
print(m.group(1) if m else json.dumps({"converged": {}, "skipped": {}}))' > "$STATE"
fi
state_get() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(json.dumps(s[sys.argv[2]]))' "$STATE" "$1"; }
state_set() {  # <converged|skipped> <unit> <value>
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s[sys.argv[2]][sys.argv[3]]=sys.argv[4]; json.dump(s,open(sys.argv[1],"w"))' "$STATE" "$1" "$2" "$3"
}
state_has() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[3] in s[sys.argv[2]] else 1)' "$STATE" "$1" "$2"; }

render_pr_body() {  # → $BZR_TMP/prbody.md
  python3 - "$STATE" "$ISSUE" "$ROUND" "$TITLE" "$RUN_DIR/units.tsv" > "$BZR_TMP/prbody.md" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); n, r, title = sys.argv[2], sys.argv[3], sys.argv[4]
units = [l.rstrip("\n").split("\t") for l in open(sys.argv[5]) if l.strip()]
print("<!-- bzr-build issue=%s round=%s -->" % (n, r))
print("<!-- bzr-build-state %s -->" % json.dumps(s, sort_keys=True))
print("## Build for #%s (round %s): %s\n" % (n, r, title))
conv, skip = s["converged"], s["skipped"]
done_all = all(u[0] in conv for u in units) and not skip
for u in units:
    if u[0] in conv and u[0] != n: print("Closes #%s" % u[0])
if done_all or (len(units) == 1 and units[0][0] == n and n in conv): print("Closes #%s" % n)
else: print("Refs #%s" % n)
print("\n| unit | spec | status |\n|---|---|---|")
for u in units:
    st = "converged" if u[0] in conv else ("skipped: " + skip[u[0]] if u[0] in skip else "pending")
    print("| #%s | `%s` | %s |" % (u[0], u[1], st))
print("\nBuilt by bazaar-build-worker; reviewed per unit by the convergent review cycle. A human merges this PR.")
PY
}
ensure_pr() {  # opens the draft PR after the first push if none exists; always syncs the body
  render_pr_body
  if [ -z "$PR" ]; then
    local url; url=$(gh pr create --repo "$REPO" --head "$BRANCH" --base "$DEFAULT_BRANCH" --draft --title "#$ISSUE $TITLE" --body-file "$BZR_TMP/prbody.md" 2>>"$LOG") || { sentinel STUCK "gh pr create failed"; exit 1; }
    PR="${url##*/}"; bzr_log "#$ISSUE draft PR #$PR opened on $BRANCH"
  else
    gh pr edit "$PR" --repo "$REPO" --body-file "$BZR_TMP/prbody.md" >/dev/null 2>>"$LOG" || true
  fi
}

# ---------- plan ----------
N_UNITS=$(grep -c . "$RUN_DIR/units.tsv")
# deterministic order: units whose blockers are all satisfied first, then by number
python3 - "$RUN_DIR/units.tsv" > "$RUN_DIR/order.txt" <<'PY'
import sys
units = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
deps = {u[0]: set(x for x in u[4].split(",") if x) for u in units}
order, seen = [], set()
while len(order) < len(units):
    ready = sorted([u for u in deps if u not in seen and deps[u] <= seen], key=int)
    if not ready: ready = sorted([u for u in deps if u not in seen], key=int)[:1]
    order.append(ready[0]); seen.add(ready[0])
print("\n".join(order))
PY
if [ "$N_UNITS" -ge 2 ] && ! gh issue view "$ISSUE" --repo "$REPO" --json comments 2>>"$LOG" | grep -q "bzr-build-plan issue=$ISSUE round=$ROUND"; then
  cat > "$BZR_TMP/promptP.txt" <<EOP
You are the planning step of Bazaar Builder for parent issue #$ISSUE in $REPO (round $ROUND). Do not change any file and do not run gh or git write commands.

Feature specs: $L3_PATHS
Units to implement (sub-issue number, L4 spec path, L4 id, title, explicit blockers):
$(cat "$RUN_DIR/units.tsv")

A dependency-respecting default order is: $(tr '\n' ' ' < "$RUN_DIR/order.txt")

Read the L4 specs and the code they touch. Decide the implementation order and, for each unit, name the units it depends on (shared files, data model first, API before UI, etc.).
Output EXACTLY one line per unit, in order, of the form:
PLAN #<unit> depends=<comma-separated unit numbers or none> — <one-line reason>
then end your final message with the sentinel PLAN_POSTED on its own last line.
EOP
  echo "  [$IMPLEMENTER implementer] planning #$ISSUE ($N_UNITS units)..." >&2
  if run_implementer "$(cat "$BZR_TMP/promptP.txt")" "$BZR_TMP/resultP" "$WT" && [ "$(last_line "$BZR_TMP/resultP")" = PLAN_POSTED ]; then
    python3 - "$BZR_TMP/resultP" "$RUN_DIR/units.tsv" "$RUN_DIR/order.txt" <<'PY'
import re, sys
units = [l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if l.strip()]
nums = [u[0] for u in units]
plan = re.findall(r"^PLAN #(\d+) depends=([\d,]*|none)", open(sys.argv[1]).read(), re.M)
order = [p[0] for p in plan]
if sorted(order) == sorted(nums):
    open(sys.argv[3], "w").write("\n".join(order) + "\n")
    deps = {p[0]: [d for d in p[1].split(",") if d and d != "none"] for p in plan}
    with open(sys.argv[2], "w") as f:
        for u in units: f.write("\t".join(u[:4] + [",".join(sorted(set(deps.get(u[0], []) + [x for x in u[4].split(",") if x])))]) + "\n")
    print("plan accepted")
else:
    print("plan rejected (not a permutation of the units); keeping the deterministic order")
PY
  else
    bzr_log "#$ISSUE plan pass failed; keeping the deterministic order"
  fi
  { printf '<!-- bzr-build-plan issue=%s round=%s -->\nbazaar-build: implementation order for round %s:\n\n' "$ISSUE" "$ROUND" "$ROUND"
    i=0; while read -r u; do i=$((i+1)); printf '%s. #%s — `%s`%s\n' "$i" "$u" "$(awk -F'\t' -v u="$u" '$1==u{print $2}' "$RUN_DIR/units.tsv")" "$(awk -F'\t' -v u="$u" '$1==u && $5!=""{printf " (after #%s)", $5}' "$RUN_DIR/units.tsv")"; done < "$RUN_DIR/order.txt"
    [ -s "$BZR_TMP/resultP" ] && { printf '\n<details><summary>Planner notes</summary>\n\n'; grep '^PLAN ' "$BZR_TMP/resultP"; printf '\n</details>\n'; }
  } > "$BZR_TMP/plan.md"
  bzr_comment issue "$ISSUE" "$BZR_TMP/plan.md"
fi

# ---------- implement + review per unit ----------
unit_field() { awk -F'\t' -v u="$1" -v c="$2" '$1==u{print $c}' "$RUN_DIR/units.tsv"; }
skip_unit() {  # <unit> <reason> <findings-file|"">
  local u="$1" reason="$2" f="${3:-}"
  state_set skipped "$u" "$reason"
  if [ "$u" != "$ISSUE" ]; then
    { printf '<!-- bzr-build-worker phase=skip ts=%s -->\nbazaar-build: this sub-issue was skipped in round %s of #%s: %s\n' "$(bzr_now)" "$ROUND" "$ISSUE" "$reason"
      [ -n "$f" ] && [ -s "$f" ] && { printf '\nLast review:\n\n```\n'; cat "$f"; printf '\n```\n'; }
      printf '\nFix the cause and remove `bzr-blocked` from this sub-issue; the parent is rebuilt for the remaining units after the current PR merges.\n'; } > "$BZR_TMP/skip-$u.md"
    bzr_comment issue "$u" "$BZR_TMP/skip-$u.md"
    gh issue edit "$u" --repo "$REPO" --add-label bzr-blocked >/dev/null 2>>"$LOG" || true   # the one worker label write
  fi
  bzr_log "#$ISSUE unit #$u skipped: $reason"
}
depends_on_skipped() {  # <unit> → prints the skipped dependency or nothing
  local d; for d in $(unit_field "$1" 5 | tr ',' ' '); do state_has skipped "$d" && { echo "$d"; return 0; }; done; return 1
}

while read -r U; do
  [ -n "$U" ] || continue
  state_has converged "$U" && { bzr_log "#$ISSUE unit #$U already converged; skipping"; continue; }
  state_has skipped "$U" && continue
  if dep=$(depends_on_skipped "$U"); then skip_unit "$U" "depends on #$dep, which was skipped"; continue; fi
  L4S=$(unit_field "$U" 2); L4IDS=$(unit_field "$U" 3); UTITLE=$(unit_field "$U" 4)
  UBODY=""; [ "$U" != "$ISSUE" ] && UBODY=$(gh issue view "$U" --repo "$REPO" --json body 2>>"$LOG" | bzr_json body)
  PRE_SHA=$(git -C "$WT" rev-parse HEAD)
  cat > "$BZR_TMP/promptU.txt" <<EOP
You are the implementation engineer of Bazaar Builder. Implement ONE unit of parent issue #$ISSUE in $REPO, in this dedicated git worktree on branch $BRANCH (do NOT rename it, do NOT push, do NOT open a PR, do NOT edit issues or labels; the wrapper owns all of that).

Parent: #$ISSUE — $TITLE
Feature specs (context): $L3_PATHS
This unit: #$U — $UTITLE
Task spec(s) to implement now: $L4S  (id: $L4IDS)
$( [ -n "$UBODY" ] && printf 'Sub-issue body:\n---\n%s\n---\n' "$UBODY" )
Helper scripts: $SCRIPTS_DIR/prs, $SCRIPTS_DIR/issues, $SCRIPTS_DIR/specs

STEP 0 — spec gap check, before any code. Read ./CLAUDE.md, the task spec(s), their parent feature spec, and the code they touch. If acceptance criteria are missing, requirements contradict, or a referenced file/interface does not exist: make NO changes and end with
  SPEC_GAP <one-line description>
STEP 1 — implement exactly this unit, following CLAUDE.md. Stay inside the spec's scope.
STEP 2 — run the relevant tests; fix real failures.
STEP 3 — commit with conventional-commit messages; every commit message ends with a line "Refs #$U".

Merge policy (non-negotiable): NEVER run gh pr merge; never push; never touch labels, issues, statuses, other branches, or other PRs.

End your final message with EXACTLY ONE sentinel as the bare last line:
UNIT_DONE | SPEC_GAP <reason> | STUCK <reason>
EOP
  echo "  [$IMPLEMENTER implementer] implementing unit #$U of #$ISSUE..." >&2
  if ! run_implementer "$(cat "$BZR_TMP/promptU.txt")" "$BZR_TMP/resultU" "$WT" "claude-sonnet-5"; then sentinel STUCK "$IMPLEMENTER failed on unit #$U"; exit 1; fi
  LAST=$(last_line "$BZR_TMP/resultU")
  case "$LAST" in
    UNIT_DONE) ;;
    SPEC_GAP*) git -C "$WT" reset --hard -q "$PRE_SHA"; sentinel SPEC_GAP "unit #$U: ${LAST#SPEC_GAP }"; exit 0 ;;
    STUCK*) sentinel STUCK "unit #$U: ${LAST#STUCK }"; exit 1 ;;
    *) sentinel STUCK "unit #$U: implementer ended without a sentinel"; exit 1 ;;
  esac
  git -C "$WT" add -A >>"$LOG" 2>&1; git -C "$WT" diff --cached --quiet || git -C "$WT" commit -q -m "feat: unit #$U (wrapper commit of uncommitted work)

Refs #$U" >>"$LOG" 2>&1
  POST_SHA=$(git -C "$WT" rev-parse HEAD)
  [ "$POST_SHA" != "$PRE_SHA" ] || { sentinel STUCK "unit #$U: implementer said UNIT_DONE but committed nothing"; exit 1; }
  git -C "$WT" push --quiet -u origin "HEAD:refs/heads/$BRANCH" >>"$LOG" 2>&1 || { sentinel STUCK "push of $BRANCH failed"; exit 1; }
  ensure_pr

  rc=0; run_review_cycle --mode code --pr "$PR" --worktree "$WT" --branch "$BRANCH" --max-cycles "$MAX_REVIEW_CYCLES" || rc=$?
  case "$rc" in
    0) state_set converged "$U" "$PRE_SHA..$(git -C "$WT" rev-parse HEAD)"; bzr_log "#$ISSUE unit #$U converged after $REVIEW_CYCLES_RUN cycle(s)" ;;
    10|20)
      END_SHA=$(git -C "$WT" rev-parse HEAD)
      # One revert commit for the whole unit range (--no-commit tolerates empty commits in the range).
      if git -C "$WT" revert --no-commit "$PRE_SHA..$END_SHA" >>"$LOG" 2>&1 \
         && git -C "$WT" commit -q --allow-empty -m "revert: skip unit #$U (review did not converge)

Reverts $PRE_SHA..$END_SHA. Refs #$U" >>"$LOG" 2>&1; then
        git -C "$WT" push --quiet origin "HEAD:refs/heads/$BRANCH" >>"$LOG" 2>&1 || true
        skip_unit "$U" "review did not converge: $REVIEW_FAIL_REASON (commits $PRE_SHA..$END_SHA reverted)" "${REVIEW_LAST_FILE:-}"
      else
        git -C "$WT" revert --abort >>"$LOG" 2>&1 || git -C "$WT" reset --hard -q "$END_SHA" >>"$LOG" 2>&1 || true
        gh pr ready "$PR" --repo "$REPO" --undo >/dev/null 2>>"$LOG" || true
        printf 'bazaar-build: unit #%s did not converge (%s) and its commits could not be reverted cleanly, so the build halted with the branch as-is. Resolve by hand.\n' "$U" "$REVIEW_FAIL_REASON" > "$BZR_TMP/rc.md"
        comment_issue halt "$BZR_TMP/rc.md"; ensure_pr; sentinel BLOCKED "unit #$U: revert conflict after non-convergence"; exit 0
      fi ;;
    2|3|4) ensure_pr; sentinel STUCK "reviewer unavailable on unit #$U: $REVIEW_FAIL_REASON"; exit 1 ;;
    *) ensure_pr; sentinel STUCK "review cycle rc=$rc on unit #$U"; exit 1 ;;
  esac
  ensure_pr
done < "$RUN_DIR/order.txt"

# ---------- finish ----------
[ -n "$PR" ] && ensure_pr   # body reflects dependent skips made without a review pass
N_CONV=$(state_get converged | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
SKIPPED=$(state_get skipped | python3 -c 'import json,sys; print(" ".join("#"+k for k in json.load(sys.stdin)))')
if [ "$N_CONV" -eq 0 ]; then
  [ -n "$PR" ] && gh pr close "$PR" --repo "$REPO" >/dev/null 2>>"$LOG" || true
  sentinel BLOCKED "no unit converged in round $ROUND (skipped: ${SKIPPED:-none})"; exit 0
fi
git -C "$WT" push --quiet origin "HEAD:refs/heads/$BRANCH" >>"$LOG" 2>&1 || { sentinel STUCK "final push failed"; exit 1; }
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
post_codex_review_status "$HEAD_SHA" "$PR" "$REVIEWER review converged for every commit on this branch" || bzr_log "#$ISSUE WARNING: codex-review status post failed"
gh pr ready "$PR" --repo "$REPO" >/dev/null 2>>"$LOG" || bzr_log "#$ISSUE WARNING: gh pr ready failed"
{ printf 'bazaar-build: round %s finished. PR ready for human merge: https://github.com/%s/pull/%s\n\nConverged units: %s\nSkipped units: %s\n' "$ROUND" "$REPO" "$PR" "$(state_get converged | python3 -c 'import json,sys; print(" ".join("#"+k for k in json.load(sys.stdin)))')" "${SKIPPED:-none}"
  [ -n "$SKIPPED" ] && printf '\nSkipped sub-issues carry `bzr-blocked` with the last review. Clear the label when fixed; after this PR merges the parent is queued for another round.\n'
  printf '\nThis pipeline never merges. A `codex-review=success` status is on `%s`.\n' "${HEAD_SHA:0:8}"; } > "$BZR_TMP/done.md"
comment_issue finish "$BZR_TMP/done.md"
sentinel PR_READY "$PR"
exit 0
