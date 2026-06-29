# scripts

Personal helper scripts for working with Claude Code and the home-lab fleet:
autonomous Claude loop (`babysit-with-review.sh`), `gh` CLI wrappers (`prs`, `issues`,
`specs`), and one-off empirical tests (`test-*`). No formal test suite, no build
step, no CI.

## Conventions

- **Tracking.** Most files are intentionally untracked. Commit when something
  stabilises.
- **Helpers are repo-agnostic.** `prs`, `issues`, and `specs` wrap `gh` and
  operate on whichever repo the caller is in. Don't add cwd-specific assumptions
  to them.
- **New scripts** need a shebang and the executable bit (`chmod +x`).
- **Tests are exploratory.** Document outcomes in commit messages or in specs
  under `~/repos/home-lab-monitor/specs/`; don't add them as assertions here.

## Files

| File | Purpose |
| --- | --- |
| `new-fleet.sh` | Provision a staff-team fleet (staff-swe/sre/pm) for a service; see `docs/STAFF-FLEET.md` |
| `claude-code-proxy.py` | OpenAI-compatible HTTP proxy routing to `claude -p`; used by new-fleet.sh |
| `babysit-with-review.sh` | Autonomous `claude -p` loop with stop-file lock and Claude↔Codex PR-review cycle; see header for env vars. Pass `--repo-base PATH` (or `REPO_BASE` env var) if helper scripts live outside `~/repos/scripts` — auto-detects `~/repos` then `~/repo`. |
| `setup-branch-protection.sh` | Enable the `codex-review` required status check on a repo's default branch; run once per repo after deploying the updated wrapper |
| `backfill-codex-reviews.py` | Post historical Codex reviews to closed PRs |
| `run-retrospective-review.sh` | One-shot Codex review for PRs that merged without automated review; posts findings as PR comments and opens issues for each BLOCKING finding |
| `find-bailed-merged-prs.sh` | Scan babysit logs for review-cycle bails, then query GitHub to find which bailed PRs were subsequently merged (unreviewed code audit) |
| `test-llm-routing.py` | Empirical test: model-alias forwarding + OAuth rejection by Anthropic |
| `test-codex-review.sh` | Codex review helper |
| `prs` | `gh pr list` with CI rollup and review state |
| `issues` | `gh issue list` sorted by priority labels |
| `specs` | List spec files with frontmatter status and components; searches any `specs/` or `*-specs/` directory |
| `babysit-specs/` | TIF specs for `babysit-with-review.sh` (L1–L3 + QA + security plans); see `babysit-specs/README.md` |

## Staff-fleet agents

`new-fleet.sh` scaffolds three always-on AI agents (staff-swe, staff-sre, staff-pm) for a
service, using `claude-code-proxy.py` to bridge Hermes Agent (needs OpenAI endpoint) with
Claude Code CLI (OAuth, no API key). One fleet per service, each fully isolated.

Full operator guide: **`docs/STAFF-FLEET.md`** — quick start, architecture, tuning, troubleshooting.

## Testing

**Local-first.** Most scripts run directly on your machine without any fleet
dependency.

**Fleet-based tests** (those that need Ollama, LiteLLM, GPU, a specific OS, or
`claude` CLI on a remote host): use the home-lab dev fleet. See
`~/repos/home-lab-monitor/HOMELAB_DEV_USAGE.md` for the slot-reservation
workflow, host inventory, and SSH prerequisites.

**SSH-stdin pattern** — the established convention for running a test script
non-interactively on a remote dev host without Docker:

```
ssh chrisrobertson@192.168.1.81 'python3 -' < test-llm-routing.py
```

Exemplar: `test-llm-routing.py:18-25`. Notes:
- Works on `dev-laptop` role hosts (192.168.1.81, .85, .84, .229).
- **Mac Mini (192.168.1.129) does NOT work** — SSH requires an interactive PTY
  (see comment in `~/repos/home-lab-monitor/config.yml`).
- **Spark DGX (192.168.1.93) is the GPU host** — prefer it when the test needs
  CUDA/Ollama inference; treat it as shared.

## babysit-with-review.sh — MCP resilience and pre-flight

**PR labels.** The review cycle uses two distinct labels:

- `review-incomplete` — a bail for a human-action reason (STUCK, no progress, max cycles exhausted). The wrapper will NOT retry; manual operator review is required before the PR can merge.
- `review-mcp-outage` — the codex MCP backend was unreachable. No code-quality review took place. The wrapper retries automatically at the top of each outer iteration. Remove the label manually if you merge the PR without waiting.

**Retry policy.** When a codex transport failure is detected (telltales: `Transport send error:`, `tool call failed for \`codex_apps/`, or `error sending request for url (https://chatgpt.com/`), the wrapper retries codex up to 3 times with 0 / 60s / 300s delays. If all retries fail, it labels the PR `review-mcp-outage`, marks it draft, and halts the babysitter. The next babysitter run picks up the labelled PR and retries.

**Pre-flight.** Before the outer loop starts, the wrapper ensures the working tree is clean and on the default branch. It auto-switches to the default branch and fast-forwards if the branch is behind origin (both are safe when the tree is otherwise clean). It refuses to start — with corrective instructions — if there are uncommitted modifications, untracked non-ignored files, or a diverged/ahead-of-origin default branch. Seeing `[preflight] switching from 'fix/...' to 'main'` is **normal** after every review cycle: `run_review_cycle` calls `gh pr checkout` and doesn't switch back, so the auto-switch is the expected recovery path on re-run.

## babysit-with-review.sh — convergence-aware review flow

**Scope discipline.** The Claude review prompt tells Claude to make minimal targeted changes, commit each finding separately, run tests after every fix, and avoid touching code Codex did not flag. This reduces the "shifting goalposts" failure mode where a fix introduces new surface for Codex to flag.

**Cycle history (cycle 2+).** Each Codex pass from cycle 2 onward receives the full text of all prior reviews plus a `git log` of commits Claude made since the review cycle started. Codex tags each finding `[NEW]` or `[RECURRENCE]` so Claude can see whether it is converging or spinning.

**Prescriptive mode (cycle 3+).** From cycle 3 onward the wrapper switches to a stricter Codex prompt that requires a concrete `Suggested fix:` line under every BLOCKING bullet. If Codex cannot propose a concrete fix it must downgrade the finding to RECOMMENDED.

**Default `MAX_REVIEW_CYCLES` is 6** (was 3). Prescriptive mode kicks in at cycle 3, so the cap needs room for it to help.

## Related repos

- `~/repos/home-lab-monitor/` — separate project. Hosts the fleet monitoring
  server, agent, specs, and the slot-reservation system used by fleet-based
  tests.
