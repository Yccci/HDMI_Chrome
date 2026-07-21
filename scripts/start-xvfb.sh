#!/bin/bash
# 虚拟显示（Xvfb）：无 HDMI 时供远程镜像/调试

set -euo pipefail

XVFB_DISPLAY=${XVFB_DISPLAY:-:99}
XVFB_WHD=${XVFB_RESOLUTION:-1920x1080x24}
XVFB_LOG=${XVFB_LOG:-/tmp/xvfb.log}

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[Xvfb]${NC} $1" >&2; }
error() { echo -e "${RED}[Xvfb]${NC} $1" >&2; }

if ! command -v Xvfb >/dev/null 2>&1; then
  error "未安装 Xvfb"
  exit 1
fi

# 已有则复用
if [ -S "/tmp/.X11-unix/X${XVFB_DISPLAY#:}" ]; then
  log "已存在 ${XVFB_DISPLAY}，复用"
  printf 'export DISPLAY=%s\n' "${XVFB_DISPLAY}"
  exit 0
fi

log "启动 Xvfb ${XVFB_DISPLAY} (${XVFB_WHD})"
Xvfb "${XVFB_DISPLAY}" -screen 0 "${XVFB_WHD}" -ac -nolisten tcp >"${XVFB_LOG}" 2>&1 &
XVFB_PID=$!
disown "${XVFB_PID}" 2>/dev/null || true
echo "${XVFB_PID}" > /tmp/xvfb.pid

for _ in $(seq 1 30); do
  if [ -S "/tmp/.X11-unix/X${XVFB_DISPLAY#:}" ]; then
    log "Xvfb 就绪 (PID ${XVFB_PID}, DISPLAY=${XVFB_DISPLAY})"
    printf 'export DISPLAY=%s\n' "${XVFB_DISPLAY}"
    exit 0
  fi
  if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
    error "Xvfb 已退出："
    cat "${XVFB_LOG}" >&2 || true
    exit 1
  fi
  sleep 0.2
done

error "等待 Xvfb socket 超时"
kill "${XVFB_PID}" 2>/dev/null || true
exit 1
