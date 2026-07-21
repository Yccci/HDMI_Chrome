FROM node:22-slim

LABEL org.opencontainers.image.source="https://github.com/Yccci/HDMI_Chrome"
LABEL org.opencontainers.image.description="HDMI Chrome Browser - Chrome kiosk with remote control"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /app

# 运行时、Chrome、Weston(DRM Kiosk) 依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    curl \
    fonts-liberation \
    fontconfig \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    xdg-utils \
    libxss1 \
    libva2 \
    libva-drm2 \
    libva-x11-2 \
    libvdpau1 \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    libgl1-mesa-dri \
    vainfo \
    weston \
    seatd \
    xvfb \
    x11-utils \
    libwayland-client0 \
    libwayland-cursor0 \
    libwayland-egl1 \
    libwayland-server0 \
    procps \
    && rm -rf /var/lib/apt/lists/*

# 安装 Google Chrome
RUN wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
COPY scripts ./scripts

RUN npm run build \
    && npm prune --omit=dev \
    && chmod +x scripts/container-entrypoint.sh scripts/start-chrome.sh scripts/start-weston.sh scripts/start-xvfb.sh scripts/copy-public.mjs

EXPOSE 8088 9222

ENV NODE_ENV=production \
    BROWSER_PORT=8088 \
    CHROME_DEBUG_PORT=9222 \
    BROWSER_HOME_URL=https://www.bing.com \
    BROWSER_DATA_DIR=/app/data \
    BROWSER_MANAGE_CHROME=true \
    DISPLAY_MODE=auto \
    XDG_RUNTIME_DIR=/tmp/runtime-root

CMD ["./scripts/container-entrypoint.sh"]
