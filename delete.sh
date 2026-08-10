#!/bin/bash

# =============================================================================
# Dockebase Uninstall Script
# =============================================================================
# Default mode removes ONLY Dockebase and the stacks it deployed:
# - Dockebase containers (api, ui, caddy/traefik proxy)
# - Containers, images, and volumes of stacks deployed BY Dockebase
# - Dockebase networks (dockebase-internal, dockebase-proxy)
# - All Dockebase data (install dir: database, stacks, configs)
#
# --nuke-all-docker additionally wipes EVERYTHING Docker on this host
# (all containers, images, volumes, networks, build cache — including
# resources that have nothing to do with Dockebase). Use only on a
# dedicated server for a completely fresh start.
# =============================================================================

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Same install-dir resolution as install.sh (macOS installs live in the
# invoking user's home because the Docker VMs don't share /opt by default)
resolve_install_dir() {
    if [ "$(uname -s)" = "Darwin" ]; then
        local user_home
        user_home=$(eval echo "~${SUDO_USER:-root}")
        if [ -n "$SUDO_USER" ] && [ -d "$user_home/.dockebase" ]; then
            echo "$user_home/.dockebase"
        elif [ -d "/Users/Shared/dockebase" ]; then
            echo "/Users/Shared/dockebase"
        else
            echo "${user_home}/.dockebase"
        fi
    else
        echo "/opt/dockebase"
    fi
}
DOCKEBASE_DIR="$(resolve_install_dir)"
NUKE_ALL=false

if [ "$1" = "--nuke-all-docker" ]; then
    NUKE_ALL=true
fi

if [ "$NUKE_ALL" = true ]; then
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                       !!!  WARNING !!!                        ║"
    echo "║                                                               ║"
    echo "║  --nuke-all-docker will DELETE EVERYTHING:                    ║"
    echo "║  - All Docker containers (not just Dockebase)                 ║"
    echo "║  - All Docker images                                          ║"
    echo "║  - All Docker volumes                                         ║"
    echo "║  - All Docker networks                                        ║"
    echo "║  - All Dockebase data (database, stacks)                      ║"
    echo "║  - Docker build cache                                         ║"
    echo "║                                                               ║"
    echo "║  This is IRREVERSIBLE!                                        ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
else
    echo -e "${YELLOW}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                  Dockebase Uninstall                          ║"
    echo "║                                                               ║"
    echo "║  This will remove:                                            ║"
    echo "║  - Dockebase containers (api, ui, proxy)                      ║"
    echo "║  - Stacks deployed by Dockebase (containers + their volumes)  ║"
    echo "║  - Dockebase networks                                         ║"
    echo "║  - All Dockebase data in the install directory                ║"
    echo "║                                                               ║"
    echo "║  Other Docker containers/images/volumes are NOT touched.      ║"
    echo "║  (Full host wipe: re-run with --nuke-all-docker)              ║"
    echo "║                                                               ║"
    echo "║  This is IRREVERSIBLE!                                        ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
fi

echo -n "Are you sure you want to continue? Type 'DELETE' to confirm: "
read confirm < /dev/tty

if [ "$confirm" != "DELETE" ]; then
    echo -e "${YELLOW}Aborted.${NC}"
    exit 1
fi

echo ""

if [ "$NUKE_ALL" = true ]; then
    echo -e "${YELLOW}Starting complete Docker cleanup...${NC}"
    echo ""

    echo -e "${YELLOW}[1/7] Stopping all containers...${NC}"
    if [ "$(docker ps -q)" ]; then
        docker stop $(docker ps -q) 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ All containers stopped${NC}"

    echo -e "${YELLOW}[2/7] Removing all containers...${NC}"
    if [ "$(docker ps -aq)" ]; then
        docker rm -f $(docker ps -aq) 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ All containers removed${NC}"

    echo -e "${YELLOW}[3/7] Removing all images...${NC}"
    if [ "$(docker images -q)" ]; then
        docker rmi -f $(docker images -q) 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ All images removed${NC}"

    echo -e "${YELLOW}[4/7] Removing all volumes...${NC}"
    if [ "$(docker volume ls -q)" ]; then
        docker volume rm -f $(docker volume ls -q) 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ All volumes removed${NC}"

    echo -e "${YELLOW}[5/7] Removing all custom networks...${NC}"
    docker network prune -f 2>/dev/null || true
    echo -e "${GREEN}✓ All custom networks removed${NC}"

    echo -e "${YELLOW}[6/7] Cleaning Docker build cache...${NC}"
    docker system prune -af --volumes 2>/dev/null || true
    echo -e "${GREEN}✓ Docker cache cleaned${NC}"

    echo -e "${YELLOW}[7/7] Removing Dockebase installation...${NC}"
else
    echo -e "${YELLOW}Starting Dockebase uninstall...${NC}"
    echo ""

    # [1/5] Stacks deployed by Dockebase — compose projects live in
    # /opt/dockebase/data/stacks/<stack-id>/ ; blue-green stacks use
    # <stack-id>-blue / <stack-id>-green project names.
    echo -e "${YELLOW}[1/5] Removing stacks deployed by Dockebase...${NC}"
    if [ -d "$DOCKEBASE_DIR/data/stacks" ]; then
        for stack_dir in "$DOCKEBASE_DIR"/data/stacks/*/; do
            [ -d "$stack_dir" ] || continue
            stack_id="$(basename "$stack_dir")"
            for project in "$stack_id" "$stack_id-blue" "$stack_id-green"; do
                docker compose -p "$project" down --volumes --remove-orphans 2>/dev/null || true
            done
            echo -e "${GREEN}  ✓ Removed stack $stack_id${NC}"
        done
    fi
    # Safety net: anything still carrying a compose project label of a known stack id
    if [ -d "$DOCKEBASE_DIR/data/stacks" ]; then
        for stack_dir in "$DOCKEBASE_DIR"/data/stacks/*/; do
            [ -d "$stack_dir" ] || continue
            stack_id="$(basename "$stack_dir")"
            leftovers="$(docker ps -aq --filter "label=com.docker.compose.project=$stack_id" 2>/dev/null || true)"
            if [ -n "$leftovers" ]; then
                docker rm -f $leftovers 2>/dev/null || true
            fi
        done
    fi
    echo -e "${GREEN}✓ Deployed stacks removed${NC}"

    # [2/5] Dockebase's own compose project (api + ui)
    echo -e "${YELLOW}[2/5] Removing Dockebase containers...${NC}"
    if [ -f "$DOCKEBASE_DIR/docker-compose.yml" ]; then
        (cd "$DOCKEBASE_DIR" && docker compose down --volumes --rmi local 2>/dev/null) || true
    fi
    docker rm -f dockebase-api dockebase-ui 2>/dev/null || true
    echo -e "${GREEN}✓ Dockebase containers removed${NC}"

    # [3/5] Proxy + cloudflared containers (created by the API outside compose)
    echo -e "${YELLOW}[3/5] Removing proxy container...${NC}"
    docker rm -f dockebase-caddy dockebase-traefik dockebase-cloudflared 2>/dev/null || true
    docker volume rm dockebase-caddy-data dockebase-caddy-config dockebase-traefik-data 2>/dev/null || true
    echo -e "${GREEN}✓ Proxy removed${NC}"

    # [4/5] Dockebase networks
    echo -e "${YELLOW}[4/5] Removing Dockebase networks...${NC}"
    docker network rm dockebase-internal dockebase-proxy 2>/dev/null || true
    echo -e "${GREEN}✓ Networks removed${NC}"

    echo -e "${YELLOW}[5/5] Removing Dockebase installation...${NC}"
fi

if [ -d "$DOCKEBASE_DIR" ]; then
    rm -rf "$DOCKEBASE_DIR"
    echo -e "${GREEN}✓ Removed $DOCKEBASE_DIR${NC}"
else
    echo -e "${GREEN}✓ No Dockebase installation found${NC}"
fi

# Remove any downloaded install scripts
if [ -f "./install.sh" ]; then
    rm -f "./install.sh"
    echo -e "${GREEN}✓ Removed ./install.sh${NC}"
fi
if [ -f "./delete.sh" ]; then
    rm -f "./delete.sh"
    echo -e "${GREEN}✓ Removed ./delete.sh${NC}"
fi

echo ""
echo -e "${GREEN}✓ Cleanup finished!${NC}"
echo ""
echo "To install Dockebase, run:"
echo ""
echo -e "${YELLOW}  curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/install.sh | sudo bash${NC}"
echo ""
