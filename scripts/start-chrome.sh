#!/bin/bash
# HDMI Chrome Browser 启动脚本（带 GPU 硬件加速）

set -e

# 配置参数
BROWSER_HOME_URL=${BROWSER_HOME_URL:-"https://www.bing.com"}
CHROME_DEBUG_PORT=${CHROME_DEBUG_PORT:-9222}
BROWSER_DATA_DIR=${BROWSER_DATA_DIR:-"./data"}

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[HDMI Chrome]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[HDMI Chrome]${NC} $1"
}

error() {
  echo -e "${RED}[HDMI Chrome]${NC} $1" >&2
}

# 等待后端服务就绪
wait_for_server() {
  log "等待后端服务启动..."
  local max_attempts=30
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    if curl -s http://localhost:8088/api/url > /dev/null 2>&1; then
      log "后端服务已就绪"
      return 0
    fi
    
    warn "等待后端服务... ($attempt/$max_attempts)"
    sleep 1
    attempt=$((attempt + 1))
  done
  
  error "后端服务启动超时"
  return 1
}

# 检查 GPU 状态
check_gpu() {
  log "检查 GPU 状态..."
  
  # 检查 GPU 设备
  if [ -d "/dev/dri" ]; then
    log "GPU 设备: /dev/dri 存在"
    ls -la /dev/dri/
  else
    warn "GPU 设备: /dev/dri 不存在"
  fi
  
  # 检查 VA-API
  if command -v vainfo &> /dev/null; then
    log "VA-API 信息:"
    vainfo 2>&1 | head -20
  else
    warn "vainfo 未安装"
  fi
  
  # 检查 NVIDIA GPU
  if command -v nvidia-smi &> /dev/null; then
    log "NVIDIA GPU 信息:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
  fi
}

# 创建 Chrome 用户数据目录
CHROME_USER_DATA_DIR="${BROWSER_DATA_DIR}/chrome-profile"
mkdir -p "${CHROME_USER_DATA_DIR}/Default"

# 清理旧的锁文件
log "清理 Chrome 锁文件..."
rm -f \
  "${CHROME_USER_DATA_DIR}/SingletonLock" \
  "${CHROME_USER_DATA_DIR}/SingletonCookie" \
  "${CHROME_USER_DATA_DIR}/SingletonSocket"

# 创建 Chrome 配置
cat > "${CHROME_USER_DATA_DIR}/Default/Preferences" <<'EOF'
{
  "browser": {
    "check_default_browser": false,
    "show_upgrade_promo": false
  },
  "distribution": {
    "import_bookmarks": false,
    "import_history": false,
    "import_home_page": false,
    "import_search_engine": false,
    "make_chrome_default_for_user": false,
    "show_welcome_page": false,
    "skip_first_run_ui": true
  },
  "profile": {
    "exit_type": "Normal",
    "exited_cleanly": true
  },
  "session": {
    "restore_on_startup": 4,
    "startup_urls": []
  }
}
EOF

# 检查 GPU
check_gpu

# Chrome 启动参数（启用 GPU 硬件加速）
CHROME_ARGS=(
  # Kiosk 模式
  "--kiosk"
  "--noerrdialogs"
  "--disable-infobars"
  "--disable-session-crashed-bubble"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-sync"
  
  # 远程调试
  "--remote-debugging-port=${CHROME_DEBUG_PORT}"
  "--remote-debugging-address=0.0.0.0"
  
  # GPU 硬件加速
  "--enable-gpu"
  "--enable-gpu-rasterization"
  "--enable-features=VaapiVideoDecoder"
  "--enable-features=VaapiVideoEncoder"
  "--enable-features=VaapiVideoDecodeLinuxGL"
  "--enable-features=PlatformHEVCDecoderSupport"
  "--enable-features=PlatformHEVCEncoderSupport"
  "--enable-features=PlatformHEVCDecoderSupport"
  "--disable-features=UseChromeOSDirectVideoDecoder"
  "--enable-zero-copy"
  "--enable-hardware-overlays"
  "--enable-smooth-scrolling"
  
  # 渲染优化
  "--use-gl=egl"
  "--ozone-platform=wayland"
  "--in-process-gpu"
  "--disable-gpu-sandbox"
  "--enable-webgl"
  "--ignore-gpu-blocklist"
  "--disable-gpu-driver-bug-workarounds"
  
  # 视频解码优化
  "--enable-accelerated-video-decode"
  "--enable-accelerated-mjpeg-decode"
  "--enable-accelerated-2d-canvas"
  "--use-vulkan"
  "--enable-vulkan"
  
  # 内存优化
  "--disable-dev-shm-usage"
  "--disable-software-rasterizer"
  "--js-flags=--max-old-space-size=4096"
  
  # 媒体优化
  "--autoplay-policy=no-user-gesture-required"
  "--enable-features=PlatformEncryptedDolbyVision"
  "--enable-features=PlatformEncryptedHEVC"
  
  # 安全相关
  "--disable-web-security"
  "--allow-running-insecure-content"
  
  # 性能监控
  "--enable-logging"
  "--v=1"
)

log "启动 Chrome..."
log "用户数据目录: ${CHROME_USER_DATA_DIR}"
log "首页: ${BROWSER_HOME_URL}"
log "调试端口: ${CHROME_DEBUG_PORT}"

# 启动 Chrome
google-chrome \
  --user-data-dir="${CHROME_USER_DATA_DIR}" \
  "${CHROME_ARGS[@]}" \
  "${BROWSER_HOME_URL}" &

CHROME_PID=$!
log "Chrome 已启动 (PID: ${CHROME_PID})"

# 等待 Chrome 启动
sleep 3

# 检查 Chrome 是否在运行
if ! kill -0 $CHROME_PID 2>/dev/null; then
  error "Chrome 启动失败"
  exit 1
fi

log "Chrome 启动成功"
log "访问地址: http://localhost:${BROWSER_PORT:-8088}"
log "调试地址: http://localhost:${CHROME_DEBUG_PORT}"

# 等待进程结束
wait $CHROME_PID
