# Dockebase Alpha

Docker images and installation script for Dockebase — a source-available Docker control panel.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/install.sh | sudo bash
```

The installer will detect your environment and guide you through configuration.

## Unattended Install

Passing any configuration flag (or its environment variable) switches the installer to
unattended mode: no prompts ever run, and anything missing or invalid fails immediately
with a machine-readable error. This is the mode for AI agents and scripts.

```bash
# Server with public IP, no domain (the public IP is auto-detected):
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/install.sh | sudo bash -s -- --mode https-selfsigned

# Server with a domain (Let's Encrypt):
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/install.sh | sudo bash -s -- --mode https-acme --domain panel.example.com --email you@example.com

# External TLS, e.g. Cloudflare Tunnel (HTTP inside, HTTPS terminated outside):
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/install.sh | sudo bash -s -- --mode http --domain xyz.trycloudflare.com
```

### Flags

| Flag | Env variable | Description |
|------|--------------|-------------|
| `--mode <http\|https-selfsigned\|https-acme>` | `DOCKEBASE_MODE` | Required in unattended mode. `http` = plain HTTP (localhost, or TLS terminated externally); `https-selfsigned` = self-signed cert for IP access; `https-acme` = Let's Encrypt |
| `--domain <host-or-ip>` | `DOCKEBASE_DOMAIN` | Required for `https-acme`. Optional for `https-selfsigned` (public IP auto-detected) and `http` (defaults to `localhost`) |
| `--email <email>` | `DOCKEBASE_EMAIL` | ACME email — required for `https-acme` |
| `--provider <caddy\|traefik>` | `DOCKEBASE_PROVIDER` | Reverse proxy (default `caddy`) |
| `--base-url <url>` | `DOCKEBASE_BASE_URL` | Advanced: override the derived `BASE_URL` (scheme+host[:port] only) |
| `-h`, `--help` | — | Print usage and exit 0 |

Flags take precedence over environment variables. `BASE_URL` is derived automatically when
`--base-url` is not given: `http` + `localhost` → `http://localhost`; `http` + any other
domain → `https://<domain>` (TLS terminates externally, e.g. Cloudflare Tunnel);
`https-selfsigned` / `https-acme` → `https://<domain>`.

### Result line

In unattended mode the **last stdout line** is a machine-readable result:

```
DOCKEBASE_RESULT: {"status":"success","fresh_install":true,"mode":"https-acme","provider":"caddy","url":"https://panel.example.com","install_dir":"/opt/dockebase","services":"running","proxy":"running","encryption_key_backup":"onboarding"}
DOCKEBASE_RESULT: {"status":"error","error":"<code>","message":"<text>"}
```

Success fields:

| Field | Meaning |
|-------|---------|
| `fresh_install` | boolean — `true` for a first install, `false` when an existing installation was repaired in place (config changes are refused, see below) |
| `mode` | effective `PROXY_MODE` |
| `provider` | `caddy` or `traefik` |
| `url` | the panel's `BASE_URL` |
| `install_dir` | installation directory |
| `services` | `running` \| `not_running` (the two compose containers) |
| `proxy` | `running` \| `pending` — `pending` means the backend had not created the proxy container within 45 s; this is not fatal |
| `encryption_key_backup` | `onboarding` — the key is generated on first startup and the panel shows it **once** during onboarding (back it up there); `env_preserved` — an existing key in `.env` was preserved; `key_file` — the key lives in `data/.encryption-key` and its one-time onboarding disclosure already happened; `instance_secret` — legacy install, the recovery material is `DOCKEBASE_INSTANCE_SECRET` in `.env`. The key itself is never printed |

Error codes: `usage`, `not_root`, `docker_missing`, `compose_missing`, `docker_not_running`,
`public_ip_unknown`, `symlink_install_dir` (the install dir **or its `.env`** is a symlink),
`download_failed`, `pull_failed`, `compose_up_failed`, `reconfigure_unsupported` and
`recovery_required` (see "Re-running the installer" below), `services_not_running`, and
`internal_error` — the blanket code for any unexpected failure (inspect stderr).

