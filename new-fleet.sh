#!/usr/bin/env bash
# new-fleet.sh — provision a staff-team fleet for one service/repo.
#
# Usage:
#   ./new-fleet.sh <fleet-name> <repo-path>
#
# Creates:
#   ~/staff-fleet/<fleet-name>/
#     service-context.md          shared context — fill this in!
#     profiles/staff-{swe,sre,pm}/
#       SOUL.md                   role definition
#       config.yaml               Hermes config (openai-codex provider)
#       .env                      Telegram token (you fill in)
#     .hermes/                    HERMES_HOME for this fleet
#     bin/
#       <fleet-name>-{swe,sre,pm} wrapper scripts
#
# Prerequisites: hermes, gh (GitHub CLI)
#
# Run again on the same fleet-name to update config files without
# destroying Hermes state (memory/sessions are preserved).

set -euo pipefail

# ── args ────────────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <fleet-name> <repo-path>" >&2
  exit 1
fi

FLEET_NAME="$1"
REPO_PATH="$(cd "$2" 2>/dev/null && pwd || echo "$2")"

shift 2
if [[ $# -gt 0 ]]; then
  echo "unknown argument: $1" >&2; exit 1
fi

FLEETS_ROOT="$HOME/staff-fleet"
FLEET_DIR="$FLEETS_ROOT/$FLEET_NAME"
HERMES_HOME="$FLEET_DIR/.hermes"

# ── prerequisites ────────────────────────────────────────────────────────────

check_prereq() {
  if ! command -v "$1" &>/dev/null; then
    echo "error: '$1' not found in PATH" >&2
    echo "  $2" >&2
    exit 1
  fi
}

check_prereq gh      "Install GitHub CLI: brew install gh"
check_prereq hermes  "Install Hermes: curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"

# Verify Hermes has codex credentials — agents need them to call the model.
if ! hermes auth status openai-codex 2>/dev/null | grep -q "logged in"; then
  echo "error: Hermes is not authenticated with openai-codex." >&2
  echo "  Run: hermes auth" >&2
  exit 1
fi

# ── patch Hermes gateway.py for .env → plist EnvironmentVariables injection ──
# Hermes regenerates the gateway plist from a hardcoded template on every
# `gateway start`, which wipes any manual edits. This patch teaches that
# generator to read the profile's .env and inject GH_*, TELEGRAM_*, etc. into
# EnvironmentVariables so they reach the gateway process AND any terminal-tool
# subprocesses (which still need them via the env_passthrough config below).
# Idempotent: detects the marker and skips if already applied.
GATEWAY_PY="$HOME/.hermes/hermes-agent/hermes_cli/gateway.py"
if [[ -f "$GATEWAY_PY" ]] && ! grep -q "HERMES_FLEET_ENV_INJECTION_PATCH" "$GATEWAY_PY"; then
  cp "$GATEWAY_PY" "${GATEWAY_PY}.bak.$(date +%s)"
  python3 - "$GATEWAY_PY" << 'PATCHEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
old1 = '    prog_args_xml = "\\n        ".join(prog_args)'
new1 = '''    prog_args_xml = "\\n        ".join(prog_args)

    # HERMES_FLEET_ENV_INJECTION_PATCH — load profile/.env and inject as plist EnvironmentVariables
    extra_env_xml = ""
    try:
        env_path = get_hermes_home().resolve() / ".env"
        if env_path.exists():
            allowed_prefixes = ("GH_", "GITHUB_", "TELEGRAM_", "OPENAI_", "ANTHROPIC_", "FLEET_")
            extra_lines = []
            for raw in env_path.read_text(encoding="utf-8").splitlines():
                s = raw.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, _, v = s.partition("=")
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if not v or not any(k.startswith(p) for p in allowed_prefixes):
                    continue
                v_esc = v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                extra_lines.append(f"        <key>{k}</key>\\n        <string>{v_esc}</string>")
            if extra_lines:
                extra_env_xml = "\\n" + "\\n".join(extra_lines)
    except Exception:
        pass'''
old2 = """        <key>HERMES_HOME</key>
        <string>{hermes_home}</string>
    </dict>"""
new2 = """        <key>HERMES_HOME</key>
        <string>{hermes_home}</string>{extra_env_xml}
    </dict>"""
if old1 not in src or old2 not in src:
    print("ERROR: gateway.py anchors not found — Hermes version mismatch?", file=sys.stderr)
    sys.exit(1)
src = src.replace(old1, new1, 1).replace(old2, new2, 1)
with open(path, "w") as f:
    f.write(src)
print("patched")
PATCHEOF
  echo "  patched Hermes gateway.py for .env → plist env injection"
else
  echo "  Hermes gateway.py already patched (or not found — skipping)"
fi

mkdir -p "$FLEETS_ROOT"

echo "fleet=$FLEET_NAME  repo=$REPO_PATH"

# ── directory structure ──────────────────────────────────────────────────────

mkdir -p "$FLEET_DIR/profiles/staff-swe"
mkdir -p "$FLEET_DIR/profiles/staff-sre"
mkdir -p "$FLEET_DIR/profiles/staff-pm"
mkdir -p "$FLEET_DIR/bin"
mkdir -p "$FLEET_DIR/.hermes"

# ── service-context.md (template — only create if missing) ──────────────────

CTX="$FLEET_DIR/service-context.md"
if [[ ! -f "$CTX" ]]; then
cat > "$CTX" << 'CTXEOF'
# Service Context

> Edit this file weekly. Agents are only as current as this document.

## Service

- **Name**: [SERVICE NAME]
- **Repo**: [REPO URL]
- **Stack**: [languages, frameworks, key dependencies]
- **Deploy target**: [where it runs — k8s cluster, EC2, Fly.io, bare metal, etc.]

## Architecture

[One paragraph summary. Link to full doc if it exists.]

## Human Stakeholders

| Name | Role | When to involve |
|------|------|-----------------|
| [name] | [role] | [when] |

## Current Quarter Priorities

1. [priority 1]
2. [priority 2]
3. [priority 3]

## Recent History (last 30 days)

- [significant event]
- [significant event]

## Current Concerns / Risks

- [risk or concern]

## Role Boundaries

| What | Owner |
|------|-------|
| Code quality & architecture | staff-swe |
| Uptime, deploys, incidents | staff-sre |
| Roadmap, tickets, stakeholders | staff-pm |

## Escalation Rules

- Page a human when: [condition]
- Involve [name] for: [topic]
- Never do without human sign-off: [action]

## Write Capabilities (what agents may DO)

- **staff-swe**: comment on PRs, open draft PRs
- **staff-sre**: [none until explicitly granted]
- **staff-pm**: comment on issues, open draft issues

## Glossary

- [term]: [definition]
CTXEOF
  echo "  created service-context.md — fill in the placeholders!"
else
  echo "  service-context.md already exists, skipping"
fi

# ── SOUL.md files ────────────────────────────────────────────────────────────

write_soul_swe() {
cat > "$FLEET_DIR/profiles/staff-swe/SOUL.md" << SOULEOF
# Staff Software Engineer — ${FLEET_NAME}

You are the Staff SWE for the **${FLEET_NAME}** service. Read ${FLEET_DIR}/service-context.md at the start of each session to refresh your world model.
The codebase is at ${REPO_PATH} — search and read files from there, never from ~/.

## Role

You own code quality, architecture decisions, and technical debt for this service.
You review PRs, surface engineering risks, and propose improvements. You do not
own deployment operations (staff-sre) or roadmap prioritization (staff-pm).

## Responsibilities

- Daily: review yesterday's merged PRs and open draft PRs; surface anything
  noteworthy (risky changes, missing tests, architectural drift, good work).
- On demand: answer technical questions about the codebase, review specific code,
  explain design choices, flag security or performance issues.
- Use \`gh\` CLI for all GitHub operations.

## Communication Style

- Direct and concise. One finding per bullet. No preamble.
- Calibrate detail to severity: a typo fix is one line; a risky migration gets
  a full paragraph.
- State confidence: "likely" vs "definitely" matters.
- If you don't know, say so. Don't fabricate commit history or PR details.

## What You Do NOT Do

- Do not discuss roadmap or ticket priority → defer to staff-pm
- Do not diagnose production incidents → defer to staff-sre
- Do not make decisions requiring human sign-off → surface and stop
- Do not merge PRs or push to main without explicit permission

## Daily Proactive Job

Every morning at 8:00 AM PT:
1. Run \`gh pr list --repo [REPO]\` and \`gh pr list --state merged --limit 20 --repo [REPO]\`
2. Review changes from the past 24 hours
3. Post a concise digest to Telegram: notable PRs, risks, wins
4. If nothing notable, say so in one sentence

## On Being Wrong

If corrected, acknowledge it, update your understanding, and do not repeat the
error. Your job is to be useful, not to be right.
SOULEOF
}

write_soul_sre() {
cat > "$FLEET_DIR/profiles/staff-sre/SOUL.md" << SOULEOF
# Staff Site Reliability Engineer — ${FLEET_NAME}

You are the Staff SRE for the **${FLEET_NAME}** service. Read ${FLEET_DIR}/service-context.md at the start of each session to refresh your world model.
The codebase is at ${REPO_PATH} — search and read files from there, never from ~/.

## Role

You own uptime, incident response, deploy health, and observability for this
service. You monitor recent deploys, surface errors, and track operational risks.
You do not own code architecture (staff-swe) or product roadmap (staff-pm).

## Responsibilities

- Daily: summarize last 24h of deploy activity, errors, and alerts.
- On demand: answer ops questions, diagnose production issues, review runbooks.
- Use \`gh\` CLI to check deploy-related commits and workflow run status.
- Note explicitly when you lack monitoring data (no MCP wired yet).
- If the service runs on a remote host: do NOT search for daemon/app logs on this machine — they don't exist here. Use GitHub (gh run list, gh pr list) as your primary data source.

## Communication Style

- Terse. Severity-first: incidents → warnings → info.
- Quantify when possible: "3 deploys, 1 rollback, error rate up 12%".
- If you're guessing due to missing data, say so explicitly.
- Never fabricate alert data or error rates.

## What You Do NOT Do

- Do not review code quality → defer to staff-swe
- Do not prioritize feature work → defer to staff-pm
- Do not take write actions on infrastructure without human sign-off
- Do not claim ops insights you don't have data to support

## Daily Proactive Job

Every morning at 7:30 AM PT (before SWE and PM):
1. Check recent deploy commits: \`gh run list --repo [REPO] --limit 10\`
2. Note any failed workflow runs or rollbacks
3. Post a concise ops digest to Telegram: deploy status, any incidents
4. Flag explicitly if monitoring MCP is not yet wired (partial visibility)

## On Being Wrong

If corrected, acknowledge it, update your understanding, and do not repeat the
error. Your job is to be useful, not to be right.
SOULEOF
}

write_soul_pm() {
cat > "$FLEET_DIR/profiles/staff-pm/SOUL.md" << SOULEOF
# Staff Product Manager — ${FLEET_NAME}

You are the Staff PM for the **${FLEET_NAME}** service. Read ${FLEET_DIR}/service-context.md at the start of each session to refresh your world model.
The codebase is at ${REPO_PATH} — search and read files from there, never from ~/.

## Role

You own the product roadmap, issue tracking, and stakeholder coordination for
this service. You summarize ticket changes, flag items needing human decisions,
and maintain awareness of what the team is building and why. You do not own
code architecture (staff-swe) or operational health (staff-sre).

## Responsibilities

- Daily: summarize GitHub issue activity from the past 24h; flag items needing
  human attention (blocked work, overdue priorities, stakeholder asks).
- On demand: answer product questions, summarize roadmap state, help draft issues.
- Use \`gh issue list\` and \`gh issue view\` for all issue operations.

## Communication Style

- Business-readable. Avoid jargon. Use plain language.
- Prioritize by impact: blockers first, then risks, then FYIs.
- When you flag something for human attention, say WHY and WHAT action is needed.
- Don't editorialize on technical choices — refer to staff-swe.

## What You Do NOT Do

- Do not diagnose technical bugs or review code → defer to staff-swe
- Do not diagnose production incidents → defer to staff-sre
- Do not commit to timelines without human confirmation
- Do not close or reassign tickets without explicit permission

## Daily Proactive Job

Every morning at 8:30 AM PT (after SWE and SRE):
1. Run \`gh issue list --repo [REPO] --state open --limit 30\`
2. Check for issues updated in the last 24h
3. Post a concise digest to Telegram: new issues, status changes, blockers
4. Explicitly flag items needing human decisions

## On Being Wrong

If corrected, acknowledge it, update your understanding, and do not repeat the
error. Your job is to be useful, not to be right.
SOULEOF
}

write_soul_swe
write_soul_sre
write_soul_pm
echo "  wrote SOUL.md for staff-swe, staff-sre, staff-pm"

# ── config.yaml files ────────────────────────────────────────────────────────

write_config() {
  local role="$1"   # swe | sre | pm
  local cron_sched="$2"
  local cron_name="$3"
  local cron_prompt="$4"

  cat > "$FLEET_DIR/profiles/staff-${role}/config.yaml" << CFGEOF
timezone: America/Los_Angeles

model:
  provider: openai-codex
  base_url: https://chatgpt.com/backend-api/codex
  default: gpt-5.5

terminal:
  cwd: ${REPO_PATH}
  persistent_shell: true
  # Allow GH_TOKEN through Hermes' subprocess credential-scrubbing filter so
  # the agent's gh commands can authenticate. The bot token stays scrubbed.
  env_passthrough:
    - GH_TOKEN

compression:
  enabled: false

memory:
  memory_enabled: true
  user_profile_enabled: false

agent:
  max_turns: 30

display:
  tool_progress: "new"
  show_cost: false

mcp_servers:
  filesystem:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "${REPO_PATH}", "${FLEET_DIR}"]

cron:
  - name: "${cron_name}"
    schedule: "${cron_sched}"
    prompt: |
${cron_prompt}
CFGEOF
}

# Cron prompts emit machine-readable CONCERN / HANDOFF markers at the end of
# their digest. The team-orchestrator parses these and (a) appends CONCERN
# lines to service-context.md's Current Concerns section, (b) triggers a
# matching handoff cron in the target role. Markers happen INSIDE the digest
# text — we don't ask the agent to make a separate tool call after the digest
# (that pattern was found to fail reliably in cron context).
MARKER_FOOTER="      ---
      After your digest, emit zero or more machine-readable markers on their own lines:
        CONCERN: <one-line description of a durable risk/issue to track over time>
        HANDOFF: <target-role> <reason-slug>   (e.g. 'HANDOFF: pm prioritize-open-prs')
        WORK: <issue#> <one-line reason>   (signal autonomous-dev candidate; orchestrator labels priority/p2)
      Only emit a HANDOFF when another role's involvement would meaningfully improve the outcome.
      Only emit a WORK when the issue is well-scoped with clear acceptance criteria and no human decisions pending.
      Markers must be the very last thing in your response. Each on its own line. No quotes, no markdown."

SWE_PROMPT="      Review PRs and commits from the last 24 hours for the ${FLEET_NAME} service.
      Use 'gh pr list' and 'gh pr list --state merged' to get recent activity.
      Post a concise code-health digest to Telegram.
      Lead with any high-risk changes or architectural concerns.
      If 5+ PRs are open without priority labels, emit HANDOFF: pm prioritize-open-prs.
${MARKER_FOOTER}"

SRE_PROMPT="      Summarize operational health of the ${FLEET_NAME} service over the last 24 hours.
      Use 'gh run list --limit 10' to check recent workflow and deploy status.
      Post a concise ops digest to Telegram.
      Flag any failed runs, rollbacks, or error spikes explicitly.
      Note if monitoring MCP is not wired (partial visibility).
${MARKER_FOOTER}"

PM_PROMPT="      Summarize GitHub issue activity for the ${FLEET_NAME} service over the last 24 hours.
      Use 'gh issue list --state open' to review open items.
      Post a concise product digest to Telegram.
      Flag any items needing human decisions, blocked work, or overdue priorities.
${MARKER_FOOTER}"

PM_HANDOFF_PROMPT="      You were triggered by the orchestrator to prioritize open PRs for the ${FLEET_NAME} service.
      Run: gh pr list --repo [REPO] --state open --limit 30 --json number,title,labels,createdAt,isDraft,author,additions,deletions
      For each open non-draft PR without an existing priority/* label, decide a priority:
        priority/p1 — security, broken main, blocking other work, customer-impacting bug
        priority/p2 — material risk, large scope, or sustained delay
        priority/p3 — small, low-risk, or backlog
      Apply labels with: gh pr edit <number> --add-label priority/pX --repo [REPO]
      If a 'priority/pX' label does not exist on the repo, create it first with:
        gh label create priority/p1 --repo [REPO] --color FF0000   (p2=FFAA00, p3=00AA00)
      Post a Telegram digest listing each PR you labeled and its assigned priority with one-line justification.
      If there are no PRs needing prioritization, respond with exactly [SILENT].
${MARKER_FOOTER}"

write_config "swe" "0 8 * * *"  "daily-code-review"  "$SWE_PROMPT"
write_config "sre" "30 7 * * *" "daily-ops-digest"   "$SRE_PROMPT"
write_config "pm"  "30 8 * * *" "daily-ticket-digest" "$PM_PROMPT"

# Stash the PM handoff prompt where start-gateways.sh can read it. The handoff
# cron is created separately (after the gateway is running) because Hermes
# only auto-seeds the FIRST cron entry from config.yaml on initial install.
cat > "$FLEET_DIR/profiles/staff-pm/handoff-prompt.txt" <<HANDOFFEOF
${PM_HANDOFF_PROMPT}
HANDOFFEOF

echo "  wrote config.yaml for staff-swe, staff-sre, staff-pm"

# ── .env templates ───────────────────────────────────────────────────────────

for role in swe sre pm; do
  env_path="$FLEET_DIR/profiles/staff-${role}/.env"
  if [[ ! -f "$env_path" ]]; then
    role_upper="$(echo "$role" | tr a-z A-Z)"
    cat > "$env_path" << ENVEOF
# Staff ${role_upper} — ${FLEET_NAME}
# Get bot token from @BotFather on Telegram (/newbot)
# Get your user ID from @userinfobot
TELEGRAM_BOT_TOKEN=
TELEGRAM_ALLOWED_USERS=
# Your Telegram user ID — required for cron delivery (same as TELEGRAM_ALLOWED_USERS if single user)
TELEGRAM_HOME_CHANNEL=
# GitHub token for headless gh CLI in cron jobs: run 'gh auth token' and paste here
GH_TOKEN=
ENVEOF
  fi
done
echo "  wrote .env templates"

# Auto-populate shared values (TELEGRAM_ALLOWED_USERS, TELEGRAM_HOME_CHANNEL, GH_TOKEN)
# from any existing fleet on this machine — same user and GH token across fleets.
# Look in .hermes/profiles/ (the live, filled-in location) not profiles/ (templates).
_ref_env=""
for _candidate in "$FLEETS_ROOT"/*/.hermes/profiles/staff-pm/.env; do
  # Skip the fleet we're currently provisioning
  [[ "$_candidate" == "$FLEET_DIR"* ]] && continue
  [[ -f "$_candidate" ]] && _ref_env="$_candidate" && break
done
if [[ -n "$_ref_env" ]]; then
  for role in swe sre pm; do
    env_path="$FLEET_DIR/profiles/staff-${role}/.env"
    for key in TELEGRAM_ALLOWED_USERS TELEGRAM_HOME_CHANNEL GH_TOKEN; do
      val=$(grep "^${key}=" "$_ref_env" | cut -d= -f2- || true)
      [[ -n "$val" ]] && sed -i '' "s|^${key}=.*|${key}=${val}|" "$env_path"
    done
  done
  echo "  copied TELEGRAM_ALLOWED_USERS / TELEGRAM_HOME_CHANNEL / GH_TOKEN from existing fleet"
else
  echo "  NOTE: no existing fleet found — shared .env values left empty"
fi
unset _ref_env _candidate

# Prompt for per-agent Telegram bot tokens if running interactively.
if [[ -t 0 ]]; then
  echo ""
  echo "▶ Enter bot tokens for the three agents (create via @BotFather → /newbot if needed):"
  for role in swe sre pm; do
    env_path="$FLEET_DIR/profiles/staff-${role}/.env"
    bot_handle="@cbr4119-${FLEET_NAME}-${role}-bot"
    printf "  ${bot_handle} token: "
    read -r _token
    if [[ -n "$_token" ]]; then
      sed -i '' "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${_token}|" "$env_path"
      echo "    ✓ saved"
    else
      echo "    ⚠ skipped — fill in manually: $env_path"
    fi
  done
  unset _token
else
  echo "  NOTE: running non-interactively — fill in TELEGRAM_BOT_TOKEN in each profile .env before starting gateways"
fi

# ── Hermes profiles ──────────────────────────────────────────────────────────

export HERMES_HOME="$HERMES_HOME"

for role in swe sre pm; do
  profile_dir="$HERMES_HOME/profiles/staff-${role}"
  if [[ ! -d "$profile_dir" ]]; then
    hermes profile create "staff-${role}" 2>/dev/null || true
    echo "  created Hermes profile: staff-${role}"
  else
    echo "  Hermes profile staff-${role} already exists, updating config"
  fi

  # Copy/overwrite config and soul into the Hermes profile directory
  cp "$FLEET_DIR/profiles/staff-${role}/SOUL.md"    "$profile_dir/SOUL.md"
  cp "$FLEET_DIR/profiles/staff-${role}/config.yaml" "$profile_dir/config.yaml"

  # Merge .env (only if token is set in source)
  src_env="$FLEET_DIR/profiles/staff-${role}/.env"
  dst_env="$profile_dir/.env"
  if [[ ! -f "$dst_env" ]]; then
    cp "$src_env" "$dst_env"
  fi
done

echo "  synced SOUL.md + config.yaml into .hermes/profiles/"

# ── auth.json symlinks ───────────────────────────────────────────────────────
# Gateway processes run with HERMES_HOME set to the profile directory.
# Symlink auth.json into each profile so codex credentials are always current.
DEFAULT_AUTH="$HOME/.hermes/auth.json"
for role in swe sre pm; do
  ln -sf "$DEFAULT_AUTH" "$HERMES_HOME/profiles/staff-${role}/auth.json"
done
echo "  linked auth.json → ~/.hermes/auth.json in each profile"

# ── team-orchestrator.py ─────────────────────────────────────────────────────
# Parses CONCERN/HANDOFF markers from the latest cron sessions of each agent.
# Appends CONCERNs to service-context.md. Fires HANDOFF crons (max one per
# fleet per day — loop guard). Scheduled by the team-orchestrator cron entry
# (see start-gateways.sh below) to run at 9:00am, after the morning crons.
cat > "$FLEET_DIR/team-orchestrator.py" << 'ORCHEOF'
#!/usr/bin/env python3
"""team-orchestrator.py — Parse marker-tagged cron sessions, patch
service-context.md, and trigger inter-agent handoffs."""
from __future__ import annotations
import argparse, json, os, re, subprocess, sys
from datetime import datetime
from pathlib import Path

ROLES = ["staff-swe", "staff-sre", "staff-pm"]
CONCERN_RE = re.compile(r"^CONCERN:\s*(.+)$", re.M)
HANDOFF_RE = re.compile(r"^HANDOFF:\s*(?:staff-)?(swe|sre|pm)\s+(\S+)(?:\s+(.+))?$", re.M)
WORK_RE = re.compile(r"^WORK:\s*#?(\d+)\s+(.+)$", re.M)
HANDOFF_TARGETS = {
    "pm": ("staff-pm", "prioritize-handoff-prs"),
}


def log(msg, log_file):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    with log_file.open("a") as f:
        f.write(line + "\n")


def load_state(p):
    if not p.exists():
        return {"last_processed": {}, "handoff_triggered_date": ""}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError:
        return {"last_processed": {}, "handoff_triggered_date": ""}


def save_state(p, s):
    p.write_text(json.dumps(s, indent=2))


def extract_final_text(p):
    try:
        d = json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return ""
    for m in reversed(d.get("messages", [])):
        if m.get("role") == "assistant":
            c = m.get("content") or ""
            if isinstance(c, str) and c.strip():
                return c
    return ""


def latest_session(profile_dir):
    sessions = sorted(
        profile_dir.glob("sessions/session_cron_*.json"),
        key=lambda p: p.stat().st_mtime, reverse=True,
    )
    return sessions[0] if sessions else None


def append_concerns(sc, role, concerns):
    if not concerns or not sc.exists():
        return 0
    content = sc.read_text()
    today = datetime.now().strftime("%Y-%m-%d")
    short = role.replace("staff-", "")
    new_lines = "\n".join(f"- [{today}/{short}] {c.strip()}" for c in concerns)
    header_re = re.compile(r"^## Current Concerns / Risks\s*\n\n?", re.M)
    if not header_re.search(content):
        return 0
    sc.write_text(header_re.sub(lambda m: m.group(0) + new_lines + "\n", content, count=1))
    return len(concerns)


def resolve_cron_id(profile, name, hbin, hhome):
    env = os.environ.copy(); env["HERMES_HOME"] = hhome
    try:
        r = subprocess.run([hbin, "-p", profile, "cron", "list"],
                           env=env, capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if r.returncode != 0:
        return None
    cur = None
    for line in r.stdout.splitlines():
        s = line.strip()
        m = re.match(r"^([a-f0-9]{12})\s+\[active\]", s)
        if m:
            cur = m.group(1)
        elif s.startswith("Name:") and cur:
            if s.split(":", 1)[1].strip() == name:
                return cur
            cur = None
    return None


def trigger_cron(profile, job_id, hbin, hhome):
    env = os.environ.copy(); env["HERMES_HOME"] = hhome
    try:
        r = subprocess.run([hbin, "-p", profile, "cron", "run", job_id],
                           env=env, capture_output=True, text=True, timeout=30)
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        return False, str(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fleet-dir", required=True)
    ap.add_argument("--hermes-bin", default=os.path.expanduser("~/.local/bin/hermes"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    fleet_dir = Path(args.fleet_dir).resolve()
    if not fleet_dir.exists():
        print(f"ERROR: fleet dir not found: {fleet_dir}", file=sys.stderr)
        return 1

    state_path = fleet_dir / ".team-orchestrator-state.json"
    log_dir = fleet_dir / "logs"; log_dir.mkdir(exist_ok=True)
    log_file = log_dir / "orchestrator.log"
    sc = fleet_dir / "service-context.md"
    hhome = str(fleet_dir / ".hermes")

    log("orchestrator start", log_file)
    state = load_state(state_path)
    today = datetime.now().strftime("%Y-%m-%d")

    total_c = 0; queue = []; work_q = []
    for role in ROLES:
        pdir = fleet_dir / ".hermes" / "profiles" / role
        latest = latest_session(pdir)
        if not latest:
            log(f"{role}: no cron session found", log_file); continue
        if str(latest) == state["last_processed"].get(role, ""):
            log(f"{role}: already processed ({latest.name})", log_file); continue
        text = extract_final_text(latest)
        if not text:
            log(f"{role}: no final text", log_file)
            state["last_processed"][role] = str(latest); continue
        cs = CONCERN_RE.findall(text); hs = HANDOFF_RE.findall(text); ws = WORK_RE.findall(text)
        log(f"{role}: session={latest.name} concerns={len(cs)} handoffs={len(hs)} works={len(ws)}", log_file)
        if cs and not args.dry_run:
            n = append_concerns(sc, role, cs)
            log(f"  appended {n} concerns to service-context.md", log_file); total_c += n
        for tgt, reason, _ in hs:
            queue.append((role, tgt, reason, latest.stem))
        for issue_num, reason in ws:
            work_q.append((role, issue_num, reason))
        state["last_processed"][role] = str(latest)

    fired = 0
    if queue:
        if state.get("handoff_triggered_date") == today:
            log(f"handoffs queued ({len(queue)}) but already fired one today — skipping", log_file)
        elif args.dry_run:
            for fr, tgt, rs, _ in queue:
                log(f"  DRY-RUN handoff: {fr} → {tgt} ({rs})", log_file)
        else:
            fr, tgt, rs, _ = queue[0]
            entry = HANDOFF_TARGETS.get(tgt)
            if not entry:
                log(f"  unknown handoff target: {tgt}", log_file)
            else:
                tp, tj = entry
                jid = resolve_cron_id(tp, tj, args.hermes_bin, hhome)
                if not jid:
                    log(f"  could not resolve cron job {tj} on {tp}", log_file)
                else:
                    ok, out = trigger_cron(tp, jid, args.hermes_bin, hhome)
                    if ok:
                        log(f"  triggered {tp}/{tj} ({jid}) from {fr}: {rs}", log_file)
                        state["handoff_triggered_date"] = today; fired = 1
                    else:
                        log(f"  trigger FAILED: {out}", log_file)

    # WORK markers → label issue priority/p2 so the babysitter picks it up
    labeled = 0
    if work_q and not args.dry_run:
        gh_repo = _derive_gh_repo(fleet_dir)
        if gh_repo:
            seen = set()
            for fr, num, rs in work_q:
                if num in seen: continue
                seen.add(num)
                if _apply_label(gh_repo, num, "priority/p2"):
                    log(f"  WORK: labeled {gh_repo}#{num} priority/p2 ({fr}: {rs})", log_file)
                    labeled += 1
                else:
                    log(f"  WORK: label failed for {gh_repo}#{num}", log_file)
    elif work_q and args.dry_run:
        for fr, num, rs in work_q:
            log(f"  DRY-RUN WORK: {fr} → label issue #{num} priority/p2 ({rs})", log_file)

    if not args.dry_run:
        save_state(state_path, state)
    log(f"orchestrator done concerns={total_c} handoffs_fired={fired} works_labeled={labeled}", log_file)
    return 0


def _derive_gh_repo(fleet_dir):
    cron_state = fleet_dir / ".hermes" / "profiles" / "staff-pm" / "cron" / "jobs.json"
    try:
        data = json.loads(cron_state.read_text())
        for job in data.get("jobs", []):
            wd = job.get("workdir")
            if wd and Path(wd).is_dir() and (Path(wd) / ".git").exists():
                r = subprocess.run(["git", "-C", wd, "config", "--get", "remote.origin.url"],
                                   capture_output=True, text=True, timeout=10)
                m = re.match(r"(?:git@github\.com:|https://github\.com/)([^.]+?)(?:\.git)?$", r.stdout.strip())
                if m: return m.group(1)
    except (OSError, json.JSONDecodeError, subprocess.TimeoutExpired):
        pass
    return None


def _apply_label(repo, num, label):
    try:
        r = subprocess.run(["gh", "issue", "edit", num, "--repo", repo, "--add-label", label],
                           capture_output=True, text=True, timeout=30)
        return r.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


if __name__ == "__main__":
    sys.exit(main())
ORCHEOF
chmod +x "$FLEET_DIR/team-orchestrator.py"
echo "  wrote team-orchestrator.py"

# Install a wrapper in the staff-pm profile's scripts/ dir so the no-agent
# cron can find it by relative name (Hermes resolves --script relative to the
# active profile's scripts/ directory, not $HOME/.hermes/scripts/).
PM_SCRIPTS="$FLEET_DIR/.hermes/profiles/staff-pm/scripts"
mkdir -p "$PM_SCRIPTS"
cat > "$PM_SCRIPTS/team-orchestrator-${FLEET_NAME}.sh" << ORCHWRAPEOF
#!/usr/bin/env bash
# Wrapper around team-orchestrator.py for the ${FLEET_NAME} fleet.
exec python3 ${FLEET_DIR}/team-orchestrator.py --fleet-dir ${FLEET_DIR}
ORCHWRAPEOF
chmod +x "$PM_SCRIPTS/team-orchestrator-${FLEET_NAME}.sh"
echo "  installed orchestrator wrapper: staff-pm/scripts/team-orchestrator-${FLEET_NAME}.sh"

# ── babysit-driver.sh ────────────────────────────────────────────────────────
# Wraps ~/repos/scripts/babysit-with-review.sh. Detects new PRs opened during
# the run, labels them `from-babysitter`, notifies Telegram via staff-pm's
# bot, and triggers the staff-pm spec-review-pr cron. The driver itself is
# detached via nohup by the dispatcher; it polls every 30s for new PRs while
# the babysitter runs in the background.
cat > "$FLEET_DIR/babysit-driver.sh" << 'DRIVEREOF'
#!/bin/bash
set -uo pipefail
FLEET_NAME="${1:-FLEET_PLACEHOLDER}"
FLEET_DIR="$HOME/staff-fleet/${FLEET_NAME}"
REPO_PATH="$HOME/repos/${FLEET_NAME}"
GH_REPO_SLUG="${GH_REPO_SLUG:-}"
if [[ -z "$GH_REPO_SLUG" ]] && [[ -d "$REPO_PATH/.git" ]]; then
  GH_REPO_SLUG=$(git -C "$REPO_PATH" config --get remote.origin.url \
    | sed -E 's#(git@github.com:|https://github.com/)([^.]+)(\.git)?#\2#' | head -n1)
fi
[[ -z "$GH_REPO_SLUG" ]] && { echo "ERROR: no GH_REPO_SLUG"; exit 1; }
export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:/usr/local/bin:/usr/bin:/bin"
export HERMES_HOME="${FLEET_DIR}/.hermes"
ENV_FILE="${FLEET_DIR}/.hermes/profiles/staff-pm/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
mkdir -p "$HOME/sisyphus-logs"
DRIVER_LOG="$HOME/sisyphus-logs/${FLEET_NAME}-driver-$(date +%Y%m%d-%H%M%S).log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$DRIVER_LOG"; }
send_telegram() {
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_HOME_CHANNEL:-}" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_HOME_CHANNEL}" \
    --data-urlencode "text=$1" --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || true
}
ensure_label() {
  gh label list --repo "$GH_REPO_SLUG" --json name --jq '.[].name' 2>/dev/null \
    | grep -qx "$1" && return 0
  gh label create "$1" --repo "$GH_REPO_SLUG" --color "$2" 2>/dev/null || true
}
trigger_spec_review() {
  local job_id
  job_id=$(hermes -p staff-pm cron list 2>/dev/null | awk '
    /^  [a-f0-9]{12} \[/ { id=$1 }
    /Name:/ { sub(/^[[:space:]]+Name:[[:space:]]+/,""); if ($0=="spec-review-pr") { print id; exit } }
  ')
  [[ -n "$job_id" ]] && hermes -p staff-pm cron run "$job_id" >/dev/null 2>&1
}
get_open_pr_numbers() {
  gh pr list --repo "$GH_REPO_SLUG" --state open --author @me \
    --json number --jq '.[].number' 2>/dev/null | sort -un
}
command -v claude >/dev/null 2>&1 || { log "ERROR: claude not on PATH"; send_telegram "❌ babysit-driver: \`claude\` not found"; exit 1; }
ensure_label from-babysitter FFD700
ensure_label spec-passed 0E8A16
ensure_label spec-changes-requested D93F0B
BEFORE=$(get_open_pr_numbers)
log "fleet=${FLEET_NAME} repo=${GH_REPO_SLUG}"
log "baseline open PRs by @me: ${BEFORE//$'\n'/ }"
cd "$REPO_PATH" || { log "ERROR: cd $REPO_PATH failed"; exit 1; }
log "spawning babysit-with-review.sh"
~/repos/scripts/babysit-with-review.sh >>"$DRIVER_LOG" 2>&1 &
BABYSIT_PID=$!
log "babysitter PID=${BABYSIT_PID}"
send_telegram "🤖 babysit-driver started for fleet \`${FLEET_NAME}\` (PID ${BABYSIT_PID})"
SEEN=""
while kill -0 "$BABYSIT_PID" 2>/dev/null; do
  sleep 30
  CURRENT=$(get_open_pr_numbers)
  for pr in $CURRENT; do
    echo "$BEFORE" | grep -qx "$pr" && continue
    echo "$SEEN"   | grep -qx "$pr" && continue
    SEEN+="$pr"$'\n'
    log "NEW PR detected: #${pr}"
    gh pr edit "$pr" --repo "$GH_REPO_SLUG" --add-label from-babysitter 2>/dev/null || true
    TITLE=$(gh pr view "$pr" --repo "$GH_REPO_SLUG" --json title --jq .title 2>/dev/null || echo "")
    send_telegram "🆕 babysitter opened PR #${pr} on \`${GH_REPO_SLUG}\`
*${TITLE}*
Triggering staff-pm spec review..."
    trigger_spec_review
  done
done
wait "$BABYSIT_PID"; EXIT_CODE=$?
log "babysitter exited with status ${EXIT_CODE}"
[[ -n "$SEEN" ]] && send_telegram "🛌 babysit-driver complete (exit ${EXIT_CODE}). PRs opened: $(echo "$SEEN" | tr '\n' ' ' | sed 's/^ *//; s/ *$//')" \
  || send_telegram "🛌 babysit-driver complete (exit ${EXIT_CODE}). No new PRs this run."
DRIVEREOF
chmod +x "$FLEET_DIR/babysit-driver.sh"
echo "  wrote babysit-driver.sh"

# ── team-dispatcher.sh ───────────────────────────────────────────────────────
# Continuous-mode dispatcher run every 5min via --no-agent cron on staff-pm.
# Spawns babysit-driver when there's work AND no babysitter is already
# running ANYWHERE in the home-lab-monitor fleet (distributed lock).
cat > "$FLEET_DIR/team-dispatcher.sh" << 'DISPEOF'
#!/bin/bash
# Distributed lock via home-lab-monitor (HLAB_MONITOR_URL); falls back to
# local stop-file if monitor unreachable.
set -uo pipefail
FLEET_NAME="${1:-FLEET_PLACEHOLDER}"
FLEET_DIR="$HOME/staff-fleet/${FLEET_NAME}"
REPO_PATH="$HOME/repos/${FLEET_NAME}"
GH_REPO_SLUG="${GH_REPO_SLUG:-}"
HLAB_MONITOR_URL="${HLAB_MONITOR_URL:-http://192.168.1.129:8888}"
export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:/usr/local/bin:/usr/bin:/bin"
export HERMES_HOME="${FLEET_DIR}/.hermes"
ENV_FILE="${FLEET_DIR}/.hermes/profiles/staff-pm/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
if [[ -z "$GH_REPO_SLUG" ]] && [[ -d "$REPO_PATH/.git" ]]; then
  GH_REPO_SLUG=$(git -C "$REPO_PATH" config --get remote.origin.url \
    | sed -E 's#(git@github.com:|https://github.com/)([^.]+)(\.git)?#\2#' | head -n1)
fi
[[ -z "$GH_REPO_SLUG" ]] && exit 0

# 1. Distributed lock: any host running babysit on this project?
HLAB=$(curl -s -m 5 "${HLAB_MONITOR_URL}/api/babysit" 2>/dev/null || echo "")
if [[ -n "$HLAB" ]]; then
  RUNNING=$(echo "$HLAB" | python3 -c "
import json, sys
try: d = json.load(sys.stdin)
except: sys.exit(0)
for host, insts in d.get('instances_by_host', {}).items():
    for inst in insts:
        if inst.get('project') == '${FLEET_NAME}' and inst.get('state') in ('running','backoff'):
            print(host); sys.exit(0)
" 2>/dev/null)
  [[ -n "$RUNNING" ]] && exit 0
fi

# 2. Belt-and-suspenders: local lockfile check
STOP_FILE="$HOME/sisyphus-logs/${FLEET_NAME}.stop"
[[ -f "$STOP_FILE" ]] && exit 0

# 3. Is there actionable work?
PR_COUNT=$(gh pr list --repo "$GH_REPO_SLUG" --state open --author @me --json number --jq 'length' 2>/dev/null || echo 0)
P1=$(gh issue list --repo "$GH_REPO_SLUG" --state open --label priority/p1 --json number --jq 'length' 2>/dev/null || echo 0)
P2=$(gh issue list --repo "$GH_REPO_SLUG" --state open --label priority/p2 --json number --jq 'length' 2>/dev/null || echo 0)
WORK=$((PR_COUNT + P1 + P2))
[[ "$WORK" -eq 0 ]] && exit 0

# 4. Spawn the driver
mkdir -p "$HOME/sisyphus-logs"
DRIVER_LOG="$HOME/sisyphus-logs/${FLEET_NAME}-dispatcher-$(date +%Y%m%d-%H%M%S).log"
DRIVER_SCRIPT="$FLEET_DIR/babysit-driver.sh"
[[ ! -x "$DRIVER_SCRIPT" ]] && { echo "ERROR: $DRIVER_SCRIPT not executable"; exit 1; }
cat > "$FLEET_DIR/.dispatcher-state.json" <<EOF
{"last_spawn":"$(date -u +%FT%TZ)","open_prs_by_me":${PR_COUNT},"open_p1":${P1},"open_p2":${P2},"log":"${DRIVER_LOG}","lock_source":"hlab-monitor"}
EOF
nohup "$DRIVER_SCRIPT" "$FLEET_NAME" >>"$DRIVER_LOG" 2>&1 < /dev/null &
DPID=$!
disown 2>/dev/null || true
echo "🚀 babysit-driver spawned (PID ${DPID}) on $(hostname -s). work: ${PR_COUNT} open PRs, ${P1} p1, ${P2} p2 issues. log: ${DRIVER_LOG}"
DISPEOF
chmod +x "$FLEET_DIR/team-dispatcher.sh"
echo "  wrote team-dispatcher.sh"

# Wrapper for the --no-agent cron --script (same PM_SCRIPTS dir as orchestrator)
cat > "$PM_SCRIPTS/team-dispatcher-${FLEET_NAME}.sh" << DISPWRAPEOF
#!/bin/bash
exec ${FLEET_DIR}/team-dispatcher.sh ${FLEET_NAME}
DISPWRAPEOF
chmod +x "$PM_SCRIPTS/team-dispatcher-${FLEET_NAME}.sh"
echo "  installed dispatcher wrapper: staff-pm/scripts/team-dispatcher-${FLEET_NAME}.sh"

# ── offline-dev skill (deployed to all three profiles) ──────────────────────
# Documents the babysitter/dispatcher chain for the agents themselves so
# they can reason about what to recommend (via WORK markers) and how to
# review autonomous PRs.
for role in swe sre pm; do
  skills_dir="$HERMES_HOME/profiles/staff-${role}/skills"
  mkdir -p "$skills_dir"
  cat > "${skills_dir}/offline-dev.md" << 'SKILLEOF'
---
name: offline-dev
description: How the staff-team drives autonomous offline development via the babysitter + dispatcher chain
trigger: When deciding which issues/PRs to recommend for autonomous work, or when reviewing a PR labeled `from-babysitter`.
---

# Offline Development Chain

The fleet runs autonomous code-writing in the background via the
**babysitter** loop. The team's role is to identify good candidates,
review what gets shipped, and steer the loop via GitHub state.

## How it works

```
team-dispatcher (every 5 min, --no-agent) → if babysitter not running AND work exists
  spawns babysit-driver.sh
    runs ~/repos/scripts/babysit-with-review.sh
      claude -p picks the highest-priority item (PRs to advance > p1/p2 issues > unimpl specs)
      opens PR → driver labels `from-babysitter`, notifies Telegram via staff-pm,
                 AND triggers staff-pm/spec-review-pr cron
```

## What you do (per role)

**SWE morning cron**: Review yesterday's babysitter PRs in your digest. Filter via
`--label from-babysitter`. If wrong-headed, leave a clear review comment so the next
babysitter iteration addresses it. Emit `WORK: <issue#> <reason>` for well-scoped issues.

**PM morning cron**: Same review/triage. Emit `WORK: <issue#> <reason>` markers for
issues with clear acceptance criteria.

**PM spec-review-pr** (triggered by driver): You own product correctness. Judge whether
the PR implements what was asked. Apply `spec-passed` OR `spec-changes-requested`.
Comment on the PR with your verdict.

## Labels that steer the babysitter

| Label                     | Effect                                              |
|---------------------------|-----------------------------------------------------|
| `priority/p1` (issue)     | Babysitter prioritizes for next iteration           |
| `priority/p2` (issue)     | Considered when no p1 work is available             |
| `review-incomplete` (PR)  | Babysitter SKIPS this PR; needs human action        |
| `review-mcp-outage` (PR)  | Wrapper handles retry; agents should not touch      |
| `from-babysitter` (PR)    | Auto-applied; signals product-review path           |
| `spec-passed` (PR)        | PM approved spec correctness                         |
| `spec-changes-requested`  | PM wants different behavior; babysitter will iterate |

## What NOT to do

- Don't invoke `babysit-with-review.sh` yourself — dispatcher enforces the single-babysitter lock.
- Don't push commits directly to a `from-babysitter` PR; let the babysitter iterate.
- Don't emit `WORK:` for work requiring human judgment beyond the issue text.
SKILLEOF
done
echo "  deployed offline-dev skill to all 3 profiles"

# ── PM spec-review prompt (stashed for start-gateways.sh) ───────────────────
cat > "$FLEET_DIR/profiles/staff-pm/spec-review-prompt.txt" << SREVEOF
You are doing a SPEC-CORRECTNESS review of one or more PRs opened by the autonomous babysitter for the ${FLEET_NAME} service. As the Product agent you OWN the product experience — judge whether each PR implements what was actually asked (codex covers code quality where available).

Find all open PRs to review:
  gh pr list --repo [REPO] --state open --label from-babysitter --json number,title,labels --jq '.[] | select(.labels | map(.name) | (contains(["spec-passed"]) or contains(["spec-changes-requested"])) | not) | {number, title}'

For EACH such PR:
  1. Read the PR body, diff, and any linked issue.
  2. If a closing issue is referenced, fetch its body too.
  3. Read ${FLEET_DIR}/service-context.md for product priorities.
  4. Judge: does this PR actually solve the user's problem? Scope match issue intent? Any obvious behavior gaps?
  5. Apply ONE of:  gh pr edit <N> --repo [REPO] --add-label spec-passed
                OR  gh pr edit <N> --repo [REPO] --add-label spec-changes-requested
  6. Post a brief verdict comment:  gh pr comment <N> --repo [REPO] --body "<verdict>"
  7. In your final Telegram digest, summarize each PR reviewed with verdict + one-line rationale.

If there are NO PRs matching, respond with exactly [SILENT].
SREVEOF
echo "  wrote spec-review-prompt.txt"

# ── bin wrappers ─────────────────────────────────────────────────────────────
# Fleet-qualified wrappers go in both the fleet bin/ and ~/.local/bin so they
# work from anywhere without PATH manipulation.  Hermes auto-creates generic
# ~/.local/bin/staff-{role} wrappers during profile create; we overwrite those
# with a note so multiple fleets don't silently step on each other.

mkdir -p "$HOME/.local/bin"

for role in swe sre pm; do
  wrapper="$FLEET_DIR/bin/${FLEET_NAME}-${role}"
  global_wrapper="$HOME/.local/bin/${FLEET_NAME}-${role}"

  for dest in "$wrapper" "$global_wrapper"; do
    cat > "$dest" << WRAPEOF
#!/usr/bin/env bash
# ${FLEET_NAME}-${role} — staff-${role} agent for fleet '${FLEET_NAME}'
export HERMES_HOME="${HERMES_HOME}"
exec hermes -p "staff-${role}" "\$@"
WRAPEOF
    chmod +x "$dest"
  done

  # Overwrite the generic hermes-created wrapper so it doesn't silently
  # point at whichever fleet last ran profile create.
  generic="$HOME/.local/bin/staff-${role}"
  if [[ -f "$generic" ]]; then
    cat > "$generic" << GENEOF
#!/usr/bin/env bash
# Multiple fleets define staff-${role}. Use fleet-qualified commands instead:
#   ${FLEET_NAME}-${role} chat
echo "ERROR: use a fleet-qualified wrapper (e.g. ${FLEET_NAME}-${role})" >&2
exit 1
GENEOF
    chmod +x "$generic"
  fi
done
echo "  wrote bin wrappers: ${FLEET_NAME}-{swe,sre,pm} (fleet/bin/ and ~/.local/bin/)"

# ── start-gateways.sh helper ─────────────────────────────────────────────────

cat > "$FLEET_DIR/start-gateways.sh" << GWEOF
#!/usr/bin/env bash
# start-gateways.sh — install/start gateways AND wire the team-orchestrator
# cron chain for ${FLEET_NAME}.
# Run this AFTER filling in TELEGRAM_BOT_TOKEN in each profile's .env.
set -euo pipefail

FLEET_NAME="${FLEET_NAME}"
FLEET_DIR="${FLEET_DIR}"
HERMES_HOME="${HERMES_HOME}"
export HERMES_HOME

# 1. Install and start Telegram gateways
for role in swe sre pm; do
  echo "--- staff-\${role} gateway ---"
  # Sync latest .env into Hermes profile
  cp "\${FLEET_DIR}/profiles/staff-\${role}/.env" "\${HERMES_HOME}/profiles/staff-\${role}/.env"
  hermes -p "staff-\${role}" gateway install
  hermes -p "staff-\${role}" gateway start
  hermes -p "staff-\${role}" gateway status
done

# 2. Wire the team-orchestrator cron chain
# The 3 morning cron jobs (daily-code-review, daily-ops-digest, daily-ticket-digest)
# are created by Hermes from config.yaml on first gateway install. The 2 extras
# (orchestrator + PM handoff job) need to be registered here.
echo ""
echo "--- team orchestrator wiring ---"

find_job_id() {
  local profile="\$1" name="\$2"
  hermes -p "\$profile" cron list 2>/dev/null \\
    | awk -v want="\$name" '
        /^  [a-f0-9]{12} \\[/ { id=\$1 }
        /Name:/             { sub(/^[[:space:]]+Name:[[:space:]]+/,""); if (\$0==want) { print id; exit } }
      '
}

# PM handoff job — far-future schedule, triggered on-demand by the orchestrator.
# The handoff prompt was written into staff-pm/config.yaml but Hermes only
# auto-creates cron entries on first install — additional entries need
# explicit cron create.
if [[ -z "\$(find_job_id staff-pm prioritize-handoff-prs)" ]]; then
  PROMPT_FILE="\${FLEET_DIR}/profiles/staff-pm/handoff-prompt.txt"
  if [[ -f "\$PROMPT_FILE" ]]; then
    hermes -p staff-pm cron create "0 0 31 12 *" "\$(cat "\$PROMPT_FILE")" \\
      --name prioritize-handoff-prs --deliver telegram \\
      --workdir "${REPO_PATH}" >/dev/null
    echo "  created staff-pm/prioritize-handoff-prs"
  else
    echo "  WARNING: \$PROMPT_FILE missing; skipping prioritize-handoff-prs"
  fi
else
  echo "  staff-pm/prioritize-handoff-prs already exists"
fi

# Orchestrator — runs the bash wrapper (no-agent mode, no LLM cost) at 9am daily.
if [[ -z "\$(find_job_id staff-pm team-orchestrator)" ]]; then
  hermes -p staff-pm cron create "0 9 * * *" \\
    --script "team-orchestrator-\${FLEET_NAME}.sh" \\
    --no-agent \\
    --name team-orchestrator \\
    --deliver telegram >/dev/null
  echo "  created staff-pm/team-orchestrator (no-agent, runs daily at 9am)"
else
  echo "  staff-pm/team-orchestrator already exists"
fi

# Team dispatcher — continuous mode (every 5 min). Spawns babysit-driver
# whenever there's work AND no babysitter is already running.
if [[ -z "\$(find_job_id staff-pm team-dispatcher)" ]]; then
  hermes -p staff-pm cron create "*/5 * * * *" \\
    --script "team-dispatcher-\${FLEET_NAME}.sh" \\
    --no-agent \\
    --name team-dispatcher \\
    --deliver telegram >/dev/null
  echo "  created staff-pm/team-dispatcher (no-agent, every 5 min)"
else
  echo "  staff-pm/team-dispatcher already exists"
fi

# PM spec-review-pr — far-future schedule (triggered on-demand by the
# babysit-driver when it detects a new PR opened by the babysitter).
if [[ -z "\$(find_job_id staff-pm spec-review-pr)" ]]; then
  PROMPT_FILE="\${FLEET_DIR}/profiles/staff-pm/spec-review-prompt.txt"
  if [[ -f "\$PROMPT_FILE" ]]; then
    hermes -p staff-pm cron create "0 0 31 12 *" "\$(cat "\$PROMPT_FILE")" \\
      --name spec-review-pr --deliver telegram \\
      --workdir "${REPO_PATH}" >/dev/null
    echo "  created staff-pm/spec-review-pr (triggered on-demand)"
  else
    echo "  WARNING: spec-review-prompt.txt missing; skipping spec-review-pr"
  fi
else
  echo "  staff-pm/spec-review-pr already exists"
fi

# Pre-flight checks for the babysitter chain
echo ""
echo "--- babysitter chain pre-flight ---"
if [[ -d "${REPO_PATH}/.git" ]]; then
  REMOTE=\$(git -C "${REPO_PATH}" remote get-url origin 2>/dev/null || echo "")
  if [[ "\$REMOTE" == git@github.com:* ]]; then
    echo "  WARN: ${REPO_PATH} uses SSH remote (\$REMOTE)."
    echo "        Babysitter needs HTTPS+GH_TOKEN to push from this host."
    echo "        Run: git -C ${REPO_PATH} remote set-url origin https://github.com/<owner>/<repo>.git"
    echo "        Then: git config --global --add 'credential.https://github.com.helper' '!/usr/local/bin/gh auth git-credential'"
  fi
  if [[ -n "\$(git -C "${REPO_PATH}" status --short 2>/dev/null)" ]]; then
    echo "  WARN: ${REPO_PATH} working tree is not clean — babysitter pre-flight will refuse to start."
    echo "        Resolve untracked/modified files first."
  fi
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "  WARN: claude CLI not on PATH. Babysitter cannot run without it."
fi

# Distributed-lock check: is this host registered with home-lab-monitor?
# The dispatcher uses GET /api/babysit to prevent two hosts running the
# same fleet's babysit simultaneously. If this host isn't visible to the
# monitor, the dispatcher falls back to local-only locking.
HLAB_URL="\${HLAB_MONITOR_URL:-http://192.168.1.129:8888}"
HLAB_HOSTS=\$(curl -s -m 3 "\${HLAB_URL}/api/hosts" 2>/dev/null || echo "")
if [[ -n "\$HLAB_HOSTS" ]]; then
  THIS_HOST=\$(hostname -s)
  if echo "\$HLAB_HOSTS" | grep -qE "\"\${THIS_HOST}\"|\"mbp[0-9]"; then
    echo "  OK: home-lab-monitor reachable at \$HLAB_URL"
    if echo "\$HLAB_HOSTS" | grep -q "\"\${THIS_HOST}\""; then
      echo "  OK: this host (\${THIS_HOST}) is registered with the monitor"
    else
      echo "  WARN: this host (\${THIS_HOST}) is NOT in \$HLAB_URL/api/hosts"
      echo "        Add an entry to /opt/hlab/config.yml on the monitor host."
      echo "        Until then, distributed lock falls back to local stop-file only."
    fi
  else
    echo "  WARN: \$HLAB_URL responded but host list looks empty/odd"
  fi
else
  echo "  INFO: home-lab-monitor unreachable at \$HLAB_URL (set HLAB_MONITOR_URL to override)"
  echo "        Distributed lock disabled; falling back to local stop-file only."
fi

echo ""
echo "All gateways started + orchestrator + dispatcher wired. Verify by DMing each bot:"
echo "  staff-swe, staff-sre, staff-pm"
echo "Ask each: 'What service do you own and what is your role?'"
echo ""
echo "Babysitter cycle:"
echo "  • Dispatcher checks every 5 min: babysitter running? work exists? → spawns driver"
echo "  • Driver runs babysit-with-review.sh on ${REPO_PATH}"
echo "  • New PRs labeled 'from-babysitter' → Telegram notification + PM spec review"
echo "  • Daily orchestrator (9am): patches service-context.md from CONCERN markers,"
echo "    labels priority/p2 from WORK markers (queue for babysitter), fires HANDOFFs."
GWEOF
chmod +x "$FLEET_DIR/start-gateways.sh"
echo "  wrote start-gateways.sh"

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Fleet '${FLEET_NAME}' provisioned at ${FLEET_DIR}"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Fill in service-context.md — this is the most important step:"
echo "   \$EDITOR ${CTX}"
echo ""
echo "2. Replace [REPO] placeholders in SOUL.md and the PM handoff prompt:"
echo "   grep -r '\[REPO\]' ${FLEET_DIR}/profiles/"
echo "   (e.g. owner/repo-name for 'gh' commands)"
echo ""
echo "3. Verify .env files — bot tokens were prompted interactively; shared values copied from"
echo "   an existing fleet. Check if anything is still empty:"
echo "   grep -h 'TELEGRAM_BOT_TOKEN' ${FLEET_DIR}/profiles/staff-*/\.env"
echo ""
echo "4. Ensure ~/.local/bin is in PATH (add to ~/.zshrc if missing):"
echo "   export PATH=\"\$PATH:\$HOME/.local/bin\""
echo "   Fleet commands already installed: ${FLEET_NAME}-swe, ${FLEET_NAME}-sre, ${FLEET_NAME}-pm"
echo ""
echo "5. Start gateways + wire orchestrator chain:"
echo "   ${FLEET_DIR}/start-gateways.sh"
echo ""
echo "6. Sanity-test each agent on Telegram:"
echo "   DM each bot: 'What service do you own and what is your role?'"
echo ""
echo "7. Verify cron entries (you should see 5 jobs on staff-pm):"
echo "   HERMES_HOME=${HERMES_HOME} hermes -p staff-swe cron list  # 1: daily-code-review"
echo "   HERMES_HOME=${HERMES_HOME} hermes -p staff-sre cron list  # 1: daily-ops-digest"
echo "   HERMES_HOME=${HERMES_HOME} hermes -p staff-pm  cron list  # 5: daily-ticket-digest, prioritize-handoff-prs, team-orchestrator, team-dispatcher, spec-review-pr"
echo ""
echo "Team orchestration chain (daily):"
echo "  07:30 SRE → 08:00 SWE → 08:30 PM → 09:00 orchestrator runs"
echo "  Orchestrator parses markers from agent digests:"
echo "    CONCERN: → appended to service-context.md"
echo "    HANDOFF: → triggers target role's cron (1/day cap)"
echo "    WORK:    → labels GitHub issue priority/p2 (queues for babysitter)"
echo "  Log: ${FLEET_DIR}/logs/orchestrator.log"
echo ""
echo "Continuous autonomous dev (every 5 min):"
echo "  team-dispatcher checks home-lab-monitor (\${HLAB_MONITOR_URL:-http://192.168.1.129:8888})"
echo "  for a distributed lock — any host running babysit on this project?"
echo "  If clear AND open-PRs-by-me OR p1/p2-issues: spawns babysit-driver.sh"
echo "  Driver runs ${HOME}/repos/scripts/babysit-with-review.sh on ${REPO_PATH}"
echo "  New PRs labeled 'from-babysitter' → Telegram notification + PM spec-review-pr cron"
echo "  PM applies spec-passed or spec-changes-requested labels"
echo "  Driver log: ~/sisyphus-logs/${FLEET_NAME}-driver-*.log"
echo ""
echo "Babysitter prerequisites on this host:"
echo "  - claude CLI installed and authenticated (we use it for the autonomous loop)"
echo "  - codex CLI optional (review cycle is skipped gracefully if missing;"
echo "    PM spec-review provides the product-correctness check either way)"
echo "  - ${REPO_PATH} uses HTTPS remote with credential.helper=gh (NOT SSH)"
echo "  - ${REPO_PATH} working tree is clean and on the default branch"
echo "  - home-lab-monitor agent installed (~/repos/home-lab-monitor/scripts/setup-dev-host.sh --agent-only)"
echo "    AND this host's entry in /opt/hlab/config.yml on the monitor host"
echo "    (otherwise distributed lock falls back to local-only)"
echo "════════════════════════════════════════════════════════════════"
