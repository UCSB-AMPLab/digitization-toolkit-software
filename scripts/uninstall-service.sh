#!/bin/bash
# Uninstall Digitization Toolkit systemd service
#
# Version: 0.1.0-beta

set -e

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_FILE="$SYSTEMD_DIR/dtk.service"

echo "=========================================="
echo "Uninstalling Digitization Toolkit Service"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "⚠ This script must be run with sudo"
    echo "Usage: sudo ./scripts/uninstall-service.sh"
    exit 1
fi

# The update page (dtk-system-helper's update-page-start), which may be up
# after a failed update with dtk stopped. Stopped first, while the helper and
# the drop-in still exist: through the helper, then directly, in case the
# helper or its verb is missing. Its runtime copy, marker and lock in /run go
# with it. The helper is not removed here, so neither is the installed page
# in /usr/local/share/dtk-update-page beside it.
echo "→ Stopping the update page..."
if [ -x /usr/local/bin/dtk-system-helper ]; then
    /usr/local/bin/dtk-system-helper update-page-stop >/dev/null 2>&1 || true
fi
systemctl stop dtk-update-page.service >/dev/null 2>&1 || true
rm -rf /run/dtk-update-page
rm -f /run/dtk-update-page.wanted /run/dtk-update-page.lock

if systemctl is-active --quiet dtk.service; then
    echo "→ Stopping service..."
    systemctl stop dtk.service
fi

if systemctl is-enabled --quiet dtk.service 2>/dev/null; then
    echo "→ Disabling service..."
    systemctl disable dtk.service
fi

if [ -f "$SERVICE_FILE" ]; then
    echo "→ Removing service file..."
    rm "$SERVICE_FILE"
fi

# Remove the paired secret-generation oneshot (installed by install-service.sh).
# Stop first: RemainAfterExit=yes keeps the oneshot 'active' after it runs.
if systemctl is-active --quiet dtk-secrets.service 2>/dev/null; then
    echo "→ Stopping dtk-secrets.service..."
    systemctl stop dtk-secrets.service
fi
if systemctl is-enabled --quiet dtk-secrets.service 2>/dev/null; then
    echo "→ Disabling dtk-secrets.service..."
    systemctl disable dtk-secrets.service
fi
if [ -f "/etc/systemd/system/dtk-secrets.service" ]; then
    echo "→ Removing dtk-secrets.service..."
    rm "/etc/systemd/system/dtk-secrets.service"
fi

# The unresolved-update start condition and its flag (install-service.sh,
# update.sh). The record itself, under /var/lib/dtk/backups, is left.
if [ -e "$SYSTEMD_DIR/dtk.service.d/unresolved.conf" ]; then
    echo "→ Removing the unresolved-update start condition..."
    rm -f "$SYSTEMD_DIR/dtk.service.d/unresolved.conf"
    rmdir "$SYSTEMD_DIR/dtk.service.d" 2>/dev/null || true
fi
# The update page's stop before every start (install-system-helper.sh).
if [ -e "$SYSTEMD_DIR/dtk.service.d/update-page.conf" ]; then
    echo "→ Removing the update page's start hook..."
    rm -f "$SYSTEMD_DIR/dtk.service.d/update-page.conf"
    rmdir "$SYSTEMD_DIR/dtk.service.d" 2>/dev/null || true
fi
if [ -d /etc/dtk ]; then
    if [ -e /etc/dtk/unresolved-deployment ]; then
        echo "  ⚠ Removing /etc/dtk/unresolved-deployment: an update had been left"
        echo "    unresolved; its record stays in /var/lib/dtk/backups/unresolved-deployment."
    fi
    rm -rf /etc/dtk
fi

echo "→ Reloading systemd daemon..."
systemctl daemon-reload

echo ""
echo "✓ Service uninstalled successfully!"
echo ""
