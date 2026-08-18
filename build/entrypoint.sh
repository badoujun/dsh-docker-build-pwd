#!/bin/bash
# DeepSeek Harness + dsh-passwords 网关入口
#
# 重要: dsh-passwords 作为 dsh 插件, 在 dsh 启动时会自动 spawn serve-gateway 子进程
# (见 dsh-passwords/src/plugin.ts:startGateway())
# 所以本 entrypoint **不直接启 serve-gateway**, 否则端口冲突.
#
# 启动顺序:
#   1. 加载挂载的自签证书 -> 写入 dsh-passwords .env
#   2. 首次启动: 注册 dsh-passwords 插件 (link 到 ~/.dsh/profiles/web)
#   3. 启动 dsh web (dsh-passwords 插件加载时自动 spawn serve-gateway 子进程)
#   4. dsh 是前台进程, 它 fork 的 serve-gateway 会自动跟随 dsh 退出
set -uo pipefail

DSH_PW_DIR="/opt/dsh-passwords"
DSH_PW_BIN="$DSH_PW_DIR/dist/cli.js"

echo "[entrypoint] starting DeepSeek Harness + dsh-passwords gateway"
echo "[entrypoint] DSH_HOME=$DSH_HOME"
echo "[entrypoint] dsh-passwords dir=$DSH_PW_DIR"

# ──────────────────────────────────────────────────────────────
# 1. 加载挂载的自签证书 (如存在) -> 写入 dsh-passwords .env
# ──────────────────────────────────────────────────────────────
TLS_CERT_IN="/certs/cert.pem"
TLS_KEY_IN="/certs/key.pem"
if [ -f "$TLS_CERT_IN" ] && [ -f "$TLS_KEY_IN" ]; then
    echo "[entrypoint] using mounted self-signed cert: $TLS_CERT_IN"
    # 删除旧条目再追加 (避免重复)
    sed -i '/^MCP_GATEWAY_TLS_CERT=/d; /^MCP_GATEWAY_TLS_KEY=/d' "$DSH_PW_DIR/.env"
    printf 'MCP_GATEWAY_TLS_CERT=%s\nMCP_GATEWAY_TLS_KEY=%s\n' "$TLS_CERT_IN" "$TLS_KEY_IN" >> "$DSH_PW_DIR/.env"
    chmod 600 "$DSH_PW_DIR/.env"
    # 既然用自备证书, 关掉 80 端口的 ACME 跳转 (避免端口浪费)
    sed -i '/^MCP_GATEWAY_REDIRECT_PORT=/d' "$DSH_PW_DIR/.env"
    echo 'MCP_GATEWAY_REDIRECT_PORT=' >> "$DSH_PW_DIR/.env"
else
    echo "[entrypoint] no mounted cert, will auto-generate self-signed on first run"
fi

# ──────────────────────────────────────────────────────────────
# 2. 首次启动: 把 dsh-passwords 注册为 dsh web profile 的 link 依赖
# ──────────────────────────────────────────────────────────────
PROFILE_DIR="$DSH_HOME/profiles/web"
mkdir -p "$PROFILE_DIR"

PROFILE_PKG="$PROFILE_DIR/package.json"
if [ ! -f "$PROFILE_PKG" ] || ! grep -q '"dsh-passwords"' "$PROFILE_PKG" 2>/dev/null; then
    echo "[entrypoint] first boot: registering dsh-passwords plugin into web profile"
    if ! node "$DSH_PW_DIR/scripts/register-plugin.mjs"; then
        echo "[entrypoint] WARN: plugin registration failed"
    fi
else
    echo "[entrypoint] dsh-passwords already linked in profile"
fi

# ──────────────────────────────────────────────────────────────
# 3. 应用远程设置补丁 (强制, 幂等)
# ──────────────────────────────────────────────────────────────
echo "[entrypoint] applying remote settings patch"
node "$DSH_PW_BIN" patch || echo "[entrypoint] patch step failed (non-fatal)"

# ──────────────────────────────────────────────────────────────
# 4. 启动 dsh (前台)
# ──────────────────────────────────────────────────────────────
# dsh 启动后会自动加载 dsh-passwords 插件
# 插件加载时会自动 spawn serve-gateway 子进程 (监听 443 + 80)
# dsh 退出时, 网关子进程跟随退出
#
# 不在 entrypoint 手动启 serve-gateway, 避免和插件自动 spawn 端口冲突
echo "[entrypoint] starting dsh web on 127.0.0.1:3080 (plugins will auto-spawn gateway on :443)"
cd /app/workspace
exec dsh web --port 3080