#!/bin/bash
# Update Digitization Toolkit to the latest committed code.
#
# This script guards IRREPLACEABLE archival data. It is designed to be safe to
# run on a live Pi at a remote venue, possibly by non-technical staff:
#
#   • All network / compile work (frontend build, pixi install) happens BEFORE
#     the running service is stopped, so a failure there leaves the old, working
#     stack untouched and still serving.
#   • Before any migration a timestamped pg_dump is taken and verified non-empty;
#     the pre-update superproject commit is recorded so a botched update can be
#     rolled back with scripts/rollback-update.sh.
#   • If anything fails after the service is stopped, an EXIT trap restarts the
#     previous stack and tells the operator the unit is back on the old version.
#   • Before starting, it checks whether the update changed dependency manifests
#     (which need the npm / conda registries) and, if so, warns the operator that
#     internet is required and lets them abort.
#
# For a network-connected Pi (fetch the latest tested code this repo pins):
#   git pull && git submodule update --init --recursive && sudo ./scripts/update.sh
#
# For an offline update from a USB drive, copy the new repo content first,
# then run this script.
#
# Usage: sudo ./scripts/update.sh [--yes]
#   --yes   Skip the "this update needs internet" confirmation prompt
#           (for scripted / unattended use).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        *) echo "Unknown argument: $arg"; echo "Usage: sudo ./scripts/update.sh [--yes]"; exit 2 ;;
    esac
done

# Load DB credentials the same way docker compose does: from the project .env.
# The bare ${VAR:-default} fallbacks below only apply if .env is absent, so the
# pg_dump and pg_isready calls talk to the DB with the SAME user the container
# was created with.
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_ROOT/.env"
    set +a
fi
DATABASE_USER="${DATABASE_USER:-user}"
DATABASE_NAME="${DATABASE_NAME:-digitization_toolkit}"

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

# Backup location (also used by rollback-update.sh — keep these in sync).
BACKUP_DIR="/var/lib/dtk/backups"
SHA_FILE="$BACKUP_DIR/pre-update-SHA"
LAST_DEPLOYED_SHA_FILE="$BACKUP_DIR/last-deployed-SHA"
KEEP_DUMPS=5

cd "$PROJECT_ROOT"

echo "=========================================="
echo " Digitization Toolkit — Update"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 0. Safety net: if we fail AFTER stopping the service, bring the old stack
#    back up so the venue is never left with a dead appliance. Armed just
#    before we stop the service (see step 6); until then failures are harmless
#    because the running stack was never touched.
# ---------------------------------------------------------------------------
SERVICE_STOPPED=0
UPDATE_OK=0
DB_STARTED_BY_US=0
DUMP_FILE=""
BACKUP_VERIFIED=0

restore_service() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  UPDATE FAILED — bringing the appliance back up"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    echo "  Something went wrong during the update. Restarting the unit"
    echo "  so it is not left dead..."
    echo ""
    # Make sure nothing is half-up before we restart cleanly.
    $COMPOSE down >/dev/null 2>&1 || true
    systemctl start dtk 2>/dev/null || true
    sleep 5
    if systemctl is-active --quiet dtk; then
        echo "  ✓ The appliance is back online."
    else
        echo "  ✗ The appliance did NOT come back up automatically."
        echo "    Check logs:  journalctl -u dtk -n 50"
    fi
    echo ""
    echo "  IMPORTANT: the failure happened after the service was stopped for"
    echo "  migration, so the database MAY have been partially (or fully)"
    echo "  migrated. A pre-update backup was saved in: $BACKUP_DIR"
    echo "  To return fully to the previous version (database and code), run:"
    echo "    sudo $SCRIPT_DIR/rollback-update.sh"
    echo ""
}

