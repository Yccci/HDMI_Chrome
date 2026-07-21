#!/bin/bash
# 在容器内启动 Weston（DRM → HDMI），供 Chrome Wayland 客户端使用
# 日志走 stderr；stdout 仅输出可 eval 的 export 行

set -euo pipefail

XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-root}
WESTON_LOG=${WESTON_LOG:-/tmp/weston.log}
WESTON_INI=${WESTON_INI:-/app/scripts/weston.ini}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[Weston]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[Weston]${NC} $1" >&2; }
error() { echo -e "${RED}[Weston]${NC} $1" >&2; }

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
export XDG_RUNTIME_DIR

if [ ! -e /dev/dri/card0 ]; then
  error "未找到 /dev/dri/card0，无法使用 DRM 输出"
  exit 1
fi

connected=0
for s in /sys/class/drm/card*-*/status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s" 2>/dev/null)" = "connected" ]; then
    connected=1
    log "显示器已连接: $s"
  fi
done
if [ "$connected" -eq 0 ]; then
  warn "当前没有 DRM 输出为 connected。请插入 HDMI/DP 显示器后再试。"
  warn "仍将尝试启动 Weston（可能黑屏或失败）。"
fi

rm -f "${XDG_RUNTIME_DIR}"/wayland-* "${XDG_RUNTIME_DIR}"/wayland-*.lock 2>/dev/null || true

if command -v seatd >/dev/null 2>&1; then
  if ! pgrep -x seatd >/dev/null 2>&1; then
    log "启动 seatd..."
    seatd -g video -u root >/tmp/seatd.log 2>&1 &
    disown || true
    sleep 0.5
  fi
fi

WESTON_ARGS=(
  --backend=drm-backend.so
  --idle-time=0
  --log="${WESTON_LOG}"
)

if [ -f "${WESTON_INI}" ]; then
  WESTON_ARGS+=(--config="${WESTON_INI}")
fi

log "启动 Weston: ${WESTON_ARGS[*]}"
weston "${WESTON_ARGS[@]}" &
WESTON_PID=$!
disown "${WESTON_PID}" 2>/dev/null || true
echo "${WESTON_PID}" > /tmp/weston.pid

socket=""
for _ in $(seq 1 40); do
  if ! kill -0 "${WESTON_PID}" 2>/dev/null; then
    error "Weston 已退出，日志如下："
    tail -n 80 "${WESTON_LOG}" 2>/dev/null || true
    exit 1
  fi
  for cand in wayland-1 wayland-0; do
    if [ -S "${XDG_RUNTIME_DIR}/${cand}" ]; then
      socket="${cand}"
      break 2
    fi
  done
  sleep 0.25
done

if [ -z "${socket}" ]; then
  error "等待 Wayland socket 超时"
  tail -n 80 "${WESTON_LOG}" 2>/dev/null || true
  kill "${WESTON_PID}" 2>/dev/null || true
  exit 1
fi

log "Weston 就绪 (PID ${WESTON_PID}, WAYLAND_DISPLAY=${socket})"
printf 'export WAYLAND_DISPLAY=%s\n' "${socket}"
printf 'export XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR}"
