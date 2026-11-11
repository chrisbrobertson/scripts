#!/bin/bash
# install-babysit-agent.sh — materialise and bootstrap a babysit launchd LaunchAgent.
#
# Usage: install-babysit-agent.sh <project_basename> <project_absolute_path>
#
# Fills com.chrisrobertson.babysit.PROJECT.plist.template with the given
# project name and path, writes it to ~/Library/LaunchAgents/, then loads it
# via launchctl. Edit the resulting plist's StartCalendarInterval to set the
# actual schedule before (or after) loading it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/com.chrisrobertson.babysit.PROJECT.plist.template"

if [ $# -ne 2 ]; then
  echo "Usage: $0 <project_basename> <project_absolute_path>" >&2
  exit 1
fi

PROJECT="$1"
PROJECT_PATH="$2"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
  echo "ERROR: project path does not exist: $PROJECT_PATH" >&2
  exit 1
fi

LABEL="com.chrisrobertson.babysit.$PROJECT"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__PROJECT__|$PROJECT|g" -e "s|__PROJECT_PATH__|$PROJECT_PATH|g" "$TEMPLATE" > "$DEST"

echo "Wrote $DEST"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$DEST"
fi

UID_NUM="$(id -u)"
if launchctl bootstrap "gui/$UID_NUM" "$DEST" 2>/dev/null; then
  echo "Bootstrapped $LABEL via launchctl bootstrap."
else
  echo "bootstrap failed or already loaded; falling back to launchctl load" >&2
  launchctl load "$DEST"
fi

launchctl print "gui/$UID_NUM/$LABEL" 2>&1 | head -40
