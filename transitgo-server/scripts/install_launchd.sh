#!/bin/sh
# Installs the backend as a macOS background service (launchd), so it runs without a Terminal
# window open, restarts itself if it crashes, and starts again automatically at login.
#   npm run service:install     (from transitgo-server/, in the checkout you want to run — e.g. ~/transitgo-run/transitgo-server)
# Undo with:  npm run service:uninstall
set -eu
cd "$(dirname "$0")/.."
DIR="$(pwd)"
[ -f .env ] || { echo "找不到 $DIR/.env（後端的設定檔，不在 git 裡），先放好再安裝服務。"; exit 1; }
NODE_BIN="$(command -v node)"
CAFFEINATE_BIN="$(command -v caffeinate)"
LABEL="local.transitgo.server"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/transitgo-server"
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Stop and unload any previous copy of this service first, so re-running the installer (e.g.
# after `git pull`) doesn't leave two instances fighting over the same port.
launchctl unload "$PLIST" 2>/dev/null || true

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${CAFFEINATE_BIN}</string>
    <string>-i</string>
    <string>${NODE_BIN}</string>
    <string>--env-file=.env</string>
    <string>src/index.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>${DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
    <key>Crashed</key><true/>
  </dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${LOG_DIR}/out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/err.log</string>
</dict>
</plist>
PLIST

launchctl load "$PLIST"
NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
PORT="$(sed -n 's/^PORT=//p' .env | head -1 | tr -d '"' | tr -d "'")"
PORT="${PORT:-8787}"
echo "已安裝背景服務：${LABEL}"
echo "  登入這台 Mac 就會自動啟動，當掉也會自動重開（不用開終端機、不用打指令）。"
echo "  手機（同一個 Wi-Fi）用 BACKEND_HOST = ${NAME}.local:${PORT}"
echo "  記錄檔： ${LOG_DIR}/out.log 和 err.log"
echo "  移除服務： npm run service:uninstall"
