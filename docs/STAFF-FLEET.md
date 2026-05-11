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

Each agent runs inside **Hermes** (NousResearch's agent framework), uses its
own Telegram bot as a messaging gateway, maintains long-term memory about the
service, and fires a cron each morning. The inference comes from **Claude Code
CLI** (`claude -p`), reached via OAuth — no API key needed.

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
- **Independent restarts.** A crashed proxy for `meridian` doesn't affect
  `secondbrain`. Restart one; the other keeps running.
- **Clean shutdown.** Retiring a service means `rm -rf ~/staff-fleet/<name>`
  and deleting a launchd plist. Nothing else is affected.

---

## 2. Quick Start

Prerequisites: `claude` (Claude Code CLI, logged in), `gh` (GitHub CLI,
authenticated), `hermes` (Hermes Agent), `python3`.

### Step 1 — Scaffold the fleet

```bash
cd ~/repos/scripts
./new-fleet.sh <fleet-name> <path-to-repo>

# Examples:
./new-fleet.sh secondbrain ~/repos/secondbrain
./new-fleet.sh meridian    ~/repos/meridian
```

**What it does.** Creates `~/staff-fleet/<fleet-name>/`, writes three Hermes
profiles (staff-swe/sre/pm) with SOUL.md + config.yaml, registers a port in
`~/staff-fleet/.port-registry`, writes a launchd plist for the proxy, and
installs fleet-qualified wrappers in `~/.local/bin/`.

**Success looks like:**
```
fleet=secondbrain  repo=/Users/you/repos/secondbrain  port=9001
  created service-context.md — fill in the placeholders!
  wrote SOUL.md for staff-swe, staff-sre, staff-pm
  wrote config.yaml for staff-swe, staff-sre, staff-pm
  wrote .env templates (fill in TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS)
  created Hermes profile: staff-swe
  created Hermes profile: staff-sre
  created Hermes profile: staff-pm
  synced SOUL.md + config.yaml into .hermes/profiles/
  wrote bin wrappers: secondbrain-{swe,sre,pm} (fleet/bin/ and ~/.local/bin/)
  wrote launchd plist: ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist
  wrote start-gateways.sh
```

**Common failure:** `error: 'hermes' not found in PATH`
→ Install Hermes: `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash`

**Re-running is safe.** If you run `new-fleet.sh` again on an existing fleet,
config files are overwritten but Hermes memory and sessions are preserved
(`.hermes/` is never deleted).

### Step 2 — Fix `[REPO]` placeholders in the SOUL files

The SOUL.md templates include `--repo [REPO]` in `gh` command examples.
Replace with the actual `owner/repo` slug:

```bash
# Find your repo slugs:
cd ~/repos/secondbrain && gh repo view --json nameWithOwner -q .nameWithOwner
cd ~/repos/meridian    && gh repo view --json nameWithOwner -q .nameWithOwner

# Find all placeholders:
grep -r '\[REPO\]' ~/staff-fleet/secondbrain/profiles/

# Replace (example — use your actual slug):
sed -i '' 's/\[REPO\]/yourorg\/secondbrain/g' \
  ~/staff-fleet/secondbrain/profiles/staff-swe/SOUL.md \
  ~/staff-fleet/secondbrain/profiles/staff-sre/SOUL.md \
  ~/staff-fleet/secondbrain/profiles/staff-pm/SOUL.md

# Then sync back into Hermes profiles:
cp ~/staff-fleet/secondbrain/profiles/staff-swe/SOUL.md \
   ~/staff-fleet/secondbrain/.hermes/profiles/staff-swe/SOUL.md
# (repeat for sre and pm)
```

**Common failure:** Agents use `gh pr list` without `--repo`, which defaults
to the cwd and may give wrong results when the proxy is started from a
different directory.

### Step 3 — Fill in `service-context.md`

This is the most important step. The proxy injects this file into every
inference call. The better this file, the better every agent response.

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
4. Fill in the `.env` for each agent:

```bash
$EDITOR ~/staff-fleet/secondbrain/profiles/staff-swe/.env
# Set TELEGRAM_BOT_TOKEN=<token>
# Set TELEGRAM_ALLOWED_USERS=<your-user-id>
```

Repeat for sre and pm. The `.env` files are never committed to git.

**Using fewer bots.** If you don't need per-agent identity in Telegram, you
can reuse one bot token across all three agents in a fleet. They'll all appear
as the same Telegram contact, but messages will still be processed by the
correct Hermes profile since each runs its own gateway.

### Step 5 — Start everything

```bash
~/staff-fleet/secondbrain/start-gateways.sh
```

This loads the launchd proxy, waits 2 seconds, runs a health check, then
installs and starts all three Telegram gateways.

**Success looks like:**
```
proxy started on port 9001
{"status": "ok", "fleet": ".../secondbrain", "repo": ".../secondbrain"}
--- staff-swe gateway ---
[hermes gateway install output]
[hermes gateway start output]
...
All gateways started. Verify by DMing each bot:
  staff-swe, staff-sre, staff-pm
Ask each: 'What service do you own and what is your role?'
```

### Smoke test

Once the gateways are running, verify end-to-end:

```bash
# 1. Proxy health
curl -s http://127.0.0.1:9001/health | python3 -m json.tool
# Expected: {"status": "ok", "fleet": "...", "repo": "..."}

# 2. One-shot CLI round-trip (bypasses Telegram, hits claude -p directly)
secondbrain-swe chat -q "what tools do you have access to?"
# Expected: response mentioning gh, git, Read, Glob, Grep — not an error
```

If the CLI round-trip returns an error or empty output, check `proxy.log`
before continuing:
```bash
tail -50 ~/staff-fleet/secondbrain/proxy.log
```

---

## 3. Architecture

### 3.1 Request lifecycle

```
Telegram DM
    │
    ▼
Hermes Agent  (profile: staff-swe, HERMES_HOME: ~/staff-fleet/secondbrain/.hermes/)
    │  POST /v1/chat/completions  (OpenAI format)
    │  includes: messages[], tools[], system messages from SOUL.md
    ▼
claude-code-proxy  (127.0.0.1:9001, launchd-managed)
    │  reads service-context.md
    │  assembles --append-system-prompt
    │  runs: claude -p --model claude-sonnet-4-6 --append-system-prompt "..."
    │         --add-dir /path/to/repo --allowedTools "Bash(gh *) ..."
    ▼
claude -p subprocess
    │  stdin: conversation formatted as "Human: ... \n\nAssistant: ..."
    │  stdout: model response (text or <tool>{...}</tool> block)
    ▼
Claude API  (via OAuth, no API key)
    │
    ◀── response ──
    │
claude-code-proxy  parses response:
    │  if <tool> block → return OpenAI tool_calls response
    │  else → return content response
    ▼
Hermes Agent  executes tool call or returns final answer
    │
    ▼
Telegram message to you
```

**Arrow 1: Telegram → Hermes.** Hermes's Telegram gateway receives your DM,
adds it to the conversation history, and fires a `/v1/chat/completions` POST
with the full message thread plus tool definitions.

**Arrow 2: Hermes → proxy.** Standard OpenAI chat completions format. The
proxy is an HTTP server (Python `http.server`, ThreadingMixIn). It accepts
`POST /v1/chat/completions` and `GET /health`.

**Arrow 3: proxy → claude -p.** The proxy assembles a system prompt and
formats the conversation as `"Human: ...\n\nAssistant: ..."` text, then pipes
it to `claude -p` as stdin. This is how `claude -p` works in print mode:
takes a conversation on stdin, returns a response on stdout.

**Arrow 4: claude -p → Claude API.** `claude` uses your OAuth session
(established via `claude auth login`). No raw API key is ever in the proxy or
fleet config.

**Arrow 5: proxy parses and wraps.** If the model's response contains a
`<tool>{...}</tool>` block, the proxy returns an OpenAI `tool_calls` response.
Otherwise it returns a plain `content` response. Hermes then either executes
the tool and sends a follow-up request, or delivers the answer to Telegram.

### 3.2 Why a proxy at all

Three constraints collide:

| Constraint | Source |
|---|---|
| Hermes requires an OpenAI-compatible HTTP endpoint | Hermes's `provider: custom` uses OpenAI client |
| `claude -p` is a subprocess, not an HTTP server | Claude Code has no server mode |
| You want OAuth auth (no raw API key) | Claude Code's `claude auth login` |

`claude-code-proxy.py` is the minimal thing that satisfies all three: an HTTP
server that accepts OpenAI requests and translates them into `claude -p`
subprocess calls.

### 3.3 The three-layer system prompt

When the proxy handles a request, it assembles `--append-system-prompt` from
up to four sources (in order of appending):

```
[Layer 0] Claude Code's built-in default system prompt
           (provides tool knowledge, injected automatically by claude -p)
           ↓
[Layer 1] Hermes-supplied system messages from your conversation
           (SOUL.md role definition, personality, etc.)
           ↓
[Layer 2] service-context.md content
           (live per-fleet facts: stack, stakeholders, priorities, risks)
           ↓
[Layer 3] Tool definitions + protocol  (only if Hermes sent tools in the request)
           AVAILABLE TOOLS:
           - list_prs: ... args=[query]
           ...
           TOOL CALLING PROTOCOL
           When you need to call a tool output exactly this:
           <tool>{"name":"TOOL_NAME","args":ARGS_JSON}</tool>
```

Layer 0 is why `--append-system-prompt` is used instead of `--system-prompt`.
The latter *replaces* Claude's default, which destroys tool knowledge. The
former *adds to* it. This distinction bit us during development — see
`claude-code-proxy.py:93-96` for the comment.

### 3.4 Why fleet isolation

| Concern | Mechanism |
|---|---|
| Memory bleed between services | Separate `HERMES_HOME` per fleet (`~/staff-fleet/<name>/.hermes/`) |
| Cron collisions between fleets | Separate launchd job (proxy) + Hermes scheduler per fleet |
| Port conflicts | Per-fleet port from `~/staff-fleet/.port-registry` (starts at 9001) |
| Profile name conflicts across fleets | Fleet-qualified bin wrappers (`secondbrain-swe`, not `staff-swe`) |

The port registry is a simple JSON file:
```json
{
  "secondbrain": 9001,
  "meridian": 9002
}
```

### 3.5 Tool-call protocol

When Hermes sends tool definitions in a chat completions request, the proxy
injects the tool specs and a protocol instruction into the system prompt. The
model is told to emit:

```
<tool>{"name":"TOOL_NAME","args":{"arg1":"val1"}}</tool>
```

The proxy parses this with a regex (`re.search(r"<tool>(.*?)</tool>", ...)`),
extracts the JSON, and wraps it in OpenAI `tool_calls` format:

```json
{
  "role": "assistant",
  "content": null,
  "tool_calls": [{
    "id": "call_a1b2c3d4",
    "type": "function",
    "function": {
      "name": "list_prs",
      "arguments": "{\"query\": \"is:open\"}"
    }
  }]
}
```

Hermes receives this, executes the tool, and sends the result back as a
`tool` role message. This is a single-shot pattern: the model generates one
tool call per turn. Nested tool loops (tool A calls tool B) are not supported.

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

**Tools available:**

| Tool | What the agent uses it for |
|---|---|
| `Bash(gh *)` | `gh pr list`, `gh pr view`, `gh pr diff`, `gh run list` |
| `Bash(git *)` | `git log`, `git diff`, `git show` for local diff inspection |
| `Read` | Read source files when reviewing a specific change |
| `Glob` / `Grep` | Find files, search for symbols, check test coverage patterns |

**Example interactive transcript** *(illustrative)*:

```
you: any risky PRs merged in the last 24h?

staff-swe: Three merged. One worth flagging: PR #482 (auth-token-storage-
           refactor). It removes salt rotation that was added post-Q3-audit.
           No test covers the regression path.
           PRs #480 and #481 are routine — test additions and a readme fix.

you: can you check if there's any test for the token encryption path?

staff-swe: [runs Grep for test files touching auth/token]
           Found 2 test files: tests/auth/test_session.py and
           tests/auth/test_login.py. Neither tests the encryption path that
           #482 modifies. test_session.py has a TODO comment: "add encryption
           regression after #412." #412 merged 3 months ago.

you: draft a comment on PR #482 flagging this?

staff-swe: I don't have write access to post comments (--allowedTools
           restricts me to read-only gh). I can draft the text and you
           can paste it:

           "This removes the salt-rotation logic added in #387 (post-Q3
           audit). tests/auth/test_session.py has a TODO for an encryption
           regression test that was never written. Recommend adding before
           this merges. cc @alice"
```

**Hand-offs:**
- Roadmap / ticket priority questions → staff-pm ("Is feature X scheduled?" — defer)
- Production incident diagnosis → staff-sre ("Why did the deploy fail?" — defer)
- Anything requiring human sign-off → surface and stop, do not act

**Source:** `new-fleet.sh:203-252` (`write_soul_swe`)

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

**Source:** `new-fleet.sh:254-300` (`write_soul_sre`)

### 4.3 staff-pm — Staff Product Manager

**Charter.** Owns the product roadmap, issue tracking, and stakeholder
coordination. Summarises ticket changes, flags items needing human decisions,
and maintains awareness of what the team is building and why. Does not own
code architecture (staff-swe) or operational health (staff-sre).

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

**Source:** `new-fleet.sh:303-350` (`write_soul_pm`)

---

## 5. Daily Operation

### 5.1 A normal morning

The SRE fires first (7:30 AM) so operations context is already in your
Telegram before the SWE code-review lands (8:00 AM) and the PM product
summary rounds out the picture (8:30 AM).

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

### 5.3 Where logs land

| Log | Location | What's in it |
|---|---|---|
| Proxy stdout/stderr | `~/staff-fleet/<fleet>/proxy.log` | HTTP request lines, `claude -p` stderr, crashes |
| Hermes session | `~/staff-fleet/<fleet>/.hermes/sessions/` | Full conversation turns for each session |
| Hermes cron | `~/staff-fleet/<fleet>/.hermes/cron/` | Cron execution records |

To watch the proxy live during a test:
```bash
tail -f ~/staff-fleet/secondbrain/proxy.log
```

### 5.4 Silent failure modes

The most dangerous failure is one you don't notice. Signs that an agent
stopped working without alerting you:

- **No Telegram digest by 9 AM** — cron fired but produced empty output
  (empty model response), or the gateway died overnight
- **"ok" health check but empty responses** — the proxy is up but `claude -p`
  is returning empty or timing out; check `proxy.log` for 180s timeout lines
- **Telegram bot shows "offline"** — the Hermes gateway process died;
  run `<fleet>-<role> gateway status` and restart if needed

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
HERMES_HOME=~/staff-fleet/secondbrain/.hermes \
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

### 6.5 Tool calls visible to the user

In rare cases (usually when there's a system prompt assembly issue) you might
see raw `<tool>{...}</tool>` blocks in the agent's Telegram messages or CLI
output. This means the proxy failed to parse the tool call and returned it
as plain text. Check `proxy.log` for JSON parse errors or `claude -p`
invocation failures.

---

## 7. Fleet Management

### Add a new fleet

```bash
./new-fleet.sh <name> <path-to-repo>
# Optional: specify port explicitly
./new-fleet.sh <name> <path-to-repo> --port 9005
```

Ports are auto-allocated sequentially from 9001. The registry is at
`~/staff-fleet/.port-registry`.

### Re-run on an existing fleet (update config)

Re-running `new-fleet.sh` on an existing fleet is safe and idempotent:

| What happens | Notes |
|---|---|
| SOUL.md overwritten | Intentional — SOUL is generated from the script |
| config.yaml overwritten | Intentional — cron schedule, model, MCP |
| service-context.md preserved | Only created if missing |
| .env preserved | Never overwritten — your tokens are safe |
| .hermes/ preserved | Memory and sessions untouched |

After re-running, sync config back into live profiles:
```bash
# Already done automatically by new-fleet.sh, but if you edit manually:
cp ~/staff-fleet/secondbrain/profiles/staff-swe/config.yaml \
   ~/staff-fleet/secondbrain/.hermes/profiles/staff-swe/config.yaml
```

### Stop / start the proxy

```bash
# Stop:
launchctl unload ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist

# Start:
launchctl load -w ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist

# Check if running:
launchctl list | grep staff-fleet
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

### Remove a fleet entirely

```bash
# 1. Unload launchd
launchctl unload ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist
rm ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist

# 2. Remove runtime data
rm -rf ~/staff-fleet/secondbrain

# 3. Remove bin wrappers
rm ~/.local/bin/secondbrain-swe ~/.local/bin/secondbrain-sre ~/.local/bin/secondbrain-pm

# 4. Remove port-registry entry
python3 -c "
import json
path = '$HOME/staff-fleet/.port-registry'
r = json.load(open(path))
del r['secondbrain']
json.dump(r, open(path, 'w'), indent=2)
"
```

### List all fleets and ports

```bash
cat ~/staff-fleet/.port-registry
# {"secondbrain": 9001, "meridian": 9002}
```

### Migrate a fleet to a new port

```bash
# 1. Update port registry
python3 -c "
import json
path = '$HOME/staff-fleet/.port-registry'
r = json.load(open(path))
r['secondbrain'] = 9010
json.dump(r, open(path, 'w'), indent=2)
"

# 2. Re-run new-fleet.sh with explicit port (overwrites plist and config.yaml)
./new-fleet.sh secondbrain ~/repos/secondbrain --port 9010

# 3. Reload launchd and restart gateways
launchctl unload ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist
launchctl load -w ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist
~/staff-fleet/secondbrain/start-gateways.sh
```

---

## 8. Tuning

### 8.1 service-context.md

This file is injected into every inference call. It's the primary lever for
improving agent responses. Edit it at least weekly; after major incidents,
launches, or stakeholder changes.

**Section-by-section guide:**

| Section | What to put there | How agents use it |
|---|---|---|
| Service | Name, repo URL, stack, deploy target | Grounds all `gh` commands in the right repo and gives context for "what is this?" questions |
| Architecture | 1–2 paragraph summary | SWE uses this when reviewing PRs for architectural fit; PM uses it when fielding "is this feasible?" questions |
| Human Stakeholders | Who to involve and when | Agents cite these in recommendations ("ask @alice before merging auth changes") |
| Current Quarter Priorities | Top 3 priorities | PM uses this to triage blockers; SWE uses it to flag when a risky PR conflicts with priorities |
| Recent History | Last 30 days of significant events | Prevents agents from being surprised by things that just happened |
| Current Concerns / Risks | Known risks | SWE and SRE proactively watch for these in their digests |
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

### 8.4 `_ALLOWED_TOOLS` — the proxy allowlist

Defined at `claude-code-proxy.py:42`:
```python
_ALLOWED_TOOLS = "Bash(gh *) Bash(git *) Bash(date *) Bash(echo *) Read Glob Grep"
```

This is the `--allowedTools` flag passed to every `claude -p` invocation.
Only commands matching these patterns can be executed.

**Adding a tool:**
```python
_ALLOWED_TOOLS = "Bash(gh *) Bash(git *) Bash(date *) Bash(echo *) Read Glob Grep Bash(curl *)"
```

**Security trade-offs:**

| Addition | Risk |
|---|---|
| `Bash(curl *)` | Agent can make outbound HTTP requests; prompt injection via external URLs is possible |
| `Edit` / `Write` | Agent can modify files in `--add-dir`; only add if you explicitly want write capability |
| `Bash(rm *)` | Obvious; don't add without very specific scoping |
| `Bash(npm *)` | Can install packages; potential supply-chain risk |

Default is intentionally minimal: agents read GitHub and the repo, nothing more.

---

## 9. Troubleshooting

### Proxy not responding

**Symptom:** `curl http://127.0.0.1:9001/health` hangs or returns `Connection refused`

**Diagnosis:**
```bash
launchctl list | grep staff-fleet.secondbrain
# If missing → not loaded
# If PID="-" → crashed

tail -50 ~/staff-fleet/secondbrain/proxy.log
```

**Fixes:**
- Not loaded: `launchctl load -w ~/Library/LaunchAgents/com.staff-fleet.secondbrain.proxy.plist`
- Crashed with `python3: No such file or directory` → the plist uses `/usr/bin/python3`; ensure it exists (`which python3`)
- Port already in use: pick a new port with `--port N` and re-run `new-fleet.sh`

### "claude: command not found" from launchd

**Symptom:** `proxy.log` contains `FileNotFoundError: [Errno 2] claude` or similar

**Cause:** launchd runs with a minimal `PATH` that doesn't include where `claude` is installed (`~/.local/bin` or `/usr/local/bin`).

**Fix:** Add a `PATH` env var to the plist. Edit the generated plist and add:
```xml
<key>EnvironmentVariables</key>
<dict>
  <key>PATH</key>
  <string>/usr/local/bin:/usr/bin:/bin:/Users/chrisrobertson/.local/bin</string>
</dict>
```
Then reload: `launchctl unload ... && launchctl load -w ...`

### Agent claims it has no tools / ignores `gh` output

**Symptom:** `staff-swe` says "I don't have access to GitHub tools" or ignores tool results

**Cause 1:** `--allowedTools` not passed → check `claude-code-proxy.py:87-92` ensures `_ALLOWED_TOOLS` is in the cmd.

**Cause 2:** `--system-prompt` was used instead of `--append-system-prompt` (replaces Claude's default, destroying tool knowledge). The current proxy uses `--append-system-prompt`; if you've modified it, revert.

**Cause 3:** The `<tool>{...}</tool>` block is not being emitted by the model. Add a debug `print(response, file=sys.stderr)` after line 101 of the proxy to see what claude -p is returning.

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
HERMES_HOME=~/staff-fleet/secondbrain/.hermes hermes -p staff-swe cron list
# Check the next-fire time; verify timezone in config.yaml
```

**Common causes:**
- Hermes gateway not running (cron requires the gateway process)
- Timezone mismatch: `config.yaml` has `timezone: America/Los_Angeles` but you expected UTC
- Cron block commented out during a previous tuning session

### Port collision on new fleet

**Symptom:** proxy.log shows `OSError: [Errno 48] Address already in use`

**Diagnosis:**
```bash
cat ~/staff-fleet/.port-registry
lsof -i :9001  # check what's using the port
```

**Fix:** Re-run with explicit port: `./new-fleet.sh <name> <repo> --port 9005`

### Model returns empty or hits 180s timeout

**Symptom:** Agent gives no response; proxy.log shows `RuntimeError: claude -p exited 1` or a timeout

**Cause 1:** The prompt is too long (conversation history + service-context.md + SOUL). Reduce context: enable Hermes compression (`compression.enabled: true` in config.yaml) or shorten service-context.md.

**Cause 2:** The `claude -p` subprocess timed out. 180s is the hard limit (proxy.py:98). Long PR reviews with many tool calls can exceed this. Lower `max_turns` in config.yaml or split the query.

**Cause 3:** Claude API rate limit or auth issue. Check: `claude -p --model claude-sonnet-4-6 < /dev/null` — if this errors, it's an auth or quota problem, not the proxy.

### service-context.md not picked up

**Symptom:** Agent doesn't seem to know anything about the service

**Diagnosis:**
```bash
# Verify the proxy is reading from the right location
curl -s http://127.0.0.1:9001/health
# "fleet" field should be ~/staff-fleet/secondbrain, not some other path

# Verify the file exists at that path
ls ~/staff-fleet/secondbrain/service-context.md
```

The proxy reads `FLEET_DIR/service-context.md` where `FLEET_DIR` is argv[2].
If the plist was generated with the wrong path, re-run `new-fleet.sh` and
reload launchd.

---

## 10. File Layout Reference

### Runtime artifacts (`~/staff-fleet/`)

```
~/staff-fleet/
├── .port-registry                    ← JSON: fleet-name → port
│
├── secondbrain/
│   ├── service-context.md            ← injected into every inference; edit weekly
│   ├── proxy.log                     ← stdout+stderr from claude-code-proxy
│   ├── start-gateways.sh             ← one-time setup; safe to re-run
│   │
│   ├── profiles/                     ← canonical (human-editable) copies
│   │   ├── staff-swe/
│   │   │   ├── SOUL.md               ← role definition
│   │   │   ├── config.yaml           ← cron, model, MCP, max_turns
│   │   │   └── .env                  ← TELEGRAM_BOT_TOKEN (never commit)
│   │   ├── staff-sre/
│   │   │   └── (same shape)
│   │   └── staff-pm/
│   │       └── (same shape)
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
│       │   │   └── .env
│       │   ├── staff-sre/
│       │   └── staff-pm/
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
├── claude-code-proxy.py              ← the HTTP proxy; manages its own process
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

**PM and SRE are read-only by default.** staff-swe can comment on PRs (if
explicitly granted in `service-context.md` Write Capabilities). PM can draft
issue comments. SRE has no write capability until explicitly granted. This is
intentional; write access for AI agents should be incremental and deliberate.

**Tool-call parsing is single-shot per turn.** The proxy parses one
`<tool>{...}</tool>` block per model response. Hermes handles the multi-turn
loop (tool → result → next tool), but each individual `claude -p` invocation
produces at most one tool call. If the model tries to emit multiple tool calls
in one response (a pattern some OpenAI models support), only the first is
parsed.

**180-second subprocess timeout.** Each `claude -p` call has a hard 3-minute
timeout (proxy.py line 98). A deeply-branching cron that needs many tool calls
(e.g., review 20 PRs with diffs) may hit this. Mitigation: lower `max_turns`,
narrow the cron prompt, or raise the timeout constant.

**No streaming.** The proxy buffers the full `claude -p` response before
returning it to Hermes. Long responses (big PR reviews) are delivered all at
once. There's no token-by-token streaming to Telegram.

**Cost: 3 cron invocations per fleet per day.** Each invocation calls
`claude -p` once, plus once per tool call. A typical morning digest might
involve 3–6 total `claude -p` calls per agent. At Claude Sonnet pricing this
is cheap; at scale (many fleets) it adds up.

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

**cron** — A scheduled prompt in `config.yaml` that Hermes fires at a given
time. Each agent has one daily cron that produces the morning digest.

**MCP** — Model Context Protocol. A standard for connecting agents to external
data sources (filesystems, GitHub, databases, monitoring tools). Our configs
include an MCP filesystem server; others can be added.

**launchd** — macOS's init system. Used to keep the claude-code-proxy running
as a background service, automatically restarted on crash.

**claude -p** — Claude Code CLI in print mode. Takes a conversation on stdin,
returns the model's response on stdout. Uses OAuth; no API key.

**--append-system-prompt** — Claude Code flag that adds text to Claude's
default system prompt without replacing it. Critical: `--system-prompt`
replaces the default (destroying tool knowledge); `--append-system-prompt`
augments it.

**--allowedTools** — Claude Code flag restricting which tools the model can
invoke. E.g. `Bash(gh *)` allows only `bash` commands starting with `gh`.

**.port-registry** — A JSON file at `~/staff-fleet/.port-registry` mapping
fleet names to proxy ports. Used by `new-fleet.sh` to allocate non-colliding
ports.

---

## Appendix B: Source References

All line numbers reference the current files in `~/repos/scripts/`.

### `claude-code-proxy.py`

| Lines | Content |
|---|---|
| 1–20 | Module docstring, usage, and imports |
| 32–38 | CLI arg parsing (PORT, FLEET_DIR, REPO_PATH) |
| 42 | `_ALLOWED_TOOLS` constant — the tool allowlist |
| 44–49 | `_TOOL_PROTOCOL` — the tool-call format instruction injected into system prompt |
| 52–54 | `_service_context()` — reads `service-context.md` on every request |
| 57–64 | `_tool_defs_text()` — formats Hermes tool definitions as plain text |
| 67–83 | `_format_conversation()` — converts OpenAI messages to "Human: / Assistant:" text |
| 86–101 | `_call_claude()` — subprocess invocation of `claude -p` with all flags |
| 104–111 | `_parse_tool_call()` — regex parse of `<tool>{...}</tool>` |
| 114–160 | `_completions()` — main request handler: assembles prompt, calls claude, formats response |
| 163–164 | `_ThreadingHTTPServer` — ThreadingMixIn for concurrent request handling |

### `new-fleet.sh`

| Lines | Content |
|---|---|
| 7–17 | Header comment — directory layout and prerequisites |
| 32–49 | Arg parsing and path setup |
| 53–69 | Prerequisite checks (claude, gh, hermes, python3, proxy file) |
| 75–119 | Port allocation from `.port-registry` |
| 124–129 | Directory structure creation |
| 131–199 | `service-context.md` template (only created if missing) |
| 203–252 | `write_soul_swe()` — staff-swe SOUL.md |
| 254–300 | `write_soul_sre()` — staff-sre SOUL.md |
| 303–350 | `write_soul_pm()` — staff-pm SOUL.md |
| 360–403 | `write_config()` — config.yaml generator |
| 421–423 | Cron schedule constants (7:30 SRE, 8:00 SWE, 8:30 PM) |
| 429–442 | `.env` templates |
| 447–468 | Hermes profile creation and config sync |
| 478–505 | Bin wrapper generation (fleet-qualified + global, generic wrapper poisoning) |
| 510–542 | launchd plist generation |
| 546–583 | `start-gateways.sh` template |
| 585–619 | Next-steps summary printed on completion |
