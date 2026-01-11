#!/bin/bash
# Production startup script for Digitization Toolkit
# Starts database + frontend in Docker, then native backend with camera support

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "=========================================="
echo "Starting Digitization Toolkit (Production)"
echo "=========================================="
echo ""

# Start Docker services (DB + Frontend)
echo "→ Starting database and frontend containers..."
docker compose up -d

echo ""
echo "→ Waiting for database to be ready..."
sleep 3

# Check if database is healthy
if ! docker compose ps | grep -q "db.*healthy"; then
    echo "⚠ Warning: Database may still be starting up"
fi

echo ""
# Start native backend
./scripts/run_backend_native.sh
