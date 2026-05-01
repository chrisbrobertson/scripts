#!/usr/bin/env python3
"""Back-fill codex review comments from ~/sisyphus-logs/ onto their GitHub PRs.

Each babysitter review cycle writes structured markers into the log:

    --- review cycle C / M (PR #N) @ <ISO> ---
    --- codex review (cycle C) ---
    <review body>
    --- end codex review ---

Before dc6be9d these blocks lived only in the logs. This script extracts them
and posts them as PR comments using the same format as post_codex_review() in
babysit-with-review.sh, with an invisible HTML marker for idempotency.

Usage:
    ./backfill-codex-reviews.py                   # dry-run: show what would post
    ./backfill-codex-reviews.py --apply           # actually post
    ./backfill-codex-reviews.py --apply --pr 79   # single PR
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

OWNER_DEFAULT = "chrisbrobertson"
LOG_DIR_DEFAULT = os.path.expanduser("~/sisyphus-logs")
FRESHNESS_MINUTES = 30

RE_CYCLE_BANNER = re.compile(
    r"^--- review cycle (\d+) / (\d+) \(PR #(\d+)\) @ "
)
RE_REVIEW_START = re.compile(r"^--- codex review \(cycle (\d+)\) ---$")
RE_REVIEW_END = re.compile(r"^--- end codex review ---$")
RE_CWD = re.compile(r'"cwd":"([^"]+)"')


def parse_cycles(path):
    """Yield (pr, cycle, max_cycles, body) tuples from a log file."""
    pr = cycle = max_cycles = None
    capturing = False
    body_lines = []

    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")

            if not capturing:
                m = RE_CYCLE_BANNER.match(line)
                if m:
                    cycle, max_cycles, pr = (
                        int(m.group(1)),
                        int(m.group(2)),
                        int(m.group(3)),
                    )
                    continue
                if RE_REVIEW_START.match(line) and pr is not None:
                    capturing = True
                    body_lines = []
                    continue
            else:
                if RE_REVIEW_END.match(line):
                    if body_lines:
                        yield (pr, cycle, max_cycles, "\n".join(body_lines))
                    capturing = False
                    body_lines = []
                else:
                    body_lines.append(line)


RE_GIT_REMOTE = re.compile(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$")


def repo_from_cwd(cwd):
    """Return 'owner/repo' by reading the git remote of a local cwd, or None."""
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "remote", "get-url", "origin"],
            capture_output=True, text=True, check=True,
        )
        url = result.stdout.strip()
        m = RE_GIT_REMOTE.search(url)
        if m:
            return m.group(1)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return None


def resolve_repo(path, owner):
    """Derive owner/repo from git remote of the cwd recorded in the log, or filename."""
    cwd = None
    with open(path, errors="replace") as f:
        for i, line in enumerate(f):
            if i > 300:
                break
            m = RE_CWD.search(line)
            if m:
                cwd = m.group(1)
                break

    if cwd:
        repo_with_owner = repo_from_cwd(cwd)
        if repo_with_owner:
            return repo_with_owner
        # cwd found but git remote lookup failed — fall back to basename
        return f"{owner}/{Path(cwd).name}"

    # No cwd at all: strip the -YYYYMMDD-HHMMSS-PID suffix from the filename stem.
    stem = Path(path).stem
    repo = re.sub(r"-\d{8}-\d{6}-\d+$", "", stem)
    print(
        f"  WARN: no cwd found in first 300 lines of {Path(path).name}; "
        f"guessing repo '{owner}/{repo}' from filename",
        file=sys.stderr,
    )
    return f"{owner}/{repo}"


def list_existing_comment_bodies(repo, pr):
    """Return list of comment body strings for repo#pr (up to 100)."""
    try:
        result = subprocess.run(
            [
                "gh", "api",
                f"repos/{repo}/issues/{pr}/comments?per_page=100",
            ],
            capture_output=True, text=True, check=True,
        )
        data = json.loads(result.stdout)
        return [item["body"] for item in data]
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError):
        return []


def already_posted(existing_bodies, pr, cycle, max_cycles):
    """Return (True, reason) if this cycle was already posted, else (False, None)."""
    backfill_needle = f"cycle={cycle}/{max_cycles}"
    forward_header = f"**Codex review — PR #{pr} cycle {cycle} of {max_cycles}**"
    for body in existing_bodies:
        if "backfill:" in body and backfill_needle in body:
            return True, "already-backfilled"
        if forward_header in body:
            return True, "forward-posted"
    return False, None


def build_comment(pr, cycle, max_cycles, review_body, log_basename):
    """Build the comment body, matching post_codex_review() format exactly."""
    header = (
        f"**Codex review — PR #{pr} cycle {cycle} of {max_cycles}**"
        f" <!-- backfill: log={log_basename} cycle={cycle}/{max_cycles} -->"
    )
    body = review_body.rstrip("\n")
    return f"{header}\n\n```\n{body}\n```"


