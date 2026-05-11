#!/usr/bin/env bash
# new-fleet.sh — provision a staff-team fleet for one service/repo.
#
# Usage:
#   ./new-fleet.sh <fleet-name> <repo-path> [--port PORT]
#
# Creates:
#   ~/staff-fleet/<fleet-name>/
#     service-context.md          shared context — fill this in!
#     profiles/staff-{swe,sre,pm}/
#       SOUL.md                   role definition
#       config.yaml               Hermes config
#       .env                      Telegram token (you fill in)
#     .hermes/                    HERMES_HOME for this fleet
#     bin/
#       <fleet-name>-{swe,sre,pm} wrapper scripts
#   ~/Library/LaunchAgents/com.staff-fleet.<fleet-name>.proxy.plist
#
# Prerequisites: hermes, claude (Claude Code CLI), gh (GitHub CLI)
#
# Run again on the same fleet-name to update config files without
# destroying Hermes state (memory/sessions are preserved).

set -euo pipefail

# ── args ────────────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <fleet-name> <repo-path> [--port PORT]" >&2
  exit 1
fi

FLEET_NAME="$1"
REPO_PATH="$(cd "$2" 2>/dev/null && pwd || echo "$2")"
PORT=""

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEETS_ROOT="$HOME/staff-fleet"
FLEET_DIR="$FLEETS_ROOT/$FLEET_NAME"
HERMES_HOME="$FLEET_DIR/.hermes"
PORT_REGISTRY="$FLEETS_ROOT/.port-registry"

# ── prerequisites ────────────────────────────────────────────────────────────

check_prereq() {
  if ! command -v "$1" &>/dev/null; then
    echo "error: '$1' not found in PATH" >&2
    echo "  $2" >&2
    exit 1
  fi
}

check_prereq claude  "Install Claude Code: https://claude.ai/code"
check_prereq gh      "Install GitHub CLI: brew install gh"
check_prereq hermes  "Install Hermes: curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
check_prereq python3 "python3 required for claude-code-proxy"

if [[ ! -f "$SCRIPTS_DIR/claude-code-proxy.py" ]]; then
  echo "error: claude-code-proxy.py not found in $SCRIPTS_DIR" >&2
  exit 1
fi

# ── port allocation ──────────────────────────────────────────────────────────

mkdir -p "$FLEETS_ROOT"

