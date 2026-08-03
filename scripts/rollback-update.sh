#!/bin/bash
# Roll back a Digitization Toolkit update: restore the pre-update database
# snapshot and return the code to the commit it was on before the update.
#
# This is the companion to scripts/update.sh. update.sh writes, before it
# migrates:
#   • a gzipped SQL dump  →  /var/lib/dtk/backups/pre-update-YYYYmmdd-HHMMSS.sql.gz
#   • the pre-update commit  →  /var/lib/dtk/backups/pre-update-SHA
#
# What this script does, loudly, for possibly non-technical venue staff:
#   1. Stops the appliance.
#   2. Restores the newest (or a named) database dump into PostgreSQL,
#      REPLACING the current database contents.
#   3. Checks out the pre-update superproject commit and syncs submodules to
#      the pins that commit records (no --remote — pins are respected).
#   4. Restarts the service and reports what happened.
#
# Usage:
#   sudo ./scripts/rollback-update.sh                       # newest dump
#   sudo ./scripts/rollback-update.sh <dump-file.sql.gz>    # a specific dump
#   sudo ./scripts/rollback-update.sh --yes                 # skip confirmation
#
# WARNING: restoring a dump DISCARDS any data written since that dump was taken.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BACKUP_DIR="/var/lib/dtk/backups"
SHA_FILE="$BACKUP_DIR/pre-update-SHA"

ASSUME_YES=0
DUMP_ARG=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help)
            echo "Usage: sudo ./scripts/rollback-update.sh [--yes] [<dump-file.sql.gz>]"
            exit 0 ;;
        -*)
            echo "✗ Unknown option: $arg"
            echo "Usage: sudo ./scripts/rollback-update.sh [--yes] [<dump-file.sql.gz>]"
            exit 2 ;;
        *)
            if [ -n "$DUMP_ARG" ]; then
                echo "✗ Too many arguments: got both '$DUMP_ARG' and '$arg'."
                echo "  Name at most one dump file."
                echo "Usage: sudo ./scripts/rollback-update.sh [--yes] [<dump-file.sql.gz>]"
                exit 2
            fi
            DUMP_ARG="$arg" ;;
    esac
done

# Load DB credentials the same way update.sh / docker compose do.
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_ROOT/.env"
    set +a
fi
DATABASE_USER="${DATABASE_USER:-user}"
DATABASE_NAME="${DATABASE_NAME:-digitization_toolkit}"

# Resolve real user (same logic as setup.sh / update.sh)
if [ -n "$SUDO_USER" ]; then
    DTK_USER="$SUDO_USER"
else
    DTK_USER="$(whoami)"
fi

COMPOSE="docker compose -f $PROJECT_ROOT/docker-compose.yml -f $PROJECT_ROOT/docker-compose.pi.yml"

cd "$PROJECT_ROOT"

echo "=========================================="
echo " Digitization Toolkit — ROLL BACK an update"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Work out which dump to restore.
# ---------------------------------------------------------------------------
if [ -n "$DUMP_ARG" ]; then
    if [ -f "$DUMP_ARG" ]; then
        DUMP_FILE="$DUMP_ARG"
    elif [ -f "$BACKUP_DIR/$DUMP_ARG" ]; then
        DUMP_FILE="$BACKUP_DIR/$DUMP_ARG"
    else
        echo "✗ Named backup not found: $DUMP_ARG"
        echo "  Available backups in $BACKUP_DIR:"
        ls -1t "$BACKUP_DIR"/pre-update-*.sql.gz 2>/dev/null || echo "    (none)"
        exit 1
    fi
else
    # Filenames are our own fixed timestamped pattern; ls -t sorting is safe.
    # shellcheck disable=SC2012
    DUMP_FILE="$(ls -1t "$BACKUP_DIR"/pre-update-*.sql.gz 2>/dev/null | head -n 1 || true)"
    if [ -z "$DUMP_FILE" ]; then
        echo "✗ No backups found in $BACKUP_DIR."
        echo "  Nothing to roll back to. Aborting (nothing changed)."
        exit 1
    fi
fi

# Sanity: the dump must be non-trivial (an empty pg_dump gzips to ~20 bytes).
DUMP_BYTES="$(wc -c < "$DUMP_FILE" | tr -d ' ')"
if [ "${DUMP_BYTES:-0}" -lt 100 ]; then
    echo "✗ Backup looks empty (${DUMP_BYTES} bytes): $DUMP_FILE"
    echo "  Refusing to restore from a broken backup. Aborting (nothing changed)."
    exit 1
fi

# Target commit (may be absent on older backups — code rollback is then skipped).
if [ -f "$SHA_FILE" ]; then
    TARGET_SHA="$(cat "$SHA_FILE" 2>/dev/null || echo "")"
else
    TARGET_SHA=""
