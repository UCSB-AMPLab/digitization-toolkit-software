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
# Uses docker-compose.pi.yml overlay for proper appliance volume paths (/var/lib/dtk, /var/log/dtk)
echo "→ Starting database and frontend containers..."
# --pull never: skip registry checks (device is offline after initial build)
# --wait: block until services report healthy (db) or running (others) before
# we launch the native backend below, so it doesn't race Postgres startup
# --remove-orphans: clear containers from services dropped between releases;
# a stale one blocks network reconciliation and detaches the db (NEH-214).
# If clearing fails, the unit fails VISIBLY (systemd marks it failed) rather
# than serving with a silently degraded stack.
docker compose -f docker-compose.yml -f docker-compose.pi.yml up -d --pull never --wait --remove-orphans

echo ""
echo "→ Starting native backend with pixi..."
PIXI="${HOME}/.pixi/bin/pixi"
if [ ! -x "$PIXI" ]; then
    PIXI="$(command -v pixi 2>/dev/null || echo pixi)"
fi
cd "$PROJECT_ROOT/backend" && "$PIXI" run start