on_exit() {
    local rc=$?
    if [ "$UPDATE_OK" -eq 1 ]; then
        return 0
    fi
    if [ "$SERVICE_STOPPED" -eq 1 ]; then
        restore_service
    else
        # Pre-stop failure: the running stack was never touched. Clean up only
        # what this script itself created.
        if [ -n "$DUMP_FILE" ] && [ "$BACKUP_VERIFIED" -eq 0 ]; then
            # Never leave a partial/unverified dump behind — rollback-update.sh
            # picks the newest dump and must not find a broken one.
            rm -f "$DUMP_FILE"
        fi
        if [ "$DB_STARTED_BY_US" -eq 1 ]; then
            # We started the db container ourselves; stop it again. Nothing
            # else is touched.
            $COMPOSE stop db >/dev/null 2>&1 || true
        fi
        echo ""
        echo "✗ Update aborted before the running service was touched."
        echo "  The appliance is still serving the current version — nothing changed."
        echo ""
    fi
    exit "$rc"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# 1. Note the commit being installed. Since the operator pulls/checks out the
#    new code BEFORE running this script (see header), HEAD is the NEW version;
#    the rollback target is the previously deployed commit, handled in step 5.
# ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
CURRENT_SHA="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
echo "→ Version being installed: $CURRENT_SHA"
echo ""

# ---------------------------------------------------------------------------
# 2. Honesty check: does this update need the internet?
#    package.json / pixi.toml live INSIDE the frontend & backend submodules,
#    so in the superproject a dependency change shows up as a moved submodule
#    pointer. We compare the last successfully-deployed commit against HEAD.
#    If a submodule pointer moved we warn — and, when the submodule contents
#    are available locally, we confirm precisely whether a manifest changed.
# ---------------------------------------------------------------------------
NEEDS_INTERNET=0
if [ -f "$LAST_DEPLOYED_SHA_FILE" ]; then
    PREV_DEPLOYED_SHA="$(cat "$LAST_DEPLOYED_SHA_FILE" 2>/dev/null || echo "")"
else
    PREV_DEPLOYED_SHA=""
fi

if [ -n "$PREV_DEPLOYED_SHA" ] && [ "$PREV_DEPLOYED_SHA" != "$CURRENT_SHA" ] \
   && git -C "$PROJECT_ROOT" cat-file -e "$PREV_DEPLOYED_SHA^{commit}" 2>/dev/null; then
    CHANGED_GITLINKS="$(git -C "$PROJECT_ROOT" diff --name-only "$PREV_DEPLOYED_SHA" "$CURRENT_SHA" -- frontend backend 2>/dev/null || echo "")"
    if [ -n "$CHANGED_GITLINKS" ]; then
        # A submodule pointer moved. Try to confirm whether a dependency
        # manifest actually changed inside it; fall back to a conservative
        # warning if we cannot resolve the submodule commits offline.
        for sub in frontend backend; do
            case "$sub" in
                frontend) manifests="package.json package-lock.json" ;;
                backend)  manifests="pixi.toml pixi.lock package.json package-lock.json" ;;
            esac
            OLD_SUB="$(git -C "$PROJECT_ROOT" rev-parse "$PREV_DEPLOYED_SHA:$sub" 2>/dev/null || echo "")"
            NEW_SUB="$(git -C "$PROJECT_ROOT" rev-parse "$CURRENT_SHA:$sub" 2>/dev/null || echo "")"
            [ "$OLD_SUB" = "$NEW_SUB" ] && continue
            if [ -d "$PROJECT_ROOT/$sub/.git" ] || [ -f "$PROJECT_ROOT/$sub/.git" ]; then
                if git -C "$PROJECT_ROOT/$sub" cat-file -e "$OLD_SUB^{commit}" 2>/dev/null \
                   && git -C "$PROJECT_ROOT/$sub" cat-file -e "$NEW_SUB^{commit}" 2>/dev/null; then
                    # $manifests is a space-separated list of pathspecs; word
                    # splitting is intended here.
                    # shellcheck disable=SC2086
                    if [ -n "$(git -C "$PROJECT_ROOT/$sub" diff --name-only "$OLD_SUB" "$NEW_SUB" -- $manifests 2>/dev/null)" ]; then
                        NEEDS_INTERNET=1
                        echo "  • $sub dependencies changed ($manifests)."
                    fi
                    continue
                fi
            fi
            # Could not resolve the submodule commits locally — be conservative.
            NEEDS_INTERNET=1
            echo "  • $sub pointer moved; cannot confirm dependencies offline."
        done
    fi
