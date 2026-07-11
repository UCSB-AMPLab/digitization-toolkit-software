#!/bin/bash
# Verify the Docker half of the stack actually came up (NEH-99).
#
# dtk.service (Type=simple) supervises only the *native backend* it execs.
# The database, frontend, and nginx run as Docker containers with their own
# restart policy, so if a container crash-loops at boot, systemd would still
# report the unit "active" — a half-dead stack that looks healthy. This script
# is wired as ExecStartPost in dtk.service: it polls until the containers are
# up and exits non-zero if they are not, so systemd marks the unit *failed*
# and the failure is visible in `systemctl status dtk` / `journalctl -u dtk`.
#
# Scope: this covers STARTUP only. A container that crashes later is handled
# by the compose `restart: unless-stopped` policy; full runtime supervision of
# the containers is out of scope for this unit.
#
# Exit 0 once: db container is healthy AND frontend is running AND (nginx is
# running OR absent). Exit 1 if that state is not reached within the timeout.
# nginx exists only in the Pi overlay (docker-compose.pi.yml); on a dev machine
# it is simply not defined, and its absence must not fail the check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Same compose-file pair as start.sh / stop.sh, so we inspect exactly the
# services those scripts brought up (base + Pi overlay).
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.pi.yml"

# Bounded poll: up to ~60s (30 tries × 2s) for the containers to settle.
MAX_TRIES=30
SLEEP_SECS=2

# Is a service defined in this compose config at all? (nginx is Pi-only.)
service_defined() {
    $COMPOSE config --services 2>/dev/null | grep -qx "$1"
}

# Print the state of a service's container ("running", "exited", "" if none).
service_state() {
    $COMPOSE ps --status running --format '{{.Service}}' 2>/dev/null \
        | grep -qx "$1"
}

# Is the db container reporting healthy per its compose healthcheck?
db_healthy() {
    # `docker inspect` on the db container's health status. Resolve the
    # container id via compose so we honour the project/overlay naming.
    local cid
    cid="$($COMPOSE ps -q db 2>/dev/null | head -n1)"
    [ -n "$cid" ] || return 1
    local status
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
    [ "$status" = "healthy" ]
}

NGINX_DEFINED=false
NGINX_NOTE=""
if service_defined nginx; then
    NGINX_DEFINED=true
    NGINX_NOTE=", nginx running"
fi

echo "→ Verifying stack health (db healthy, frontend running${NGINX_NOTE})..."

for i in $(seq 1 "$MAX_TRIES"); do
    ok=true

    if ! db_healthy; then
        ok=false
    fi

    if ! service_state frontend; then
        ok=false
    fi

    if [ "$NGINX_DEFINED" = true ] && ! service_state nginx; then
        ok=false
    fi

    if [ "$ok" = true ]; then
        echo "✓ Stack healthy: db healthy, frontend running${NGINX_NOTE}."
        exit 0
    fi

    if [ "$i" -lt "$MAX_TRIES" ]; then
        sleep "$SLEEP_SECS"
    fi
done

echo "✗ Stack did not become healthy within $((MAX_TRIES * SLEEP_SECS))s."
echo "  Inspect with:"
echo "    $COMPOSE ps"
echo "    $COMPOSE logs db frontend"
exit 1
