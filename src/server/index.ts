import Fastify from 'fastify';
import { spawn, type ChildProcess } from 'child_process';
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } from 'fs';
import { join } from 'path';
import { WebSocketServer, WebSocket } from 'ws';

interface BrowserConfig {
  port: number;
  homeUrl: string;
  chromePort: number;
  dataDir: string;
  manageChrome: boolean;
  chromeBin: string;
}

function loadConfig(): BrowserConfig {
  const port = Number(process.env.BROWSER_PORT ?? "8088");
  const chromePort = Number(process.env.CHROME_DEBUG_PORT ?? "9222");
  const manageChrome = !['0', 'false', 'no'].includes(
    (process.env.BROWSER_MANAGE_CHROME ?? 'true').toLowerCase()
  );

  return {
    port,
    homeUrl: process.env.BROWSER_HOME_URL ?? "https://www.bing.com",
    chromePort,
    dataDir: process.env.BROWSER_DATA_DIR ?? "./data",
    manageChrome,
    chromeBin: process.env.CHROME_BIN ?? "google-chrome"
  };
}

function resolveOzonePlatform(): string {
  if (process.env.CHROME_OZONE_PLATFORM) {
    return process.env.CHROME_OZONE_PLATFORM;
  }
  if (process.env.WAYLAND_DISPLAY) {
    return 'wayland';
  }
  return 'x11';
}

function buildChromeArgs(config: BrowserConfig, targetUrl: string): string[] {
  const ozone = resolveOzonePlatform();
  const enableGpu = !['0', 'false', 'no'].includes(
    (process.env.CHROME_ENABLE_GPU ?? 'true').toLowerCase()
  );

  const args = [
    '--kiosk',
    '--noerrdialogs',
    '--disable-infobars',
    '--disable-session-crashed-bubble',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-sync',
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--disable-dev-shm-usage',
    `--remote-debugging-port=${config.chromePort}`,
    '--remote-debugging-address=0.0.0.0',
    `--ozone-platform=${ozone}`,
    '--window-size=1920,1080',
    '--autoplay-policy=no-user-gesture-required',
    '--ignore-gpu-blocklist',
  ];

  if (ozone === 'wayland') {
    args.push('--enable-features=UseOzonePlatform');
  }

  if (enableGpu) {
    args.push(
      '--enable-gpu',
      '--enable-gpu-rasterization',
      '--disable-gpu-sandbox',
      '--in-process-gpu',
      '--enable-features=VaapiVideoDecoder,VaapiVideoEncoder,VaapiVideoDecodeLinuxGL,CanvasOopRasterization',
      '--enable-accelerated-video-decode',
      '--enable-accelerated-2d-canvas',
      '--use-gl=egl',
      '--use-angle=gl-egl'
    );
  } else {
    args.push('--disable-gpu', '--use-gl=swiftshader');
  }

  args.push(targetUrl);
  return args;
}

// 检测是否是移动设备
function isMobileDevice(userAgent: string): boolean {
  const mobileKeywords = [
    'Android', 'iPhone', 'iPad', 'iPod', 'Windows Phone', 
    'BlackBerry', 'Opera Mini', 'Mobile', 'mobile'
  ];
  return mobileKeywords.some(keyword => userAgent.includes(keyword));
}

// Chrome DevTools Protocol 客户端
class ChromeController {
  private ws: WebSocket | null = null;
  private currentUrl: string;
  private config: BrowserConfig;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private messageId = 0;
  private pendingCallbacks = new Map<number, (result: any) => void>();

  constructor(config: BrowserConfig) {
    this.config = config;
    this.currentUrl = config.homeUrl;
  }

  private cursorX = 100;
  private cursorY = 100;
  private viewportWidth = 1920;
  private viewportHeight = 1080;

  getCursorPosition(): { x: number; y: number } {
    return { x: this.cursorX, y: this.cursorY };
  }

