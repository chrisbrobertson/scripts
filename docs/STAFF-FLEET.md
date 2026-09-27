# Staff-Fleet Operator Guide

A staff-fleet is three always-on AI agents — **staff-swe**, **staff-sre**, and
**staff-pm** — running continuously for a single service. Each morning they scan
GitHub, post a Telegram digest to you, and stay ready for on-demand questions
throughout the day. You run one fleet per service; fleets share no state.

**Who is this for.** You (the operator) installing and managing fleets, or a
collaborator coming in cold who needs to understand both how to use the agents
and why the system is built the way it is.

---

## Table of Contents

1. [Mental Model](#1-mental-model)
2. [Quick Start](#2-quick-start)
3. [Architecture](#3-architecture)
4. [The Three Agents](#4-the-three-agents)
5. [Daily Operation](#5-daily-operation)
6. [Working With the Agents Interactively](#6-working-with-the-agents-interactively)
7. [Fleet Management](#7-fleet-management)
8. [Tuning](#8-tuning)
9. [Troubleshooting](#9-troubleshooting)
10. [File Layout Reference](#10-file-layout-reference)
11. [Limitations & Design Notes](#11-limitations--design-notes)
- [Appendix A: Glossary](#appendix-a-glossary)
- [Appendix B: Source References](#appendix-b-source-references)

---

## 1. Mental Model

### 1.1 What you're building

Imagine the `secondbrain` service has a senior engineer who checks every merged
PR for risk, an SRE who notes every deploy and CI failure, and a PM who scans
every open issue for blockers — and you can DM any of them anytime. That's a
staff-fleet.

Each agent runs inside **Hermes** (NousResearch's agent framework) as its own
profile, uses its own Telegram bot as a messaging gateway, maintains long-term
memory about the service, and fires a cron each morning. Inference comes from
Hermes's native **`openai-codex`** provider — ChatGPT OAuth against
`https://chatgpt.com/backend-api/codex`, model `gpt-5.5` — already authenticated
via `hermes auth`; no API key, and (since 2026-05-11) no proxy in front of it.

### 1.2 Why three agents instead of one

Role conditioning is the cheapest form of specialisation. When a single agent
is asked to be SWE, SRE, and PM simultaneously, it dilutes across all three
roles and gives mushy answers.

Compare asking a single general agent vs. a role-conditioned one the same
question:

```
# General agent — unfocused, hedgy:
you: was the auth refactor in PR #482 risky?
agent: That's a complex question. The PR touches authentication which is
       important. You might want to consider the code quality as well as
       the product implications and also whether the infrastructure is ready...

# staff-swe — sharp, in-role:
you: was the auth refactor in PR #482 risky?
staff-swe: Yes. It removes the session-token salt rotation that was added
           after the Q3 audit. No test covers the regression path. I'd ask
           @alice to sign off before this hits prod.
```

An agent whose SOUL says "you only handle code quality; defer roadmap
questions to staff-pm" gives the second answer, not the first.

### 1.3 Why per-service fleets

One fleet per service means:

- **Focused memory.** The SWE for `meridian` builds deep familiarity with that
  codebase. If it shared memory with `secondbrain`, cross-service noise would
  dilute its model of either codebase.
- **Isolated crons.** Each fleet's morning digests cover exactly one service.
  You don't get a merged `secondbrain` + `meridian` PR list that you have to
  mentally filter.
- **Independent restarts.** A crashed gateway for `meridian` doesn't affect
  `secondbrain`. Restart one; the other keeps running.
- **Clean shutdown.** Retiring a service means `rm -rf ~/staff-fleet/<name>`
  and stopping its three Hermes gateways. Nothing else is affected.

---

## 2. Quick Start

Prerequisites: `gh` (GitHub CLI, authenticated), `hermes` (Hermes Agent,
authenticated with `openai-codex` — run `hermes auth` if `hermes auth status
openai-codex` doesn't say "logged in"). `new-fleet.sh` defensively checks both
and refuses to start if either is missing. `python3` is also required (used
directly to patch Hermes's `gateway.py`) but isn't defensively checked —
macOS ships it, so this rarely bites.

### Step 1 — Scaffold the fleet

```bash
cd ~/repos/scripts
./new-fleet.sh <fleet-name> <path-to-repo>

# Examples:
./new-fleet.sh secondbrain ~/repos/secondbrain
./new-fleet.sh meridian    ~/repos/meridian
```

There is no `--port` or other flag — exactly two positional arguments.

**What it does** (abbreviated; see [§10](#10-file-layout-reference) for the
full artifact list):
- Idempotently patches `~/.hermes/hermes-agent/hermes_cli/gateway.py` so it
  injects each profile's `.env` (`GH_*`/`TELEGRAM_*`/`OPENAI_*`/`ANTHROPIC_*`/
  `FLEET_*` keys) into the gateway's launchd `EnvironmentVariables` — Hermes
  regenerates that plist from a hardcoded template on every `gateway start`,
  which would otherwise wipe manual edits.
- Creates `~/staff-fleet/<fleet-name>/`, a `service-context.md` template (only
  if missing), and per-role `SOUL.md` + `config.yaml` + `.env` under
  `profiles/staff-{swe,sre,pm}/`.
- Copies `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`, and `GH_TOKEN` from
  any other fleet already on this machine (same operator, same GitHub token).
- If run interactively, prompts for each of the three per-agent Telegram bot
  tokens; if not, leaves `TELEGRAM_BOT_TOKEN` for you to fill in.
- Creates the three Hermes profiles, syncs `SOUL.md`/`config.yaml` into them,
  and symlinks `~/.hermes/auth.json` into each so the gateway processes (which
  run with `HERMES_HOME` set to the profile dir) always see current
  `openai-codex` credentials.
- Writes `team-orchestrator.py`, `babysit-driver.sh`, `team-dispatcher.sh`,
  the `offline-dev` skill, and a PM `spec-review-prompt.txt` — the autonomous
  dev chain described in [§3.6](#36-the-autonomous-dev-chain).
- Writes fleet-qualified bin wrappers (`<fleet>-{swe,sre,pm}`) into both
  `<fleet-dir>/bin/` and `~/.local/bin/`, and writes `start-gateways.sh`.

**Common failure:** `error: 'hermes' not found in PATH`
→ Install Hermes: `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash`

**Common failure:** `error: Hermes is not authenticated with openai-codex.`
→ Run `hermes auth` and complete the ChatGPT OAuth flow, then re-run.

**Re-running is safe.** If you run `new-fleet.sh` again on an existing fleet,
config files are overwritten but Hermes memory and sessions are preserved
(`.hermes/` is never deleted), and an existing `service-context.md`/`.env` is
left untouched.

### Step 2 — Fix `[REPO]` placeholders in the SOUL files

The SOUL.md templates, each role's `config.yaml` `cron:` block, and the PM
handoff/spec-review prompts all include `--repo [REPO]` in `gh` command
examples. Replace with the actual `owner/repo` slug everywhere it appears:

```bash
# Find your repo slugs:
cd ~/repos/secondbrain && gh repo view --json nameWithOwner -q .nameWithOwner
cd ~/repos/meridian    && gh repo view --json nameWithOwner -q .nameWithOwner

# Find all placeholders:
grep -rl '\[REPO\]' ~/staff-fleet/secondbrain/profiles/

# Replace (example — use your actual slug):
sed -i '' 's/\[REPO\]/yourorg\/secondbrain/g' \
  ~/staff-fleet/secondbrain/profiles/staff-swe/SOUL.md \
  ~/staff-fleet/secondbrain/profiles/staff-sre/SOUL.md \
  ~/staff-fleet/secondbrain/profiles/staff-pm/SOUL.md \
  ~/staff-fleet/secondbrain/profiles/staff-swe/config.yaml \
  ~/staff-fleet/secondbrain/profiles/staff-sre/config.yaml \
  ~/staff-fleet/secondbrain/profiles/staff-pm/config.yaml \
  ~/staff-fleet/secondbrain/profiles/staff-pm/handoff-prompt.txt \
  ~/staff-fleet/secondbrain/profiles/staff-pm/spec-review-prompt.txt

# Then sync SOUL.md + config.yaml back into Hermes profiles — new-fleet.sh
# copied the originals here once at fleet-creation time, and `gateway install`
# (Step 5) reads config.yaml from THIS location, not the template above:
for role in swe sre pm; do
  cp ~/staff-fleet/secondbrain/profiles/staff-${role}/SOUL.md \
     ~/staff-fleet/secondbrain/.hermes/profiles/staff-${role}/SOUL.md
  cp ~/staff-fleet/secondbrain/profiles/staff-${role}/config.yaml \
     ~/staff-fleet/secondbrain/.hermes/profiles/staff-${role}/config.yaml
done
```

The prompt files don't need a separate sync step — `start-gateways.sh` reads
`handoff-prompt.txt` and `spec-review-prompt.txt` directly from the template
`profiles/` directory when it registers those cron jobs.

Do this **before** running `start-gateways.sh` (Step 5): the three daily
crons are created by Hermes from `config.yaml` on first `gateway install`,
and the two extra cron jobs embed the prompt file's contents as a literal
argument at creation time. A placeholder left in either copy of `config.yaml`
at that point, or fixed only after the cron already exists, produces a
literal "unknown repository [REPO]" error from `gh` — not a
silently-wrong-repo result, since `terminal.cwd` is already pinned to the
service repo. Re-registering after the fact means deleting the affected cron
job (`hermes -p staff-<role> cron remove <job_id>`) and re-running
`start-gateways.sh`.

### Step 3 — Fill in `service-context.md`

This is the most important step. `SOUL.md` instructs each agent to read
`${FLEET_DIR}/service-context.md` at the start of every session — the
`filesystem` MCP server in `config.yaml` gives it read access to both the repo
and the fleet directory. Unlike the old proxy, nothing forces this read to
happen; it depends on the model following its own system-prompt instruction.
The better this file, the better every agent response.

```bash
$EDITOR ~/staff-fleet/secondbrain/service-context.md
```

See [§8.1 Tuning service-context.md](#81-service-contextmd) for a detailed
guide and worked example. At minimum, fill in the service name, repo URL,
stack, and the "Role Boundaries" and "Escalation Rules" sections.

**Don't skip this.** An agent without context will give generic GitHub-scraping
responses. An agent with a good service-context.md will give targeted,
nuanced ones.

### Step 4 — Create Telegram bots and fill `.env` files

Each agent needs its own Telegram bot (3 bots per fleet = 6 bots for two
fleets):

1. Open Telegram → search `@BotFather` → `/newbot`
2. Follow prompts; note the token (looks like `123456:ABCdef...`)
3. Get your Telegram user ID from `@userinfobot`
4. If `new-fleet.sh` ran interactively it already prompted you for each bot
   token. Otherwise fill in the `.env` for each agent:

```bash
$EDITOR ~/staff-fleet/secondbrain/profiles/staff-swe/.env
# Set TELEGRAM_BOT_TOKEN=<token>
# Set TELEGRAM_ALLOWED_USERS=<your-user-id>
# Set TELEGRAM_HOME_CHANNEL=<your-user-id>  (same as above for a single user)
# Set GH_TOKEN=<output of: gh auth token>
```

Repeat for sre and pm — though `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`,
and `GH_TOKEN` are usually already filled in for you (copied from an existing
fleet on the same machine). The `.env` files are never committed to git.

**Using fewer bots.** If you don't need per-agent identity in Telegram, you
can reuse one bot token across all three agents in a fleet. They'll all appear
as the same Telegram contact, but messages will still be processed by the
correct Hermes profile since each runs its own gateway.

### Step 5 — Start everything

```bash
~/staff-fleet/secondbrain/start-gateways.sh
```

This installs and starts all three Telegram gateways, wires the five staff-pm
cron jobs (see [§3.6](#36-the-autonomous-dev-chain)), and runs a set of
pre-flight checks for the autonomous-dev chain (repo remote protocol, clean
working tree, `claude` CLI on PATH, home-lab-monitor reachability).

**Success looks like** (trimmed):
```
--- staff-swe gateway ---
[hermes gateway install output]
[hermes gateway start output]
[hermes gateway status output]
--- staff-sre gateway ---
...
--- staff-pm gateway ---
...

--- team orchestrator wiring ---
  created staff-pm/prioritize-handoff-prs
  created staff-pm/team-orchestrator (no-agent, runs daily at 9am)
  created staff-pm/team-dispatcher (no-agent, every 5 min)
  created staff-pm/spec-review-pr (triggered on-demand)

--- babysitter chain pre-flight ---
  OK: home-lab-monitor reachable at http://192.168.1.129:8888
  OK: this host (yourhost) is registered with the monitor

All gateways started + orchestrator + dispatcher wired. Verify by DMing each bot:
  staff-swe, staff-sre, staff-pm
Ask each: 'What service do you own and what is your role?'
```

Re-running `start-gateways.sh` is idempotent — already-installed gateways and
already-created cron jobs are skipped with a "already exists" message.

### Smoke test

Once the gateways are running, verify end-to-end:

```bash
# 1. Gateway status
secondbrain-swe gateway status
# Expected: "running", not "stopped"

# 2. One-shot CLI round-trip (bypasses Telegram, hits openai-codex directly)
secondbrain-swe chat -q "what tools do you have access to?"
# Expected: response mentioning gh, git, filesystem/terminal — not an error

# 3. Cron wiring — staff-pm should show 5 jobs, staff-swe/sre 1 each
HERMES_HOME=~/staff-fleet/secondbrain/.hermes hermes -p staff-pm cron list
```

If the CLI round-trip errors or returns nothing, check `hermes auth status
openai-codex` first, then the gateway's own logs (`hermes -p staff-swe gateway
status` and Hermes's own log location for the profile).

---

## 3. Architecture

### 3.1 Request lifecycle

```
Telegram DM
    │
    ▼
Hermes Agent  (profile: staff-swe, HERMES_HOME: ~/staff-fleet/secondbrain/.hermes/profiles/staff-swe/)
    │  system prompt = SOUL.md + Hermes conversation history
    │  terminal.cwd = the service repo; env_passthrough: GH_TOKEN
    │  mcp_servers.filesystem → read access to the repo AND the fleet dir
    ▼
openai-codex provider  (Hermes-native; https://chatgpt.com/backend-api/codex)
    │  authenticated via the symlinked auth.json (ChatGPT OAuth, shared across
    │  fleets from ~/.hermes/auth.json — ​no API key)
    ▼
gpt-5.5
    │
    ◀── response / tool call ──
    │
Hermes Agent  executes the tool call (gh, git, filesystem read, ...) or
    returns the final answer
    │
    ▼
Telegram message to you
```

There is no HTTP proxy in this path. Until 2026-05-11, Hermes's `provider:
custom` pointed at a local `claude-code-proxy.py` that shelled out to
`claude -p` per request; that proxy had an 8-second stale-connection timeout
in Hermes it couldn't cleanly override, so every agent response failed
intermittently. `openai-codex` is a provider Hermes already speaks natively,
already OAuth-authenticated, and responds in ~5s — no proxy needed.
`claude-code-proxy.py` is still in this repo but nothing wires it up anymore
(see [§11](#11-limitations--design-notes)).

### 3.2 Fleet isolation

| Concern | Mechanism |
|---|---|
| Memory bleed between services | Separate `HERMES_HOME` per fleet (`~/staff-fleet/<name>/.hermes/`) |
| Cron collisions between fleets | Separate `HERMES_HOME` + independent Hermes scheduler per fleet; no shared process |
| Profile name conflicts across fleets | Fleet-qualified bin wrappers (`secondbrain-swe`, not `staff-swe`) — the generic `~/.local/bin/staff-<role>` is intentionally overwritten with an error message |
| Credential bleed | `auth.json` is shared (one ChatGPT OAuth session), but each profile's `.env`/bot token/memory is fleet-local |

There is no port registry, launchd plist, or per-fleet HTTP server to manage —
`openai-codex` is an outbound HTTPS call Hermes makes itself; nothing listens
on a local port for this.

### 3.3 Credentials and env injection

Two separate credential paths feed each gateway process:

- **`openai-codex` auth** — `~/.hermes/auth.json`, symlinked into every
  profile directory by `new-fleet.sh`. One ChatGPT OAuth session, shared by
  all fleets and roles on the machine.
- **`.env` secrets** (`TELEGRAM_BOT_TOKEN`, `GH_TOKEN`, ...) — the gateway
  process runs under launchd with `HERMES_HOME` set to the profile dir, and
  Hermes regenerates that launchd plist from a template on every `gateway
  start`. The `HERMES_FLEET_ENV_INJECTION_PATCH` applied to `gateway.py` by
  `new-fleet.sh` teaches that template generator to also read the profile's
  `.env` and add matching keys (`GH_`, `GITHUB_`, `TELEGRAM_`, `OPENAI_`,
  `ANTHROPIC_`, `FLEET_` prefixes) as plist `EnvironmentVariables`, so they
  reach both the gateway process and any `terminal` subprocess it spawns.
  `terminal.env_passthrough: [GH_TOKEN]` in `config.yaml` additionally lets
  `GH_TOKEN` through Hermes's own subprocess credential-scrubbing filter so
  the agent's `gh` commands can authenticate — the bot token isn't on that
  passthrough list, so it's scrubbed from `terminal` subprocess env and
  output. That scrub only covers the process-env path, though: the `.env`
  file itself (`~/staff-fleet/<fleet>/.hermes/profiles/staff-*/.env`) lives
  inside the fleet directory, which is one of the two roots the `filesystem`
  MCP server (§3.4) is scoped to — so the model can read the bot token
  directly off disk via a filesystem tool call regardless of the scrub.

### 3.4 Tool access

`config.yaml` wires one MCP server (`filesystem`, scoped to the repo and the
fleet directory) plus a `terminal` block (`cwd` = the repo, `persistent_shell:
true`). There is no custom tool-call allowlist layer anymore — the old
`claude-code-proxy.py`-specific `_ALLOWED_TOOLS`/`--allowedTools` restriction
doesn't apply to the native `openai-codex` provider. What (if anything) bounds
which shell commands an agent can run under `terminal:` is Hermes's own
configuration surface, not something `new-fleet.sh` currently sets — treat
tighter sandboxing here as an open follow-up if you need it, rather than an
existing guarantee.

### 3.5 Response format and streaming

`openai-codex` is a real OpenAI-compatible provider Hermes talks to directly;
there's no custom `<tool>{...}</tool>` regex parsing or single-shot-per-turn
restriction to work around (that was `claude-code-proxy.py`-specific, see
`git show 84364ea` for what was removed). Multi-tool-call turns and normal
provider-level behavior apply.

### 3.6 The autonomous-dev chain

Beyond the three chat/digest agents, `new-fleet.sh` wires a second system: a
`--no-agent` (no-LLM-cost) cron chain on `staff-pm` that watches for
actionable GitHub work and drives `babysit-with-review.sh` (from this repo)
against it, unattended.

```
team-dispatcher (every 5 min, --no-agent)
    │  checks home-lab-monitor's distributed lock (GET /api/babysit;
    │  falls back to a local ~/sisyphus-logs/<fleet>.stop file if
    │  unreachable) — is a babysitter already running for this fleet
    │  anywhere on the home-lab?
    │  if clear AND (open PRs by @me) + (open priority/p1 or /p2 issues) > 0:
    ▼
babysit-driver.sh  (spawned via nohup)
    │  requires `claude` CLI on PATH — this IS still a `claude -p` subprocess,
    │  just for autonomous coding, unrelated to the staff agents' own
    │  openai-codex inference above
    │  runs babysit-with-review.sh against the service repo
    │  polls gh every 30s for new PRs opened during the run
    ▼
new PR opened → labelled `from-babysitter`, Telegram notice sent,
    staff-pm's `spec-review-pr` cron triggered on-demand
```

> **Hardcoded repo path.** `team-dispatcher.sh` and `babysit-driver.sh` both
> recompute `REPO_PATH="$HOME/repos/${FLEET_NAME}"` at runtime
> (`new-fleet.sh:836,923`) instead of reusing the `<repo-path>` argument
> `new-fleet.sh` was invoked with. That argument only flows into
> generation-time text (SOUL.md, config.yaml, MCP filesystem-server args); the
> autonomous-dev chain's own scripts ignore it. If your repo doesn't live at
> `~/repos/<fleet-name>`, the dispatcher and driver will silently no-op
> (`[[ -d "$REPO_PATH/.git" ]]` fails, so `GH_REPO_SLUG` stays empty and the
> dispatcher exits without spawning) or, worse, operate on an unrelated
> checkout that happens to exist at that path. Symlink `~/repos/<fleet-name>`
> to the real location if your layout differs.

```
    ▼
staff-pm (spec-review-pr, LLM-backed)
    │  judges product correctness (codex, if configured, already covers code
    │  quality via babysit-with-review.sh's own review cycle)
    ▼
PR labelled `spec-passed` or `spec-changes-requested`; verdict comment posted
```

Separately, once a day:

```
team-orchestrator (09:00, --no-agent, after the 3 morning digests)
    │  reads each role's latest cron session transcript, extracts trailing
    │  CONCERN: / HANDOFF: / WORK: marker lines (see the MARKER_FOOTER
    │  appended to every digest prompt)
    ├─ CONCERN: <text>        → appended to service-context.md's
    │                            "## Current Concerns / Risks" section
    ├─ HANDOFF: pm <reason>   → triggers staff-pm's prioritize-handoff-prs
    │                            cron (max ONE handoff fired per fleet per
    │                            day — a loop guard; only "pm" is a wired
    │                            target today, other roles log "unknown
    │                            handoff target" and no-op)
    └─ WORK: #N <reason>      → labels GitHub issue #N priority/p2 (queues
                                 it for team-dispatcher/babysit-driver above)
```

The `offline-dev` skill (deployed to all three profiles) documents this whole
chain to the agents themselves, so their morning digests can reason about
what to hand off or flag as `WORK:` candidates, and so `staff-swe`/`staff-pm`
know how to review a `from-babysitter`-labelled PR.

---

## 4. The Three Agents

### 4.1 staff-swe — Staff Software Engineer

**Charter.** Owns code quality, architecture decisions, and technical debt.
Reviews PRs, surfaces engineering risks, and proposes improvements. Does not
own deployment operations (staff-sre) or roadmap (staff-pm).

**Daily cron** — fires at **8:00 AM PT**:
- `gh pr list` and `gh pr list --state merged --limit 20 --repo <REPO>`
- Reviews changes from the past 24 hours
- Posts a Telegram digest: notable PRs, risks, wins
- If nothing notable: says so in one sentence
- Emits `HANDOFF: pm prioritize-open-prs` if 5+ PRs are open without priority labels
- Ends with `CONCERN:`/`HANDOFF:`/`WORK:` marker lines for `team-orchestrator` to parse

**Tools available:**

| Tool | What the agent uses it for |
|---|---|
| `Bash(gh *)` | `gh pr list`, `gh pr view`, `gh pr diff`, `gh run list` |
| `Bash(git *)` | `git log`, `git diff`, `git show` for local diff inspection |
| filesystem MCP | Read source files when reviewing a specific change, and read `service-context.md` |

**Example interactive transcript** *(illustrative)*:

```
you: any risky PRs merged in the last 24h?

staff-swe: Three merged. One worth flagging: PR #482 (auth-token-storage-
           refactor). It removes salt rotation that was added post-Q3-audit.
           No test covers the regression path.
           PRs #480 and #481 are routine — test additions and a readme fix.

you: can you check if there's any test for the token encryption path?

staff-swe: [greps for test files touching auth/token]
           Found 2 test files: tests/auth/test_session.py and
           tests/auth/test_login.py. Neither tests the encryption path that
           #482 modifies. test_session.py has a TODO comment: "add encryption
           regression after #412." #412 merged 3 months ago.

you: draft a comment on PR #482 flagging this?

staff-swe: My SOUL.md instructs me not to post PR comments without your
           sign-off — nothing in config actually blocks the `gh` call, so
           treat that as a behavioral norm, not an enforced permission. I can
           draft the text and you can paste it:

           "This removes the salt-rotation logic added in #387 (post-Q3
           audit). tests/auth/test_session.py has a TODO for an encryption
           regression test that was never written. Recommend adding before
           this merges. cc @alice"
```

**Hand-offs:**
- Roadmap / ticket priority questions → staff-pm ("Is feature X scheduled?" — defer)
- Production incident diagnosis → staff-sre ("Why did the deploy fail?" — defer)
- Anything requiring human sign-off → surface and stop, do not act

**Source:** `new-fleet.sh:207-255` (`write_soul_swe`)

### 4.2 staff-sre — Staff Site Reliability Engineer

**Charter.** Owns uptime, incident response, deploy health, and observability.
Monitors recent deploys, surfaces errors, and tracks operational risks. Does
not own code architecture (staff-swe) or product roadmap (staff-pm). Always
notes explicitly when it lacks monitoring data (no monitoring MCP is wired
by default).

**Daily cron** — fires at **7:30 AM PT** (first, before SWE and PM):
- `gh run list --repo <REPO> --limit 10` — checks recent workflow runs
- Notes failed runs and rollbacks
- Posts a Telegram ops digest: deploy status, incidents
- Flags explicitly when monitoring MCP is not wired (partial visibility)

**Tools available:** Same set as staff-swe. For SRE use, `gh run list`,
`gh run view`, and `Bash(git log)` are the primary instruments.

**Example interactive transcript** *(illustrative)*:

```
you: did the deploy last night succeed?

staff-sre: [runs gh run list --limit 5]
           Last 5 workflow runs:
           - deploy-prod   #2341   success   2h ago
           - deploy-prod   #2340   failure   6h ago   (retried → #2341)
           - run-tests     #2339   success   7h ago

           The first attempt (#2340) failed in the "migrate-db" step. It
           retried automatically and #2341 succeeded. No rollback. I don't
           have application-level metrics (no monitoring MCP wired) — if
           you saw errors in prod after the deploy, check your APM tool.

you: what caused #2340 to fail?

staff-sre: [runs gh run view 2340]
           Step "migrate-db" exited 1. Error: "relation 'user_sessions'
           does not exist." This is a missing-migration error — a prior
           migration was likely not run in staging before deploying. The
           retry (#2341) succeeded, which suggests the migration ran on
           the second attempt (or a fix was deployed).
```

**Hand-offs:**
- Code quality / PR review → staff-swe
- Product priorities / ticket status → staff-pm
- Write actions on infrastructure → requires human sign-off; staff-sre stops and asks

**Source:** `new-fleet.sh:258-305` (`write_soul_sre`)

### 4.3 staff-pm — Staff Product Manager

**Charter.** Owns the product roadmap, issue tracking, and stakeholder
coordination. Summarises ticket changes, flags items needing human decisions,
and maintains awareness of what the team is building and why. Does not own
code architecture (staff-swe) or operational health (staff-sre). Also carries
the autonomous-dev chain's `--no-agent` crons (`team-orchestrator`,
`team-dispatcher`) and the on-demand `prioritize-handoff-prs` /
`spec-review-pr` crons — see [§3.6](#36-the-autonomous-dev-chain).

**Daily cron** — fires at **8:30 AM PT** (last, after SWE and SRE):
- `gh issue list --repo <REPO> --state open --limit 30`
- Checks for issues updated in the last 24h
- Posts a Telegram digest: new issues, status changes, blockers
- Flags items needing human decisions

**Example interactive transcript** *(illustrative)*:

```
you: anything blocking the v2 launch?

staff-pm: [runs gh issue list --label "v2" --state open]
          Three open v2 issues:
          - #201 (P0): "SSO integration broken for enterprise tenants" —
            open 4 days, no assignee. Blocking enterprise customers.
          - #198 (P1): "PDF export fails on Safari" — assigned @bob,
            last updated 2 days ago, no comments since.
          - #194 (P2): "Update onboarding copy" — assigned @carol, PR
            linked (#481), merged yesterday. Can close this issue.

          I'd flag #201 as the blocker — it's unassigned and affects
          paying customers. #198 may be stalled; worth a check-in with @bob.

you: can you assign #201 to me?

staff-pm: I don't have write access to reassign issues (by design — changes
          to issue state require human sign-off). You can assign it with:
          gh issue edit 201 --assignee @me --repo yourorg/secondbrain
```

**Hand-offs:**
- Technical diagnosis → staff-swe
- Deploy / incident status → staff-sre
- Committing to timelines → requires human confirmation; staff-pm stops and says so

**Source:** `new-fleet.sh:308-355` (`write_soul_pm`)

---

## 5. Daily Operation

### 5.1 A normal morning

The SRE fires first (7:30 AM) so operations context is already in your
Telegram before the SWE code-review lands (8:00 AM) and the PM product
summary rounds out the picture (8:30 AM). The `team-orchestrator` no-agent
cron runs at 9:00 AM, after all three.

**7:30 AM — staff-sre Telegram message** *(sample)*:
```
[secondbrain / ops digest]
Deploys (last 24h): 2 successful, 0 failures
Workflow health: all green
No incidents in CI. No rollbacks.

Note: application metrics not available (monitoring MCP not wired).
```

**8:00 AM — staff-swe Telegram message** *(sample)*:
```
[secondbrain / code digest]
Merged PRs (last 24h): 3
  • #483 — add /export endpoint (low risk, 1 test)
  • #482 — auth-token-storage-refactor (FLAG: removes salt rotation, no
    regression test — see PR comment)
  • #481 — fix typo in README (trivial)

Open draft PRs: 1 (#484, WIP — database sharding sketch)
```

**8:30 AM — staff-pm Telegram message** *(sample)*:
```
[secondbrain / product digest]
Issues updated (last 24h): 2
  • #194 closed (PR #481 merged, onboarding copy done)
  • #201 new P0: SSO broken for enterprise — unassigned, needs owner

Blockers needing human decision: #201
```

### 5.2 Cron staggering rationale

SRE fires first because operational context (did anything break?) is the
highest-priority daily check. SWE fires second because code-review findings
feed into the PM's issue triage. PM fires last because it can reference
("PR #483 is the implementation of issue #192") what the SWE already reported.
If all three fired simultaneously, the PM would miss that PR context.
`team-orchestrator` fires last of all (9:00 AM) so it has all three digests'
markers to parse.

### 5.3 Where logs land

| Log | Location | What's in it |
|---|---|---|
| Hermes session | `~/staff-fleet/<fleet>/.hermes/profiles/staff-<role>/sessions/` | Full conversation turns for each session |
| Hermes cron | `~/staff-fleet/<fleet>/.hermes/profiles/staff-<role>/cron/` | Cron execution records |
| `team-orchestrator` | `~/staff-fleet/<fleet>/logs/orchestrator.log` | What it parsed from each role's latest session and what it fired |
| `babysit-driver` | `~/sisyphus-logs/<fleet>-driver-*.log` | Autonomous babysitter run output, one file per invocation |
| `team-dispatcher` state | `~/staff-fleet/<fleet>/.dispatcher-state.json` | Last spawn time and the PR/issue counts that triggered it |

To watch the orchestrator or a driver run live:
```bash
tail -f ~/staff-fleet/secondbrain/logs/orchestrator.log
tail -f ~/sisyphus-logs/secondbrain-driver-*.log
```

### 5.4 Silent failure modes

The most dangerous failure is one you don't notice. Signs that an agent
stopped working without alerting you:

- **No Telegram digest by 9 AM** — cron fired but produced empty output
  (empty model response), or the gateway died overnight
- **Telegram bot shows "offline"** — the Hermes gateway process died;
  run `<fleet>-<role> gateway status` and restart if needed
- **`hermes auth status openai-codex` stops saying "logged in"** — the shared
  ChatGPT OAuth session expired; every fleet's every agent fails until you
  re-run `hermes auth`
- **No `from-babysitter` PRs ever appear despite open `priority/p1`/`p2`
  issues** — check `~/sisyphus-logs/<fleet>.stop` (a stale stop-file blocks
  `team-dispatcher` from spawning) and whether home-lab-monitor considers a
  babysitter already "running" for this fleet on some other host

A simple monitoring approach: set a Telegram message reminder at 9:30 AM to
check that all three digests arrived. If any are missing, check gateways first.

### 5.5 Memory model

Hermes maintains four layers of memory:

1. **Ephemeral** — in-context for the current turn only (automatic)
2. **Working** — the current session's conversation history (automatic)
3. **Long-term** — facts the agent writes to persistent memory across sessions
4. **User profile** — persistent user-specific facts

In our `config.yaml`, `memory_enabled: true` and `user_profile_enabled: false`.
Long-term memory is on so agents build up familiarity with the service over
time. User profile is off to keep agents focused on the service, not on you
personally (that can create unexpectedly personal responses).

---

## 6. Working With the Agents Interactively

### 6.1 From the CLI

**Interactive REPL:**
```bash
secondbrain-swe chat        # opens interactive session
meridian-sre chat           # SRE for meridian
```

**One-shot query:**
```bash
secondbrain-swe chat -q "what PRs merged today?"
secondbrain-pm  chat -q "show me open P0 issues"
```

**Direct Hermes command (bypasses the wrapper, useful for debugging):**
```bash
HERMES_HOME=~/staff-fleet/secondbrain/.hermes/profiles/staff-swe \
  hermes -p staff-swe chat -q "what tools do you have?"
```

**Example CLI session** *(illustrative)*:
```
$ secondbrain-swe chat
staff-swe> Hello! I'm the Staff SWE for secondbrain. I'll review PRs,
           surface code risks, and answer technical questions. What
           would you like to look at today?

you> list the open draft PRs

staff-swe> [fetches gh pr list --state open --repo yourorg/secondbrain]
           2 open draft PRs:
           - #484: database-sharding-sketch (WIP, no CI run yet)
           - #479: fix/retry-logic (CI passing, needs review)

you> what's in #479?

staff-swe> [fetches gh pr view 479]
           [fetches gh pr diff 479 | head -200]
           PR #479 adds exponential backoff to the payment API client.
           Looks solid. The new retry logic has a unit test. One concern:
           the max retry count (10) seems high for a payment call — if
           the payment provider is down, you'll hold a connection for
           ~90s. Might want to cap at 3-4.
```

### 6.2 From Telegram

DM the fleet's bot directly. Each agent has its own bot identity; you send
to the agent you want.

**Useful patterns:**

```
# Morning follow-up after reading a digest
"tell me more about PR #482 — how serious is the salt rotation removal?"

# Ad-hoc checks between digests
"did anything merge in the last 2 hours?"
"is there a test for the new /export endpoint?"

# Drafting without write access
"draft a comment for issue #201 asking for an owner"
(agent returns text you can copy-paste)

# Sanity checks before a deploy
"any open PRs with failing CI?"
"is there anything I should know before deploying the current main?"
```

### 6.3 Decision matrix: who do I ask?

| Question | Ask |
|---|---|
| Is this PR risky? | staff-swe |
| What tests cover this file? | staff-swe |
| Who wrote this function and why? | staff-swe |
| Did the last deploy succeed? | staff-sre |
| Why did CI fail on workflow run #X? | staff-sre |
| Is there an ongoing incident? | staff-sre |
| What's blocking the v2 launch? | staff-pm |
| Who owns issue #X? | staff-pm |
| Is feature Y scheduled this sprint? | staff-pm |
| Should I merge this PR? | staff-swe (risk) + your own judgement |
| Should I roll back? | staff-sre (context) + your own judgement |
| Should we reprioritise? | staff-pm (context) + your own judgement |
| Is the architecture right for this feature? | staff-swe |
| When will the feature ship? | staff-pm (what's committed) |
| Is prod healthy right now? | staff-sre |

Note the last column in the last three rows: agents give you context and
recommendations; final decisions stay with you. No agent has write access
unless you explicitly grant it.

### 6.4 Anti-patterns

**Don't ask staff-pm to review code.** It will try, but the SOUL doesn't
condition it to think about architecture; you'll get vague product-framing
of a code problem.

**Don't ask staff-sre for product opinions.** "Should we prioritise fixing
this bug or the new feature?" is a product question. SRE will give you
an ops-flavoured non-answer.

**Don't ask all three the same question.** Each role is designed to be
authoritative in its lane. Asking all three "what should I do?" triangulates
noise. Ask the right specialist.

**Don't expect real-time metrics.** No monitoring MCP is wired by default.
staff-sre can see CI runs and workflow results, but not app-level metrics,
error rates, or APM data unless you add an MCP server for it.

---

## 7. Fleet Management

### Add a new fleet

```bash
./new-fleet.sh <name> <path-to-repo>
```

There is no port to allocate — `openai-codex` needs no local listener.

### Re-run on an existing fleet (update config)

Re-running `new-fleet.sh` on an existing fleet is safe and idempotent:

| What happens | Notes |
|---|---|
| SOUL.md overwritten | Intentional — SOUL is generated from the script |
| config.yaml overwritten | Intentional — cron schedule, model, MCP |
| service-context.md preserved | Only created if missing |
| .env preserved | Never overwritten — your tokens are safe |
| .hermes/ preserved | Memory and sessions untouched |
| team-orchestrator.py / babysit-driver.sh / team-dispatcher.sh / offline-dev skill / spec-review-prompt.txt | Overwritten every run |

After re-running, sync config back into live profiles:
```bash
# Already done automatically by new-fleet.sh, but if you edit manually:
cp ~/staff-fleet/secondbrain/profiles/staff-swe/config.yaml \
   ~/staff-fleet/secondbrain/.hermes/profiles/staff-swe/config.yaml
```

### Stop / start a Telegram gateway

```bash
secondbrain-swe gateway stop
secondbrain-swe gateway start
secondbrain-swe gateway status
```

### Stop / start all gateways for a fleet

```bash
for role in swe sre pm; do
  ~/staff-fleet/secondbrain/bin/secondbrain-${role} gateway start
done
```

Or re-run `start-gateways.sh` (it's idempotent; already-running gateways will error harmlessly).

### Pause crons without disabling agents

Edit the agent's `config.yaml` and comment out the cron block, then sync it:
```bash
$EDITOR ~/staff-fleet/secondbrain/profiles/staff-swe/config.yaml
# Comment out or remove the cron: block

cp ~/staff-fleet/secondbrain/profiles/staff-swe/config.yaml \
   ~/staff-fleet/secondbrain/.hermes/profiles/staff-swe/config.yaml
```
The agent is still reachable via CLI and Telegram; it just won't fire on a schedule.

To pause only the autonomous-dev chain (leave the chat/digest agents running),
use the dispatcher's stop-file — `~/sisyphus-logs/<fleet-name>.stop` — but the
correct action depends on whether a babysitter is currently running:

- **No babysitter running.** `team-dispatcher.sh` refuses to spawn one while
  this file exists (`new-fleet.sh:953`). `touch` it to block future spawns;
  `rm` it to allow them again.
- **A babysitter is already running.** `rm`-ing the stop-file only stops the
  *current* run — it does not pause the chain. `team-dispatcher` is a Hermes
  cron job that still ticks every 5 minutes, and if open `priority/p1`/`p2`
  work remains once the current babysitter exits, the very next tick spawns
  a fresh one. To actually pause the chain while a babysitter is running:

  1. **Pause `team-dispatcher` first**, so nothing can respawn once the
     current run exits:
     ```bash
     JOB_ID=$(HERMES_HOME=~/staff-fleet/<fleet>/.hermes hermes -p staff-pm cron list \
       | awk '/^  [a-f0-9]{12} \[/{id=$1} /Name:/{sub(/^[[:space:]]+Name:[[:space:]]+/,""); if ($0=="team-dispatcher") {print id; exit}}')
     HERMES_HOME=~/staff-fleet/<fleet>/.hermes hermes -p staff-pm cron pause "$JOB_ID"
     ```
  2. **Then `rm` the stop-file.** The running babysitter created and owns
     this file itself as its run-lock (`babysit-with-review.sh:243`); its
     `EXIT` trap deletes it on exit. `touch`-ing it is a no-op — the file
     already exists, and the loop only checks for *absence* to detect a stop
     request. Removing it makes the loop notice on its next check
     (`babysit-with-review.sh:1751-1752`) and exit gracefully — this can take
     as long as the iteration currently in progress.
  3. **Verify it actually exited** before declaring the chain paused. Don't
     `pgrep` for the fleet name — the driver launches `babysit-with-review.sh`
     with no fleet-identifying argument at all (`new-fleet.sh:877`; it selects
     the repo via its working directory, not argv), so a name-based pattern
     can report "exited" while the run is still committing, pushing, or
     merging a reviewed PR. Use the actual PID instead, taken from the
     **current** run's driver log line `babysitter PID=...`
     (`new-fleet.sh:876`):
     ```bash
     BABYSIT_PID=12345 # from this run's "babysitter PID=..." line in the driver log
     while kill -0 "$BABYSIT_PID" 2>/dev/null; do
       sleep 2
     done
     echo "babysitter has exited"
     ```

  Don't try to "resume" by touching the stop-file back — the exit trap has
  already removed it. To resume, `hermes -p staff-pm cron resume "$JOB_ID"`
  (same `HERMES_HOME`); the dispatcher will spawn a fresh babysitter on its
  next tick if work is still open, which recreates its own stop-file as its
  run-lock.

### Remove a fleet entirely

```bash
# 1. Stop the three gateways
for role in swe sre pm; do
  secondbrain-${role} gateway stop
done

# 2. Remove runtime data
rm -rf ~/staff-fleet/secondbrain

# 3. Remove bin wrappers
rm ~/.local/bin/secondbrain-swe ~/.local/bin/secondbrain-sre ~/.local/bin/secondbrain-pm
```

### List all fleets

```bash
ls ~/staff-fleet/
```

---

## 8. Tuning

### 8.1 service-context.md

`SOUL.md` instructs each agent to read this file at the start of every
session — it's the primary lever for improving agent responses. Edit it at
least weekly; after major incidents, launches, or stakeholder changes.

**Section-by-section guide:**

| Section | What to put there | How agents use it |
|---|---|---|
| Service | Name, repo URL, stack, deploy target | Grounds all `gh` commands in the right repo and gives context for "what is this?" questions |
| Architecture | 1–2 paragraph summary | SWE uses this when reviewing PRs for architectural fit; PM uses it when fielding "is this feasible?" questions |
| Human Stakeholders | Who to involve and when | Agents cite these in recommendations ("ask @alice before merging auth changes") |
| Current Quarter Priorities | Top 3 priorities | PM uses this to triage blockers; SWE uses it to flag when a risky PR conflicts with priorities |
| Recent History | Last 30 days of significant events | Prevents agents from being surprised by things that just happened |
| Current Concerns / Risks | Known risks | SWE and SRE proactively watch for these in their digests; `team-orchestrator` also appends `CONCERN:` markers here automatically |
| Role Boundaries | Who owns what | Keeps agents in lane; critical for hand-off behaviour |
| Escalation Rules | When to involve a human | Prevents agents from acting autonomously on things that need sign-off |
| Write Capabilities | What agents may DO | Explicit permission list; agents default to read-only unless listed here |
| Glossary | Service-specific terms | Prevents misinterpretation of jargon |

**Worked example — filled-in `service-context.md`** *(illustrative)*:

```markdown
# Service Context

## Service
- **Name**: SecondBrain
- **Repo**: yourorg/secondbrain
- **Stack**: Python 3.11 / FastAPI / PostgreSQL / Redis / Celery
- **Deploy target**: Fly.io (prod), Render (staging)

## Architecture
FastAPI monolith with Celery workers for background jobs (PDF export,
email delivery). PostgreSQL for persistence, Redis for caching and task
queue. No microservices. Deployed via GitHub Actions on push to main.

## Human Stakeholders
| Name | Role | When to involve |
|------|------|-----------------|
| @alice | Lead Engineer | Auth changes, DB migrations, architecture decisions |
| @bob | Product | Roadmap changes, enterprise customer issues |
| @carol | CEO | Anything affecting enterprise contracts |

## Current Quarter Priorities
1. Fix SSO for enterprise customers (P0, blocking revenue)
2. Ship PDF export v2 (committed to 3 customers)
3. Reduce p95 API latency to <200ms

## Recent History (last 30 days)
- 2026-04-20: Deployed auth refactor; removed salt rotation accidentally
  (PR #382, should have been caught in review)
- 2026-04-28: Prod outage 14:00-14:45 PT — Redis OOM; added eviction policy
- 2026-05-01: Hired @dave as second engineer; onboarding this month

## Current Concerns / Risks
- Salt rotation is missing from auth (see PR #482); regression risk
- Redis eviction policy is new; monitor for cache stampede under load

## Role Boundaries
| What | Owner |
|------|-------|
| Code quality & architecture | staff-swe |
| Uptime, deploys, incidents | staff-sre |
| Roadmap, tickets, stakeholders | staff-pm |

## Escalation Rules
- Page a human when: prod error rate >1% for >5 minutes
- Involve @alice for: any auth changes, DB migration reviews
- Involve @bob for: any enterprise customer impact
- Never do without human sign-off: merging to main, closing P0 issues

## Write Capabilities
- **staff-swe**: comment on PRs, open draft PRs
- **staff-sre**: (none until explicitly granted)
- **staff-pm**: comment on issues, open draft issues

## Glossary
- "export job": the Celery task that generates PDFs (celery/tasks/export.py)
- "enterprise tenant": customers on the Enterprise SKU (SSO required)
```

### 8.2 SOUL.md tuning

SOUL.md defines the agent's role identity. The canonical copy lives at
`~/staff-fleet/<fleet>/profiles/staff-<role>/SOUL.md`; sync it to `.hermes/`
after edits.

**When to edit:**

*Agent keeps wandering into product talk:*
Add a line to "What You Do NOT Do":
```
- Do not discuss feature roadmap or sprint priorities — defer to staff-pm
```

*Daily digests are too verbose:*
Add a length constraint to "Communication Style":
```
- Keep each digest under 10 bullets. If there's more, rank by severity and
  cut the bottom.
```

*Agent fabricates PR numbers or commit hashes:*
Add to "Communication Style":
```
- Never fabricate PR numbers, commit hashes, or issue IDs. If you can't
  verify it with a gh command, say you don't know.
```

**After editing SOUL.md:**
```bash
cp ~/staff-fleet/secondbrain/profiles/staff-swe/SOUL.md \
   ~/staff-fleet/secondbrain/.hermes/profiles/staff-swe/SOUL.md
```

### 8.3 config.yaml knobs

The config lives at
`~/staff-fleet/<fleet>/profiles/staff-<role>/config.yaml` (canonical) and
`~/staff-fleet/<fleet>/.hermes/profiles/staff-<role>/config.yaml` (live).

**Model provider** — Hermes's native `openai-codex`, no local endpoint:
```yaml
model:
  provider: openai-codex
  base_url: https://chatgpt.com/backend-api/codex
  default: gpt-5.5
```

**Terminal / credential passthrough:**
```yaml
terminal:
  cwd: /path/to/repo
  persistent_shell: true
  env_passthrough:
    - GH_TOKEN   # only this key crosses Hermes's subprocess credential scrub
```

**Cron schedule** — uses standard cron syntax, America/Los_Angeles timezone:
```yaml
cron:
  - name: "daily-code-review"
    schedule: "0 8 * * *"    # 8:00 AM PT daily
    # schedule: "0 8 * * 1-5"  # weekdays only
```

**Max turns** — limits how many tool-call round-trips the agent can make
per cron invocation. Default 30. Raise if you want deeper PR analysis:
```yaml
agent:
  max_turns: 50
```

**Adding an MCP server** (example: add GitHub MCP for richer PR data):
```yaml
mcp_servers:
  filesystem:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/repo"]
  github:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "ghp_..."
```

After editing, sync to `.hermes/`:
```bash
cp ~/staff-fleet/secondbrain/profiles/staff-swe/config.yaml \
   ~/staff-fleet/secondbrain/.hermes/profiles/staff-swe/config.yaml
```

### 8.4 Tool access — no proxy allowlist anymore

Before 2026-05-11, `claude-code-proxy.py:42` hardcoded an `_ALLOWED_TOOLS`
allowlist (`Bash(gh *) Bash(git *) ... Read Glob Grep`) passed as
`--allowedTools` to every `claude -p` call. That mechanism doesn't exist for
the native `openai-codex` provider — `new-fleet.sh` doesn't currently set an
equivalent hard restriction. What an agent can actually reach is bounded only
by `terminal.cwd`, `env_passthrough`, and whichever `mcp_servers` are listed
in `config.yaml`. If you need a stricter guarantee (e.g. explicitly deny
`Bash(rm *)` or outbound `curl`), that's an open gap in the current scaffold,
not a documented, tested control — don't assume one exists.

---

## 9. Troubleshooting

### `hermes` gateway not responding

**Symptom:** `secondbrain-swe chat -q "..."` hangs, errors, or times out;
`secondbrain-swe gateway status` shows anything other than "running"

**Diagnosis:**
```bash
secondbrain-swe gateway status
hermes auth status openai-codex   # shared across all fleets — check this first
```

**Fixes:**
- Not running: `secondbrain-swe gateway start`
- Not authenticated: `hermes auth` (re-does the ChatGPT OAuth flow)
- Still failing: check whether `~/.hermes/hermes-agent/hermes_cli/gateway.py`
  still carries the `HERMES_FLEET_ENV_INJECTION_PATCH` marker (a Hermes
  upgrade may have replaced the file); re-run `new-fleet.sh` to re-apply it

### Agent claims it has no tools / ignores `gh` output

**Symptom:** `staff-swe` says "I don't have access to GitHub tools" or ignores tool results

**Cause 1:** `GH_TOKEN` isn't reaching the `gh` subprocess. Check
`terminal.env_passthrough` includes `GH_TOKEN` in `config.yaml`, and that the
profile's `.env` actually has it set (`gh auth token` to get a fresh one).

**Cause 2:** The `filesystem` MCP server failed to start (check its `command`/
`args` in `config.yaml` — it shells out to `npx`, which needs Node.js on PATH
for the gateway process, not just your interactive shell).

### Telegram gateway silent

**Symptom:** You DM the bot; no response

**Diagnosis:**
```bash
secondbrain-swe gateway status
# Look for "running" vs "stopped"
```

**Fixes:**
- Stopped: `secondbrain-swe gateway start`
- Bad token: check `.env` TELEGRAM_BOT_TOKEN is correct (no trailing spaces)
- Bot not started: go to the bot in Telegram and press Start
- Multiple fleets using the same token: Telegram delivers messages to only one webhook; each fleet's agent must have a unique bot token

### Wrong fleet responds

**Symptom:** You run `staff-swe chat` (the generic name) and get the wrong fleet

**Cause:** Hermes created `~/.local/bin/staff-swe` during profile setup and it points at the last fleet that ran `new-fleet.sh`.

**Fix:** Always use fleet-qualified wrappers: `secondbrain-swe`, `meridian-swe`. The generic `staff-swe` wrapper was intentionally poisoned with an error message — if it's not erroring, something overwrote it.

### Cron didn't fire

**Diagnosis:**
```bash
HERMES_HOME=~/staff-fleet/secondbrain/.hermes/profiles/staff-swe hermes -p staff-swe cron list
# Check the next-fire time; verify timezone in config.yaml
```

**Common causes:**
- Hermes gateway not running (cron requires the gateway process)
- Timezone mismatch: `config.yaml` has `timezone: America/Los_Angeles` but you expected UTC
- Cron block commented out during a previous tuning session
- For `team-orchestrator`/`team-dispatcher`/`prioritize-handoff-prs`/
  `spec-review-pr`: these aren't auto-seeded from `config.yaml` like the 3
  digest crons — they're created explicitly by `start-gateways.sh`. If you
  never ran it (or ran it before the profile existed), they won't be there;
  re-run `start-gateways.sh`.

### `team-dispatcher` never spawns a babysitter despite open work

**Diagnosis:**
```bash
cat ~/sisyphus-logs/secondbrain.stop 2>/dev/null && echo "stop-file present"
pgrep -f babysit-with-review.sh   # if this prints a PID, the stop-file is that run's active lock — don't remove it; see "Pause crons without disabling agents" instead
curl -s http://192.168.1.129:8888/api/babysit | python3 -m json.tool
gh pr list --repo yourorg/secondbrain --state open --author @me --json number
gh issue list --repo yourorg/secondbrain --state open --label priority/p1 --json number
gh issue list --repo yourorg/secondbrain --state open --label priority/p2 --json number
```

**Common causes:**
- A stale `~/sisyphus-logs/<fleet>.stop` file from a previous manual pause
- home-lab-monitor reports a babysitter already `running`/`backoff` for this
  fleet on another host (by design — only one babysitter per project at a time)
- No open PR by the authenticated user AND no `priority/p1`/`p2` issues — this
  is the "no actionable work" no-op case, not a bug
- `claude` CLI missing on PATH for the dispatcher's environment — check
  `~/sisyphus-logs/<fleet>-dispatcher-*.log`

### `team-orchestrator` isn't appending CONCERN markers / firing handoffs

**Diagnosis:**
```bash
tail -50 ~/staff-fleet/secondbrain/logs/orchestrator.log
```

**Common causes:**
- The role's latest cron session was already processed (state cached in
  `.team-orchestrator-state.json`) — only a NEW session triggers re-parsing
- A `HANDOFF:` was already fired for this fleet today (max one per day)
- `HANDOFF: swe ...` or `HANDOFF: sre ...` — only `pm` is a wired target
  today; other targets log "unknown handoff target" and no-op
- The digest prompt's `MARKER_FOOTER` instructions weren't followed by the
  model — markers must be the literal last lines of the response

### service-context.md not picked up

**Symptom:** Agent doesn't seem to know anything about the service

**Diagnosis:**
```bash
ls ~/staff-fleet/secondbrain/service-context.md   # confirm it exists
secondbrain-swe chat -q "read ~/staff-fleet/secondbrain/service-context.md and summarize it"
```

Unlike the old proxy, nothing forces this file to be read every session —
it's a `SOUL.md` instruction the model has to act on. If the summarize test
above fails, check that the `filesystem` MCP server's `args` in `config.yaml`
actually include the fleet directory (`${FLEET_DIR}`), not just the repo.

---

## 10. File Layout Reference

### Runtime artifacts (`~/staff-fleet/`)

```
~/staff-fleet/
├── secondbrain/
│   ├── service-context.md            ← agents are told to read this every session; edit weekly
│   ├── start-gateways.sh             ← one-time setup; safe to re-run
│   ├── team-orchestrator.py          ← parses CONCERN/HANDOFF/WORK markers, fires handoffs
│   ├── babysit-driver.sh             ← spawns and monitors babysit-with-review.sh
│   ├── team-dispatcher.sh            ← every-5-min distributed-lock check + spawn
│   ├── .team-orchestrator-state.json ← last-processed session per role, handoff-fired date
│   ├── .dispatcher-state.json        ← last dispatcher spawn decision
│   ├── logs/
│   │   └── orchestrator.log
│   │
│   ├── profiles/                     ← canonical (human-editable) copies
│   │   ├── staff-swe/
│   │   │   ├── SOUL.md               ← role definition
│   │   │   ├── config.yaml           ← cron, model, MCP, max_turns
│   │   │   └── .env                  ← TELEGRAM_BOT_TOKEN, GH_TOKEN (never commit)
│   │   ├── staff-sre/
│   │   │   └── (same shape)
│   │   └── staff-pm/
│   │       ├── (same shape)
│   │       ├── handoff-prompt.txt        ← stashed for start-gateways.sh's cron create
│   │       └── spec-review-prompt.txt    ← stashed for start-gateways.sh's cron create
│   │
│   ├── bin/                          ← fleet-local wrappers (same as ~/.local/bin)
│   │   ├── secondbrain-swe
│   │   ├── secondbrain-sre
│   │   └── secondbrain-pm
│   │
│   └── .hermes/                      ← HERMES_HOME; do not edit directly
│       ├── profiles/
│       │   ├── staff-swe/            ← live copies; synced from profiles/ by new-fleet.sh
│       │   │   ├── SOUL.md
│       │   │   ├── config.yaml
│       │   │   ├── .env
│       │   │   ├── auth.json         ← symlink → ~/.hermes/auth.json (openai-codex creds)
│       │   │   └── skills/
│       │   │       └── offline-dev.md
│       │   ├── staff-sre/
│       │   │   └── (same shape)
│       │   └── staff-pm/
│       │       ├── (same shape)
│       │       └── scripts/
│       │           ├── team-orchestrator-secondbrain.sh  ← --script wrapper for cron
│       │           └── team-dispatcher-secondbrain.sh    ← --script wrapper for cron
│       ├── memory/                   ← Hermes long-term memory files
│       ├── sessions/                 ← conversation history per session
│       └── gateways/                 ← Telegram gateway state
│
└── meridian/                         ← same shape; independent HERMES_HOME
```

### Source artifacts (`~/repos/scripts/`)

```
~/repos/scripts/
├── new-fleet.sh                      ← run this to provision a fleet
├── claude-code-proxy.py              ← orphaned; nothing wires this up anymore
├── docs/
│   └── STAFF-FLEET.md                ← this file
└── CLAUDE.md                         ← Claude Code instructions for this repo
```

### Relationship between `profiles/` and `.hermes/profiles/`

`profiles/` in the fleet dir is the human-editable canonical source.
`.hermes/profiles/` is what Hermes actually reads at runtime.
`new-fleet.sh` syncs from canonical → live on every run. If you edit
`profiles/staff-swe/SOUL.md`, you must copy it to `.hermes/profiles/staff-swe/SOUL.md`
for the change to take effect. `new-fleet.sh` does this automatically when re-run.

---

## 11. Limitations & Design Notes

**No monitoring MCP wired.** staff-sre can see CI run status and workflow
logs via `gh run list`, but has no access to application metrics, error rates,
APM data, or log aggregators. It notes this explicitly in every digest. To add
monitoring: wire a monitoring MCP server in staff-sre's `config.yaml`.

**PM and SRE are read-only by default — as an instruction, not an enforced
boundary.** Nothing in `config.yaml` restricts which `gh` subcommands an agent
can run (see §3.4 and the note below); "read-only by default" means SOUL.md
and `service-context.md`'s Write Capabilities section tell the agent not to
write unless explicitly granted there. staff-swe can comment on PRs (if
explicitly granted). PM can draft issue comments. SRE has no write capability
until explicitly granted. This is intentional; write access for AI agents
should be incremental and deliberate — but it's a norm the agent is expected
to follow, not one it's technically prevented from breaking.

**No documented tool-call allowlist.** The pre-2026-05-11 proxy hardcoded a
tool allowlist (`_ALLOWED_TOOLS`); the native `openai-codex` provider has no
equivalent configured by `new-fleet.sh` today (see [§8.4](#84-tool-access--no-proxy-allowlist-anymore)).
This is a real reduction in the explicit-allowlist guarantee the original
design had, traded for reliability — revisit if you need a hard boundary.

**`HANDOFF:` only supports the `pm` target today.** `team-orchestrator.py`'s
`HANDOFF_TARGETS` dict has exactly one entry (`"pm": ("staff-pm",
"prioritize-handoff-prs")`). A digest emitting `HANDOFF: swe ...` or `HANDOFF:
sre ...` logs "unknown handoff target" and does nothing.

**At most one handoff fires per fleet per day.** A loop guard in
`team-orchestrator.py` (`handoff_triggered_date`) prevents cascading handoffs;
if multiple roles emit `HANDOFF:` markers on the same day, only the first
queued one actually fires.

**`WORK:` markers aren't verified before labelling.** Any role can emit
`WORK: #N <reason>` and `team-orchestrator` labels issue `#N` `priority/p2`
unconditionally — there's no check that `#N` is well-scoped or even exists
in the expected repo beyond what `_derive_gh_repo` resolves from the PM
profile's own cron `workdir`.

**One babysitter per project at a time, enforced across the whole home-lab.**
`team-dispatcher.sh` treats "already running" as a hard stop, checked via
home-lab-monitor's `/api/babysit` with a local-stop-file fallback if that's
unreachable. If home-lab-monitor is down AND you also manually started
`babysit-with-review.sh` on another host, you can get two babysitters running
against the same repo — the local fallback only protects the current host.

**Duplicate PRs are possible.** If `babysit-driver.sh`'s spawned
`babysit-with-review.sh` crashes mid-run, `team-dispatcher` will simply
re-spawn on the next 5-minute tick if work still looks open — the same
accepted-duplicate-PR trade-off `babysit-builder.sh` makes (see
`babysit-specs/L3-builder.md`).

**`gateway.py` patch is version-fragile.** `new-fleet.sh`'s
`HERMES_FLEET_ENV_INJECTION_PATCH` does a literal string match against two
anchors in Hermes's installed `gateway.py`. A Hermes upgrade that reformats
that function breaks the patch silently (it prints "anchors not found" and
exits 1, so it fails loud, not silently — but only if you're watching
`new-fleet.sh`'s own output during that run).

**Telegram bot tokens are per-agent (3 per fleet).** You can reuse one bot
token across all three agents in a fleet if you don't need per-agent identity
in Telegram, but messages will show the same sender. If you share a token
across fleets, Telegram will deliver all DMs to the last-registered webhook
(only one fleet will respond).

**`service-context.md` is not versioned by default.** The file lives in
`~/staff-fleet/<fleet>/` which is outside any git repo. If you want history,
either put the fleet dir under version control or keep the canonical copy
in the service's repo and symlink it.

---

## Appendix A: Glossary

**Hermes** — NousResearch's agent framework. Provides profiles, four-layer
memory, Telegram gateway, and cron scheduler. Each agent is a Hermes profile.

**profile** — A Hermes named configuration: SOUL.md, config.yaml, .env, and
memory state. Addressed with `hermes -p <name>`.

**HERMES_HOME** — The directory Hermes reads profiles and stores memory in.
Each fleet has its own (`~/staff-fleet/<fleet>/.hermes/`), set via env var.

**SOUL.md** — The role definition file Hermes prepends to every conversation.
Contains the agent's charter, responsibilities, communication style, and
boundaries.

**gateway** — The Hermes subsystem that connects a profile to a messaging
platform (Telegram). `hermes -p staff-swe gateway start` starts the listener.

**cron** — A scheduled prompt (or, with `--no-agent`, a scheduled script) in
`config.yaml`/created via `hermes cron create` that Hermes fires at a given
time.

**MCP** — Model Context Protocol. A standard for connecting agents to external
data sources (filesystems, GitHub, databases, monitoring tools). Our configs
include an MCP filesystem server; others can be added.

**`openai-codex`** — Hermes's native provider for ChatGPT/Codex-backed
inference (`https://chatgpt.com/backend-api/codex`), authenticated via
`hermes auth` (OAuth). Replaced the custom `claude-code-proxy.py` bridge on
2026-05-11 (`84364ea`). Model used here: `gpt-5.5`.

**`claude -p`** — Claude Code CLI in print mode. No longer used for staff-agent
inference (that's `openai-codex`/`gpt-5.5` now); still used, separately, by
`babysit-with-review.sh` for the autonomous-dev chain's actual code changes
(see [§3.6](#36-the-autonomous-dev-chain)).

**`team-orchestrator.py`** — No-agent daily cron (9:00 AM) on `staff-pm` that
parses `CONCERN:`/`HANDOFF:`/`WORK:` markers from each role's latest digest
and acts on them.

**`babysit-driver.sh`** — Spawns and monitors `babysit-with-review.sh`,
labelling and announcing any PR it opens.

**`team-dispatcher.sh`** — No-agent 5-minute cron on `staff-pm` that spawns
`babysit-driver.sh` when there's actionable GitHub work and no babysitter is
already running for this fleet (checked via home-lab-monitor's distributed
lock).

**`from-babysitter`** — Label `babysit-driver.sh` applies to any PR it detects
the babysitter opened, triggering `staff-pm`'s on-demand spec-review.

**auth.json** — `~/.hermes/auth.json`, the shared ChatGPT OAuth credential
file; `new-fleet.sh` symlinks it into every profile.

## Appendix B: Source References

All line numbers reference the current files in `~/repos/scripts/`.

### `new-fleet.sh`

| Lines | Content |
|---|---|
| 1–21 | Header comment — directory layout and prerequisites |
| 25–38 | Arg parsing (exactly 2 positional args) |
| 44–62 | Prerequisite checks (`gh`, `hermes`) and `hermes auth status openai-codex` pre-flight |
| 64–121 | `HERMES_FLEET_ENV_INJECTION_PATCH` — idempotent patch of Hermes's `gateway.py` |
| 123–199 | Directory structure + `service-context.md` template (only created if missing) |
| 207–255 | `write_soul_swe()` — staff-swe SOUL.md |
| 258–305 | `write_soul_sre()` — staff-sre SOUL.md |
| 308–355 | `write_soul_pm()` — staff-pm SOUL.md |
| 365–412 | `write_config()` — config.yaml generator (`provider: openai-codex`, `default: gpt-5.5`) |
| 414–464 | Cron schedule constants and digest/handoff prompt text (7:30 SRE, 8:00 SWE, 8:30 PM) |
| 477–517 | `.env` templates + cross-fleet auto-populate of shared values |
| 519–538 | Interactive Telegram bot-token prompting (falls back to a note if non-interactive) |
| 542–563 | Hermes profile creation and SOUL/config sync |
| 567–574 | `auth.json` symlink into each profile |
| 581–808 | `team-orchestrator.py` template — CONCERN/HANDOFF/WORK marker parsing |
| 812–823 | Orchestrator's `--script` wrapper (installed under `staff-pm/scripts/`) |
| 831–908 | `babysit-driver.sh` template |
| 916–974 | `team-dispatcher.sh` template — distributed lock + spawn logic |
| 979–984 | Dispatcher's `--script` wrapper |
| 986–1049 | `offline-dev` skill, deployed to all three profiles |
| 1051–1070 | PM `spec-review-prompt.txt` template |
| 1072–1108 | Bin wrapper generation (fleet-qualified + global, generic wrapper poisoning) |
| 1110–1267 | `start-gateways.sh` template — gateway install/start, 5-cron wiring, pre-flight checks |
| 1269–1330 | Final provisioning summary printed on completion |

### `claude-code-proxy.py`

Orphaned as of `84364ea` (2026-05-11) — no longer invoked by anything in this
repo. Left in place for reference; see `git show 84364ea` for exactly what
`new-fleet.sh` stopped doing with it.
