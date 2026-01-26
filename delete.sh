#!/bin/bash

# =============================================================================
# Dockebase Complete Cleanup Script
# =============================================================================
# WARNING: This script will DELETE EVERYTHING:
# - All Docker containers, images, volumes, networks
# - All Dockebase data (database, stacks, configs)
# - Docker build cache
#
# Use this for a completely fresh start.
# =============================================================================

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                    ⚠️  WARNING ⚠️                              ║"
echo "║                                                               ║"
echo "║  This will DELETE EVERYTHING:                                 ║"
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

echo -n "Are you sure you want to continue? Type 'DELETE' to confirm: "
read confirm < /dev/tty

if [ "$confirm" != "DELETE" ]; then
    echo -e "${YELLOW}Aborted.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Starting complete cleanup...${NC}"
echo ""

# Stop all running containers
echo -e "${YELLOW}[1/7] Stopping all containers...${NC}"
if [ "$(docker ps -q)" ]; then
    docker stop $(docker ps -q) 2>/dev/null || true
fi
echo -e "${GREEN}✓ All containers stopped${NC}"

# Remove all containers
echo -e "${YELLOW}[2/7] Removing all containers...${NC}"
if [ "$(docker ps -aq)" ]; then
    docker rm -f $(docker ps -aq) 2>/dev/null || true
fi
echo -e "${GREEN}✓ All containers removed${NC}"

# Remove all images
echo -e "${YELLOW}[3/7] Removing all images...${NC}"
if [ "$(docker images -q)" ]; then
    docker rmi -f $(docker images -q) 2>/dev/null || true
fi
echo -e "${GREEN}✓ All images removed${NC}"

# Remove all volumes
echo -e "${YELLOW}[4/7] Removing all volumes...${NC}"
if [ "$(docker volume ls -q)" ]; then
    docker volume rm -f $(docker volume ls -q) 2>/dev/null || true
fi
echo -e "${GREEN}✓ All volumes removed${NC}"

# Remove all networks (except default ones)
echo -e "${YELLOW}[5/7] Removing all custom networks...${NC}"
docker network prune -f 2>/dev/null || true
echo -e "${GREEN}✓ All custom networks removed${NC}"

# Docker system prune (removes build cache, dangling images, etc.)
echo -e "${YELLOW}[6/7] Cleaning Docker build cache...${NC}"
docker system prune -af --volumes 2>/dev/null || true
echo -e "${GREEN}✓ Docker cache cleaned${NC}"

# Remove Dockebase installation
echo -e "${YELLOW}[7/7] Removing Dockebase installation...${NC}"
DOCKEBASE_DIR="/opt/dockebase"
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
echo -e "${GREEN}✓ Complete cleanup finished!${NC}"
echo ""
echo "To install Dockebase, run:"
echo ""
echo -e "${YELLOW}  curl -fsSL https://raw.githubusercontent.com/dockebase/dockebase-alpha-images/main/install.sh | bash${NC}"
echo ""