  async connect(): Promise<void> {
    try {
      if (this.ws) {
        try { this.ws.close(); } catch { /* ignore */ }
        this.ws = null;
      }

      const response = await fetch(`http://127.0.0.1:${this.config.chromePort}/json`);
      const targets = await response.json() as Array<{ type: string; webSocketDebuggerUrl?: string }>;

      const pageTarget = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      if (!pageTarget?.webSocketDebuggerUrl) {
        throw new Error('No page target found');
      }

      await new Promise<void>((resolve, reject) => {
        const ws = new WebSocket(pageTarget.webSocketDebuggerUrl!);
        const timer = setTimeout(() => {
          try { ws.close(); } catch { /* ignore */ }
          reject(new Error('CDP websocket connect timeout'));
        }, 10000);

        ws.onopen = () => {
          clearTimeout(timer);
          this.ws = ws;
          console.log('Connected to Chrome');
          this.clearReconnect();
          resolve();
        };

        ws.onmessage = (event) => {
          const data = JSON.parse(String(event.data));
          if (data.id && this.pendingCallbacks.has(data.id)) {
            const callback = this.pendingCallbacks.get(data.id);
            callback?.(data.result);
            this.pendingCallbacks.delete(data.id);
          }
        };

        ws.onclose = () => {
          console.log('Disconnected from Chrome');
          this.ws = null;
          this.scheduleReconnect();
        };

        ws.onerror = (error) => {
          clearTimeout(timer);
          console.error('Chrome WebSocket error:', error);
          reject(new Error('CDP websocket error'));
        };
      });

      await this.sendCommand('Page.enable', {});
      await this.sendCommand('Runtime.enable', {});
      await this.installCursorOverlay();
      await this.refreshViewportSize();
    } catch (error) {
      console.error('Failed to connect to Chrome:', error);
      this.scheduleReconnect();
    }
  }

  private cursorOverlayScript(): string {
    return `(() => {
      const ID = '__hdmi_cursor_overlay';
      if (document.getElementById(ID)) return true;
      const style = document.createElement('style');
      style.textContent = \`
        #\${ID} {
          position: fixed !important;
          width: 22px !important;
          height: 22px !important;
          margin-left: -3px !important;
          margin-top: -3px !important;
          border: 2px solid #fff !important;
          border-radius: 50% !important;
          background: rgba(255, 64, 64, 0.85) !important;
          box-shadow: 0 0 0 1px rgba(0,0,0,.6), 0 0 8px rgba(255,64,64,.8) !important;
          pointer-events: none !important;
          z-index: 2147483647 !important;
          left: 0; top: 0;
          transform: translate(-50%, -50%);
        }
        #\${ID}::after {
          content: '';
          position: absolute;
          left: 50%; top: 50%;
          width: 2px; height: 2px;
          background: #fff;
          transform: translate(-50%, -50%);
        }
      \`;
      const dot = document.createElement('div');
      dot.id = ID;
      const root = document.documentElement;
      (document.head || root).appendChild(style);
      root.appendChild(dot);
      window.__hdmiCursor = {
        set(x, y) {
          dot.style.left = x + 'px';
          dot.style.top = y + 'px';
        }
      };
      return true;
    })()`;
  }

  async installCursorOverlay(): Promise<void> {
    try {
      await this.sendCommand('Page.addScriptToEvaluateOnNewDocument', {
        source: this.cursorOverlayScript()
      });
      await this.sendCommand('Runtime.evaluate', {
        expression: this.cursorOverlayScript(),
        returnByValue: true
      });
      await this.updateCursorOverlay();
    } catch (error) {
      console.error('installCursorOverlay failed:', error);
    }
  }

  async refreshViewportSize(): Promise<void> {
    try {
      const size = await this.getPageSize();
      if (size.width > 0 && size.height > 0) {
        this.viewportWidth = size.width;
        this.viewportHeight = size.height;
      }
    } catch {
      // keep defaults
    }
  }

  private clampCursor(x: number, y: number): { x: number; y: number } {
    return {
      x: Math.max(0, Math.min(this.viewportWidth - 1, Math.round(x))),
      y: Math.max(0, Math.min(this.viewportHeight - 1, Math.round(y)))
    };
  }

  async updateCursorOverlay(): Promise<void> {
    try {
      await this.sendCommand('Runtime.evaluate', {
        expression: `window.__hdmiCursor && window.__hdmiCursor.set(${this.cursorX}, ${this.cursorY})`,
        returnByValue: true
      });
    } catch {
      // page may be navigating
    }
  }

  async setCursorAbsolute(x: number, y: number): Promise<void> {
    const next = this.clampCursor(x, y);
    this.cursorX = next.x;
    this.cursorY = next.y;
    await this.mouseMove(this.cursorX, this.cursorY);
    await this.updateCursorOverlay();
  }

