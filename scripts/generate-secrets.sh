#!/bin/bash
# Per-unit secret generation for cloned SD cards (NEH-158)
#
# The distribution model is "provision a golden card, image it, flash many":
# anything on the card at imaging time — .env AND the initialized Postgres
# data directory — is cloned bit-for-bit onto every unit. So SECRET_KEY and
# DATABASE_PASSWORD must be generated per unit, AFTER cloning, not at setup.
#
# This script runs as a systemd oneshot (dtk-secrets.service) before
# dtk.service on every boot and decides, cheaply, whether this machine needs
# fresh secrets. Provenance is tracked by recording the Pi's hardware serial
# in a marker file — a cloned card carries the donor's marker, so the serial
# mismatch is what detects "this is a copy" even though the golden master was
# itself booted and tested before imaging.
#
#   marker matches this serial          -> nothing to do
#   placeholder secrets (any machine)   -> generate + rotate
#   real secrets, no marker             -> adopt as-is (hand-provisioned unit;
#                                          never rotate secrets we didn't make)
#   real secrets, marker from another   -> cloned card: generate + rotate
#     machine
#
# Rotation order is crash-safe: the Postgres password is ALTERed first (via
# the local socket inside the db container, which needs no old password),
# then .env is rewritten atomically, then the marker is stamped. A power cut
# anywhere in between leaves a state this script converges from on next boot.
#
# Backend contract (NEH-54/NEH-55): by the time the backend starts with
# APP_ENV=production, real secrets exist in .env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
MARKER=/var/lib/dtk/secrets-provenance
COMPOSE="docker compose -f $PROJECT_ROOT/docker-compose.yml -f $PROJECT_ROOT/docker-compose.pi.yml"
PG_DATA=/var/lib/dtk/db/postgres

log() { echo "dtk-secrets: $*"; }

# ── Hardware identity ───────────────────────────────────────────────────────
# /etc/machine-id is useless here: a full-disk clone copies it too. The SoC
# serial survives cloning because it lives in silicon, not on the card.
get_serial() {
    if [ -r /proc/device-tree/serial-number ]; then
        tr -d '\0' < /proc/device-tree/serial-number
    else
        awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo
    fi
}
SERIAL="$(get_serial || true)"
if [ -z "$SERIAL" ]; then
    # Non-Pi hardware (dev box): no stable serial, so clone detection is
    # impossible — fall back to placeholder detection only.
    log "no hardware serial available; using placeholder detection only"
    SERIAL="no-serial"
fi

if [ ! -f "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE not found — run setup.sh first"
    exit 1
fi

get_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | xargs; }

SECRET_KEY="$(get_env SECRET_KEY || true)"
DB_PASSWORD="$(get_env DATABASE_PASSWORD || true)"
DB_USER="$(get_env DATABASE_USER || true)"; DB_USER="${DB_USER:-user}"
DB_NAME="$(get_env DATABASE_NAME || true)"; DB_NAME="${DB_NAME:-digitization_toolkit}"

is_placeholder_secret() {
    case "$1" in
        ""|"your-secret-key-here-change-in-production"|"dev-secret-change-me") return 0 ;;
        *) return 1 ;;
    esac
}
is_placeholder_dbpass() {
    case "$1" in
        ""|"change-this-in-production"|"password") return 0 ;;
        *) return 1 ;;
    esac
}

# ── Decide ──────────────────────────────────────────────────────────────────
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$SERIAL" ]; then
    log "secrets already generated on this unit — nothing to do"
    exit 0
fi

if is_placeholder_secret "$SECRET_KEY" || is_placeholder_dbpass "$DB_PASSWORD"; then
    REASON="placeholder secrets in .env"
elif [ ! -f "$MARKER" ]; then
    # Real secrets but no provenance record: a hand-provisioned unit (e.g. the
    # Rionegro card). Adopt them — never rotate secrets we didn't generate.
    log "real secrets with no provenance marker — adopting as hand-provisioned"
    echo "$SERIAL" > "$MARKER"
    exit 0
else
    REASON="marker from another machine ($(cat "$MARKER")) — this card is a clone"
fi

log "generating per-unit secrets: $REASON"
NEW_SECRET="$(openssl rand -hex 32)"
NEW_DBPASS="$(openssl rand -hex 24)"

# ── 1. Rotate the Postgres password first (crash-safe ordering) ─────────────
# Only needed when a data directory already exists (cloned or test-booted
# card). On a never-initialized card, initdb will simply pick up the new
# password from .env on first start. ALTER runs over the container's local
# socket as the cluster superuser, so it works no matter what the old
# password was — which is what makes re-runs after a mid-rotation power cut
# converge.
if [ -f "$PG_DATA/PG_VERSION" ]; then
    log "rotating Postgres password for existing data directory..."
    cd "$PROJECT_ROOT"
    $COMPOSE up -d db >/dev/null
    for i in $(seq 1 30); do
        if $COMPOSE exec -T db pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
            break
        fi
        if [ "$i" -eq 30 ]; then
            log "ERROR: database did not become ready — leaving secrets untouched"
            $COMPOSE stop db >/dev/null 2>&1 || true
            exit 1
        fi
        sleep 2
    done
    $COMPOSE exec -T db psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
        -c "ALTER USER \"$DB_USER\" WITH PASSWORD '$NEW_DBPASS';" >/dev/null
    $COMPOSE stop db >/dev/null
    log "Postgres password rotated"
else
    log "no Postgres data directory yet — initdb will use the new password"
fi

# ── 2. Rewrite .env atomically ───────────────────────────────────────────────
set_env() {
    local var="$1" val="$2"
    if grep -qE "^$var=" "$TMP_ENV"; then
        sed -i "s|^$var=.*|$var=$val|" "$TMP_ENV"
    else
        echo "$var=$val" >> "$TMP_ENV"
    fi
}
TMP_ENV="$(mktemp "$PROJECT_ROOT/.env.XXXXXX")"
cp "$ENV_FILE" "$TMP_ENV"
set_env SECRET_KEY "$NEW_SECRET"
set_env DATABASE_PASSWORD "$NEW_DBPASS"
chown --reference="$ENV_FILE" "$TMP_ENV"
chmod --reference="$ENV_FILE" "$TMP_ENV"
mv "$TMP_ENV" "$ENV_FILE"
sync

# ── 3. Stamp provenance ──────────────────────────────────────────────────────
echo "$SERIAL" > "$MARKER"
sync
log "done — this unit now has its own SECRET_KEY and DATABASE_PASSWORD"
