# dsh-docker-build-pwd

An all-in-one Docker image build repository that packages **DeepSeek Harness** and the **dsh-passwords** gateway into a single image, with a one-click deployment script.

## What is this

- A Docker image `deepseek-harness-dshpw:latest` based on `node:22-bookworm`
- Inside the image, both of the following run:
  - `dsh` (DeepSeek Harness Web service, port 3080 inside the container)
  - `dsh-passwords` (HTTPS login gateway, port 443 inside the container; automatically spawned when the dsh plugin loads)
- Self-signed HTTPS certificate (mkcert), zero browser warnings
- Full data persistence (no data loss on restart)

## Repository structure

```
dsh-docker-build-pwd/
├── README.md              ← this file (Chinese)
├── README_en.md           ← English version
├── LICENSE                ← BSD 3-Clause
├── .gitignore
├── .gitmodules            ← submodule config (dsh-passwords)
├── restart.sh             ← one-click rebuild/start script
└── build/
    ├── Dockerfile         ← image build definition
    ├── entrypoint.sh      ← container start script
    ├── build-env.sh       ← generates .env at build time
    ├── build-setup-key.sh ← generates the first-time setup key at build time
    ├── nginx.conf         ← (reserved, currently unused)
    ├── config/
    │   └── settings.yaml.example
    └── dsh-passwords/     ← submodule: slywalker2006/dsh-passwords
```

## One-click deployment

```bash
git clone git@github.com:badoujun/dsh-docker-build-pwd.git
cd dsh-docker-build-pwd
git submodule update --init --recursive   # pull dsh-passwords source
./restart.sh                               # full build + start
```

First run takes about 1–2 minutes (npm dependencies ~17s, the rest is fast).

Once started, open your browser at:
```
https://<your-server-ip>/
```
On the first visit, you'll be asked for `SETUP_KEY` (see container logs or `setup-key.txt`).

## Common commands

| Scenario | Command |
|---|---|
| Dockerfile changed, rebuild + start | `./restart.sh` |
| Restart container only (skip build) | `./restart.sh --no-build` |
| Show help | `./restart.sh --help` |

## Configuration (top of `restart.sh`)

Edit these variables as needed before running:

| Variable | Default | Description |
|---|---|---|
| `PUBLIC_HOST` | `192.168.10.24` | Public hostname/IP (injected into the container as `DSH_PUBLIC_HOST`) |
| `HOST_HTTPS_PORT` | `443` | Host HTTPS port (mapped to container 443) |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm registry (npmmirror recommended in China) |
| `DSH_VERSION` | `0.1.0-rc.6` | dsh npm package version |

## Data persistence

| Host path | Container path | Contents |
|---|---|---|
| `/home/bake/dsh-data` | `/data/dsh-home` | dsh home (users, sessions, config) |
| `/home/bake/dsh-data/workspace` | `/app/workspace` | agent workspace |
| `/home/bake/dsh-data/certs` | `/certs` (ro) | mkcert self-signed certificate |
| `/home/bake/dsh-data/passwords-data` | `/opt/dsh-passwords/data` | dsh-passwords database |

If `/home/bake/dsh-data` does not exist when `restart.sh` runs, the script will rebuild it and automatically restore/generate the mkcert certificate.

## HTTPS certificate

`restart.sh` prepares the certificate in this priority order:

1. **Reuse**: if `/home/bake/nginx-web/conf/conf.d/ssl/dsh.local*.pem` exists (mkcert certificates left over from the old nginx reverse proxy)
2. **Generate**: invoke `mkcert` to create a new certificate covering `192.168.10.24` / `dsh.local` / `localhost`

If the host's mkcert CA is not installed, the script runs `mkcert -install` automatically.

## Updating dsh-passwords

`dsh-passwords` is a submodule, pinned to the upstream version. To upgrade:

```bash
cd build/dsh-passwords
git pull origin main           # pull upstream latest
cd ../..
git add build/dsh-passwords
git commit -m "bump dsh-passwords"
git push
./restart.sh                   # rebuild the image
```

## Submodule (dsh-passwords)

```
[submodule "build/dsh-passwords"]
    path = build/dsh-passwords
    url = https://github.com/slywalker2006/dsh-passwords.git
```

Currently pinned commit: `0afcd29` (v2.4.9-8-g0afcd29)

## Architecture notes

1. **Port plan**
   - Inside the container: dsh `3080` (loopback only) + dsh-passwords `443` (public HTTPS) + `80` (301 redirect, currently not exposed)
   - Host: `443` (modifiable via `HOST_HTTPS_PORT`)

2. **Plugin auto-spawn**
   - `dsh-passwords` is loaded as a dsh plugin; it automatically spawns the `serve-gateway` process when it listens for `plugin.startGateway()`
   - Therefore `entrypoint.sh` does NOT start the gateway directly, to avoid `EADDRINUSE 443`

3. **HTTPS enforced**
   - The container detects `/certs/cert.pem` and switches to HTTPS mode
   - If missing, it falls back to plain HTTP (dev only; **never use this on the public internet**)

4. **China build optimization**
   - The image uses `registry.npmmirror.com` throughout to avoid `registry.npmjs.org` timeouts

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `health: starting` timeout | Health check `curl https://127.0.0.1:443/health` fails | Check `/home/bake/dsh-data/certs/cert.pem` exists; check `docker logs dsh` for HTTP fallback warning |
| `EADDRINUSE 443` | entrypoint starts serve-gateway twice | Don't start the gateway manually in entrypoint; let the plugin auto-spawn it |
| npm hangs for 6+ minutes | Using the npmjs.org official registry | Switch to `NPM_REGISTRY=https://registry.npmmirror.com` |
| dsh-passwords database gets reset after container start | Missing `-v ...:/opt/dsh-passwords/data` | Upgrade restart.sh to the latest version, ensuring `-v "$PW_DATA_DIR:/opt/dsh-passwords/data"` is present |

## License

This repository's build scripts are released under the BSD 3-Clause License — see [LICENSE](LICENSE).

The `dsh-passwords` submodule follows its upstream license (see `build/dsh-passwords/LICENSE`).