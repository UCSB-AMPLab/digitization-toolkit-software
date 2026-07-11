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
#
# Recovery toggle: if /boot/firmware/dtk-no-kiosk exists, the kiosk is skipped
# and tty1 drops to a normal shell. Create that (empty) file from any computer
# — including from the FAT boot partition on the SD card — to get a local
# terminal without a working Ctrl+Alt+F2; delete it to restore the kiosk.
if [[ "\$(tty)" == "/dev/tty1" ]] && [[ ! -f /boot/firmware/dtk-no-kiosk ]]; then
    exec $KIOSK_SCRIPT
fi
EOF
chown "$KIOSK_USER:$KIOSK_USER" "$BASH_PROFILE"

# ── 2b. tty2 autologin so Ctrl+Alt+F2 lands on a usable shell ───────────────
# cage owns tty1; the VT-escape below switches to tty2. Without autologin the
# operator would face a login prompt with no known password, so autologin the
# kiosk user on tty2 as well.
echo "→ Configuring autologin on tty2 (recovery VT)..."
sudo mkdir -p /etc/systemd/system/getty@tty2.service.d
sudo tee /etc/systemd/system/getty@tty2.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
sudo systemctl enable getty@tty2 >/dev/null 2>&1 || true
sudo systemctl daemon-reload

# ── 2c. VT-escape from the kiosk (triggerhappy) ─────────────────────────────
# cage does not bind Ctrl+Alt+Fn and puts the keyboard in raw mode, so on a
# stock provision there is NO way out of the kiosk. The VT *mechanism* works
# (chvt releases cage); only the keybinding is missing. triggerhappy (thd)
# reads /dev/input directly and can run chvt on a chord — but it must run as
# root to grab the input devices, and the chord must list the TRIGGERING KEY
# FIRST (modifiers after), or it silently never fires.
echo "→ Installing VT-escape (triggerhappy)..."

# Install triggerhappy only if missing, so offline re-runs never touch the
# network. It ships with Raspberry Pi OS, so this is usually a no-op.
if ! command -v thd >/dev/null 2>&1 && [ ! -x /usr/sbin/thd ]; then
    echo "  triggerhappy not present — installing via apt..."
    sudo apt-get install -y triggerhappy || \
        echo "  ⚠ triggerhappy not available via apt (offline?) — install it before relying on Ctrl+Alt+F2"
else
    echo "  triggerhappy already installed — skipping apt."
fi

# Run thd as root (drop-in) so it can open /dev/input/event*.
sudo mkdir -p /etc/systemd/system/triggerhappy.service.d
sudo tee /etc/systemd/system/triggerhappy.service.d/run-as-root.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --user root --deviceglob /dev/input/event*
EOF

# Trigger file — triggering key FIRST, modifiers after (the reverse never fires).
# F1 → tty1 (back to kiosk), F2 → tty2 (recovery shell), F3 → tty3.
sudo mkdir -p /etc/triggerhappy/triggers.d
sudo tee /etc/triggerhappy/triggers.d/dtk-vt-escape.conf > /dev/null << 'EOF'
KEY_F1+KEY_LEFTCTRL+KEY_LEFTALT 1 /usr/bin/chvt 1
KEY_F2+KEY_LEFTCTRL+KEY_LEFTALT 1 /usr/bin/chvt 2
KEY_F3+KEY_LEFTCTRL+KEY_LEFTALT 1 /usr/bin/chvt 3
EOF

sudo systemctl daemon-reload
sudo systemctl enable triggerhappy >/dev/null 2>&1 || true
sudo systemctl restart triggerhappy >/dev/null 2>&1 || true
echo "  Ctrl+Alt+F2 → tty2 shell, Ctrl+Alt+F1 → kiosk (verify 'ps -o user -C thd' shows root)"

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
