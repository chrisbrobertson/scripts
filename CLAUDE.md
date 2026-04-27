# scripts

Personal helper scripts for working with Claude Code and the home-lab fleet:
autonomous Claude loops (`babysit*.sh`), `gh` CLI wrappers (`prs`, `issues`,
`specs`), and one-off empirical tests (`test-*`). No formal test suite, no build
step, no CI.

## Conventions

- **Tracking.** Most files are intentionally untracked. Commit when something
  stabilises. Currently only `babysit.sh` is in git.
- **Helpers are repo-agnostic.** `prs`, `issues`, and `specs` wrap `gh` and
  operate on whichever repo the caller is in. Don't add cwd-specific assumptions
  to them.
- **New scripts** need a shebang and the executable bit (`chmod +x`).
- **Tests are exploratory.** Document outcomes in commit messages or in specs
  under `~/repos/home-lab-monitor/specs/`; don't add them as assertions here.

## Files

| File | Purpose |
| --- | --- |
| `babysit.sh` | Autonomous `claude -p` loop with stop-file lock; see its header for env vars |
| `babysit-with-review.sh` | Variant that interleaves adversarial code review |
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

## Related repos

- `~/repos/home-lab-monitor/` — separate project. Hosts the fleet monitoring
  server, agent, specs, and the slot-reservation system used by fleet-based
  tests.