allocate_port() {
  # Check if fleet already has a port assigned
  if [[ -f "$PORT_REGISTRY" ]]; then
    existing=$(python3 -c "
import json, sys
r = json.load(open('$PORT_REGISTRY'))
print(r.get('$FLEET_NAME', ''))
" 2>/dev/null || echo "")
    [[ -n "$existing" ]] && echo "$existing" && return
  fi

  # Find next available port starting at 9001
  next=9001
  if [[ -f "$PORT_REGISTRY" ]]; then
    next=$(python3 -c "
import json
r = json.load(open('$PORT_REGISTRY'))
ports = list(r.values())
print(max(ports) + 1 if ports else 9001)
" 2>/dev/null || echo "9001")
  fi

  # Register it
  python3 -c "
import json, os
path = '$PORT_REGISTRY'
r = json.load(open(path)) if os.path.exists(path) else {}
r['$FLEET_NAME'] = $next
json.dump(r, open(path, 'w'), indent=2)
print($next)
"
}

if [[ -z "$PORT" ]]; then
  PORT=$(allocate_port)
else
  # Record user-specified port
  python3 -c "
import json, os
path = '$PORT_REGISTRY'
r = json.load(open(path)) if os.path.exists(path) else {}
r['$FLEET_NAME'] = $PORT
json.dump(r, open(path, 'w'), indent=2)
"
fi

echo "fleet=$FLEET_NAME  repo=$REPO_PATH  port=$PORT"

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

You are the Staff SWE for the **${FLEET_NAME}** service. Read service-context.md
in your fleet directory at the start of each session to refresh your world model.

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

You are the Staff SRE for the **${FLEET_NAME}** service. Read service-context.md
in your fleet directory at the start of each session to refresh your world model.

## Role

You own uptime, incident response, deploy health, and observability for this
service. You monitor recent deploys, surface errors, and track operational risks.
You do not own code architecture (staff-swe) or product roadmap (staff-pm).

## Responsibilities

- Daily: summarize last 24h of deploy activity, errors, and alerts.
- On demand: answer ops questions, diagnose production issues, review runbooks.
- Use \`gh\` CLI to check deploy-related commits and workflow run status.
- Note explicitly when you lack monitoring data (no MCP wired yet).

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

You are the Staff PM for the **${FLEET_NAME}** service. Read service-context.md
in your fleet directory at the start of each session to refresh your world model.

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
  provider: custom
  base_url: http://127.0.0.1:${PORT}/v1
  default: claude-code

terminal:
  cwd: ${REPO_PATH}
  persistent_shell: true

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
    args: ["-y", "@modelcontextprotocol/server-filesystem", "${REPO_PATH}"]

cron:
  - name: "${cron_name}"
    schedule: "${cron_sched}"
    prompt: |
${cron_prompt}
CFGEOF
}

SWE_PROMPT="      Review PRs and commits from the last 24 hours for the ${FLEET_NAME} service.
      Use 'gh pr list' and 'gh pr list --state merged' to get recent activity.
      Post a concise code-health digest to Telegram.
      Lead with any high-risk changes or architectural concerns."

SRE_PROMPT="      Summarize operational health of the ${FLEET_NAME} service over the last 24 hours.
      Use 'gh run list --limit 10' to check recent workflow and deploy status.
      Post a concise ops digest to Telegram.
      Flag any failed runs, rollbacks, or error spikes explicitly.
      Note if monitoring MCP is not wired (partial visibility)."

PM_PROMPT="      Summarize GitHub issue activity for the ${FLEET_NAME} service over the last 24 hours.
      Use 'gh issue list --state open' to review open items.
      Post a concise product digest to Telegram.
      Flag any items needing human decisions, blocked work, or overdue priorities."

write_config "swe" "0 8 * * *"  "daily-code-review"  "$SWE_PROMPT"
write_config "sre" "30 7 * * *" "daily-ops-digest"   "$SRE_PROMPT"
write_config "pm"  "30 8 * * *" "daily-ticket-digest" "$PM_PROMPT"

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
ENVEOF
  fi
done
echo "  wrote .env templates (fill in TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS)"

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

# ── launchd plist for proxy ──────────────────────────────────────────────────

PLIST_LABEL="com.staff-fleet.${FLEET_NAME}.proxy"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

cat > "$PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${SCRIPTS_DIR}/claude-code-proxy.py</string>
    <string>${PORT}</string>
    <string>${FLEET_DIR}</string>
    <string>${REPO_PATH}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${FLEET_DIR}/proxy.log</string>
  <key>StandardErrorPath</key>
  <string>${FLEET_DIR}/proxy.log</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
PLISTEOF

echo "  wrote launchd plist: $PLIST_PATH"

# ── start-gateways.sh helper ─────────────────────────────────────────────────

cat > "$FLEET_DIR/start-gateways.sh" << GWEOF
#!/usr/bin/env bash
# start-gateways.sh — load proxy + install Telegram gateways for ${FLEET_NAME}.
# Run this AFTER filling in TELEGRAM_BOT_TOKEN in each profile's .env.
set -euo pipefail

FLEET_DIR="${FLEET_DIR}"
HERMES_HOME="${HERMES_HOME}"
export HERMES_HOME

# Start the claude-code proxy
launchctl load -w "$HOME/Library/LaunchAgents/com.staff-fleet.${FLEET_NAME}.proxy.plist"
echo "proxy started on port ${PORT}"
sleep 2

# Verify proxy is healthy
curl -sf "http://127.0.0.1:${PORT}/health" | python3 -m json.tool || {
  echo "ERROR: proxy health check failed — check ${FLEET_DIR}/proxy.log"
  exit 1
}

# Install and start Telegram gateways
for role in swe sre pm; do
  echo "--- staff-\${role} gateway ---"
  # Sync latest .env into Hermes profile
  cp "\${FLEET_DIR}/profiles/staff-\${role}/.env" "\${HERMES_HOME}/profiles/staff-\${role}/.env"
  hermes -p "staff-\${role}" gateway install
  hermes -p "staff-\${role}" gateway start
  hermes -p "staff-\${role}" gateway status
done

echo ""
echo "All gateways started. Verify by DMing each bot:"
echo "  staff-swe, staff-sre, staff-pm"
echo "Ask each: 'What service do you own and what is your role?'"
GWEOF
chmod +x "$FLEET_DIR/start-gateways.sh"
echo "  wrote start-gateways.sh"

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Fleet '${FLEET_NAME}' provisioned at ${FLEET_DIR}"
echo "Proxy port: ${PORT}"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Fill in service-context.md — this is the most important step:"
echo "   \$EDITOR ${CTX}"
echo ""
echo "2. Replace [REPO] placeholders in each SOUL.md with the actual repo:"
echo "   grep -r '\[REPO\]' ${FLEET_DIR}/profiles/"
echo "   (e.g. owner/repo-name for 'gh' commands)"
echo ""
echo "3. Create three Telegram bots via @BotFather (one per agent)."
echo "   Fill in each profile's .env:"
echo "   \$EDITOR ${FLEET_DIR}/profiles/staff-swe/.env"
echo "   \$EDITOR ${FLEET_DIR}/profiles/staff-sre/.env"
echo "   \$EDITOR ${FLEET_DIR}/profiles/staff-pm/.env"
echo ""
echo "4. Ensure ~/.local/bin is in PATH (add to ~/.zshrc if missing):"
echo "   export PATH=\"\$PATH:\$HOME/.local/bin\""
echo "   Fleet commands already installed: ${FLEET_NAME}-swe, ${FLEET_NAME}-sre, ${FLEET_NAME}-pm"
echo ""
echo "5. Start everything:"
echo "   ${FLEET_DIR}/start-gateways.sh"
echo ""
echo "6. Sanity-test each agent on Telegram:"
echo "   DM each bot: 'What service do you own and what is your role?'"
echo ""
echo "7. Verify cron entries:"
echo "   HERMES_HOME=${HERMES_HOME} hermes -p staff-swe cron list"
echo "════════════════════════════════════════════════════════════════"
