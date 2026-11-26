#!/bin/bash
# install-system-helper.sh — install the scoped privileged helper and its
# single sudoers entry. Idempotent: safe to re-run.
#
# The sudoers entry allows exactly one command, /usr/local/bin/dtk-system-helper,
# which validates its arguments and confines all effects to /var/lib/dtk/mounts,
# rather than open-ended NOPASSWD mount/umount/mkdir/chown, each of which is a
# root escalation primitive (see the threat model in dtk-system-helper).
#
# It also installs the update page the helper serves during an update
# (scripts/update-page) into /usr/local/share/dtk-update-page, and the
# dtk.service drop-in (scripts/dtk-update-page.conf) that stops that page
# before every start of dtk.
#
# Called by setup.sh, install-service.sh and update.sh; can also be run standalone:
#   sudo ./scripts/install-system-helper.sh
#
# Version: 0.1.0-beta

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HELPER_SRC="$SCRIPT_DIR/dtk-system-helper"
HELPER_DST="/usr/local/bin/dtk-system-helper"
SUDOERS_DST="/etc/sudoers.d/dtk-storage"

if [ ! -f "$HELPER_SRC" ]; then
    echo "✗ Helper source not found: $HELPER_SRC"
    exit 1
fi

echo "→ Installing privileged helper..."
install -o root -g root -m 0755 "$HELPER_SRC" "$HELPER_DST"
echo "  $HELPER_DST  ✓"

echo "→ Enforcing root-owned mounts root..."
# OWNERSHIP INVARIANT: /var/lib/dtk/mounts must be root-owned, mode 0755,
# with the helper as the only writer beneath it. If it were pi-writable, a
# local pi process could swap a validated mountpoint for a symlink between
# the helper's realpath check and mount(8) (TOCTOU) and redirect the mount
# anywhere. This runs after setup.sh's blanket chown of /var/lib/dtk
# (section 2b follows section 2), so it wins. The backend must not create
# or remove anything under this directory — the helper owns that lifecycle.
install -d -o root -g root -m 0755 /var/lib/dtk/mounts
echo "  /var/lib/dtk/mounts (root:root 0755)  ✓"

echo "→ Configuring scoped sudoers rule..."
# Write to a temp file and validate with visudo BEFORE moving into place. A
# malformed file in /etc/sudoers.d bricks sudo for the whole machine, so this
# check is non-negotiable.
SUDOERS_TMP="$(mktemp)"
trap 'rm -f "$SUDOERS_TMP"' EXIT
cat > "$SUDOERS_TMP" << 'EOF'
# Digitization Toolkit — single scoped entry point for privileged operations.
# The helper validates devices and confines paths to /var/lib/dtk/mounts.
Defaults:pi !requiretty
pi ALL=(root) NOPASSWD: /usr/local/bin/dtk-system-helper
EOF

if ! visudo -c -f "$SUDOERS_TMP" >/dev/null; then
    echo "✗ Generated sudoers file failed validation; not installing."
    exit 1
fi

install -o root -g root -m 0440 "$SUDOERS_TMP" "$SUDOERS_DST"
echo "  $SUDOERS_DST  ✓"

echo "→ Installing the update page..."
# The page the helper's update-page-start serves on port 80 while the stack is
# down for an update, and its server. Installed root's, outside the checkout,
# which an update rewrites and pi owns; the helper copies the page from here
# into /run. The page is a courtesy: a failure here warns and does not fail
# the install or the update that runs it.
PAGE_SRC="$SCRIPT_DIR/update-page"
PAGE_DST="/usr/local/share/dtk-update-page"
if [ -f "$PAGE_SRC/index.html" ] && [ -f "$PAGE_SRC/serve.py" ] \
    && install -o root -g root -m 0755 -d "$PAGE_DST" \
    && install -o root -g root -m 0644 "$PAGE_SRC/index.html" "$PAGE_DST/index.html" \
    && install -o root -g root -m 0644 "$PAGE_SRC/serve.py" "$PAGE_DST/serve.py"; then
    echo "  $PAGE_DST  ✓"
else
    echo "  ⚠ Could not install the update page from $PAGE_SRC; updates will"
    echo "    leave port 80 empty while the stack is down."
fi

echo "→ Installing the update page's stop before every start of dtk..."
# A drop-in for dtk.service: ExecStartPre runs update-page-stop, as root, on
# every start of dtk (by update.sh, a rollback, systemd's own restart or by
# hand), so the page never holds port 80 against nginx, whichever start.sh
# the checkout has. Outside the checkout, like the helper. Non-fatal, and
# without systemd (a test, a build machine) the reload is skipped.
DROPIN_DIR="/etc/systemd/system/dtk.service.d"
if install -o root -g root -m 0755 -d "$DROPIN_DIR" \
    && install -o root -g root -m 0644 "$SCRIPT_DIR/dtk-update-page.conf" "$DROPIN_DIR/update-page.conf"; then
    echo "  $DROPIN_DIR/update-page.conf  ✓"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || echo "  ⚠ systemctl daemon-reload failed; the drop-in applies after the next reload."
    fi
else
    echo "  ⚠ Could not install $DROPIN_DIR/update-page.conf."
fi
