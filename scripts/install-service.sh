#!/bin/bash
# Install Digitization Toolkit as a systemd service
# This enables auto-start on boot and proper service management

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SERVICE_FILE="$SCRIPT_DIR/dtk.service"
SYSTEMD_DIR="/etc/systemd/system"

echo "=========================================="
echo "Installing Digitization Toolkit Service"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ This script must be run with sudo"
    echo "Usage: sudo ./scripts/install-service.sh"
    exit 1
fi

# Check if service file exists
if [ ! -f "$SERVICE_FILE" ]; then
    echo "✗ Service file not found: $SERVICE_FILE"
    exit 1
fi

echo "→ Copying service file to systemd..."
cp "$SERVICE_FILE" "$SYSTEMD_DIR/dtk.service"

echo "→ Reloading systemd daemon..."
systemctl daemon-reload

echo "→ Enabling service to start on boot..."
systemctl enable dtk.service

echo ""
echo "✓ Service installed successfully!"
echo ""
echo "Usage:"
echo "  sudo systemctl start dtk     # Start the service"
echo "  sudo systemctl stop dtk      # Stop the service"
echo "  sudo systemctl restart dtk   # Restart the service"
echo "  sudo systemctl status dtk    # Check service status"
echo "  journalctl -u dtk -f         # View service logs"
echo ""
echo "The service will automatically start on boot."
echo ""
