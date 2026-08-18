#!/bin/bash
# Build helper: 从 .env 读密钥, 写 setup-key.txt (用户备份用)
set -eux

SETUP_KEY=$(grep ^SETUP_KEY= /opt/dsh-passwords/.env | cut -d= -f2)

cat > /opt/dsh-passwords/setup-key.txt <<EOF
dsh-passwords 首次配置密钥
========================

SETUP_KEY = ${SETUP_KEY}

用法: 启动容器后浏览器打开 https://<服务器IP>
首次进入"配置"页, 输入上面的 SETUP_KEY 创建主用户
完成后删除本文件.
EOF

chmod 600 /opt/dsh-passwords/setup-key.txt
echo "[build] setup-key.txt generated"