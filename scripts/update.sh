#!/bin/bash
# Update Digitization Toolkit to the latest committed code.
#
# This script is safe to run on a live Pi — it stops the service, applies
# changes, runs any new DB migrations, then restarts.
#
# For a network-connected Pi (fetch the latest tested code this repo pins):
#   git pull && git submodule update --init --recursive && sudo ./scripts/update.sh
#
# For an offline update from a USB drive, copy the new repo content first,
# then run this script.
#
# Usage: sudo ./scripts/update.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Resolve real user (same logic as setup.sh)
if [ -n "$SUDO_USER" ]; then
    DTK_USER="$SUDO_USER"
else
    DTK_USER="$(whoami)"
fi
DTK_USER_HOME=$(eval echo "~$DTK_USER")
PIXI_BIN="$DTK_USER_HOME/.pixi/bin/pixi"

run_as_user() {
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" PATH="$DTK_USER_HOME/.pixi/bin:$PATH" "$@"
}

COMPOSE="docker compose -f $PROJECT_ROOT/docker-compose.yml -f $PROJECT_ROOT/docker-compose.pi.yml"

cd "$PROJECT_ROOT"

echo "=========================================="
echo " Digitization Toolkit — Update"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Stop the service
# ---------------------------------------------------------------------------
echo "→ Stopping service..."
systemctl stop dtk 2>/dev/null || true
echo ""

# ---------------------------------------------------------------------------
# 2. Rebuild frontend image (always — picks up any code changes)
# ---------------------------------------------------------------------------
echo "→ Rebuilding frontend image..."
$COMPOSE build frontend
echo ""

# ---------------------------------------------------------------------------
# 3. Update pixi environment (picks up any new backend dependencies)
# ---------------------------------------------------------------------------
echo "→ Updating backend dependencies (pixi)..."
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" install
echo ""

# ---------------------------------------------------------------------------
# 4. Apply any new DB migrations
# ---------------------------------------------------------------------------
cd "$PROJECT_ROOT"
echo "→ Starting database for migrations..."
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "${DATABASE_USER:-user}" -d "${DATABASE_NAME:-digitization_toolkit}" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s."
        $COMPOSE down
        exit 1
    fi
    sleep 2
done

echo "→ Applying migrations..."
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" run db-upgrade
echo ""

echo "→ Stopping database..."
cd "$PROJECT_ROOT"
$COMPOSE down
echo ""

# ---------------------------------------------------------------------------
# 5. Restart the service
# ---------------------------------------------------------------------------
echo "→ Starting service..."
systemctl start dtk
sleep 5
if systemctl is-active --quiet dtk; then
    echo "  Service running ✓"
else
    echo "✗ Service failed to start. Check logs: journalctl -u dtk -n 50"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "=========================================="
echo " Update complete!"
echo "=========================================="
echo ""
echo "  Frontend: http://localhost:3000"
echo "  Backend:  http://localhost:8000/health"
echo "  Logs:     journalctl -u dtk -f"
echo ""
