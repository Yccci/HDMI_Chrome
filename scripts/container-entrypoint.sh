#!/bin/bash
# HDMI Chrome Browser 容器入口：只启动后端，由 Node 管理 Chrome（避免双开）

set -e

BROWSER_PORT=${BROWSER_PORT:-8088}
CHROME_DEBUG_PORT=${CHROME_DEBUG_PORT:-9222}
BROWSER_HOME_URL=${BROWSER_HOME_URL:-"https://www.bing.com"}
BROWSER_DATA_DIR=${BROWSER_DATA_DIR:-"/app/data"}
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-root}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[HDMI Chrome]${NC} $1"; }
warn() { echo -e "${YELLOW}[HDMI Chrome]${NC} $1"; }
error() { echo -e "${RED}[HDMI Chrome]${NC} $1" >&2; }

mkdir -p "${BROWSER_DATA_DIR}" "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true

# 默认由 Node 拉起 Chrome；外部脚本启动时设 BROWSER_MANAGE_CHROME=false
export BROWSER_MANAGE_CHROME="${BROWSER_MANAGE_CHROME:-true}"
export BROWSER_PORT CHROME_DEBUG_PORT BROWSER_HOME_URL BROWSER_DATA_DIR XDG_RUNTIME_DIR
export DISPLAY="${DISPLAY:-:0}"
export CHROME_OZONE_PLATFORM="${CHROME_OZONE_PLATFORM:-x11}"

log "=========================================="
log "  HDMI Chrome Browser 启动"
log "=========================================="
log "Web:     http://localhost:${BROWSER_PORT}"
log "DevTools http://localhost:${CHROME_DEBUG_PORT}"
log "Home:    ${BROWSER_HOME_URL}"
log "DISPLAY: ${DISPLAY}  ozone: ${CHROME_OZONE_PLATFORM}"
log "manageChrome: ${BROWSER_MANAGE_CHROME}"
log ""

if [ ! -S /tmp/.X11-unix/X"${DISPLAY#*:}" ] && [ ! -S "/tmp/.X11-unix/X0" ]; then
  warn "未检测到 X11 socket（/tmp/.X11-unix）。若无桌面会话，Chrome 可能无法出屏。"
fi

cd /app
log "启动后端..."
exec node dist/server/index.js
