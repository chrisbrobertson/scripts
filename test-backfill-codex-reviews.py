#!/usr/bin/env python3
"""test-backfill-codex-reviews.py — coverage for backfill-codex-reviews.py.

backfill-codex-reviews.py shipped with no test of its own (unlike its
sibling find-bailed-merged-prs.sh / run-retrospective-review.sh, which each
have a test-*.sh harness). Its log-parsing and dedup core (parse_cycles,
already_posted, build_comment) is pure, and its repo-resolution fallback
chain (resolve_repo -> repo_from_cwd -> filename-stem guess) is the part
most likely to silently misroute a comment to the wrong repo, so both get
direct unit coverage here. subprocess.run is mocked for the `git`/`gh` calls
so no network or real git remote is needed; one end-to-end dry-run case
drives the CLI with a stub `gh` on PATH to check the --logs/--all/--pr/
--repo filters and the overall output format together.

Regressions this guards against:
  1. An unterminated "--- codex review ... ---" block (no matching
     "--- end codex review ---") must not yield a candidate.
  2. already_posted() must match on the backfill marker OR the forward
     (live) post header, not just one of the two.
  3. resolve_repo()'s three-tier fallback (git remote of recorded cwd ->
     owner + cwd basename when the remote lookup fails -> owner + filename
     stem with the "-YYYYMMDD-HHMMSS-PID" suffix stripped when no cwd was
     recorded at all) picks the right tier and warns on stderr only in the
     last case.
  4. The freshness filter skips logs younger than FRESHNESS_MINUTES unless
     --all is passed, and --pr/--repo narrow the candidate set.
"""
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "backfill-codex-reviews.py"

