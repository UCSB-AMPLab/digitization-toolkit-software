#!/bin/bash
# Stop script for Digitization Toolkit
# Safely stops all services (Docker containers + native backend)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "=========================================="
echo "Stopping Digitization Toolkit"
echo "=========================================="
echo ""

# Stop native backend if running
echo "→ Checking for native backend process..."
BACKEND_PID=$(ps aux | grep "[u]vicorn app.main:app" | awk '{print $2}')

if [ -n "$BACKEND_PID" ]; then
    echo "  Found backend process (PID: $BACKEND_PID)"
    kill -SIGTERM $BACKEND_PID 2>/dev/null || true
    sleep 2
    
    # Force kill if still running
    if ps -p $BACKEND_PID > /dev/null 2>&1; then
        echo "  Backend didn't stop gracefully, forcing..."
        kill -9 $BACKEND_PID 2>/dev/null || true
    fi
    echo "  ✓ Native backend stopped"
else
    echo "  No native backend process found"
fi

echo ""
echo "→ Stopping Docker containers..."
docker compose down

echo ""
echo "✓ All services stopped"
echo ""
