#!/bin/bash
# Restart script for Digitization Toolkit (Production mode)
# Safely stops and restarts all services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "=========================================="
echo "Restarting Digitization Toolkit"
echo "=========================================="
echo ""

# Stop everything
./scripts/stop.sh

echo ""
echo "→ Waiting 2 seconds before restart..."
sleep 2

echo ""
# Start in production mode
./scripts/start.sh
