#!/bin/bash
# Install Wayland kiosk browser

set -e  # Exit on error

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔════════════════════════════════════════╗"
echo "║  Raspberry Pi 5 Wayland Kiosk Setup    ║"
echo "╚════════════════════════════════════════╝"
echo ""

echo "Installing Cage (Wayland compositor) and Chromium..."
sudo apt update
sudo apt install -y cage chromium-browser

echo ""
echo "✓ Installation complete!"
echo ""
echo "════════════════════════════════════════"
echo "  To start the kiosk:"
echo "════════════════════════════════════════"
echo ""
echo "  ~/dtk/scripts/start-kiosk.sh"
echo ""
echo "════════════════════════════════════════"
echo "  For auto-start on boot (optional):"
echo "════════════════════════════════════════"
echo ""
echo "  1. Test manually first to ensure it works"
echo "  2. Then run: sudo ~/dtk/scripts/install-kiosk-service.sh"
echo ""

