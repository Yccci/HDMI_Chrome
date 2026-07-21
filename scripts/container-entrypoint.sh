#!/bin/bash
# 容器入口
# DISPLAY_MODE=virtual  → Xvfb + Chrome（无电视，远程镜像调试）
# DISPLAY_MODE=hdmi     → Weston DRM + Chrome（本机 HDMI）

set -euo pipefail

BROWSER_PORT=${BROWSER_PORT:-8088}
CHROME_DEBUG_PORT=${CHROME_DEBUG_PORT:-9222}
BROWSER_HOME_URL=${BROWSER_HOME_URL:-"https://www.bing.com"}
BROWSER_DATA_DIR=${BROWSER_DATA_DIR:-"/app/data"}
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-root}

# 兼容旧变量 ENABLE_WESTON
if [ -n "${DISPLAY_MODE:-}" ]; then
  :
elif [ "${ENABLE_WESTON:-}" = "false" ]; then
  DISPLAY_MODE=virtual
else
  DISPLAY_MODE=${DISPLAY_MODE:-virtual}
fi

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
export DISPLAY_MODE

log "=========================================="
log "  HDMI Chrome Browser 启动"
log "=========================================="
log "Web:      http://0.0.0.0:${BROWSER_PORT}"
log "DevTools: http://0.0.0.0:${CHROME_DEBUG_PORT}"
log "Home:     ${BROWSER_HOME_URL}"
log "Mode:     ${DISPLAY_MODE}"
log ""

WESTON_PID=""
XVFB_PID=""
cleanup() {
  log "正在关闭..."
  if [ -n "${WESTON_PID}" ] && kill -0 "${WESTON_PID}" 2>/dev/null; then
    kill "${WESTON_PID}" 2>/dev/null || true
  fi
  if [ -n "${XVFB_PID}" ] && kill -0 "${XVFB_PID}" 2>/dev/null; then
    kill "${XVFB_PID}" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup SIGINT SIGTERM

cd /app

case "${DISPLAY_MODE}" in
  hdmi|weston)
    log "启动 Weston (DRM → HDMI)..."
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
    export CHROME_ENABLE_GPU="${CHROME_ENABLE_GPU:-true}"
    log "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
    ;;
  virtual|xvfb|debug)
    log "启动 Xvfb（无物理屏，供远程镜像调试）..."
    eval "$(bash scripts/start-xvfb.sh | tee /tmp/start-xvfb.out | grep '^export ')"
    if [ -f /tmp/xvfb.pid ]; then
      XVFB_PID="$(cat /tmp/xvfb.pid)"
    fi
    if [ -z "${DISPLAY:-}" ]; then
      error "Xvfb 未能导出 DISPLAY"
      exit 1
    fi
    export DISPLAY
    unset WAYLAND_DISPLAY || true
    export CHROME_OZONE_PLATFORM="${CHROME_OZONE_PLATFORM:-x11}"
    # 虚拟屏默认软渲染更稳
    export CHROME_ENABLE_GPU="${CHROME_ENABLE_GPU:-false}"
    log "DISPLAY=${DISPLAY}  ozone=${CHROME_OZONE_PLATFORM}  gpu=${CHROME_ENABLE_GPU}"
    log "用手机/PC 打开 http://<主机>:${BROWSER_PORT} 查看镜像画面"
    ;;
  *)
    error "未知 DISPLAY_MODE=${DISPLAY_MODE}（支持 virtual | hdmi）"
    exit 1
    ;;
esac

log "启动后端 (Node 将拉起 Chrome)..."
exec node dist/server/index.js