Exit codes: `0` success, `1` runtime failure, `2` usage error (also returned when the
installer is piped without flags and no terminal is available).

### Re-running the installer

The installer is idempotent (this applies to interactive runs too). When
`<install-dir>/.env` already exists, existing non-empty `AUTH_SECRET` and
`DOCKEBASE_ENCRYPTION_KEY` are **never regenerated**, `DOCKEBASE_INSTANCE_SECRET`
is left untouched, and the configuration keys (`DOMAIN`, `ACME_EMAIL`, `BASE_URL`,
`PROXY_PROVIDER`, `PROXY_MODE`, `DOCKEBASE_INSTALL_DIR`) are updated in place —
all other lines and comments in `.env` are preserved.

A re-run can only **repair** an installation, not reconfigure it: once the
database exists (the instance has booted at least once), domain, proxy mode and
provider live in the database, and an `.env`-only change would never take
effect. A re-run with a different `--mode`/`--domain`/`--provider` therefore
fails with `reconfigure_unsupported` — change these settings in the panel, or
uninstall first with `delete.sh`. When `--provider` is not given, a re-run
inherits the existing `.env` value instead of defaulting to caddy, so a repair
cannot silently flip the proxy.

Two states refuse with `recovery_required` instead of proceeding: an
initialized database without `.env`, or without any encryption key (missing in
`.env` and no `data/.encryption-key`). Continuing would orphan the encrypted
data — restore from a backup, or start over with `delete.sh`.

## Requirements

