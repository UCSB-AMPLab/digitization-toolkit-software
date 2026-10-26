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
#
# Version: 0.1.0-beta

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
# Restart (not just enable) so the recovery VT is usable immediately after
# provisioning, without waiting for a reboot.
sudo systemctl restart getty@tty2 >/dev/null 2>&1 || true

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
# If it IS missing, this must succeed: provisioning happens online, and
# continuing without thd would silently produce a kiosk with no VT-escape.
if ! command -v thd >/dev/null 2>&1 && [ ! -x /usr/sbin/thd ]; then
    echo "  triggerhappy not present — installing via apt..."
    if ! sudo apt-get install -y triggerhappy; then
        echo "✗ triggerhappy could not be installed — refusing to provision a kiosk"
        echo "  with no escape path. Connect to the internet (or install the"
        echo "  triggerhappy package manually) and re-run this script."
        exit 1
    fi
else
    echo "  triggerhappy already installed — skipping apt."
fi

# Late-appearing input devices (NEH-184). thd opens /dev/input/event* once, at
# start (--deviceglob). A node that appears afterwards reaches it only through
# the packaged udev rule (triggerhappy-udev.rules: th-cmd --socket
# /var/run/thd.socket --passfd --udev), and a boot where the keyboard
# enumerates late has been seen to leave the Ctrl+Alt+F2 escape dead until a
# manual restart. Whether that packaged hand-off fires under the ExecStart
# override below is not established from the package alone (it names the same
# socket as the override, /run/thd.socket), so this does not rely on it: a
# helper, run from our own udev rule and once after thd starts, adds event
# nodes thd does not already hold through the same socket.
#
# The helper only ever ADDS, never removes. thd's add_device() appends without
# checking for duplicates, so a node registered twice is two fds on one device
# and the chord fires chvt twice, which is harmless (switching to tty2 twice is
# switching once). Removing first would risk the opposite: a remove that
# succeeds followed by an add that fails leaves a working device unregistered
# and the escape dead, which needs a physical SD-card edit to recover. Prefer
# benign duplication to a destroyed escape. If a non-idempotent entry is ever
# added to triggers.d, double-firing would matter and this needs revisiting.
# To avoid duplicates in the common case the helper skips a node that thd
# already holds open (read from /proc/<thd pid>/fd); if that cannot be
# determined it adds anyway.
sudo tee /usr/local/sbin/dtk-thd-sync > /dev/null << 'EOF'
#!/bin/sh
# Hand input event nodes to the running triggerhappy daemon (add only).
# Usage: dtk-thd-sync [/dev/input/eventN ...]   (no arguments: every node
# thd does not already hold)
# Test overrides: CAPTUA_<NAME> first, DTK_<NAME> as the fallback. Installed
# on its own, so it cannot source scripts/captua-env.sh.
SOCK="${CAPTUA_THD_SOCKET:-${DTK_THD_SOCKET:-/run/thd.socket}}"
TH_CMD="${CAPTUA_TH_CMD:-${DTK_TH_CMD:-/usr/sbin/th-cmd}}"
# th-cmd's sendmsg() has no deadline; bound every call.
BOUND="${CAPTUA_THD_TIMEOUT:-${DTK_THD_TIMEOUT:-3}}"
PROC="${CAPTUA_PROC:-${DTK_PROC:-/proc}}"
INPUT_DIR="${CAPTUA_INPUT_DIR:-${DTK_INPUT_DIR:-/dev/input}}"
# Called from ExecStartPost (no arguments), thd may not have bound its socket
# yet: wait up to ~5 s. Called with a device (udev), never wait.
if [ "$#" -eq 0 ]; then
    i=0
    while [ ! -S "$SOCK" ] && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
fi
if [ ! -S "$SOCK" ]; then
    echo "dtk-thd-sync: $SOCK not present; thd is not running, nothing to sync" >&2
    exit 0
fi

# Is $1 already open in thd? Empty/unknown answers "no" (then we add).
# MAINPID is set by systemd for ExecStartPost. Otherwise only a single thd
# process is taken to be the service's: with none or several we cannot tell
# whose descriptors we would be reading (a diagnostic thd may hold the
# keyboard), so treat identity as unknown and add. A duplicate is benign; a
# skipped add is not.
THD_PID="$MAINPID"
if [ -z "$THD_PID" ]; then
    PIDS="$(pidof thd 2>/dev/null)"
    case "$PIDS" in
        ""|*" "*) THD_PID="" ;;
        *) THD_PID="$PIDS" ;;
    esac
