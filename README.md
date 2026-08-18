# dsh-docker-build-pwd

一体化 Docker 镜像构建仓库 —— 把 **DeepSeek Harness** 与 **dsh-passwords** 网关打包成单镜像，附带一键部署脚本。

## 这是什么

- 一个基于 `node:22-bookworm` 的 Docker 镜像 `deepseek-harness-dshpw:latest`
- 镜像内同时运行：
  - `dsh`（DeepSeek Harness Web 服务，容器内 3080 端口）
  - `dsh-passwords`（HTTPS 登录网关，容器内 443 端口，dsh 插件加载时自动 spawn）
- 自签 HTTPS 证书（mkcert），浏览器零警告访问
- 完整的数据持久化（重启不丢）

## 仓库结构

```
dsh-docker-build-pwd/
├── README.md              ← 本文件（中文）
├── README_en.md           ← English version
├── LICENSE                ← BSD 3-Clause
├── .gitignore
├── .gitmodules            ← submodule 配置（dsh-passwords）
├── restart.sh             ← 一键重建/启动脚本
└── build/
    ├── Dockerfile         ← 镜像构建定义
    ├── entrypoint.sh      ← 容器启动脚本
    ├── build-env.sh       ← 构建期生成 .env
    ├── build-setup-key.sh ← 构建期生成首次配置密钥
    ├── nginx.conf         ← （备用，目前未使用）
    ├── config/
    │   └── settings.yaml.example
    └── dsh-passwords/     ← submodule: slywalker2006/dsh-passwords
```

## 一键部署

```bash
git clone git@github.com:badoujun/dsh-docker-build-pwd.git
cd dsh-docker-build-pwd
git submodule update --init --recursive   # 拉 dsh-passwords 源码
./restart.sh                               # 完整构建 + 启动
```

首次运行约 1–2 分钟（npm 依赖约 17s，其余步骤秒级）。

启动完成后浏览器访问：
```
https://<你的服务器IP>/
```
首次进入会要求输入 `SETUP_KEY`（见容器日志或 `setup-key.txt`）。

## 常用命令

| 场景 | 命令 |
|---|---|
| 修改了 Dockerfile，重新构建 + 启动 | `./restart.sh` |
| 仅重启容器（跳过构建）| `./restart.sh --no-build` |
| 查看帮助 | `./restart.sh --help` |

## 配置项（`restart.sh` 顶部）

按需修改这些变量后再跑：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUBLIC_HOST` | `192.168.10.24` | 对外主机名/IP（注入到容器的 `DSH_PUBLIC_HOST`）|
| `HOST_HTTPS_PORT` | `443` | 宿主机 HTTPS 端口（映射到容器 443）|
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像（国内推荐用 npmmirror）|
| `DSH_VERSION` | `0.1.0-rc.6` | dsh npm 包版本 |

## 数据持久化

| 宿主机路径 | 容器内路径 | 内容 |
|---|---|---|
| `/home/bake/dsh-data` | `/data/dsh-home` | dsh 主目录（用户、会话、配置）|
| `/home/bake/dsh-data/workspace` | `/app/workspace` | agent 工作区 |
| `/home/bake/dsh-data/certs` | `/certs`（ro） | mkcert 自签证书 |
| `/home/bake/dsh-data/passwords-data` | `/opt/dsh-passwords/data` | dsh-passwords 数据库 |

`restart.sh` 启动时若 `/home/bake/dsh-data` 不存在会自动重建，并自动恢复/生成 mkcert 证书。

## HTTPS 证书

`restart.sh` 会按以下优先级准备证书：

1. **复用**：如果 `/home/bake/nginx-web/conf/conf.d/ssl/dsh.local*.pem` 存在（旧 nginx 反代留下的 mkcert 证书）
2. **生成**：调用 `mkcert` 生成新证书，覆盖 `192.168.10.24` / `dsh.local` / `localhost`

如果宿主机的 mkcert CA 未安装，脚本会自动执行 `mkcert -install`。

## 更新 dsh-passwords

`dsh-passwords` 是 submodule，跟上游版本绑定。要升级：

```bash
cd build/dsh-passwords
git pull origin main           # 拉上游最新
cd ../..
git add build/dsh-passwords
git commit -m "bump dsh-passwords"
git push
./restart.sh                   # 重建镜像
```

## 子模块（dsh-passwords）

```
[submodule "build/dsh-passwords"]
    path = build/dsh-passwords
    url = https://github.com/slywalker2006/dsh-passwords.git
```

当前锁定 commit：`0afcd29`（v2.4.9-8-g0afcd29）

## 架构要点

1. **端口规划**
   - 容器内：dsh `3080`（仅本机回环）+ dsh-passwords `443`（对外 HTTPS）+ `80`（301 跳转，目前未对外暴露）
   - 宿主机：`443`（可通过 `HOST_HTTPS_PORT` 修改）

2. **插件自动 spawn**
   - `dsh-passwords` 作为 dsh 插件加载，监听 `plugin.startGateway()` 事件时**自动** spawn `serve-gateway` 进程
   - 因此 `entrypoint.sh` 不直接启动网关，避免 `EADDRINUSE 443`

3. **HTTPS 强制**
   - 容器内检测到 `/certs/cert.pem` 即走 HTTPS 模式
   - 未检测到则降级为明文 HTTP（仅 dev 用，公网禁止）

4. **国内构建优化**
   - 镜像内全程使用 `registry.npmmirror.com`，避免 `registry.npmjs.org` 超时

## 故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| `health: starting` 超时 | 健康检查 `curl https://127.0.0.1:443/health` 失败 | 检查 `/home/bake/dsh-data/certs/cert.pem` 是否存在；看 `docker logs dsh` 是否降级为 HTTP |
| `EADDRINUSE 443` | entrypoint 重复启了 serve-gateway | 不要在 entrypoint 里手动启网关，让插件自动 spawn |
| npm 卡 6+ 分钟 | 用了 npmjs.org 官方源 | 改用 `NPM_REGISTRY=https://registry.npmmirror.com` |
| 容器启动后 dsh-passwords 数据库被重置 | 没挂 `-v ...:/opt/dsh-passwords/data` | 升级 restart.sh 到最新版，确保包含 `-v "$PW_DATA_DIR:/opt/dsh-passwords/data"` |

## 许可证

本仓库按 **BSD 3-Clause** 许可证发布 —— 详见 [LICENSE](LICENSE)。

英文文档：[README_en.md](README_en.md)。

`dsh-passwords` 子模块遵循其上游许可证（见 `build/dsh-passwords/LICENSE`）。