def post_comment(repo, pr, body):
    """Post body as a PR comment. Returns (success, stderr_text)."""
    proc = subprocess.run(
        ["gh", "pr", "comment", str(pr), "--repo", repo, "--body-file", "-"],
        input=body + "\n",
        text=True,
        capture_output=True,
    )
    return proc.returncode == 0, proc.stderr.strip()


def main():
    parser = argparse.ArgumentParser(
        description="Back-fill codex review comments from sisyphus logs onto GitHub PRs.",
        epilog="Default mode is dry-run. Pass --apply to actually post.",
    )
    parser.add_argument(
        "--apply", action="store_true",
        help="Post comments. Without this flag, only prints what would be posted.",
    )
    parser.add_argument(
        "--pr", type=int, action="append", dest="prs", metavar="N",
        help="Only process this PR number (repeatable).",
    )
    parser.add_argument(
        "--repo", metavar="OWNER/REPO",
        help="Only process logs whose resolved repo matches.",
    )
    parser.add_argument(
        "--owner", default=OWNER_DEFAULT,
        help=f"GitHub owner prefix (default: {OWNER_DEFAULT}).",
    )
    parser.add_argument(
        "--logs", default=None, metavar="GLOB",
        help=f"Glob for log files (default: {LOG_DIR_DEFAULT}/*.log).",
    )
    parser.add_argument(
        "--all", dest="include_recent", action="store_true",
        help=f"Include logs modified within the last {FRESHNESS_MINUTES} min (skipped by default).",
    )
    args = parser.parse_args()

    log_glob = args.logs or os.path.join(LOG_DIR_DEFAULT, "*.log")
    all_logs = sorted(glob.glob(log_glob))
    if not all_logs:
        print(f"No log files found matching: {log_glob}", file=sys.stderr)
        sys.exit(1)

    now = time.time()
    recent = []
    active = []
    for path in all_logs:
        age_min = (now - os.path.getmtime(path)) / 60
        if not args.include_recent and age_min < FRESHNESS_MINUTES:
            recent.append(path)
        else:
            active.append(path)

    if recent:
        print(
            f"Skipping {len(recent)} recently-modified log(s) "
            f"(< {FRESHNESS_MINUTES} min old; use --all to include):"
        )
        for p in recent:
            print(f"  {Path(p).name}")
        print()

    # Collect all cycles from active logs.
    # candidates: list of (repo, pr, cycle, max_cycles, body, log_basename)
    candidates = []
    repo_cache = {}
    for path in active:
        if path not in repo_cache:
            repo_cache[path] = resolve_repo(path, args.owner)
        repo = repo_cache[path]
        if args.repo and repo != args.repo:
            continue
        log_basename = Path(path).name
        for pr, cycle, max_cycles, body in parse_cycles(path):
            if args.prs and pr not in args.prs:
                continue
            candidates.append((repo, pr, cycle, max_cycles, body, log_basename))

    if not candidates:
        print("No review cycles found matching the given filters.")
        return

    # Dedup: load existing comments per (repo, pr) once, update as we post.
    comments_cache = {}  # (repo, pr) -> list[str]

    n_posted = n_skip_bf = n_skip_fwd = n_failed = 0

    for repo, pr, cycle, max_cycles, body, log_basename in candidates:
        key = (repo, pr)
        if key not in comments_cache:
            comments_cache[key] = list_existing_comment_bodies(repo, pr)

        skip, reason = already_posted(comments_cache[key], pr, cycle, max_cycles)
        label = f"{repo}#{pr} cycle {cycle}/{max_cycles}"

        if skip:
            print(f"  {label}  skipped ({reason})")
            if reason == "already-backfilled":
                n_skip_bf += 1
            else:
                n_skip_fwd += 1
            continue

        comment = build_comment(pr, cycle, max_cycles, body, log_basename)

        if not args.apply:
            print(f"  {label}  [dry-run: would post]")
            n_posted += 1
        else:
            ok, err = post_comment(repo, pr, comment)
            if ok:
                print(f"  {label}  posted")
                comments_cache[key].append(comment)
                n_posted += 1
            else:
                print(f"  {label}  FAILED: {err}")
                n_failed += 1

    mode = "apply" if args.apply else "dry-run"
    verb = "posted" if args.apply else "would post"
    parts = [f"{n_posted} {verb}"]
    if n_skip_fwd:
        parts.append(f"{n_skip_fwd} skipped (forward-posted)")
    if n_skip_bf:
        parts.append(f"{n_skip_bf} skipped (already back-filled)")
    if n_failed:
        parts.append(f"{n_failed} FAILED")
    print(f"\n[{mode}] {', '.join(parts)}")


if __name__ == "__main__":
    main()
