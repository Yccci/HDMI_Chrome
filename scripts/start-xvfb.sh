#!/bin/bash
# 虚拟显示（Xvfb）：无 HDMI 时供远程镜像/调试
# 每次启动都重建，避免复用死掉的 /tmp/.X11-unix/X* 导致 Chrome Missing X server

set -euo pipefail

XVFB_DISPLAY=${XVFB_DISPLAY:-:99}
XVFB_NUM="${XVFB_DISPLAY#:}"
XVFB_WHD=${XVFB_RESOLUTION:-1920x1080x24}
XVFB_LOG=${XVFB_LOG:-/tmp/xvfb.log}
XVFB_SOCKET="/tmp/.X11-unix/X${XVFB_NUM}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[Xvfb]${NC} $1" >&2; }
error() { echo -e "${RED}[Xvfb]${NC} $1" >&2; }

if ! command -v Xvfb >/dev/null 2>&1; then
  error "未安装 Xvfb"
  exit 1
fi

# 清理旧 Xvfb / 死链 socket
if [ -f /tmp/xvfb.pid ]; then
  old="$(cat /tmp/xvfb.pid 2>/dev/null || true)"
  if [ -n "${old}" ]; then
    kill "${old}" 2>/dev/null || true
  fi
  rm -f /tmp/xvfb.pid
fi
pkill -f "Xvfb ${XVFB_DISPLAY} " 2>/dev/null || true
pkill -f "Xvfb ${XVFB_DISPLAY}$" 2>/dev/null || true
rm -f "${XVFB_SOCKET}" 2>/dev/null || true
sleep 0.3

mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

log "启动 Xvfb ${XVFB_DISPLAY} (${XVFB_WHD})"
# -nolisten tcp 仅本机；不要禁用 unix socket
Xvfb "${XVFB_DISPLAY}" -screen 0 "${XVFB_WHD}" -ac -nolisten tcp >"${XVFB_LOG}" 2>&1 &
XVFB_PID=$!
disown "${XVFB_PID}" 2>/dev/null || true
echo "${XVFB_PID}" > /tmp/xvfb.pid

for _ in $(seq 1 50); do
  if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
    error "Xvfb 已退出："
    cat "${XVFB_LOG}" >&2 || true
    exit 1
  fi

  ready=0
  if command -v xdpyinfo >/dev/null 2>&1; then
    if DISPLAY="${XVFB_DISPLAY}" xdpyinfo >/dev/null 2>&1; then
      ready=1
    fi
  elif [ -S "${XVFB_SOCKET}" ]; then
    ready=1
  fi

  if [ "${ready}" -eq 1 ]; then
    log "Xvfb 就绪 (PID ${XVFB_PID}, DISPLAY=${XVFB_DISPLAY})"
    printf 'export DISPLAY=%s\n' "${XVFB_DISPLAY}"
    exit 0
  fi
  sleep 0.1
done

error "等待 Xvfb 就绪超时"
kill "${XVFB_PID}" 2>/dev/null || true
cat "${XVFB_LOG}" >&2 || true
exit 1
