#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│  ___           _        _                                               │"
echo "│ |   \ ___  ___| |_____ | |__  __ _ ___ ___                              │"
echo "│ | |) / _ \/ __| / / -_)| '_ \/ _\` (_-</ -_)                             │"
echo "│ |___/\___/\___|_\_\___||_.__/\__,_/__/\___|                             │"
echo "│                                                                         │"
echo "│ Docker Control Panel - Alpha                                            │"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo -e "${NC}"

INSTALL_DIR="/opt/dockebase"
REPO_URL="https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo)${NC}"
    exit 1
fi

# Check for Docker
echo -e "${BLUE}Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    echo "Install Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo -e "${RED}Error: Docker Compose v2 is not installed${NC}"
    echo "Docker Compose should be included with Docker Desktop or Docker Engine"
    exit 1
fi

echo -e "${GREEN}✓ Docker and Docker Compose found${NC}"

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker daemon is running${NC}"

# ──────────────────────────────────────────────
# Environment detection
# ──────────────────────────────────────────────

detect_environment() {
    # Try to get public IP
    local PUBLIC_IP
    PUBLIC_IP=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "")

    if [ -z "$PUBLIC_IP" ]; then
        echo "local"
        return
    fi

    # Check if public IP is directly on this machine (= VPS/server)
    if ip addr show 2>/dev/null | grep -qw "$PUBLIC_IP"; then
        echo "vps:$PUBLIC_IP"
    else
        echo "local"
    fi
}

# ──────────────────────────────────────────────
# Proxy provider selection
# ──────────────────────────────────────────────

ask_proxy_provider() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                  Reverse Proxy Selection                  ${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Choose your reverse proxy:${NC}"
    echo ""
    echo -e "  ${GREEN}1) Caddy${NC} (Recommended)"
    echo -e "     • Lightweight (~20MB RAM)"
    echo -e "     • Simple configuration"
    echo ""
    echo -e "  ${BLUE}2) Traefik${NC}"
    echo -e "     • More features (~40MB RAM)"
    echo -e "     • Native Docker integration"
    echo ""
    echo -e "Enter choice [1/2] (default: 1):"
    read -r PROXY_CHOICE < /dev/tty

    case "$PROXY_CHOICE" in
        2)
            PROXY_PROVIDER="traefik"
            echo -e "${GREEN}✓ Selected: Traefik${NC}"
            ;;
        *)
            PROXY_PROVIDER="caddy"
            echo -e "${GREEN}✓ Selected: Caddy${NC}"
            ;;
    esac
}

# ──────────────────────────────────────────────
# Setup wizard (manual mode)
# ──────────────────────────────────────────────

show_wizard() {
    echo ""
    echo -e "${CYAN}Choose your setup:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Local PC/Mac (HTTP on localhost)"
    echo -e "  ${GREEN}2)${NC} Server with public IP, no domain (self-signed HTTPS)"
    echo -e "  ${GREEN}3)${NC} Server with domain (Let's Encrypt HTTPS)"
    echo -e "  ${GREEN}4)${NC} Cloudflare Tunnel (homelab, NAT, no public IP)"
    echo ""
    echo -e "Enter choice [1-4]:"
    read -r SETUP_CHOICE < /dev/tty

    case "$SETUP_CHOICE" in
        1)
            DOMAIN=localhost
            PROXY_MODE=http
            BASE_URL="http://localhost"
            PROXY_PROVIDER=caddy
            echo -e "${GREEN}✓ Configured: HTTP localhost with Caddy${NC}"
            ;;
        2)
            echo -e "\n${BLUE}Enter your server's public IP address:${NC}"
            read -r SERVER_IP < /dev/tty
            if [ -z "$SERVER_IP" ]; then
                echo -e "${RED}Error: IP address is required${NC}"
                exit 1
            fi
            DOMAIN="$SERVER_IP"
            PROXY_MODE=https-selfsigned
            BASE_URL="https://$SERVER_IP"
            ask_proxy_provider
            ;;
        3)
            echo -e "\n${BLUE}Enter your domain (e.g., panel.example.com):${NC}"
            read -r DOMAIN < /dev/tty
            if [ -z "$DOMAIN" ]; then
                echo -e "${RED}Error: Domain is required${NC}"
                exit 1
            fi
            echo -e "\n${BLUE}Enter email for Let's Encrypt SSL certificates:${NC}"
            read -r ACME_EMAIL < /dev/tty
            if [ -z "$ACME_EMAIL" ]; then
                echo -e "${RED}Error: Email is required for SSL certificates${NC}"
                exit 1
            fi
            PROXY_MODE=https-acme
            BASE_URL="https://$DOMAIN"
            ask_proxy_provider
            ;;
        4)
            echo -e "\n${BLUE}Enter your Cloudflare Tunnel URL (e.g., https://xyz.trycloudflare.com):${NC}"
            read -r TUNNEL_URL < /dev/tty
            if [ -z "$TUNNEL_URL" ]; then
                echo -e "${RED}Error: Tunnel URL is required${NC}"
                exit 1
            fi
            # Extract hostname from URL
            DOMAIN=$(echo "$TUNNEL_URL" | sed 's|https\?://||' | sed 's|/.*||')
            PROXY_MODE=http
            BASE_URL="$TUNNEL_URL"
            PROXY_PROVIDER=caddy
            echo -e "${GREEN}✓ Configured: Cloudflare Tunnel with Caddy${NC}"
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
}

