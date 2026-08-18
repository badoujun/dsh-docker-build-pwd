#!/bin/bash
# Build helper: 生成 dsh-passwords .env (随机密钥)
set -eux

SETUP_KEY=$(openssl rand -hex 24)
DB_ENC_KEY=$(openssl rand -hex 32)

cat > /opt/dsh-passwords/.env <<EOF
SETUP_KEY=${SETUP_KEY}
MCP_DB_ENC_KEY=${DB_ENC_KEY}
MCP_GATEWAY_HOST=0.0.0.0
MCP_GATEWAY_PORT=443
MCP_GATEWAY_REDIRECT_PORT=80
MCP_GATEWAY_UPSTREAM=http://127.0.0.1:3080
MCP_GATEWAY_AUTO_TLS=0
MCP_DSH_RESTART_SERVICE=
EOF

chmod 600 /opt/dsh-passwords/.env
echo "[build] .env generated, SETUP_KEY length: ${#SETUP_KEY}"