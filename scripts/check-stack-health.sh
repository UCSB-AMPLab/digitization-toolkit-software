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
# Exit 0 once: db container is healthy AND its published port answers on the
# host AND frontend is running AND (nginx is running OR absent). Exit 1 if
# that state is not reached within the timeout.
# nginx exists only in the Pi overlay (docker-compose.pi.yml); on a dev machine
# it is simply not defined, and its absence must not fail the check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Same compose-file pair as start.sh / stop.sh, so we inspect exactly the
# services those scripts brought up (base + Pi overlay).
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.pi.yml"

# Bounded poll: up to ~60s (30 tries × 2s) by default for the containers to
# settle. Tunable per hardware/venue via environment (e.g. in a dtk.service
# drop-in: Environment=DTK_HEALTH_MAX_TRIES=60) without editing this script.
MAX_TRIES="${DTK_HEALTH_MAX_TRIES:-30}"
SLEEP_SECS="${DTK_HEALTH_SLEEP_SECS:-2}"

# Is a service defined in this compose config at all? (nginx is Pi-only.)
service_defined() {
    $COMPOSE config --services 2>/dev/null | grep -qx "$1"
}

# Succeed iff the service has a container in the "running" set.
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

# Is the db's published port actually LISTENING on the host? The container
# healthcheck runs inside the container: after a botched teardown the db can
# report healthy while detached from the project network, with nothing on
# 127.0.0.1:5432 (Rionegro, 2026-08-03). ss is a positive listen check that
# makes no connection; if ss is unavailable, skip rather than fail the boot
# on missing tooling. grep without -q reads to EOF (pipefail-safe).
db_port_listening() {
    command -v ss >/dev/null 2>&1 || return 0
    ss -ltn 2>/dev/null | grep -E '[:.]5432[[:space:]]' >/dev/null
}

NGINX_DEFINED=false
NGINX_NOTE=""
if service_defined nginx; then
    NGINX_DEFINED=true
    NGINX_NOTE=", nginx running"
fi

echo "→ Verifying stack health (db healthy + listening on host, frontend running${NGINX_NOTE})..."

for i in $(seq 1 "$MAX_TRIES"); do
    ok=true

    if ! db_healthy; then
        ok=false
    fi

    if ! db_port_listening; then
        ok=false
    fi

    if ! service_state frontend; then
        ok=false
    fi

    if [ "$NGINX_DEFINED" = true ] && ! service_state nginx; then
        ok=false
    fi

    if [ "$ok" = true ]; then
        echo "✓ Stack healthy: db healthy and listening on the host, frontend running${NGINX_NOTE}."
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
echo "    ss -ltn | grep 5432    # is the db port published on the host?"
exit 1