# ──────────────────────────────────────────────
# Interactive configuration
# ──────────────────────────────────────────────

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                    Configuration                          ${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Initialize variables
DOMAIN=""
ACME_EMAIL=""
PROXY_PROVIDER=""
PROXY_MODE=""
BASE_URL=""

# Detect environment
ENV_RESULT=$(detect_environment)
ENV_TYPE=$(echo "$ENV_RESULT" | cut -d: -f1)
PUBLIC_IP=$(echo "$ENV_RESULT" | cut -s -d: -f2)

if [ "$ENV_TYPE" = "local" ]; then
    echo -e "${CYAN}Detected: Local machine (PC/Mac)${NC}"
    echo -e "Default: HTTP on localhost with Caddy proxy"
    echo ""
    echo -e "Press Enter to continue, or type ${YELLOW}other${NC} for more options:"
    read -r CHOICE < /dev/tty

    if [ -z "$CHOICE" ]; then
        DOMAIN=localhost
        PROXY_MODE=http
        PROXY_PROVIDER=caddy
        BASE_URL="http://localhost"
        echo -e "${GREEN}✓ Configured: HTTP localhost with Caddy${NC}"
    else
        show_wizard
    fi

elif [ "$ENV_TYPE" = "vps" ]; then
    echo -e "${CYAN}Detected: Server with public IP ${GREEN}$PUBLIC_IP${NC}"
    echo ""
    echo -e "${BLUE}Enter your domain (e.g., panel.example.com)${NC}"
    echo -e "Leave empty for IP-based access with self-signed HTTPS:"
    read -r DOMAIN < /dev/tty

    if [ -n "$DOMAIN" ]; then
        PROXY_MODE=https-acme
        BASE_URL="https://$DOMAIN"

        echo -e "\n${BLUE}Enter email for Let's Encrypt SSL certificates:${NC}"
        read -r ACME_EMAIL < /dev/tty
        if [ -z "$ACME_EMAIL" ]; then
            echo -e "${RED}Error: Email is required for SSL certificates${NC}"
            exit 1
        fi
    else
        DOMAIN="$PUBLIC_IP"
        PROXY_MODE=https-selfsigned
        BASE_URL="https://$PUBLIC_IP"
        echo -e "${GREEN}✓ Using IP-based access with self-signed HTTPS${NC}"
    fi

    ask_proxy_provider

else
    echo -e "${CYAN}Could not detect environment automatically.${NC}"
    show_wizard
fi

# Generate secrets
AUTH_SECRET=$(openssl rand -hex 32)
# Encryption key for local data - NEVER sent to worker, backup this key!
ENCRYPTION_KEY=$(openssl rand -hex 32)
# Note: DOCKEBASE_INSTANCE_SECRET is generated by the worker and saved automatically

# Create installation directory
echo ""
echo -e "${BLUE}Creating installation directory...${NC}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Download docker-compose.yml
echo -e "${BLUE}Downloading configuration files...${NC}"
curl -fsSL "$REPO_URL/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$REPO_URL/.env.example" -o .env.example

echo -e "${GREEN}✓ Configuration files downloaded${NC}"

# Create .env file
echo ""
echo -e "${BLUE}Creating configuration...${NC}"
cat > .env << EOF
# Dockebase Configuration
# Generated by install.sh

DOMAIN=$DOMAIN
ACME_EMAIL=${ACME_EMAIL:-}
BASE_URL=$BASE_URL
AUTH_SECRET=$AUTH_SECRET
DOCKEBASE_ENCRYPTION_KEY=$ENCRYPTION_KEY
# DOCKEBASE_INSTANCE_SECRET will be added automatically on first startup
PROXY_PROVIDER=$PROXY_PROVIDER
PROXY_MODE=$PROXY_MODE
EOF

echo -e "${GREEN}✓ Configuration created${NC}"

# Create data directory for bind mount
# This is required for stack bind mounts to work (Docker socket runs on host)
echo -e "${BLUE}Creating data directory...${NC}"
mkdir -p "$INSTALL_DIR/data/stacks"
echo -e "${GREEN}✓ Data directory created${NC}"

# Create Docker networks
echo -e "${BLUE}Creating Docker networks...${NC}"
docker network create dockebase-internal 2>/dev/null || true
docker network create dockebase-proxy 2>/dev/null || true
echo -e "${GREEN}✓ Docker networks created${NC}"

# Pull images
echo ""
echo -e "${BLUE}Pulling Docker images...${NC}"
docker compose pull

echo -e "${GREEN}✓ Images pulled${NC}"

# Start services
echo ""
echo -e "${BLUE}Starting Dockebase...${NC}"
docker compose up -d

echo -e "${GREEN}✓ Dockebase started${NC}"

# Wait for services to be ready
echo ""
echo -e "${BLUE}Waiting for services to initialize...${NC}"
echo -e "${YELLOW}(Proxy will be configured automatically)${NC}"
sleep 10

# Check if services are running
if docker compose ps | grep -q "running"; then
    echo -e "${GREEN}✓ Services are running${NC}"
else
    echo -e "${RED}Warning: Some services may not be running properly${NC}"
    echo "Check status with: cd $INSTALL_DIR && docker compose ps"
fi

# Check if proxy was started
if docker ps | grep -q "dockebase-$PROXY_PROVIDER"; then
    echo -e "${GREEN}✓ Proxy ($PROXY_PROVIDER) is running${NC}"
else
    echo -e "${YELLOW}Note: Proxy container will start after first API request${NC}"
fi

# Print success message
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}           Dockebase Installation Complete!                ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

