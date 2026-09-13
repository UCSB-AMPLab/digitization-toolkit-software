#!/bin/bash
# provision-chdk-usb.sh — libusb + udev rule + group membership for CHDK
# cameras (NEH-231). Idempotent: safe to re-run every time.
#
# Shared, not copied, between scripts/setup.sh (first-time provisioning) and
# scripts/update.sh (every later update), because update.sh is the supported
# way an appliance already in the field moves forward, and it never ran
# setup.sh's provisioning again. Without this also running on update, an
# appliance upgraded to a release with the CHDK backend would still have no
# udev rule and no group membership, and a camera that cannot be opened
# looks exactly like a broken backend — on the machine furthest away and
# hardest to debug. Two copies of this block would drift, and the copy that
# drifts is the one nobody runs by hand.
#
# Does not start, stop, or restart the dtk service: both callers manage that
# themselves, on their own schedule, and this script must not add a restart
# neither of them is already doing.
#
# Called by scripts/setup.sh and scripts/update.sh; can also be run
# standalone:
#   sudo ./scripts/provision-chdk-usb.sh

set -e

# Resolve the real (non-root) user the same way setup.sh and update.sh do,
# so this script behaves identically whichever one calls it, or run by hand.
if [ -n "$SUDO_USER" ]; then
    DTK_USER="$SUDO_USER"
else
    DTK_USER="$(whoami)"
fi

# A CHDK body is a plain USB device that pychdk drives through pyusb, not
# through gphoto2: pyusb needs libusb as the userspace library it binds to,
# and a udev rule so the appliance user can claim the device without root.
# Without the rule the backend sees the camera on the bus and cannot open
# it, which looks exactly like a broken cable rather than a permissions
# problem.
#
# Unlike python3-picamera2/python3-libcamera in setup.sh, libusb is not
# Pi-only: it is available on every architecture this appliance runs on, so
# a failure here is not "wrong hardware for this package" the way those are
# — it is a broken provisioning run. Left to continue quietly, it hands back
# an appliance that finishes setup, reports nothing wrong, and cannot open a
# camera. So this one stops the run (set -e) rather than being swallowed.
echo "→ Installing libusb for CHDK camera support..."
apt-get install -y libusb-1.0-0
echo "  libusb-1.0-0  ✓"
echo ""

echo "→ Installing udev rule for CHDK cameras..."
# mkdir -p already treats a missing directory, or one that already exists,
# as success — that is the whole point of -p. So reaching a failure here
# is never "this system has no /etc/udev/rules.d because it isn't a Pi": it
# is a filesystem that genuinely refused the write (read-only, full, no
# permission even as root). That is not survivable the way a Pi-only
# package being absent is, so it is a hard requirement like libusb above:
# stop the run (set -e) rather than skip the rule and call it fine.
mkdir -p /etc/udev/rules.d

# Numbered 60, not 90: /usr/lib/udev/rules.d/73-seat-late.rules (shipped
# by systemd itself, not by the udev package — a container with only
# udev installed has no such file) ends with
#   TAG=="uaccess", ENV{MAJOR}!="", RUN{builtin}+="uaccess"
# which is what actually applies the ACL for a device tagged "uaccess" -
# and only for a device already carrying that tag by the time udev
# reaches that file. 70-uaccess.rules and 71-seat.rules, also shipped by
# systemd, key off the same tag; 60 sorts ahead of all three. A rule
# numbered after 73 would set the tag too late for any of them to see it,
# making TAG+="uaccess" a silent no-op.
# GROUP="plugdev" + MODE="0660" is what actually grants the backend
# service its access, independent of any desktop session; the group is
# what the usermod below adds the appliance user to. Do not drop either
# half as "redundant" — TAG+="uaccess" only works because this file is
# numbered ahead of 73, and GROUP/MODE is what works regardless of that.
# Rewriting this same file with the same content on every run — setup and
# every later update — is a no-op in effect; tee does not care whether
# the file already existed.
tee /etc/udev/rules.d/60-captua-chdk.rules >/dev/null <<'EOF'
# Digitization Toolkit — CHDK camera USB access (NEH-231).
# Canon's USB vendor id is 04a9. GROUP="plugdev" + MODE="0660" grants the
# appliance service access via the plugdev group regardless of any desktop
# session, and is what actually does the granting here. TAG+="uaccess"
# additionally grants the logged-in session's user access through
# systemd-logind's ACL mechanism (applied by systemd's own
# 73-seat-late.rules, which acts on this tag), but only because this file
# is numbered ahead of that one; renumbering this file past 73 would
# silently break that half without breaking the group grant.
SUBSYSTEM=="usb", ATTR{idVendor}=="04a9", GROUP="plugdev", MODE="0660", TAG+="uaccess"
EOF
echo "  /etc/udev/rules.d/60-captua-chdk.rules  ✓"

echo "→ Adding $DTK_USER to plugdev group..."
# Required, not conditional: run bare so set -e stops the script if this
# fails, the same reasoning as libusb and the directory above. A silent
# `if usermod ...; then ... else warn; fi` here would let provisioning
# report success while the udev rule's GROUP="plugdev" grant — and
# scripts/dtk.service's own SupplementaryGroups= belt-and-suspenders entry —
# both resolve to a group the appliance user was never actually added to.
# usermod -aG is itself idempotent — adding a user to a group they already
# belong to is a silent no-op — so this is exactly as safe to re-run as
# everything else here, on every update, not just the once.
usermod -aG plugdev "$DTK_USER"
echo "  $DTK_USER in plugdev group  ✓"

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules && udevadm trigger \
        && echo "  udev rules reloaded  ✓" \
        || echo "  ⚠ udev reload failed — the rule takes effect on next boot"
else
    echo "  udevadm not found — the rule takes effect on next boot"
fi
echo ""
