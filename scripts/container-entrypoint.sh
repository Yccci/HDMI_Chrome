#!/bin/bash
# 容器入口
# DISPLAY_MODE=auto     → 有 HDMI connected 用物理屏，否则虚拟屏（默认）
# DISPLAY_MODE=virtual  → 强制 Xvfb
# DISPLAY_MODE=hdmi     → 强制 Weston DRM

set -euo pipefail

BROWSER_PORT=${BROWSER_PORT:-8088}
CHROME_DEBUG_PORT=${CHROME_DEBUG_PORT:-9222}
BROWSER_HOME_URL=${BROWSER_HOME_URL:-"https://www.bing.com"}
BROWSER_DATA_DIR=${BROWSER_DATA_DIR:-"/app/data"}
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-root}

# 兼容旧变量
if [ -z "${DISPLAY_MODE:-}" ]; then
  if [ "${ENABLE_WESTON:-}" = "false" ]; then
    DISPLAY_MODE=virtual
  elif [ "${ENABLE_WESTON:-}" = "true" ]; then
    DISPLAY_MODE=hdmi
  else
    DISPLAY_MODE=auto
  fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[HDMI Chrome]${NC} $1"; }
warn() { echo -e "${YELLOW}[HDMI Chrome]${NC} $1"; }
error() { echo -e "${RED}[HDMI Chrome]${NC} $1" >&2; }

has_connected_display() {
  local s status
  if [ ! -d /sys/class/drm ]; then
    return 1
  fi
  for s in /sys/class/drm/card*-*/status; do
    [ -f "$s" ] || continue
    status="$(cat "$s" 2>/dev/null || true)"
    if [ "${status}" = "connected" ]; then
      log "检测到已连接输出: ${s#"${s%/*}"/} (${s})"
      return 0
    fi
  done
  return 1
}

resolve_display_mode() {
  case "${DISPLAY_MODE}" in
    auto|detect|"")
      if has_connected_display; then
        echo "hdmi"
      else
        warn "未检测到 connected 的 DRM 输出 → 使用虚拟屏"
        echo "virtual"
      fi
      ;;
    hdmi|weston|virtual|xvfb|debug)
      echo "${DISPLAY_MODE}"
      ;;
    *)
      error "未知 DISPLAY_MODE=${DISPLAY_MODE}（支持 auto | virtual | hdmi）"
      exit 1
      ;;
  esac
}

start_hdmi() {
  log "启动 Weston (DRM → 物理屏)..."
  eval "$(bash scripts/start-weston.sh | tee /tmp/start-weston.out | grep '^export ')"
  if [ -f /tmp/weston.pid ]; then
    WESTON_PID="$(cat /tmp/weston.pid)"
  fi
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    return 1
  fi
  export WAYLAND_DISPLAY XDG_RUNTIME_DIR
  export CHROME_OZONE_PLATFORM="${CHROME_OZONE_PLATFORM:-wayland}"
  export CHROME_ENABLE_GPU="${CHROME_ENABLE_GPU:-true}"
  log "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}  ozone=${CHROME_OZONE_PLATFORM}  gpu=${CHROME_ENABLE_GPU}"
  return 0
}

start_virtual() {
  log "启动 Xvfb（虚拟屏，远程镜像调试）..."
  eval "$(bash scripts/start-xvfb.sh | tee /tmp/start-xvfb.out | grep '^export ')"
  if [ -f /tmp/xvfb.pid ]; then
    XVFB_PID="$(cat /tmp/xvfb.pid)"
  fi
  if [ -z "${DISPLAY:-}" ]; then
    error "Xvfb 未能导出 DISPLAY"
    return 1
  fi
  export DISPLAY
  unset WAYLAND_DISPLAY || true
  export CHROME_OZONE_PLATFORM="${CHROME_OZONE_PLATFORM:-x11}"
  export CHROME_ENABLE_GPU="${CHROME_ENABLE_GPU:-false}"
  log "DISPLAY=${DISPLAY}  ozone=${CHROME_OZONE_PLATFORM}  gpu=${CHROME_ENABLE_GPU}"
  log "打开 http://<主机>:${BROWSER_PORT} 查看镜像画面"
  return 0
}

mkdir -p "${BROWSER_DATA_DIR}" "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

export BROWSER_MANAGE_CHROME="${BROWSER_MANAGE_CHROME:-true}"
export BROWSER_PORT CHROME_DEBUG_PORT BROWSER_HOME_URL BROWSER_DATA_DIR XDG_RUNTIME_DIR

REQUESTED_MODE="${DISPLAY_MODE}"
EFFECTIVE_MODE="$(resolve_display_mode)"
export DISPLAY_MODE="${EFFECTIVE_MODE}"

log "=========================================="
log "  HDMI Chrome Browser 启动"
log "=========================================="
log "Web:      http://0.0.0.0:${BROWSER_PORT}"
log "DevTools: http://0.0.0.0:${CHROME_DEBUG_PORT}"
log "Home:     ${BROWSER_HOME_URL}"
log "Mode:     ${REQUESTED_MODE} → ${EFFECTIVE_MODE}"
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

case "${EFFECTIVE_MODE}" in
  hdmi|weston)
    if ! start_hdmi; then
      warn "物理屏/Weston 启动失败，回退到虚拟屏"
      tail -n 40 /tmp/weston.log 2>/dev/null || true
      WESTON_PID=""
      # 清除可能被强制的 wayland 相关设置，让虚拟屏用默认值
      unset WAYLAND_DISPLAY || true
      unset CHROME_OZONE_PLATFORM || true
      unset CHROME_ENABLE_GPU || true
      EFFECTIVE_MODE=virtual
      export DISPLAY_MODE=virtual
      start_virtual
    fi
    ;;
  virtual|xvfb|debug)
    start_virtual
    ;;
esac

log "启动后端 (Node 将拉起 Chrome)..."
exec node dist/server/index.js