case "$PROXY_MODE" in
    http)
        echo -e "Access Dockebase at: ${BLUE}$BASE_URL${NC}"
        echo ""
        if [ "$DOMAIN" = "localhost" ]; then
            echo -e "${YELLOW}Running in HTTP mode on localhost.${NC}"
        else
            echo -e "${YELLOW}Running in HTTP mode (SSL handled externally).${NC}"
        fi
        ;;
    https-selfsigned)
        echo -e "Access Dockebase at: ${BLUE}$BASE_URL${NC}"
        echo ""
        echo -e "${YELLOW}Using self-signed HTTPS certificate.${NC}"
        echo -e "${YELLOW}Your browser will show a security warning — this is expected.${NC}"
        ;;
    https-acme)
        echo -e "Access Dockebase at: ${BLUE}$BASE_URL${NC}"
        echo ""
        echo -e "Proxy: ${CYAN}$PROXY_PROVIDER${NC}"
        echo -e "${YELLOW}SSL certificate will be automatically provisioned via Let's Encrypt.${NC}"
        echo -e "${YELLOW}This may take a few minutes on first access.${NC}"
        ;;
esac

echo ""
echo -e "Installation directory: ${BLUE}$INSTALL_DIR${NC}"
echo ""
echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
echo -e "${RED}                    IMPORTANT                             ${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Backup this encryption key to a secure location:${NC}"
echo ""
echo -e "${CYAN}DOCKEBASE_ENCRYPTION_KEY=$ENCRYPTION_KEY${NC}"
echo ""
echo -e "${YELLOW}This key encrypts your stack environment variables.${NC}"
echo -e "${YELLOW}If you lose it, encrypted data cannot be recovered.${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Useful commands:"
echo -e "  ${BLUE}cd $INSTALL_DIR${NC}"
echo -e "  ${BLUE}docker compose ps${NC}          - Check services status"
echo -e "  ${BLUE}docker compose logs -f${NC}     - View logs"
echo -e "  ${BLUE}docker compose down${NC}        - Stop services"
echo -e "  ${BLUE}docker compose up -d${NC}       - Start services"
echo ""