  async moveCursorBy(dx: number, dy: number): Promise<void> {
    await this.setCursorAbsolute(this.cursorX + dx, this.cursorY + dy);
  }

  private scheduleReconnect(): void {
    if (!this.reconnectTimer) {
      this.reconnectTimer = setTimeout(() => {
        this.reconnectTimer = null;
        this.connect();
      }, 2000);
    }
  }

  private clearReconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private sendCommand(method: string, params: any = {}): Promise<any> {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
        reject(new Error('Not connected to Chrome'));
        return;
      }

      const id = ++this.messageId;
      this.pendingCallbacks.set(id, resolve);

      this.ws.send(JSON.stringify({
        id,
        method,
        params
      }));

      setTimeout(() => {
        if (this.pendingCallbacks.has(id)) {
          this.pendingCallbacks.delete(id);
          reject(new Error('Command timeout'));
        }
      }, 10000);
    });
  }

  async navigate(url: string): Promise<void> {
    this.currentUrl = url;
    await this.sendCommand('Page.navigate', { url });
    setTimeout(() => {
      void this.installCursorOverlay();
      void this.refreshViewportSize();
    }, 800);
  }

  async refresh(): Promise<void> {
    await this.sendCommand('Page.reload');
  }

  async goBack(): Promise<void> {
    await this.sendCommand('Page.goBack');
  }

  async goForward(): Promise<void> {
    await this.sendCommand('Page.goForward');
  }

  getCurrentUrl(): string {
    return this.currentUrl;
  }

  // 截图
  async captureScreenshot(format: 'jpeg' | 'png' = 'jpeg', quality: number = 60): Promise<string> {
    const result = await this.sendCommand('Page.captureScreenshot', {
      format,
      quality,
      optimizeForSpeed: true
    });
    return result.data; // base64 编码的图片
  }

  // 获取页面尺寸
  async getPageSize(): Promise<{ width: number; height: number }> {
    const result = await this.sendCommand('Runtime.evaluate', {
      expression: 'JSON.stringify({ width: window.innerWidth, height: window.innerHeight })'
    });
    return JSON.parse(result.result.value);
  }

  // 获取 GPU 信息
  async getGpuInfo(): Promise<Record<string, unknown>> {
    const result = await this.sendCommand('Runtime.evaluate', {
      expression: `
        (() => {
          const info = {
            gpuRenderer: null,
            gpuVendor: null,
            webglVersion: null,
            hardwareAccelerated: false,
            glBackend: null
          };
          try {
            const canvas = document.createElement('canvas');
            const gl = canvas.getContext('webgl2') || canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
            if (gl) {
              const debugInfo = gl.getExtension('WEBGL_debug_renderer_info');
              if (debugInfo) {
                info.gpuRenderer = gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL);
                info.gpuVendor = gl.getParameter(debugInfo.UNMASKED_VENDOR_WEBGL);
              }
              info.webglVersion = gl.getParameter(gl.VERSION);
              info.glBackend = gl.getParameter(gl.RENDERER);
              const label = String(info.gpuRenderer || info.glBackend || '');
              info.hardwareAccelerated = !/swiftshader|llvmpipe|softpipe|microsoft basic render|cpu/i.test(label);
            }
          } catch (e) {
            info.error = String(e);
          }
          return JSON.stringify(info);
        })()
      `,
      returnByValue: true
    });
    const value = result?.result?.value;
    return typeof value === 'string' ? JSON.parse(value) : (value ?? {});
  }

  // 鼠标移动
  async mouseMove(x: number, y: number): Promise<void> {
    const nx = Math.round(x);
    const ny = Math.round(y);
    await this.sendCommand('Input.dispatchMouseEvent', {
      type: 'mouseMoved',
      x: nx,
      y: ny,
      button: 'none',
      buttons: 0,
      clickCount: 0,
      pointerType: 'mouse'
    });
  }

  // 鼠标按下
  async mouseDown(x: number, y: number, button: 'left' | 'right' | 'middle' = 'left'): Promise<void> {
    const buttons = button === 'left' ? 1 : button === 'right' ? 2 : 4;
    await this.sendCommand('Input.dispatchMouseEvent', {
      type: 'mousePressed',
      x: Math.round(x),
      y: Math.round(y),
      button,
      buttons,
      clickCount: 1,
      pointerType: 'mouse'
    });
  }

  // 鼠标释放
  async mouseUp(x: number, y: number, button: 'left' | 'right' | 'middle' = 'left'): Promise<void> {
    await this.sendCommand('Input.dispatchMouseEvent', {
      type: 'mouseReleased',
      x: Math.round(x),
      y: Math.round(y),
      button,
      buttons: 0,
      clickCount: 1,
      pointerType: 'mouse'
    });
  }

  // 鼠标点击
  async mouseClick(x: number, y: number, button: 'left' | 'right' | 'middle' = 'left'): Promise<void> {
    const pos = this.clampCursor(x, y);
    this.cursorX = pos.x;
    this.cursorY = pos.y;
    await this.mouseMove(pos.x, pos.y);
    await this.updateCursorOverlay();
    await this.mouseDown(pos.x, pos.y, button);
    await this.mouseUp(pos.x, pos.y, button);
  }

  // 鼠标滚轮
  async mouseScroll(x: number, y: number, deltaX: number, deltaY: number): Promise<void> {
    await this.sendCommand('Input.dispatchMouseEvent', {
      type: 'mouseWheel',
      x: Math.round(x),
      y: Math.round(y),
      deltaX,
      deltaY,
      pointerType: 'mouse'
    });
  }

  // 键盘输入
  async keyDown(key: string, modifiers: { alt?: boolean; ctrl?: boolean; meta?: boolean; shift?: boolean } = {}): Promise<void> {
    await this.sendCommand('Input.dispatchKeyEvent', {
      type: 'keyDown',
      key,
      code: key,
      ...modifiers
    });
  }

  async keyUp(key: string, modifiers: { alt?: boolean; ctrl?: boolean; meta?: boolean; shift?: boolean } = {}): Promise<void> {
    await this.sendCommand('Input.dispatchKeyEvent', {
      type: 'keyUp',
      key,
      code: key,
      ...modifiers
    });
  }

  async pressKey(key: string, modifiers: { alt?: boolean; ctrl?: boolean; meta?: boolean; shift?: boolean } = {}): Promise<void> {
    await this.keyDown(key, modifiers);
    await this.keyUp(key, modifiers);
  }

  async typeText(text: string): Promise<void> {
    for (const char of text) {
      await this.sendCommand('Input.dispatchKeyEvent', {
        type: 'char',
        text: char
      });
    }
  }

  isConnected(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  close(): void {
    this.clearReconnect();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }
}