else
    # No record of a previous deploy (first run of this newer update.sh), or
    # the recorded commit is unreachable. We cannot prove the update is
    # offline-safe, so warn conservatively.
    NEEDS_INTERNET=1
    echo "  • No previous-deploy record found — cannot confirm this update is offline-safe."
fi

if [ "$NEEDS_INTERNET" -eq 1 ]; then
    echo ""
    echo "⚠  This update may need INTERNET access."
    echo "   It rebuilds the frontend and/or re-solves backend dependencies,"
    echo "   which can reach the npm / conda registries. If this appliance is"
    echo "   offline right now, the update will likely fail partway."
    echo ""
    if [ "$ASSUME_YES" -eq 1 ]; then
        echo "   --yes given: continuing without prompting."
        echo ""
    elif [ ! -t 0 ]; then
        echo "✗ No terminal to confirm on, and --yes was not given. Aborting."
        echo "  Re-run with internet available, or pass --yes to proceed anyway."
        exit 1
    else
        printf "   Continue anyway? [y/N] "
        read -r reply
        case "$reply" in
            y|Y|yes|YES) echo "" ;;
            *) echo ""; echo "Aborted by operator. Nothing changed."; exit 1 ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# 3. Rebuild frontend image (network/compile risk — done BEFORE stopping).
# ---------------------------------------------------------------------------
echo "→ Rebuilding frontend image..."
$COMPOSE build frontend
echo ""

# ---------------------------------------------------------------------------
# 4. Update pixi environment (network risk — done BEFORE stopping).
# ---------------------------------------------------------------------------
echo "→ Updating backend dependencies (pixi)..."
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" install
cd "$PROJECT_ROOT"
echo ""

# ---------------------------------------------------------------------------
# 5. Pre-migration backup. The old stack is STILL RUNNING and serving, so this
#    dump is a consistent snapshot of live data before we change anything.
#    (pg_dump takes a single transactional snapshot, so it is safe to run while
#    the app is live.) We take and verify the dump BEFORE stopping anything, so
#    a backup failure aborts the update with the appliance untouched.
# ---------------------------------------------------------------------------
echo "→ Making sure the database is up so we can back it up..."
# If the service is running, the db container is already up and we must not
# touch it (or anything else) on failure — the stack was never stopped. Only
# if we start db ourselves here do we stop it (and only it) when aborting.
if ! $COMPOSE ps --services --status running 2>/dev/null | grep -qx db; then
    DB_STARTED_BY_US=1
fi
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s — cannot take a safe backup."
        echo "  Aborting the update; the running appliance was not touched."
        exit 1   # EXIT trap: pre-stop path, scoped cleanup only
    fi
    sleep 2
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DUMP_FILE="$BACKUP_DIR/pre-update-$TIMESTAMP.sql.gz"
echo "→ Backing up the database to:"
echo "    $DUMP_FILE"
# Pipe pg_dump through gzip. set -o pipefail so a pg_dump failure fails the line
# even though gzip exits 0.
set -o pipefail
$COMPOSE exec -T db pg_dump -U "$DATABASE_USER" -d "$DATABASE_NAME" | gzip > "$DUMP_FILE"
set +o pipefail

# A failed pg_dump can still leave a tiny valid gzip (an empty stream gzips to
# ~20 bytes). Refuse to proceed if the dump looks empty — better to abort than
# to migrate with no real safety net.
DUMP_BYTES="$(wc -c < "$DUMP_FILE" | tr -d ' ')"
if [ "${DUMP_BYTES:-0}" -lt 100 ]; then
    echo "✗ Backup looks empty (${DUMP_BYTES} bytes) — pg_dump likely failed."
    echo "  Refusing to migrate without a real backup. Aborting; the running"
    echo "  appliance was not touched."
    exit 1   # EXIT trap: pre-stop path removes the bad dump, scoped cleanup only