fi

echo "This will:"
echo "  • RESTORE the database from:"
echo "      $DUMP_FILE   (${DUMP_BYTES} bytes)"
echo "    ⚠  This DISCARDS anything saved since that backup was taken."
if [ -n "$TARGET_SHA" ]; then
    echo "  • Return the code to commit: $TARGET_SHA"
else
    echo "  • (No pre-update commit recorded — code will be left as-is.)"
fi
echo "  • Restart the appliance."
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo "✗ No terminal to confirm on, and --yes was not given. Aborting."
        exit 1
    fi
    printf "Proceed with rollback? [y/N] "
    read -r reply
    case "$reply" in
        y|Y|yes|YES) echo "" ;;
        *) echo ""; echo "Aborted by operator. Nothing changed."; exit 1 ;;
    esac
fi

# ---------------------------------------------------------------------------
# 2. Stop the appliance.
# ---------------------------------------------------------------------------
echo "→ Stopping the appliance..."
systemctl stop dtk 2>/dev/null || true
$COMPOSE down --remove-orphans >/dev/null 2>&1 || true
echo ""

# ---------------------------------------------------------------------------
# 3. Restore the database.
#    Start only the db container, wait for it, drop & recreate the database so
#    the restore lands in a clean state, then load the dump.
# ---------------------------------------------------------------------------
echo "→ Starting the database container..."
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s. Aborting."
        echo "  The dump at $DUMP_FILE is intact; you can retry the rollback."
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
        exit 1
    fi
    sleep 2
done

echo "→ Restoring the database (dropping and recreating '$DATABASE_NAME')..."
# Terminate other sessions, then drop/recreate via the maintenance 'postgres'
# database so we are not connected to the DB we are dropping.
$COMPOSE exec -T db psql -U "$DATABASE_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DATABASE_NAME' AND pid <> pg_backend_pid();" \
    >/dev/null
$COMPOSE exec -T db psql -U "$DATABASE_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$DATABASE_NAME\";" \
    -c "CREATE DATABASE \"$DATABASE_NAME\" OWNER \"$DATABASE_USER\";" \
    >/dev/null

set -o pipefail
if ! gunzip -c "$DUMP_FILE" | $COMPOSE exec -T db psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -v ON_ERROR_STOP=1 >/dev/null; then
    set +o pipefail
    echo "✗ Restore FAILED while loading the dump."
    echo "  The database may be in a partial state. The dump file itself is"
    echo "  intact at: $DUMP_FILE"
    echo "  Do NOT start the service until this is resolved. Get technical help."
    $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    exit 1
fi
set +o pipefail
echo "  ✓ Database restored from backup."
echo ""

echo "→ Stopping the database container..."
$COMPOSE down --remove-orphans
echo ""

# ---------------------------------------------------------------------------
# 4. Return the code to the pre-update commit (pins respected — no --remote).
# ---------------------------------------------------------------------------
CODE_ROLLED_BACK=0
if [ -n "$TARGET_SHA" ]; then
    if git -C "$PROJECT_ROOT" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null; then
        echo "→ Returning code to commit $TARGET_SHA ..."
        # Run git as the repo owner to avoid dubious-ownership issues under sudo.
        sudo -u "$DTK_USER" git -C "$PROJECT_ROOT" checkout "$TARGET_SHA"
        sudo -u "$DTK_USER" git -C "$PROJECT_ROOT" submodule update --init --recursive
        CODE_ROLLED_BACK=1
        echo "  ✓ Code restored to the pre-update version."
    else
        echo "⚠ Recorded commit $TARGET_SHA is not present locally."
        echo "  Skipping code rollback — the database was still restored."
        echo "  You may need to check out the previous version manually."
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# 5. Restart the service.
# ---------------------------------------------------------------------------
echo "→ Starting the appliance..."
systemctl start dtk
sleep 5
SERVICE_OK=0
if systemctl is-active --quiet dtk; then
    SERVICE_OK=1
fi

# ---------------------------------------------------------------------------
# What happened
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " Rollback summary"
echo "=========================================="
echo "  Database:  RESTORED from $DUMP_FILE"
if [ "$CODE_ROLLED_BACK" -eq 1 ]; then
    echo "  Code:      restored to $TARGET_SHA"
elif [ -n "$TARGET_SHA" ]; then
    echo "  Code:      NOT changed (commit $TARGET_SHA unavailable) — see warning above"
else
    echo "  Code:      NOT changed (no pre-update commit was recorded)"
fi
if [ "$SERVICE_OK" -eq 1 ]; then
    echo "  Service:   running ✓"
    echo ""
    echo "  The appliance is back on the previous version."
else
    echo "  Service:   ✗ did NOT come back up"
    echo ""
    echo "  Check logs:  journalctl -u dtk -n 50"
fi
echo ""
