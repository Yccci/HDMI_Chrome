#!/bin/bash
# 手动启动 Chrome（开发或 BROWSER_MANAGE_CHROME=false 时使用）

set -e

BROWSER_HOME_URL=${BROWSER_HOME_URL:-"https://www.bing.com"}
CHROME_DEBUG_PORT=${CHROME_DEBUG_PORT:-9222}
BROWSER_DATA_DIR=${BROWSER_DATA_DIR:-"./data"}
CHROME_BIN=${CHROME_BIN:-google-chrome}
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/runtime-root}
DISPLAY=${DISPLAY:-:0}

if [ -n "${CHROME_OZONE_PLATFORM}" ]; then
  OZONE="${CHROME_OZONE_PLATFORM}"
elif [ -n "${WAYLAND_DISPLAY}" ]; then
  OZONE="wayland"
else
  OZONE="x11"
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log() { echo -e "${GREEN}[HDMI Chrome]${NC} $1"; }
warn() { echo -e "${YELLOW}[HDMI Chrome]${NC} $1"; }
error() { echo -e "${RED}[HDMI Chrome]${NC} $1" >&2; }

mkdir -p "${XDG_RUNTIME_DIR}" "${BROWSER_DATA_DIR}/chrome-profile/Default"
chmod 700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true
export XDG_RUNTIME_DIR DISPLAY

CHROME_USER_DATA_DIR="${BROWSER_DATA_DIR}/chrome-profile"
rm -f \
  "${CHROME_USER_DATA_DIR}/SingletonLock" \
  "${CHROME_USER_DATA_DIR}/SingletonCookie" \
  "${CHROME_USER_DATA_DIR}/SingletonSocket"

if [ -d /dev/dri ]; then
  log "GPU 设备:"
  ls -la /dev/dri/ || true
else
  warn "无 /dev/dri，将主要使用软解"
fi

# 诊断不阻塞启动
if command -v vainfo >/dev/null 2>&1; then
  log "VA-API（失败可忽略）:"
  vainfo --display drm 2>&1 | head -15 || true
fi

CHROME_ARGS=(
  --user-data-dir="${CHROME_USER_DATA_DIR}"
  --kiosk
  --noerrdialogs
  --disable-infobars
  --disable-session-crashed-bubble
  --no-first-run
  --no-default-browser-check
  --disable-sync
  --no-sandbox
  --disable-setuid-sandbox
  --disable-dev-shm-usage
  --remote-debugging-port="${CHROME_DEBUG_PORT}"
  --remote-debugging-address=0.0.0.0
  --ozone-platform="${OZONE}"
  --autoplay-policy=no-user-gesture-required
  --ignore-gpu-blocklist
)

if [ "${CHROME_ENABLE_GPU:-true}" = "true" ]; then
  CHROME_ARGS+=(
    --enable-gpu
    --enable-gpu-rasterization
    --disable-gpu-sandbox
    --enable-features=VaapiVideoDecoder,VaapiVideoEncoder,VaapiVideoDecodeLinuxGL
    --enable-accelerated-video-decode
    --use-gl=egl
  )
else
  CHROME_ARGS+=(--disable-gpu --use-gl=swiftshader)
fi

log "启动 Chrome (${CHROME_BIN}), ozone=${OZONE}, debug=${CHROME_DEBUG_PORT}"
"${CHROME_BIN}" "${CHROME_ARGS[@]}" "${BROWSER_HOME_URL}" &
CHROME_PID=$!

# 等待 CDP 端口
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${CHROME_DEBUG_PORT}/json/version" >/dev/null 2>&1; then
    log "Chrome CDP 已就绪 (PID ${CHROME_PID})"
    wait "${CHROME_PID}"
    exit $?
  fi
  if ! kill -0 "${CHROME_PID}" 2>/dev/null; then
    error "Chrome 进程已退出，CDP ${CHROME_DEBUG_PORT} 未就绪"
    error "请检查 DISPLAY=${DISPLAY}、X11 socket、或设置 CHROME_ENABLE_GPU=false 重试"
    exit 1
  fi
  sleep 1
done

error "等待 CDP 超时 (port ${CHROME_DEBUG_PORT})"
kill "${CHROME_PID}" 2>/dev/null || true
exit 1
