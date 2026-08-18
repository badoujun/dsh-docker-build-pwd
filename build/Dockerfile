# DeepSeek Harness + dsh-passwords 网关一体化镜像
# 基于 bakeroot/deepseek-harness-docker + slywalker2006/dsh-passwords
#
# 架构:
#   dsh web          监听容器内 3080 (loopback only, 由 dsh-passwords 反代)
#   dsh-passwords    插件加载时自动 spawn serve-gateway 子进程, 监听 443 (HTTPS)
#                    + 80 (301 跳转, 用自签证书时自动关掉)
#
# 端口映射:
#   443:443  HTTPS 入口 (dsh-passwords 网关)
#   80:80    HTTP 跳转 (自签证书模式下被关掉)

# === 1. 基础镜像 ===
ARG BASE_IMAGE=node:22-bookworm
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# === 2. 系统依赖 ===
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
        python3 \
        python3-venv \
        build-essential \
        openssl \
    && rm -rf /var/lib/apt/lists/*

# === 3. 安装官方 dsh CLI + pnpm (国内镜像) ===
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG DSH_VERSION=0.1.0-rc.6
RUN npm config set registry ${NPM_REGISTRY} \
    && npm install -g @deepseek-ai/dsh@${DSH_VERSION} \
    && npm install -g pnpm \
    && dsh --version && pnpm --version

# === 4. 编译 dsh-passwords ===
COPY dsh-passwords /opt/dsh-passwords
WORKDIR /opt/dsh-passwords
RUN npm config set registry ${NPM_REGISTRY} \
    && npm install --no-audit --no-fund \
    && npm run build \
    && test -f dist/cli.js && echo "[build] dsh-passwords built OK"

# === 5. 生成 dsh-passwords .env (随机 SETUP_KEY + DB 加密密钥) ===
# install.sh 走 scripts/install.mjs, 它要求 dsh 已全局装 + pnpm 装 + profile 注册
# 这里只生成 .env; profile 注册 (link) 放到 entrypoint.sh 首次启动时做
COPY build-env.sh /tmp/build-env.sh
RUN bash /tmp/build-env.sh

# === 6. 生成 setup-key.txt (从 .env 读取 SETUP_KEY) ===
COPY build-setup-key.sh /tmp/build-setup-key.sh
RUN bash /tmp/build-setup-key.sh

# === 7. dsh state + 工作区目录 ===
ENV DSH_HOME=/data/dsh-home
RUN mkdir -p /data/dsh-home /app/workspace /opt/dsh-passwords/data /opt/dsh-passwords/certs

# dsh 把 startup 目录当作默认 workspace
WORKDIR /app/workspace

# === 8. 应用远程设置补丁 (强制, 幂等) ===
RUN node /opt/dsh-passwords/dist/cli.js patch || echo "[build] patch will retry at first dsh start"

# === 9. entrypoint ===
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# === 10. 健康检查 ===
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsSk https://127.0.0.1:443/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]