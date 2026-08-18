#!/usr/bin/env bash
#
# restart.sh —— 一键重建并启动 deepseek-harness-dshpw 容器
#
# 流程：
#   1. 停掉旧容器（如果存在）
#   2. 删除旧容器（保留镜像 / 数据卷）
#   3. 重新构建镜像 deepseek-harness-dshpw:latest
#   4. 启动新容器（端口 443，挂载 dsh-data / workspace / certs）
#
# 用法：
#   ./restart.sh            # 完整流程
#   ./restart.sh --no-build # 跳过构建，只重启容器
#

set -euo pipefail

# ---------- 配置 ----------
CONTAINER_NAME="dsh"
IMAGE_NAME="deepseek-harness-dshpw:latest"
BUILD_CONTEXT="/home/bake/dsh/build"

# 挂载源（宿主机 → 容器）
DSDATA_DIR="/home/bake/dsh-data"
WORKSPACE_DIR="/home/bake/dsh-data/workspace"
CERTS_DIR="/home/bake/dsh-data/certs"
PW_DATA_DIR="/home/bake/dsh-data/passwords-data"  # dsh-passwords 数据库（platform.db）

# 镜像构建参数（与 Dockerfile 中的 ARG 对齐）
NPM_REGISTRY="https://registry.npmmirror.com"
DSH_VERSION="0.1.0-rc.6"

# 运行时配置
# 容器对外的主机名/IP（注入 DSH_PUBLIC_HOST）
PUBLIC_HOST="192.168.10.24"
# 宿主机 HTTPS 端口（映射到容器 443）
HOST_HTTPS_PORT="443"

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[restart]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[fail]${NC} $*" >&2; exit 1; }

# ---------- 解析参数 ----------
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --no-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) die "未知参数: $arg  (用法: $0 [--no-build])" ;;
  esac
done

# ---------- 前置检查 ----------
[ -d "$BUILD_CONTEXT" ] || die "构建目录不存在: $BUILD_CONTEXT"
[ -f "$BUILD_CONTEXT/Dockerfile" ] || die "找不到 Dockerfile: $BUILD_CONTEXT/Dockerfile"

command -v docker >/dev/null 2>&1 || die "未安装 docker"

