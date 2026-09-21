#!/bin/sh
# Runs the backend on THIS computer, with the settings from transitgo-server/.env (git-ignored) — no hosting bill.
#   npm run local
# The phone (same Wi-Fi) then uses  BACKEND_HOST = <this-computer>.local:<port>  in Config/Secrets.xcconfig.
# Nothing secret is printed.
set -eu
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "找不到 transitgo-server/.env（後端的設定檔，不在 git 裡）。"; exit 1; }

NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
PORT="$(sed -n 's/^PORT=//p' .env | head -1 | tr -d '"' | tr -d "'")"
PORT="${PORT:-8787}"
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '?')"

echo "TransitGo 後端啟動中（第一次載入路線圖約需 1 分鐘）"
echo "  手機（要跟這台電腦同一個 Wi‑Fi）請把 BACKEND_HOST 設成： ${NAME}.local:${PORT}"
echo "  或用 IP：${IP}:${PORT}（IP 換 Wi‑Fi 就會變）"
echo "  電腦不要睡眠；按 Ctrl+C 停止。"
echo
# --env-file loads .env without printing it; caffeinate keeps the Mac awake while the server runs.
exec caffeinate -i node --env-file=.env src/index.mjs
