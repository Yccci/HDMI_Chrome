#!/bin/bash
# 容器入口：Weston(DRM) → Node(管理 Chrome) → 远程 8088/9222

set -euo pipefail

BROWSER_PORT=${BROWSER_PORT:-8088}
CHROME_DEBUG_PORT=${CHROME_DEBUG_PORT:-9222}
BROWSER_HOME_URL=${BROWSER_HOME_URL:-"https://www.bing.com"}
BROWSER_DATA_DIR=${BROWSER_DATA_DIR:-"/app/data"}
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-root}
ENABLE_WESTON=${ENABLE_WESTON:-true}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[HDMI Chrome]${NC} $1"; }
warn() { echo -e "${YELLOW}[HDMI Chrome]${NC} $1"; }
error() { echo -e "${RED}[HDMI Chrome]${NC} $1" >&2; }

mkdir -p "${BROWSER_DATA_DIR}" "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

export BROWSER_MANAGE_CHROME="${BROWSER_MANAGE_CHROME:-true}"
export BROWSER_PORT CHROME_DEBUG_PORT BROWSER_HOME_URL BROWSER_DATA_DIR XDG_RUNTIME_DIR

log "=========================================="
log "  HDMI Chrome Browser 启动"
log "=========================================="
log "Web:      http://0.0.0.0:${BROWSER_PORT}"
log "DevTools: http://0.0.0.0:${CHROME_DEBUG_PORT}"
log "Home:     ${BROWSER_HOME_URL}"
log "Weston:   ${ENABLE_WESTON}"
log ""

WESTON_PID=""
cleanup() {
  log "正在关闭..."
  if [ -n "${WESTON_PID}" ] && kill -0 "${WESTON_PID}" 2>/dev/null; then
    kill "${WESTON_PID}" 2>/dev/null || true
    wait "${WESTON_PID}" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup SIGINT SIGTERM

cd /app

if [ "${ENABLE_WESTON}" = "true" ]; then
  log "启动 Weston (DRM → HDMI)..."
  # start-weston 在后台拉起 weston，并 echo export 行
  # shellcheck disable=SC1091
  eval "$(bash scripts/start-weston.sh | tee /tmp/start-weston.out | grep '^export ')"
  if [ -f /tmp/weston.pid ]; then
    WESTON_PID="$(cat /tmp/weston.pid)"
  fi
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    error "Weston 未能导出 WAYLAND_DISPLAY"
    tail -n 80 /tmp/weston.log 2>/dev/null || true
    exit 1
  fi
  export WAYLAND_DISPLAY XDG_RUNTIME_DIR
  export CHROME_OZONE_PLATFORM="${CHROME_OZONE_PLATFORM:-wayland}"
  log "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}  CHROME_OZONE_PLATFORM=${CHROME_OZONE_PLATFORM}"
else
  warn "ENABLE_WESTON=false，回退到宿主机显示（需 DISPLAY / X11）"
  export DISPLAY="${DISPLAY:-:0}"
  export CHROME_OZONE_PLATFORM="${CHROME_OZONE_PLATFORM:-x11}"
fi

log "启动后端 (Node 将拉起 Chrome)..."
exec node dist/server/index.js