// Chrome 进程管理
class ChromeProcessManager {
  private process: ChildProcess | null = null;
  private config: BrowserConfig;

  constructor(config: BrowserConfig) {
    this.config = config;
  }

  private profileDir(): string {
    return join(this.config.dataDir, 'chrome-profile');
  }

  private clearLocks(): void {
    const dir = this.profileDir();
    // SingletonLock 常为指向 hostname-pid 的符号链接；目标进程不存在时
    // existsSync 可能为 false，但仍会挡住新 Chrome —— 必须强制删除
    const lockNames = [
      'SingletonLock',
      'SingletonCookie',
      'SingletonSocket',
      'lockfile',
      'RunningChromeVersion'
    ];
    for (const name of lockNames) {
      const path = join(dir, name);
      try {
        unlinkSync(path);
        console.log(`Cleared Chrome profile lock: ${name}`);
      } catch {
        // 不存在则忽略
      }
    }
  }

  start(url?: string): void {
    if (this.process) {
      this.stop();
    }

    const targetUrl = url || this.config.homeUrl;
    const profileDir = this.profileDir();
    mkdirSync(join(profileDir, 'Default'), { recursive: true });
    this.clearLocks();

    const args = [
      `--user-data-dir=${profileDir}`,
      ...buildChromeArgs(this.config, targetUrl)
    ];

    console.log(`Starting Chrome (${this.config.chromeBin}):`, args.join(' '));
    console.log(`Chrome env DISPLAY=${process.env.DISPLAY ?? ''} WAYLAND_DISPLAY=${process.env.WAYLAND_DISPLAY ?? ''}`);

    this.process = spawn(this.config.chromeBin, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        ...process.env,
        DISPLAY: process.env.DISPLAY ?? '',
        WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY ?? '',
        XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR ?? '/tmp/runtime-root',
        // 减少无 dbus 时的噪音（可选）
        DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS ?? 'unix:path=/dev/null'
      }
    });

    this.process.stdout?.on('data', (chunk: Buffer) => {
      console.log(`[chrome] ${chunk.toString().trimEnd()}`);
    });
    this.process.stderr?.on('data', (chunk: Buffer) => {
      console.error(`[chrome] ${chunk.toString().trimEnd()}`);
    });

    this.process.on('error', (error) => {
      console.error('Chrome process error:', error);
      this.process = null;
    });

    this.process.on('exit', (code, signal) => {
      console.log(`Chrome exited with code ${code} signal ${signal}`);
      this.process = null;
    });
  }

  stop(): void {
    if (this.process) {
      this.process.kill('SIGTERM');
      this.process = null;
    }
  }

  restart(url?: string): void {
    this.stop();
    this.start(url);
  }

  isRunning(): boolean {
    return this.process !== null && this.process.exitCode === null;
  }
}

