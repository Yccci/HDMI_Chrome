#!/bin/bash
# HDMI Chrome Browser 容器入口脚本

set -e

# 配置参数
BROWSER_PORT=${BROWSER_PORT:-8088}
CHROME_DEBUG_PORT=${CHROME_DEBUG_PORT:-9222}
BROWSER_HOME_URL=${BROWSER_HOME_URL:-"https://www.bing.com"}
BROWSER_DATA_DIR=${BROWSER_DATA_DIR:-"/app/data"}

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

# 创建数据目录
mkdir -p "${BROWSER_DATA_DIR}"

log "=========================================="
log "  HDMI Chrome Browser 启动"
log "=========================================="
log ""
log "Web 控制界面: http://localhost:${BROWSER_PORT}"
log "Chrome 调试: http://localhost:${CHROME_DEBUG_PORT}"
log "首页: ${BROWSER_HOME_URL}"
log "数据目录: ${BROWSER_DATA_DIR}"
log ""

# 设置环境变量
export BROWSER_PORT
export CHROME_DEBUG_PORT
export BROWSER_HOME_URL
export BROWSER_DATA_DIR

# 启动后端服务
log "启动后端服务..."
cd /app
node dist/server/index.js &
SERVER_PID=$!

# 等待后端服务启动
sleep 2

# 检查后端服务是否在运行
if ! kill -0 $SERVER_PID 2>/dev/null; then
  error "后端服务启动失败"
  exit 1
fi

log "后端服务已启动 (PID: ${SERVER_PID})"

# 启动 Chrome
ENABLE_KIOSK=${ENABLE_KIOSK:-true}

if [ "${ENABLE_KIOSK}" = "true" ] || [ -n "${DISPLAY}" ]; then
  log "启动 Chrome Kiosk 模式..."
  bash scripts/start-chrome.sh &
  CHROME_PID=$!
  
  # 等待 Chrome 启动
  sleep 3
  
  # 检查 Chrome 是否在运行
  if ! kill -0 $CHROME_PID 2>/dev/null; then
    warn "Chrome 启动失败，但后端服务仍在运行"
  else
    log "Chrome 已启动 (PID: ${CHROME_PID})"
  fi
fi

log ""
log "=========================================="
log "  HDMI Chrome Browser 启动完成"
log "=========================================="
log ""
log "访问地址: http://localhost:${BROWSER_PORT}"
log ""

# 信号处理
cleanup() {
  log "收到退出信号，正在关闭..."
  
  # 关闭 Chrome
  if [ -n "${CHROME_PID}" ]; then
    kill ${CHROME_PID} 2>/dev/null || true
    wait ${CHROME_PID} 2>/dev/null || true
  fi
  
  # 关闭后端服务
  if [ -n "${SERVER_PID}" ]; then
    kill ${SERVER_PID} 2>/dev/null || true
    wait ${SERVER_PID} 2>/dev/null || true
  fi
  
  log "已关闭所有服务"
  exit 0
}

# 注册信号处理
trap cleanup SIGINT SIGTERM

# 等待进程结束
wait
