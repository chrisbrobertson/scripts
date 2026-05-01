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
| `babysit-with-review.sh` | Autonomous `claude -p` loop with stop-file lock and Claude↔Codex PR-review cycle; see header for env vars |
| `test-llm-routing.py` | Empirical test: model-alias forwarding + OAuth rejection by Anthropic |
| `test-codex-review.sh` | Codex review helper |
| `prs` | `gh pr list` with CI rollup and review state |
| `issues` | `gh issue list` sorted by priority labels |
| `specs` | List spec files (`-v0.1.md`) with frontmatter status and components |

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

**Pre-flight.** Before the outer loop starts, the wrapper fetches origin and refuses to start if the local default branch has unpushed commits. This prevents review tools from computing the wrong diff. If you see the pre-flight error, run `git log --oneline origin/<branch>..<branch>` to inspect the commits, then `git push origin <branch>` and re-run.

## Related repos

- `~/repos/home-lab-monitor/` — separate project. Hosts the fleet monitoring
  server, agent, specs, and the slot-reservation system used by fleet-based
  tests.