- Ubuntu 22.04+ or Debian 12+ (recommended)
- Docker Engine 24+ with Docker Compose v2
- Root access (sudo)
- Domain pointed to your server (optional, for Let's Encrypt SSL)

## Manual Installation

If you prefer to install manually instead of using the install script:

> **Install directory**: `/opt/dockebase` on Linux. On **macOS** use a directory in your
> home instead (the install script picks `~/.dockebase`) — Docker Desktop / Colima VMs
> do not share `/opt` with the host by default, so bind mounts there fail. Whatever you
> choose, set it as `DOCKEBASE_INSTALL_DIR` in `.env` so docker-compose.yml mounts it.
> The examples below use the Linux path.

1. Create installation and data directories:
```bash
sudo mkdir -p /opt/dockebase/data/stacks
cd /opt/dockebase
```

2. Create Docker networks:
```bash
docker network create dockebase-internal
docker network create dockebase-proxy
```

3. Download files:
```bash
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/docker-compose.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/.env.example -o .env
```

4. Generate secrets and edit `.env`:
```bash
# Generate AUTH_SECRET (leave DOCKEBASE_ENCRYPTION_KEY empty — it is
# generated on first startup and shown once in the panel onboarding)
openssl rand -hex 32

nano .env
```

5. Pull images and start:
```bash
docker compose pull
docker compose up -d
```

The backend will automatically create and start the reverse proxy container (Caddy or Traefik, based on your `PROXY_PROVIDER` setting).

## Configuration

Edit `/opt/dockebase/.env`:

| Variable | Description | Default |
|----------|-------------|---------|
| `DOMAIN` | Your domain or IP address | `localhost` |
| `ACME_EMAIL` | Email for Let's Encrypt SSL (required for `https-acme` mode) | |
| `BASE_URL` | Full URL with protocol | `http://localhost` |
| `AUTH_SECRET` | Authentication secret — `openssl rand -hex 32` | |
| `DOCKEBASE_ENCRYPTION_KEY` | Encryption key for stack environment variables. **Leave empty** — it is generated on first startup and the panel shows it **once** during onboarding for backup. Set it only when restoring a backed-up key. **If the key is lost, encrypted env vars cannot be recovered.** | |
| `DOCKEBASE_INSTANCE_SECRET` | Instance secret (leave empty — auto-generated on first startup) | |
| `PROXY_PROVIDER` | Reverse proxy: `caddy` or `traefik` | `caddy` |
| `PROXY_MODE` | `http`, `https-selfsigned`, or `https-acme` | `http` |

### Proxy Modes

| Mode | Use case |
|------|----------|
| `http` | Localhost development or behind Cloudflare Tunnel |
| `https-selfsigned` | Server with public IP, no domain (browser will show security warning) |
| `https-acme` | Server with domain — automatic Let's Encrypt certificates |

## Commands

```bash
cd /opt/dockebase

# Status
docker compose ps

# Logs
docker compose logs -f

# Stop
docker compose down

# Start
docker compose up -d

# Update
docker compose pull && docker compose down && docker compose up -d
```

## Ports

The reverse proxy container publishes the ports Dockebase has registered: port 80 only in
`PROXY_MODE=http`, ports 80 and 443 in `https-selfsigned` / `https-acme`. It is created automatically
by the backend on first startup; extra public ports added in the UI are published on the next proxy
restart.

## Data

All data is stored on the host via bind mounts (paths below show the Linux install dir
`/opt/dockebase`; macOS installs live in `~/.dockebase`):

| Path | Contents |
|------|----------|
| `/opt/dockebase/data/dockebase.db` | SQLite database |
| `/opt/dockebase/data/stacks/` | Stack files (compose files, repos) |
| `/opt/dockebase/.env` | Configuration |

The reverse proxy container manages its own SSL certificates internally.

## Backup

```bash
# Backup database and stack files
sudo tar czf dockebase-backup.tar.gz -C /opt/dockebase data .env
```

The archive includes `.env` (and `data/.encryption-key` if the key was auto-generated) — store it
somewhere private. Without `DOCKEBASE_ENCRYPTION_KEY` the backup's stack environment variables cannot
be decrypted.

## Uninstall

Removes Dockebase, the stacks it deployed, and the install directory.
The directory is resolved from the running `dockebase-api` container
(its `DATABASE_PATH`), falling back to probing the known locations
(`/opt/dockebase`, `~/.dockebase`); the resolved path is shown before
the deletion is confirmed, and an ambiguous result aborts. Other Docker
containers, images, and volumes on the host are not touched:

```bash
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/delete.sh | sudo bash
```

A non-default install directory can be passed explicitly:
`delete.sh [--nuke-all-docker] <install-dir>`.

⚠️ For a completely fresh start on a **dedicated** server, `delete.sh --nuke-all-docker`
additionally wipes ALL Docker resources on the host — including ones that have
nothing to do with Dockebase.

## Troubleshooting

### SSL not working
- Ensure your domain DNS points to the server
- Check proxy logs: `docker logs dockebase-caddy` (or `dockebase-traefik`)
- Ports 80 and 443 must be open in firewall
- Verify `PROXY_MODE=https-acme` and `ACME_EMAIL` is set in `.env`

### API unreachable
- Check API logs: `docker compose logs dockebase-api`
- Verify Docker socket is accessible: `ls -la /var/run/docker.sock`

### Containers not starting
- Check status: `docker compose ps`
- Check logs: `docker compose logs`
- Verify networks exist: `docker network ls | grep dockebase`

## Architecture

Dockebase runs as two containers defined in `docker-compose.yml`:

- **dockebase-api** — Backend API server with Docker socket access
- **dockebase-ui** — Frontend static build served by nginx (static files only; the external proxy routes `/api` and `/ws` straight to dockebase-api)

The reverse proxy (Caddy or Traefik) is a separate container created and managed by the backend via the Docker API. It handles SSL termination and routes traffic to the UI and API containers.

## Support

This is alpha software. Report issues at: https://github.com/dockebase/dockebase-alpha-images/issues