// 屏幕镜像流管理
class ScreenMirrorStream {
  private chrome: ChromeController;
  private clients: Set<WebSocket> = new Set();
  private isStreaming = false;
  private frameInterval: NodeJS.Timeout | null = null;
  private fps = 10; // 默认 10fps
  private quality = 50; // 默认质量 50

  constructor(chrome: ChromeController) {
    this.chrome = chrome;
  }

  addClient(ws: WebSocket): void {
    this.clients.add(ws);
    
    if (!this.isStreaming) {
      this.startStreaming();
    }

    ws.on('close', () => {
      this.clients.delete(ws);
      if (this.clients.size === 0) {
        this.stopStreaming();
      }
    });
  }

  private startStreaming(): void {
    this.isStreaming = true;
    console.log(`Starting screen mirror stream at ${this.fps}fps`);
    
    this.frameInterval = setInterval(async () => {
      if (!this.chrome.isConnected()) return;
      
      try {
        const screenshot = await this.chrome.captureScreenshot('jpeg', this.quality);
        
        // 发送给所有客户端
        for (const client of this.clients) {
          if (client.readyState === WebSocket.OPEN) {
            client.send(JSON.stringify({
              type: 'frame',
              data: screenshot,
              timestamp: Date.now()
            }));
          }
        }
      } catch (error) {
        console.error('Screenshot error:', error);
      }
    }, 1000 / this.fps);
  }

  private stopStreaming(): void {
    this.isStreaming = false;
    if (this.frameInterval) {
      clearInterval(this.frameInterval);
      this.frameInterval = null;
    }
    console.log('Stopped screen mirror stream');
  }

  setFps(fps: number): void {
    this.fps = Math.max(1, Math.min(30, fps));
    if (this.isStreaming) {
      this.stopStreaming();
      this.startStreaming();
    }
  }

  setQuality(quality: number): void {
    this.quality = Math.max(10, Math.min(100, quality));
  }

  getClientCount(): number {
    return this.clients.size;
  }
}

