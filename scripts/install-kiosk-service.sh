#!/bin/bash
# Install systemd service for auto-starting kiosk on boot

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Creating kiosk systemd service..."

cat > /tmp/kiosk.service << 'EOF'
[Unit]
Description=Wayland Kiosk (Cage + Chromium)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=pi
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=/home/pi/dtk/scripts/start-kiosk.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/kiosk.service /etc/systemd/system/kiosk.service
sudo systemctl daemon-reload
sudo systemctl enable kiosk.service

echo ""
echo "✓ Kiosk service installed and enabled!"
echo ""
echo "The kiosk will start automatically on next boot."
echo ""
echo "To control it:"
echo "  sudo systemctl start kiosk    # Start now"
echo "  sudo systemctl stop kiosk     # Stop"
echo "  sudo systemctl status kiosk   # Check status"
echo "  sudo systemctl disable kiosk  # Disable auto-start"
echo ""
