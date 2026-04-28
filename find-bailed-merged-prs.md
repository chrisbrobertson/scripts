# Agent instructions: Find bailed-and-merged babysit PRs

## Goal

Find PRs that were merged into the default branch where `babysit-with-review.sh`'s review cycle bailed before reporting zero BLOCKING findings. These PRs may contain unreviewed AI-generated commits.

**Before the bug fix in this repo, every bail path silently left the PR as open and mergeable. Run this audit against historical logs to find any PRs merged during that window.**

---

## When to use these instructions (vs. the script)

Use these agent instructions when:
- Logs live on a remote machine (SSH first, then grep)
- You want LLM-assisted triage: "was the merged code actually risky given the unmet findings?"
- You don't have a `repo-map.tsv` yet and need to infer repos from the project directories
- The script's output needs narrative context for a report

For batch/deterministic audit, prefer `find-bailed-merged-prs.sh`.

---

## Inputs

| Input | Default | Notes |
| --- | --- | --- |
| Log directory | `~/sisyphus-logs` | Change with `--log-dir` in the script; adjust path below if different |
| Repo map | `~/.config/babysit-audit/repo-map.tsv` | Optional; agent can infer repos from `~/repos/<project>` directories |
| Date window | All logs | Narrow to a date range if the log dir is large |

---

## Steps

### 1. Filter to babysit-with-review.sh logs

```bash
grep -l "^=== babysit-with-review\.sh @" ~/sisyphus-logs/*.log 2>/dev/null
```

Skip any log that doesn't match — those are plain `babysit.sh` runs without review cycles.

### 2. Extract review-handoff blocks and classify outcomes

For each matching log, extract `(project, pr_num, outcome, reason)` tuples.

**Block boundaries:**
- Block starts: `=== review handoff: PR #N @ <timestamp> ===`
- Block ends: next `=== review handoff` or `=== iter` or EOF

**Project name:** basename of the log file with the `YYYYMMDD-HHMMSS-PID.log` suffix stripped.

**Outcome classification (priority order):**

| Outcome | Match phrase |
| --- | --- |
| `CLEARED` | line contains `cleared after` |
| `BAILED` | line contains `bailing review cycle`, `hit MAX_REVIEW_CYCLES`, `HEAD unchanged`, `STUCK_REVIEW`, or `gh pr checkout.*failed` |
| `UNKNOWN` | none of the above (block may have been truncated) |

A PR can appear in multiple logs (re-reviewed across runs). Keep the **worst** outcome: `BAILED > UNKNOWN > CLEARED`.

**Extraction command:**
```bash
grep -n "review handoff\|bailing review cycle\|hit MAX_REVIEW_CYCLES\|cleared after\|HEAD unchanged\|STUCK_REVIEW\|gh pr checkout.*failed" <log_file>
```

### 3. Resolve project → GitHub repo

For each unique `(project, pr_num)` with outcome `BAILED` or `UNKNOWN`:

Option A — repo map exists:
```bash
cat ~/.config/babysit-audit/repo-map.tsv
```

Option B — infer from git remote:
```bash
git -C ~/repos/<project> config --get remote.origin.url 2>/dev/null \
  | sed -E 's|git@github.com:|https://github.com/|; s|\.git$||'
```

Option C — ask the user which repo to query.

### 4. Query GitHub for merge state

```bash
gh pr view <pr_num> --repo <OWNER/REPO> \
  --json number,state,mergedAt,mergedBy,url,headRefName,additions,deletions
```

Flag every row where `state == MERGED`.

### 5. For MERGED PRs — triage the unmet findings

For each merged PR, retrieve:

**The last codex review from the log:**
```bash
grep -A 200 "codex review (cycle" <log_file> | grep -B 200 "end codex review" | tail -n +2 | head -n -1
```

**The merged diff:**
```bash
gh pr diff <pr_num> --repo <OWNER/REPO>
```

Assess: did the merged diff address the BLOCKING findings that caused the bail, or does the merged code still contain the issues flagged by codex?

### 6. Report

Produce a Markdown report with:

1. Summary line: `N bailed PR(s) found; K were merged.`
2. **MERGED PRs** section (one subsection per PR):
   - PR URL + title + merged-at date
   - Bail reason (from log)
   - Last codex BLOCKING findings
   - Assessment: "findings appear addressed" / "findings NOT addressed — review manually" / "cannot determine"
3. **Non-merged bailed PRs** section: list with PR URL + current state + bail reason.
4. **PRs with no repo mapping** section: list with project + pr_num + log path.

---

## Stop conditions

- No babysit-with-review.sh logs in log dir → exit with "No review logs found."
- No bailed handoffs → exit with "No bailed handoffs — no candidates."
- gh auth not configured → instruct user to run `gh auth login` first.

---

## Notes

- The codex review content in the log is bracketed by `--- codex review (cycle N) ---` / `--- end codex review ---`.
- A PR may have been **closed without merge** (operator noticed the issue) — that's OK, only MERGED matters.
- If the PR has since been reverted, note it in the assessment but still flag it as "was merged unreviewed."
- If `fail_review_cycle` from the fixed script ran on a prior bail (PR is now draft + labeled `review-incomplete`), the PR can't be merged without operator intervention — those are safe, but still worth noting if they're from before the fix.
