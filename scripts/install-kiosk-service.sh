#!/bin/bash
# Set up kiosk auto-start on boot via autologin + ~/.bash_profile
#
# The kiosk must run inside the tty1 login session (not as a standalone
# systemd service) so that cage (Wayland compositor) takes ownership of
# tty1, which is what the monitor displays.
#
# Boot sequence:
#   getty@tty1 autologin → bash login shell → .bash_profile → start-kiosk.sh → cage
#
# Restart: when cage exits, the shell exits, getty re-autologins, .bash_profile
# runs again → kiosk restarts automatically.

set -e

KIOSK_USER="${SUDO_USER:-pi}"
KIOSK_HOME=$(eval echo "~$KIOSK_USER")
BASH_PROFILE="$KIOSK_HOME/.bash_profile"
KIOSK_SCRIPT="/home/pi/dtk/scripts/start-kiosk.sh"

echo "Setting up kiosk auto-start for user: $KIOSK_USER"
echo ""

# ── 1. Ensure autologin is configured for tty1 ──────────────────────────────
echo "→ Configuring autologin on tty1..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
sudo systemctl daemon-reload

# ── 2. Write ~/.bash_profile to launch kiosk on tty1 ────────────────────────
echo "→ Writing $BASH_PROFILE..."
cat > "$BASH_PROFILE" << EOF
# ~/.bash_profile - executed for login shells (including autologin on tty1)

# Source .bashrc if present (standard practice)
if [ -f "\$HOME/.bashrc" ]; then
    . "\$HOME/.bashrc"
fi

# Start the kiosk when autologged-in on tty1.
# cage (Wayland compositor + Chromium) must run from the tty1 login session
# so it takes ownership of tty1 and is visible on the monitor.
# When cage exits, this shell exits → getty re-autologins → kiosk restarts.
if [[ "\$(tty)" == "/dev/tty1" ]]; then
    exec $KIOSK_SCRIPT
fi
EOF
chown "$KIOSK_USER:$KIOSK_USER" "$BASH_PROFILE"

# ── 3. Remove old kiosk.service if present (replaced by .bash_profile) ──────
if systemctl is-enabled kiosk.service &>/dev/null; then
    echo "→ Disabling legacy kiosk.service..."
    sudo systemctl disable kiosk.service
    sudo systemctl stop kiosk.service 2>/dev/null || true
fi

echo ""
echo "✓ Kiosk auto-start configured!"
echo ""
echo "The kiosk will start automatically on next boot."
echo "(dtk.service starts Docker/backend; autologin starts cage on tty1)"
echo ""
echo "To apply immediately without rebooting:"
echo "  exec /home/pi/dtk/scripts/start-kiosk.sh"
echo ""
echo "To disable auto-start, remove the tty1 block from $BASH_PROFILE"
echo ""