spec = importlib.util.spec_from_file_location("backfill_codex_reviews", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def write(path, text):
    path.write_text(textwrap.dedent(text).lstrip("\n"))


class ParseCyclesTests(unittest.TestCase):
    def test_single_cycle(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.log"
            write(p, """
                --- review cycle 1 / 6 (PR #42) @ 2026-01-01T00:00:00Z ---
                --- codex review (cycle 1) ---
                looks good
                --- end codex review ---
            """)
            self.assertEqual(
                list(mod.parse_cycles(p)),
                [(42, 1, 6, "looks good")],
            )

    def test_multiple_cycles_in_one_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.log"
            write(p, """
                --- review cycle 1 / 6 (PR #42) @ 2026-01-01T00:00:00Z ---
                --- codex review (cycle 1) ---
                first
                --- end codex review ---
                --- review cycle 2 / 6 (PR #42) @ 2026-01-01T01:00:00Z ---
                --- codex review (cycle 2) ---
                second
                --- end codex review ---
            """)
            self.assertEqual(
                list(mod.parse_cycles(p)),
                [(42, 1, 6, "first"), (42, 2, 6, "second")],
            )

    def test_unterminated_block_is_dropped(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.log"
            write(p, """
                --- review cycle 1 / 6 (PR #42) @ 2026-01-01T00:00:00Z ---
                --- codex review (cycle 1) ---
                never closed
            """)
            self.assertEqual(list(mod.parse_cycles(p)), [])

    def test_review_block_before_any_banner_is_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.log"
            write(p, """
                --- codex review (cycle 1) ---
                orphaned, no pr banner yet
                --- end codex review ---
            """)
            self.assertEqual(list(mod.parse_cycles(p)), [])


class AlreadyPostedTests(unittest.TestCase):
    def test_matches_backfill_marker(self):
        bodies = ["**Codex review — PR #5 cycle 2 of 6** <!-- backfill: log=x.log cycle=2/6 -->"]
        self.assertEqual(mod.already_posted(bodies, 5, 2, 6), (True, "already-backfilled"))

    def test_matches_forward_header(self):
        bodies = ["**Codex review — PR #5 cycle 2 of 6**\n\n```\nok\n```"]
        self.assertEqual(mod.already_posted(bodies, 5, 2, 6), (True, "forward-posted"))

    def test_no_match(self):
        bodies = ["unrelated comment", "**Codex review — PR #5 cycle 1 of 6**"]
        self.assertEqual(mod.already_posted(bodies, 5, 2, 6), (False, None))

    def test_empty_bodies(self):
        self.assertEqual(mod.already_posted([], 5, 2, 6), (False, None))


class BuildCommentTests(unittest.TestCase):
    def test_format_matches_post_codex_review(self):
        comment = mod.build_comment(5, 2, 6, "some findings\n", "proj-20260101-000000-1.log")
        self.assertEqual(
            comment,
            "**Codex review — PR #5 cycle 2 of 6**"
            " <!-- backfill: log=proj-20260101-000000-1.log cycle=2/6 -->"
            "\n\n```\nsome findings\n```",
        )


class RepoFromCwdTests(unittest.TestCase):
    def test_ssh_remote(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                [], 0, stdout="git@github.com:chrisbrobertson/scripts.git\n", stderr=""
            )
            self.assertEqual(mod.repo_from_cwd("/some/path"), "chrisbrobertson/scripts")

    def test_https_remote(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                [], 0, stdout="https://github.com/chrisbrobertson/scripts\n", stderr=""
            )
            self.assertEqual(mod.repo_from_cwd("/some/path"), "chrisbrobertson/scripts")

    def test_command_failure_returns_none(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.side_effect = subprocess.CalledProcessError(128, ["git"])
            self.assertIsNone(mod.repo_from_cwd("/some/path"))

    def test_git_not_found_returns_none(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.side_effect = FileNotFoundError()
            self.assertIsNone(mod.repo_from_cwd("/some/path"))


class ResolveRepoTests(unittest.TestCase):
    def test_uses_cwd_git_remote_when_available(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "proj-20260101-000000-1.log"
            write(p, '{"cwd":"/home/x/repos/scripts"}\n')
            with mock.patch.object(mod, "repo_from_cwd", return_value="chrisbrobertson/scripts"):
                self.assertEqual(mod.resolve_repo(p, "chrisbrobertson"), "chrisbrobertson/scripts")

    def test_falls_back_to_owner_plus_cwd_basename(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "proj-20260101-000000-1.log"
            write(p, '{"cwd":"/home/x/repos/scripts"}\n')
            with mock.patch.object(mod, "repo_from_cwd", return_value=None):
                self.assertEqual(mod.resolve_repo(p, "chrisbrobertson"), "chrisbrobertson/scripts")

    def test_falls_back_to_filename_stem_and_warns(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "scripts-20260101-000000-1.log"
            write(p, "no cwd line at all\n")
            with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
                repo = mod.resolve_repo(p, "chrisbrobertson")
            self.assertEqual(repo, "chrisbrobertson/scripts")
            self.assertIn("guessing repo", stderr.getvalue())

    def test_filename_stem_strips_timestamp_pid_suffix_only(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "my-project-20261231-235959-42.log"
            write(p, "no cwd line at all\n")
            with mock.patch("sys.stderr", new_callable=io.StringIO):
                repo = mod.resolve_repo(p, "someowner")
            self.assertEqual(repo, "someowner/my-project")


class ListExistingCommentBodiesTests(unittest.TestCase):
    def test_success_returns_bodies(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                [], 0, stdout='[{"body": "a"}, {"body": "b"}]', stderr=""
            )
            self.assertEqual(mod.list_existing_comment_bodies("o/r", 5), ["a", "b"])

    def test_gh_failure_returns_empty_list(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.side_effect = subprocess.CalledProcessError(1, ["gh"])
            self.assertEqual(mod.list_existing_comment_bodies("o/r", 5), [])

    def test_malformed_json_returns_empty_list(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, stdout="not json", stderr="")
            self.assertEqual(mod.list_existing_comment_bodies("o/r", 5), [])


class PostCommentTests(unittest.TestCase):
    def test_success(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
            ok, err = mod.post_comment("o/r", 5, "body")
            self.assertTrue(ok)
            self.assertEqual(err, "")

    def test_failure_returns_stderr(self):
        with mock.patch.object(mod.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, stdout="", stderr="boom\n")
            ok, err = mod.post_comment("o/r", 5, "body")
            self.assertFalse(ok)
            self.assertEqual(err, "boom")


FAKE_GH = """#!/bin/bash
if [ "$1" = "api" ]; then
  echo "[]"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  exit 0
fi
exit 1
"""


class CliEndToEndTests(unittest.TestCase):
    """Drive the script as a subprocess with a stub `gh` on PATH."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.env = dict(os.environ)
        self.env["PATH"] = f"{bin_dir}:{self.env['PATH']}"
        self.logs = Path(self.tmp.name) / "logs"
        self.logs.mkdir()

    def write_log(self, name, pr=7, cycle=1, max_cycles=6, body="fine", old=True):
        p = self.logs / name
        write(p, f"""
            {{"cwd":"/tmp/nonexistent-repo-dir"}}
            --- review cycle {cycle} / {max_cycles} (PR #{pr}) @ 2026-01-01T00:00:00Z ---
            --- codex review (cycle {cycle}) ---
            {body}
            --- end codex review ---
        """)
        if old:
            old_time = 3600 * 2
            ts = os.path.getmtime(p) - old_time
            os.utime(p, (ts, ts))
        return p

    def run_script(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--logs", str(self.logs / "*.log"), *args],
            env=self.env, capture_output=True, text=True,
        )

    def test_dry_run_reports_would_post(self):
        self.write_log("proj-20260101-000000-1.log")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would post", result.stdout)
        self.assertIn("[dry-run: would post]", result.stdout)

    def test_recent_log_skipped_without_all(self):
        self.write_log("proj-20260101-000000-1.log", old=False)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Skipping 1 recently-modified log", result.stdout)
        self.assertIn("No review cycles found", result.stdout)

    def test_recent_log_included_with_all(self):
        self.write_log("proj-20260101-000000-1.log", old=False)
        result = self.run_script("--all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would post", result.stdout)

    def test_pr_filter_excludes_other_prs(self):
        self.write_log("proj-20260101-000000-1.log", pr=7)
        result = self.run_script("--pr", "999")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No review cycles found", result.stdout)

    def test_repo_filter_excludes_non_matching_repo(self):
        self.write_log("proj-20260101-000000-1.log")
        result = self.run_script("--repo", "someone/else")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No review cycles found", result.stdout)

    def test_help(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("usage", result.stdout.lower())


if __name__ == "__main__":
    unittest.main()