# 从宿主机 ~/.dsh-env 读取 DEEPSEEK_API_KEY（可选）
DSH_ENV_FILE="$HOME/.dsh-env"
if [ -f "$DSH_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$DSH_ENV_FILE"
  log "已加载 $DSH_ENV_FILE"
fi

# 准备好挂载目录（避免 docker run 因为源路径不存在而失败）
mkdir -p "$DSDATA_DIR" "$WORKSPACE_DIR" "$CERTS_DIR" "$PW_DATA_DIR"

# ---------- 0. 确保 mkcert 自签证书存在 ----------
# 如果 /certs/cert.pem 不存在，entrypoint 会降级到 HTTP，导致健康检查失败。
# 优先复用 nginx-web 留下的旧证书（同一个 mkcert CA 签发），
# 否则调用 mkcert 生成新的。
if [ ! -f "$CERTS_DIR/cert.pem" ] || [ ! -f "$CERTS_DIR/key.pem" ]; then
  log "未发现挂载证书，准备生成或恢复"
  LEGACY_CERT="/home/bake/nginx-web/conf/conf.d/ssl/dsh.local.pem"
  LEGACY_KEY="/home/bake/nginx-web/conf/conf.d/ssl/dsh.local-key.pem"
  if [ -f "$LEGACY_CERT" ] && [ -f "$LEGACY_KEY" ]; then
    log "复用 nginx-web 旧证书: $LEGACY_CERT"
    cp "$LEGACY_CERT" "$CERTS_DIR/cert.pem"
    cp "$LEGACY_KEY"  "$CERTS_DIR/key.pem"
  else
    log "调用 mkcert 生成新证书"
    command -v mkcert >/dev/null 2>&1 || die "需要 mkcert，但未安装"
    CAROOT="$HOME/.local/share/mkcert"
    [ -f "$CAROOT/rootCA.pem" ] || mkcert -install
    mkcert -cert-file "$CERTS_DIR/cert.pem" \
           -key-file  "$CERTS_DIR/key.pem" \
           "${PUBLIC_HOST}" "dsh.local" "localhost"
  fi
  chmod 644 "$CERTS_DIR/cert.pem"
  chmod 600 "$CERTS_DIR/key.pem"
  ok "证书就位: $CERTS_DIR"
else
  log "证书已存在，跳过生成"
fi

# ---------- 1. 停掉旧容器 ----------
if sudo docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  log "停止容器: $CONTAINER_NAME"
  sudo docker stop "$CONTAINER_NAME" >/dev/null || warn "stop 失败，继续"
else
  log "容器 $CONTAINER_NAME 不存在，跳过 stop"
fi

# ---------- 2. 删除旧容器 ----------
if sudo docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  log "删除容器: $CONTAINER_NAME"
  sudo docker rm "$CONTAINER_NAME" >/dev/null || die "rm 失败"
else
  log "容器 $CONTAINER_NAME 不存在，跳过 rm"
fi

# ---------- 3. 重新构建镜像 ----------
if [ "$SKIP_BUILD" -eq 1 ]; then
  warn "--no-build：跳过镜像构建"
  log "确保镜像 $IMAGE_NAME 已存在"
  sudo docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
    || die "镜像 $IMAGE_NAME 不存在，无法跳过构建"
else
  log "构建镜像: $IMAGE_NAME"
  log "  context : $BUILD_CONTEXT"
  log "  registry: $NPM_REGISTRY"
  log "  version : $DSH_VERSION"
  cd "$BUILD_CONTEXT"
  sudo docker build \
    --build-arg NPM_REGISTRY="$NPM_REGISTRY" \
    --build-arg DSH_VERSION="$DSH_VERSION" \
    -t "$IMAGE_NAME" \
    -f Dockerfile \
    . || die "docker build 失败"
  ok "镜像构建完成: $IMAGE_NAME"
fi

# ---------- 4. 启动新容器 ----------
log "启动容器: $CONTAINER_NAME"
sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p ${HOST_HTTPS_PORT}:443 \
  -v "$DSDATA_DIR:/data/dsh-home" \
  -v "$WORKSPACE_DIR:/app/workspace" \
  -v "$CERTS_DIR:/certs:ro" \
  -v "$PW_DATA_DIR:/opt/dsh-passwords/data" \
  -e NODE_ENV=production \
  -e DSH_PUBLIC_HOST="${PUBLIC_HOST}" \
  ${DEEPSEEK_API_KEY:+-e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY"} \
  "$IMAGE_NAME" \
  || die "docker run 失败"

ok "容器已启动: $CONTAINER_NAME"

# ---------- 5. 等 healthy ----------
log "等待容器健康检查（最多 60 秒）…"
for i in $(seq 1 30); do
  STATUS=$(sudo docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "starting")
  if [ "$STATUS" = "healthy" ]; then
    ok "容器 HEALTHY（用时 ${i}*2s）"
    break
  fi
  if [ "$i" = "30" ]; then
    warn "60 秒内未 healthy，查看日志："
    sudo docker logs --tail 30 "$CONTAINER_NAME" 2>&1 | sed 's/^/  /'
    die "健康检查超时"
  fi
  sleep 2
done

# ---------- 6. 打印访问信息 ----------
SETUP_KEY=""
if sudo docker exec "$CONTAINER_NAME" test -f /opt/dsh-passwords/setup-key.txt; then
  SETUP_KEY=$(sudo docker exec "$CONTAINER_NAME" cat /opt/dsh-passwords/setup-key.txt \
    | grep -E '^SETUP_KEY' | head -1 | awk '{print $NF}')
fi

echo
echo "============================================"
echo " ✅ dsh 已重启"
echo " 访问 : https://${PUBLIC_HOST}:${HOST_HTTPS_PORT}/"
echo " 状态 : $(sudo docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME")"
if [ -n "$SETUP_KEY" ]; then
  echo " SETUP_KEY : $SETUP_KEY"
fi
echo "============================================"