fi
held() {
    [ -n "$THD_PID" ] && [ -d "$PROC/$THD_PID/fd" ] || return 1
    for fd in "$PROC/$THD_PID"/fd/*; do
        [ "$(readlink "$fd" 2>/dev/null)" = "$1" ] && return 0
    done
    return 1
}

if [ "$#" -eq 0 ]; then
    set -- "$INPUT_DIR"/event*
fi
for dev in "$@"; do
    [ -e "$dev" ] || continue
    if held "$dev"; then
        continue
    fi
    timeout "$BOUND" "$TH_CMD" --socket "$SOCK" --passfd --add "$dev" ||
        echo "dtk-thd-sync: could not add $dev" >&2
done
exit 0
EOF
sudo chmod 755 /usr/local/sbin/dtk-thd-sync

# Every new event node is synced as it appears. Runs after the packaged rule
# (60-), carrying its guard against thd's own virtual device. The work is
# queued with systemd-run so a blocked th-cmd cannot hold a udev worker.
# --no-block still makes one synchronous call to the manager, so the enqueue
# itself is bounded by timeout, and a failure is logged rather than lost.
sudo tee /usr/local/sbin/dtk-thd-enqueue > /dev/null << 'EOF'
#!/bin/sh
# Queue dtk-thd-sync for one input node without holding the udev worker.
# Test overrides: CAPTUA_<NAME> first, DTK_<NAME> as the fallback.
SYSTEMD_RUN="${CAPTUA_SYSTEMD_RUN:-${DTK_SYSTEMD_RUN:-/usr/bin/systemd-run}}"
# Both calls are bounded. systemd-run --no-block still makes one synchronous
# call to the manager, and logger writes to /dev/log with a blocking socket, so
# a stalled journal would hold this udev worker just as surely as a stalled
# manager. Neither failure is worth a wedged worker: the node is picked up by
# the ExecStartPost sweep on the next thd start either way.
BOUND="${CAPTUA_ENQUEUE_TIMEOUT:-${DTK_ENQUEUE_TIMEOUT:-3}}"
timeout "$BOUND" "$SYSTEMD_RUN" --no-block --collect --quiet \
    /usr/local/sbin/dtk-thd-sync "$1" ||
    timeout "$BOUND" logger -t dtk-thd-sync \
        "could not queue $1 for triggerhappy; it will be picked up on the next thd start" ||
    :
exit 0
EOF
sudo chmod 755 /usr/local/sbin/dtk-thd-enqueue
sudo tee /etc/udev/rules.d/61-dtk-triggerhappy.rules > /dev/null << 'EOF'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event[0-9]*", ATTRS{name}!="triggerhappy", RUN+="/usr/local/sbin/dtk-thd-enqueue $env{DEVNAME}"
EOF
sudo udevadm control --reload >/dev/null 2>&1 || true

# Run thd as root (drop-in) so it can open /dev/input/event*. ExecStartPost
# covers a node that appeared between thd's enumeration and its socket binding
# (the udev hand-off finds no socket then); it takes no device, so it adds
# only nodes thd does not already hold. The leading '-' ignores its exit
# status and `timeout 20` keeps it inside the unit's start timeout.
sudo mkdir -p /etc/systemd/system/triggerhappy.service.d
sudo tee /etc/systemd/system/triggerhappy.service.d/run-as-root.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/thd --triggers /etc/triggerhappy/triggers.d/ --socket /run/thd.socket --user root --deviceglob /dev/input/event*
ExecStartPost=
ExecStartPost=-/usr/bin/timeout 20 /usr/local/sbin/dtk-thd-sync
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
echo "  Late-plugged keyboards are handed to thd by /usr/local/sbin/dtk-thd-sync (NEH-184)."

# ── 2d. Chromium managed policies — password manager (NEH-67), translate ────
# (NEH-185). The kiosk browser must never offer to save passwords or autofill
# payment / address data, and must never show the "translate this page?"
# popup over the UI. Managed policy JSONs enforce this regardless of launch
# flags — which matters for translate: Chromium renamed the TranslateUI
# feature to Translate several versions ago, so a --disable-features flag
# silently rots; the policy is version-proof (verified on hardware, bench
# 2026-07-24). Raspberry Pi OS ships Chromium under one of two policy roots
# depending on the build (chromium vs chromium-browser); installing into both
# is harmless and covers either. No network access is needed.
echo "→ Installing Chromium managed policies (password manager, translate)..."
for policy_dir in /etc/chromium/policies/managed /etc/chromium-browser/policies/managed; do
    sudo mkdir -p "$policy_dir"
    sudo tee "$policy_dir/dtk-no-password-manager.json" > /dev/null << 'EOF'
{
    "PasswordManagerEnabled": false,
    "AutofillAddressEnabled": false,
    "AutofillCreditCardEnabled": false
}
EOF
    sudo tee "$policy_dir/dtk-no-translate.json" > /dev/null << 'EOF'
{
    "TranslateEnabled": false
}
EOF
done
echo "  /etc/chromium{,-browser}/policies/managed/dtk-no-password-manager.json  ✓"
echo "  /etc/chromium{,-browser}/policies/managed/dtk-no-translate.json  ✓"

# ── 3. Disable kiosk.service if present; the kiosk runs from .bash_profile ──
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
