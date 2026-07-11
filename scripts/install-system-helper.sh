#!/bin/bash
# install-system-helper.sh — install the scoped privileged helper and its
# single sudoers entry. Idempotent: safe to re-run.
#
# It replaces the old open-ended sudoers rule (mount/umount/mkdir/chown with
# NOPASSWD) with exactly one allowed command: /usr/local/bin/dtk-system-helper,
# which validates its arguments and confines all effects to /var/lib/dtk/mounts.
#
# Called by setup.sh and install-service.sh; can also be run standalone:
#   sudo ./scripts/install-system-helper.sh

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
