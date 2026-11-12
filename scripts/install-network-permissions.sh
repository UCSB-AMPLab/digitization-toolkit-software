#!/bin/bash
# install-network-permissions.sh — install the polkit rule that lets the
# appliance user manage Wi-Fi. Idempotent: safe to re-run.
#
# The backend runs as the user pi (dtk.service). Staff join and forget Wi-Fi
# networks from Captua's settings, and the backend does that through nmcli.
# NetworkManager refuses those calls from a process outside a local session
# unless polkit grants them. The rule grants pi three actions and no others:
#
#   org.freedesktop.NetworkManager.wifi.scan
#   org.freedesktop.NetworkManager.network-control
#   org.freedesktop.NetworkManager.settings.modify.system
#
# The rule file is /etc/polkit-1/rules.d/40-captua-network.rules. Rules are
# read in the order of their file names, and the packaged rules under
# /usr/share/polkit-1/rules.d start at 49, so a name that starts with 40 is
# read before them.
#
# If /etc/polkit-1/rules.d is not a directory (absent, or present as another
# kind of file), polkit is not installed in the form this script expects. The
# script does not create it: it prints a warning and exits 0. A failed write
# into an existing directory exits non-zero, as does a directory at the rule's
# own path.
#
# It does not restart or reload any service.
#
# --prefix DIR relocates every system path it writes (tests).
#
# Called by setup.sh, install-service.sh and update.sh; can also be run
# standalone:
#   sudo ./scripts/install-network-permissions.sh
#
# Version: 0.1.0-beta

set -e

PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "✗ install-network-permissions.sh: --prefix needs a value."
                exit 1
            fi
            PREFIX="$2"
            shift
            ;;
        *)
            echo "✗ install-network-permissions.sh: unknown argument '$1'."
            echo "  Usage: install-network-permissions.sh [--prefix DIR]"
            exit 1
            ;;
    esac
    shift
done

RULES_DIR="$PREFIX/etc/polkit-1/rules.d"
RULE_DST="$RULES_DIR/40-captua-network.rules"

echo "→ Installing the Wi-Fi permissions rule..."

if [ ! -d "$RULES_DIR" ]; then
    echo "  ⚠ $RULES_DIR is not a directory: the rule was not installed."
    echo "    Joining a Wi-Fi network from Captua's settings will be refused on this machine."
    exit 0
fi

if [ -d "$RULE_DST" ]; then
    echo "✗ install-network-permissions.sh: $RULE_DST is a directory; the rule was not installed."
    exit 1
fi

RULE_TMP="$(mktemp)"
RULE_NEW="$RULE_DST.new"
trap 'rm -f "$RULE_TMP" "$RULE_NEW"' EXIT
cat > "$RULE_TMP" << 'EOF'
polkit.addRule(function(action, subject) {
    if (subject.user == "pi" &&
        (action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system")) {
        return polkit.Result.YES;
    }
});
EOF

# The rule is written beside its destination and renamed over it, so a reader
# sees either the old rule or the new one. polkit reads only files whose names
# end in .rules, so the .new file is never read as a rule. With --prefix the
# owner is the caller's.
if [ -z "$PREFIX" ]; then
    install -o root -g root -m 0644 "$RULE_TMP" "$RULE_NEW"
else
    install -m 0644 "$RULE_TMP" "$RULE_NEW"
fi
mv -f "$RULE_NEW" "$RULE_DST"
echo "  $RULE_DST  ✓"
