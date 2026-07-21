# HDMI Chrome Browser

基于 Chrome 的 HDMI 浏览器输出系统，支持远程控制和屏幕镜像。

## 功能特性

### PC 端
- **屏幕镜像**：实时查看电视画面
- **WebSocket 推流**：1–30 FPS 可调
- **画质调节**：JPEG 压缩 10–100%
- **GPU 信息**：查看硬件加速状态
- **全屏模式**：按 F 键切换

### 手机端
- **触摸板**：模拟鼠标移动
- **虚拟键盘**：26 键 + 特殊键
- **手势控制**：
  - 单指滑动 = 移动鼠标
  - 单击 = 左键
  - 长按 = 右键
  - 双指滑动 = 滚动
- **灵敏度调节**：0.5x–3x
- **振动反馈**：可开关

### GPU 硬件加速
- **VA-API**：Linux 硬件解码
- **Vulkan**：现代图形 API
- **H.264 / H.265 硬解**：Chrome 完整支持

## 快速开始

### 1. Docker 部署（推荐）

本地构建：

```bash
docker compose up -d --build
docker compose logs -f
```

或拉取 GHCR 镜像（`main` 推送后由 Actions 自动发布）：

```bash
docker pull ghcr.io/yccci/hdmi_chrome:latest
# 私有包需先登录：echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
```

访问：

```
PC / 手机:  http://<host>:8088   # 按 UA 自动分流镜像页 / 触控页
DevTools:   http://<host>:9222
```

> Compose 使用 `network_mode: host`，便于本机 HDMI 与 DevTools 访问。  
> 镜像仅构建 `linux/amd64`（依赖 Google Chrome deb）。

### 2. 本地开发

```bash
npm install
npm run dev              # 后端 :8088
npm run start:chrome     # 另开终端启动 Chrome Kiosk
```

### 3. 校验与构建

```bash
npm run verify           # typecheck + esbuild
npm start                # 运行 dist/server/index.js
```

## GPU 配置

### 检查 GPU 状态

```bash
ls -la /dev/dri/
vainfo
nvidia-smi   # 如使用 NVIDIA
```

### Docker GPU

AMD / Intel：确保映射 `/dev/dri`（已在 `docker-compose.yaml` 中）。

NVIDIA：可在 Compose 中增加 `runtime: nvidia`，并保留：

```yaml
environment:
  - NVIDIA_VISIBLE_DEVICES=all
  - NVIDIA_DRIVER_CAPABILITIES=all
```

### Chrome GPU 参数

启动参数已包含（见 `scripts/start-chrome.sh` / 服务端 `ChromeProcessManager`）：

- `--enable-gpu` / `--enable-gpu-rasterization`
- `--enable-features=VaapiVideoDecoder,VaapiVideoEncoder`
- `--enable-zero-copy` / `--use-gl=egl`
- `--enable-accelerated-video-decode`

## API 接口

### 导航

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/url` | GET | 获取当前 URL |
| `/api/url` | POST | 设置新 URL |
| `/api/back` | POST | 后退 |
| `/api/forward` | POST | 前进 |
| `/api/refresh` | POST | 刷新 |
| `/api/home` | POST | 首页 |

### 鼠标

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/mouse/move` | POST | 移动鼠标 |
| `/api/mouse/click` | POST | 鼠标点击 |
| `/api/mouse/scroll` | POST | 鼠标滚轮 |

### 键盘

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/keyboard/key` | POST | 按键 |
| `/api/keyboard/type` | POST | 输入文本 |

### 系统

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/chrome/restart` | POST | 重启 Chrome |
| `/api/screenshot` | GET | 截图 |
| `/api/gpu/info` | GET | GPU 信息 |
| `/api/mirror/settings` | POST | 推流设置 `{ fps, quality }` |

### WebSocket

| 路径 | 说明 |
|------|------|
| `/ws/mirror` | 屏幕镜像 JPEG 帧推流 |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BROWSER_PORT` | `8088` | Web 控制界面端口 |
| `CHROME_DEBUG_PORT` | `9222` | Chrome DevTools 端口 |
| `BROWSER_HOME_URL` | `https://www.bing.com` | 首页 URL |
| `BROWSER_DATA_DIR` | `./data`（容器内 `/app/data`） | 数据 / Chrome profile |
| `DISPLAY` | `:0` | X11 / 显示 |
| `ENABLE_KIOSK` | `true` | 容器内是否启动 Chrome |

## 故障排查

### Chrome 无法启动

```bash
which google-chrome
ls -la /dev/dri/
docker compose logs hdmi-chrome-browser
```

### GPU 未启用

访问 `chrome://gpu`，确认 Video Decode / WebGL 为 Hardware accelerated。

### 无法连接 Chrome

```bash
curl http://localhost:9222/json
```

### 屏幕镜像卡顿

```bash
curl -X POST http://localhost:8088/api/mirror/settings \
  -H "Content-Type: application/json" \
  -d '{"fps": 5, "quality": 30}'
```

## 项目结构

```
hdmi-chrome-browser/
├── src/
│   ├── server/
│   │   └── index.ts              # Fastify + CDP 控制 + 镜像推流 + 内嵌 UI
│   └── public/
│       ├── pc-mirror.html        # PC 屏幕镜像页
│       ├── mobile-control.html   # 手机触控页
│       └── index.html            # 可选简易静态页（开发参考）
├── scripts/
│   ├── start-chrome.sh           # Chrome Kiosk 启动（GPU 参数）
│   ├── container-entrypoint.sh   # 容器：后端 + Chrome
│   └── copy-public.mjs           # 构建时复制 public → dist/public
├── Dockerfile
├── docker-compose.yaml
├── package.json
└── README.md
```

## 开发说明

核心逻辑在 `src/server/index.ts`，页面模板在 `src/public/*.html`：

1. `ChromeController`：连接 `CHROME_DEBUG_PORT`，通过 CDP 发命令
2. `ScreenMirrorStream`：定时截图，经 `/ws/mirror` 广播
3. `startServer()`：REST API + UA 分流（加载 `pc-mirror.html` / `mobile-control.html`）

添加 API：

```typescript
app.post('/api/new-feature', async () => {
  return { ok: true };
});
```

## 许可证

MIT License
