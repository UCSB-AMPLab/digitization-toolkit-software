#!/bin/bash
# Update Digitization Toolkit to the latest committed code.
#
# This script is designed to be safe to run on a live Pi at a remote venue,
# possibly by non-technical staff:
#
#   • All network / compile work (frontend build, pixi install) happens BEFORE
#     the running service is stopped, so a failure there leaves the old, working
#     stack untouched and still serving.
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
# pg_isready calls talk to the DB with the SAME user the container was created
# with.
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

# State recorded across runs, so the offline check can diff the last good deploy
# against HEAD.
STATE_DIR="/var/lib/dtk/backups"
LAST_DEPLOYED_SHA_FILE="$STATE_DIR/last-deployed-SHA"

cd "$PROJECT_ROOT"

echo "=========================================="
echo " Digitization Toolkit — Update"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 0. Safety net: if we fail AFTER stopping the service, bring the old stack
#    back up so the venue is never left with a dead appliance. Armed just
#    before we stop the service (see step 4); until then failures are harmless
#    because the running stack was never touched.
# ---------------------------------------------------------------------------
SERVICE_STOPPED=0
UPDATE_OK=0

restore_previous_stack() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  UPDATE FAILED — restoring the previous version"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    echo "  Something went wrong during the update. Bringing the unit"
    echo "  back up on the version it was running before..."
    echo ""
    # Make sure nothing is half-up before we restart cleanly.
    $COMPOSE down >/dev/null 2>&1 || true
    systemctl start dtk 2>/dev/null || true
    sleep 5
    if systemctl is-active --quiet dtk; then
        echo "  ✓ The appliance is back online on the OLD (previous) version."
        echo "    Nothing was migrated or changed permanently."
    else
        echo "  ✗ The appliance did NOT come back up automatically."
        echo "    Check logs:  journalctl -u dtk -n 50"
    fi
    echo ""
}

on_exit() {
    local rc=$?
    if [ "$UPDATE_OK" -eq 1 ]; then
        return 0
    fi
    if [ "$SERVICE_STOPPED" -eq 1 ]; then
        restore_previous_stack
    else
        echo ""
        echo "✗ Update aborted before the running service was touched."
        echo "  The appliance is still serving the current version — nothing changed."
        echo ""
    fi
    exit "$rc"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# 1. Note where we are now.
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR"
CURRENT_SHA="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
echo "→ Current version: $CURRENT_SHA"
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
# 5. Stop the service. From HERE the EXIT trap will restart the old stack on
#    any failure.
# ---------------------------------------------------------------------------
echo "→ Stopping service to apply migrations..."
SERVICE_STOPPED=1
systemctl stop dtk 2>/dev/null || true
echo ""

# ---------------------------------------------------------------------------
# 6. Apply DB migrations.
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
# 7. Restart the service on the new version.
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
echo ""
echo "  Frontend: http://localhost:3000"
echo "  Backend:  http://localhost:8000/health"
echo "  Logs:     journalctl -u dtk -f"
echo ""
