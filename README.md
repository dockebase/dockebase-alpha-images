# Dockebase Alpha Builds

Docker images and installation script for Dockebase Alpha.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-builds/main/install.sh | sudo bash
```

## Requirements

- Ubuntu 22.04+ or Debian 12+ (recommended)
- Docker Engine 24+ with Docker Compose v2
- Root access (sudo)
- Domain pointed to your server (optional, for SSL)

## Manual Installation

1. Create installation directory:
```bash
sudo mkdir -p /opt/dockebase
cd /opt/dockebase
```

2. Download files:
```bash
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-builds/main/docker-compose.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-builds/main/.env.example -o .env
```

3. Edit `.env` file:
```bash
nano .env
```

4. Start Dockebase:
```bash
sudo docker compose up -d
```

## Configuration

Edit `/opt/dockebase/.env`:

| Variable | Description | Example |
|----------|-------------|---------|
| `DOMAIN` | Your domain or localhost | `panel.example.com` |
| `ACME_EMAIL` | Email for SSL certs | `admin@example.com` |
| `BASE_URL` | Full URL with protocol | `https://panel.example.com` |
| `AUTH_SECRET` | Random 64-char hex string | `openssl rand -hex 32` |

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
docker compose pull
docker compose up -d
```

## Ports

- **80** - HTTP (redirects to HTTPS when domain is set)
- **443** - HTTPS

## Data

All data is stored in Docker volumes:
- `dockebase-data` - SQLite database and stack files
- `caddy-data` - SSL certificates
- `caddy-config` - Caddy configuration

## Backup

```bash
# Backup data volume
docker run --rm -v dockebase-data:/data -v $(pwd):/backup alpine tar czf /backup/dockebase-backup.tar.gz /data
```

## Troubleshooting

### SSL not working
- Ensure your domain DNS points to the server
- Check Caddy logs: `docker compose logs dockebase-web`
- Port 80 and 443 must be open in firewall

### API unreachable
- Check API logs: `docker compose logs dockebase-api`
- Verify Docker socket permissions

## Support

This is alpha software. Report issues at: https://github.com/dockebase/dockebase-alpha/issues