fi
BACKUP_VERIFIED=1
echo "  ✓ Backup written (${DUMP_BYTES} bytes)."

# Record the commit to roll back to, next to the dump, for rollback-update.sh.
# IMPORTANT: this script runs AFTER the operator has already pulled / checked
# out the new code (see header), so HEAD ($CURRENT_SHA) is the NEW version.
# The rollback target is the commit that was RUNNING before this update — the
# one the last successful update recorded in last-deployed-SHA — never HEAD.
if [ -n "$PREV_DEPLOYED_SHA" ]; then
    echo "$PREV_DEPLOYED_SHA" > "$SHA_FILE"
    echo "  Rollback target recorded: $PREV_DEPLOYED_SHA"
else
    # No record of the previously deployed version. Writing HEAD here would
    # make rollback-update.sh "roll back" to the very version being installed,
    # so record nothing: the DB restore still works without it.
    rm -f "$SHA_FILE"
    echo "  ⚠ No record of the previously deployed version — if this update"
    echo "    needs rolling back, rollback-update.sh will restore the database"
    echo "    but cannot switch the code back automatically."
fi

# Retention: keep only the newest $KEEP_DUMPS dumps.
echo "→ Pruning old backups (keeping newest $KEEP_DUMPS)..."
# Filenames are our own fixed timestamped pattern; ls -t sorting is safe here.
# shellcheck disable=SC2012
ls -1t "$BACKUP_DIR"/pre-update-*.sql.gz 2>/dev/null | tail -n +$((KEEP_DUMPS + 1)) | while read -r old; do
    echo "    removing $old"
    rm -f "$old"
done
echo ""

# ---------------------------------------------------------------------------
# 6. Stop the service. From HERE the EXIT trap will restart the stack on any
#    failure. (The db container — whether it was already up under the service
#    or started by us for the backup — is stopped by systemd's stop path via
#    docker compose; we bring it back for the migration below.)
# ---------------------------------------------------------------------------
echo "→ Stopping service to apply migrations..."
SERVICE_STOPPED=1
systemctl stop dtk 2>/dev/null || true
echo ""

# ---------------------------------------------------------------------------
# 7. Apply DB migrations.
# ---------------------------------------------------------------------------
echo "→ Starting database for migrations..."
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s."
        exit 1   # EXIT trap restores the previous stack
    fi
    sleep 2
done

echo "→ Applying migrations..."
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" run db-upgrade
cd "$PROJECT_ROOT"
echo ""

echo "→ Stopping database..."
$COMPOSE down
echo ""

# ---------------------------------------------------------------------------
# 8. Restart the service on the new version.
# ---------------------------------------------------------------------------
echo "→ Starting service..."
systemctl start dtk
sleep 5
if systemctl is-active --quiet dtk; then
    echo "  Service running ✓"
else
    echo "✗ Service failed to start on the new version."
    exit 1   # EXIT trap restores the previous stack
fi
echo ""

# Success: record this commit as the last good deploy, and disarm the trap.
echo "$CURRENT_SHA" > "$LAST_DEPLOYED_SHA_FILE"
UPDATE_OK=1
SERVICE_STOPPED=0

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "=========================================="
echo " Update complete!"
echo "=========================================="
echo ""
echo "  Now running version: $CURRENT_SHA"
echo "  A pre-update backup was saved at:"
echo "    $DUMP_FILE"
echo "  If something looks wrong, you can roll back with:"
echo "    sudo $SCRIPT_DIR/rollback-update.sh"
echo ""
echo "  Frontend: http://localhost:3000"
echo "  Backend:  http://localhost:8000/health"
echo "  Logs:     journalctl -u dtk -f"
echo ""