async function startServer(): Promise<void> {
  const config = loadConfig();
  const app = Fastify({ logger: true });

  if (!existsSync(config.dataDir)) {
    mkdirSync(config.dataDir, { recursive: true });
  }

  const stateFile = join(config.dataDir, 'browser-state.json');
  
  let currentUrl = config.homeUrl;
  if (existsSync(stateFile)) {
    try {
      const state = JSON.parse(readFileSync(stateFile, 'utf8'));
      if (state.url) currentUrl = state.url;
    } catch {}
  }

  function saveState(): void {
    writeFileSync(stateFile, JSON.stringify({ url: currentUrl }));
  }

  const chrome = new ChromeController(config);
  const chromeProcess = new ChromeProcessManager(config);
  const mirrorStream = new ScreenMirrorStream(chrome);

  if (config.manageChrome) {
    chromeProcess.start(currentUrl);
  } else {
    console.log('BROWSER_MANAGE_CHROME=false, waiting for external Chrome on debug port');
  }

  // 等 CDP 端口就绪再连（Chrome 冷启动常超过 2s）
  void (async () => {
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(`http://127.0.0.1:${config.chromePort}/json/version`);
        if (res.ok) break;
      } catch {
        // retry
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
    await chrome.connect();
  })();

  // WebSocket 服务器用于屏幕镜像
  const wss = new WebSocketServer({ noServer: true });

  app.server.on('upgrade', (request, socket, head) => {
    if (request.url === '/ws/mirror') {
      wss.handleUpgrade(request, socket, head, (ws) => {
        mirrorStream.addClient(ws);
      });
    } else {
      socket.destroy();
    }
  });

  // API：获取当前 URL
  app.get('/api/url', async () => ({
    url: chrome.getCurrentUrl() || currentUrl,
    chromeRunning: chromeProcess.isRunning(),
    connected: chrome.isConnected(),
    mirrorClients: mirrorStream.getClientCount()
  }));

  // API：设置新 URL
  app.post<{ Body: { url?: string } }>('/api/url', async (request, reply) => {
    const { url } = request.body;
    
    if (!url || typeof url !== 'string') {
      reply.code(400);
      return { error: 'url is required' };
    }

    try {
      const parsed = new URL(url.startsWith('http') ? url : `https://${url}`);
      currentUrl = parsed.toString();
      saveState();

      try {
        await chrome.navigate(currentUrl);
      } catch (error) {
        chromeProcess.restart(currentUrl);
        setTimeout(() => chrome.connect(), 2000);
      }

      return { ok: true, url: currentUrl };
    } catch {
      reply.code(400);
      return { error: 'Invalid URL' };
    }
  });

  // API：后退
  app.post('/api/back', async () => {
    try {
      await chrome.goBack();
      return { ok: true };
    } catch (error) {
      return { error: 'Failed to go back' };
    }
  });

  // API：前进
  app.post('/api/forward', async () => {
    try {
      await chrome.goForward();
      return { ok: true };
    } catch (error) {
      return { error: 'Failed to go forward' };
    }
  });

  // API：刷新
  app.post('/api/refresh', async () => {
    try {
      await chrome.refresh();
      return { ok: true };
    } catch (error) {
      return { error: 'Failed to refresh' };
    }
  });

  // API：首页
  app.post('/api/home', async () => {
    currentUrl = config.homeUrl;
    saveState();
    
    try {
      await chrome.navigate(currentUrl);
    } catch {
      chromeProcess.restart(currentUrl);
      setTimeout(() => chrome.connect(), 2000);
    }

    return { ok: true, url: currentUrl };
  });

  // API：重启 Chrome
  app.post('/api/chrome/restart', async () => {
    chromeProcess.restart(currentUrl);
    setTimeout(() => chrome.connect(), 2000);
    return { ok: true };
  });

  // API：GPU 信息
  app.get('/api/gpu/info', async () => {
    try {
      const gpuInfo = await chrome.getGpuInfo();
      const driRender =
        existsSync('/dev/dri/renderD128') || existsSync('/dev/dri/renderD129');
      return {
        ...gpuInfo,
        displayMode: process.env.DISPLAY_MODE ?? null,
        chromeEnableGpu: process.env.CHROME_ENABLE_GPU ?? null,
        driRenderNode: driRender,
        note: driRender
          ? '虚拟屏也可使用 /dev/dri/renderD* 做 EGL/VA-API 加速（无需 HDMI connected）'
          : '无 DRM render 节点，只能软渲染'
      };
    } catch (error) {
      return { error: 'Failed to get GPU info' };
    }
  });

  // API：鼠标移动（支持绝对 x/y 或相对 dx/dy）
  app.post<{ Body: { x?: number; y?: number; dx?: number; dy?: number } }>('/api/mouse/move', async (request, reply) => {
    if (!chrome.isConnected()) {
      reply.code(503);
      return { error: 'Chrome not connected' };
    }
    const { x, y, dx, dy } = request.body ?? {};
    try {
      if (typeof dx === 'number' || typeof dy === 'number') {
        await chrome.moveCursorBy(Number(dx) || 0, Number(dy) || 0);
      } else if (typeof x === 'number' && typeof y === 'number') {
        await chrome.setCursorAbsolute(x, y);
      } else {
        reply.code(400);
        return { error: 'Provide x/y or dx/dy' };
      }
      return { ok: true, cursor: chrome.getCursorPosition() };
    } catch (error) {
      reply.code(500);
      return { error: 'Failed to move mouse', detail: String(error) };
    }
  });

  // API：鼠标点击（可省略坐标，点击当前光标位置）
  app.post<{ Body: { x?: number; y?: number; button?: string } }>('/api/mouse/click', async (request, reply) => {
    if (!chrome.isConnected()) {
      reply.code(503);
      return { error: 'Chrome not connected' };
    }
    const { x, y, button = 'left' } = request.body ?? {};
    try {
      const pos = chrome.getCursorPosition();
      const cx = typeof x === 'number' ? x : pos.x;
      const cy = typeof y === 'number' ? y : pos.y;
      await chrome.mouseClick(cx, cy, button as 'left' | 'right' | 'middle');
      return { ok: true, cursor: chrome.getCursorPosition() };
    } catch (error) {
      reply.code(500);
      return { error: 'Failed to click', detail: String(error) };
    }
  });

  // API：鼠标滚轮
  app.post<{ Body: { deltaX?: number; deltaY?: number } }>('/api/mouse/scroll', async (request, reply) => {
    if (!chrome.isConnected()) {
      reply.code(503);
      return { error: 'Chrome not connected' };
    }
    const { deltaX = 0, deltaY = 0 } = request.body ?? {};
    if (typeof deltaX !== 'number' || typeof deltaY !== 'number') {
      reply.code(400);
      return { error: 'deltaX and deltaY are required numbers' };
    }
    try {
      const pos = chrome.getCursorPosition();
      await chrome.mouseScroll(pos.x, pos.y, deltaX, deltaY);
      return { ok: true };
    } catch (error) {
      reply.code(500);
      return { error: 'Failed to scroll', detail: String(error) };
    }
  });

  // API：按键
  app.post<{ Body: { key: string; modifiers?: object } }>('/api/keyboard/key', async (request, reply) => {
    const { key, modifiers = {} } = request.body;
    if (typeof key !== 'string') {
      reply.code(400);
      return { error: 'key is required' };
    }
    
    try {
      await chrome.pressKey(key, modifiers);
      return { ok: true };
    } catch (error) {
      return { error: 'Failed to press key' };
    }
  });

  // API：输入文本
  app.post<{ Body: { text: string } }>('/api/keyboard/type', async (request, reply) => {
    const { text } = request.body;
    if (typeof text !== 'string') {
      reply.code(400);
      return { error: 'text is required' };
    }
    
    try {
      await chrome.typeText(text);
      return { ok: true };
    } catch (error) {
      return { error: 'Failed to type text' };
    }
  });

  // API：截图
  app.get('/api/screenshot', async (request, reply) => {
    try {
      const screenshot = await chrome.captureScreenshot('jpeg', 80);
      reply.type('image/jpeg');
      return Buffer.from(screenshot, 'base64');
    } catch (error) {
      reply.code(500);
      return { error: 'Failed to capture screenshot' };
    }
  });

  // API：设置镜像参数
  app.post<{ Body: { fps?: number; quality?: number } }>('/api/mirror/settings', async (request) => {
    const { fps, quality } = request.body;
    
    if (typeof fps === 'number') {
      mirrorStream.setFps(fps);
    }
    if (typeof quality === 'number') {
      mirrorStream.setQuality(quality);
    }
    
    return { ok: true };
  });

  // 根据设备类型提供不同界面
  app.get('/', async (request, reply) => {
    const userAgent = request.headers['user-agent'] || '';
    const isMobile = isMobileDevice(userAgent);
    
    console.log(`User Agent: ${userAgent}`);
    console.log(`Is Mobile: ${isMobile}`);
    
    if (isMobile) {
      // 手机：显示控制界面
      reply.type('text/html').send(getMobileControlHtml(currentUrl));
    } else {
      // PC：显示屏幕镜像
      reply.type('text/html').send(getPCMirrorHtml(currentUrl));
    }
  });

  await app.listen({ host: '0.0.0.0', port: config.port });
  
  app.log.info({
    port: config.port,
    chromePort: config.chromePort,
    homeUrl: config.homeUrl
  }, 'Browser server started');

  const shutdown = () => {
    chrome.close();
    chromeProcess.stop();
    process.exit(0);
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

// PC 屏幕镜像界面
function loadHtmlTemplate(name: string, currentUrl: string): string {
  const htmlDir = join(process.cwd(), 'src/public');
  const distDir = join(process.cwd(), 'dist/public');
  const filePath = existsSync(join(distDir, name))
    ? join(distDir, name)
    : join(htmlDir, name);
  const raw = readFileSync(filePath, 'utf8');
  return raw.split('{{CURRENT_URL}}').join(currentUrl);
}

function getPCMirrorHtml(currentUrl: string): string {
  return loadHtmlTemplate('pc-mirror.html', currentUrl);
}

function getMobileControlHtml(currentUrl: string): string {
  return loadHtmlTemplate('mobile-control.html', currentUrl);
}

startServer().catch(console.error);

