#!/bin/sh
# Removes the background service installed by install_launchd.sh.
set -eu
LABEL="local.transitgo.server"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "已移除背景服務。若要再跑後端，改用「npm run local」或重新「npm run service:install」。"
