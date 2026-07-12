#!/bin/bash
# Uninstall Digitization Toolkit systemd service

set -e

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_FILE="$SYSTEMD_DIR/dtk.service"

echo "=========================================="
echo "Uninstalling Digitization Toolkit Service"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ This script must be run with sudo"
    echo "Usage: sudo ./scripts/uninstall-service.sh"
    exit 1
fi

# Stop service if running
if systemctl is-active --quiet dtk.service; then
    echo "→ Stopping service..."
    systemctl stop dtk.service
fi

# Disable service
if systemctl is-enabled --quiet dtk.service 2>/dev/null; then
    echo "→ Disabling service..."
    systemctl disable dtk.service
fi

# Remove service file
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

echo "→ Reloading systemd daemon..."
systemctl daemon-reload

echo ""
echo "✓ Service uninstalled successfully!"
echo ""
