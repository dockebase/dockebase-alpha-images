# Dockebase Alpha

Docker images and installation script for Dockebase — a source-available Docker control panel.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/install.sh | sudo bash
```

The installer will detect your environment and guide you through configuration.

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
# Generate AUTH_SECRET and DOCKEBASE_ENCRYPTION_KEY
openssl rand -hex 32
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
| `DOCKEBASE_ENCRYPTION_KEY` | Encryption key for stack environment variables — `openssl rand -hex 32`. **Back this up separately — if you lose it, encrypted env vars cannot be recovered.** | |
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

Removes Dockebase, the stacks it deployed, and the install directory
(`/opt/dockebase` on Linux, `~/.dockebase` on macOS). Other Docker
containers, images, and volumes on the host are not touched:

```bash
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/delete.sh | sudo bash
```

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
