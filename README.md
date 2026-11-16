# scripts

Personal helper scripts for Claude Code workflows and the home-lab fleet.

## Contents

| File / Dir | Purpose |
|---|---|
| `new-fleet.sh` | Provision a staff-team fleet (3 AI agents) for a service |
| `babysit-with-review.sh` | Autonomous `claude -p` loop with Codex PR-review cycle |
| `babysit-work-prep.sh` | Ticket-to-spec intake loop; drafts specs and hands off `build-ready` sub-tickets |
| `babysit-builder.sh` | Spec-to-PR build loop; implements `build-ready` tickets, never merges |
| `bazaar-issues.sh` / `bazaar-build.sh` | Bazaar Builder controllers (two-controller successor to work-prep/builder) |
| `lib/bazaar-common.sh` / `lib/bazaar-review.sh` | Shared libraries behind the Bazaar controllers and workers |
| `backfill-codex-reviews.py` | Post historical Codex reviews to closed PRs |
| `prs` | `gh pr list` with CI rollup and review state |
| `issues` | `gh issue list` sorted by priority labels |
| `specs` | List spec files with frontmatter status |
| `spec-guide.md` | Schema document for all specs in this repo — read before drafting or editing one |
| `babysit-specs/` | TIF specs for the babysit script family (L1–L4, QA, security plans) |
| `bazaar-builder-specs/` | TIF specs for Bazaar Builder |
| `docs/STAFF-FLEET.md` | Full operator guide for the staff-fleet system |
| `docs/BAZAAR-BUILDER.md` | Full operator guide for Bazaar Builder |
| `launchd/` | LaunchAgent template + installer for scheduling `babysit-with-review.sh` |
| `skills/` | Standalone Claude Skill packages versioned in this repo |

See [CLAUDE.md](CLAUDE.md) for the full file-by-file reference, including the
`test-*.sh` harnesses and deprecated scripts.

## Staff-fleet agents

`new-fleet.sh` lets you run three always-on AI agents (SWE, SRE, PM) per
service on Hermes Agent's native `openai-codex` provider. They post morning
digests over Telegram and answer on-demand questions via CLI or DM.

See **[docs/STAFF-FLEET.md](docs/STAFF-FLEET.md)** for the full guide:
quick start, architecture deep-dive, tuning, troubleshooting, and file layout.

## Logs

`babysit-with-review.sh` writes iteration and review logs to `~/sisyphus-logs/`.
Log files contain code diffs, commit messages, and Codex review output — treat
them as sensitive. No automatic cleanup; remove manually when no longer needed.
