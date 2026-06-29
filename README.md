# scripts

Personal helper scripts for Claude Code workflows and the home-lab fleet.

## Contents

| File / Dir | Purpose |
|---|---|
| `new-fleet.sh` | Provision a staff-team fleet (3 AI agents) for a service |
| `claude-code-proxy.py` | OpenAI-compatible proxy routing to `claude -p` |
| `babysit-with-review.sh` | Autonomous `claude -p` loop with Codex PR-review cycle |
| `backfill-codex-reviews.py` | Post historical Codex reviews to closed PRs |
| `prs` | `gh pr list` with CI rollup and review state |
| `issues` | `gh issue list` sorted by priority labels |
| `specs` | List spec files with frontmatter status |
| `babysit-specs/` | TIF specs for `babysit-with-review.sh` (L1–L3, QA, security plans) |
| `docs/STAFF-FLEET.md` | Full operator guide for the staff-fleet system |

## Staff-fleet agents

`new-fleet.sh` + `claude-code-proxy.py` together let you run three always-on
AI agents (SWE, SRE, PM) per service. They post morning digests over Telegram
and answer on-demand questions via CLI or DM.

See **[docs/STAFF-FLEET.md](docs/STAFF-FLEET.md)** for the full guide:
quick start, architecture deep-dive, tuning, troubleshooting, and file layout.

## Logs

`babysit-with-review.sh` writes iteration and review logs to `~/sisyphus-logs/`.
Log files contain code diffs, commit messages, and Codex review output — treat
them as sensitive. No automatic cleanup; remove manually when no longer needed.

## Other scripts

See [CLAUDE.md](CLAUDE.md) for conventions, testing patterns, and
babysit-with-review.sh documentation.
