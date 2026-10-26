#!/bin/bash
# provision-hostname.sh — the unit's network name: captua, with the old
# digitool.local still answering on units renamed from it. Idempotent: safe
# to re-run on every provision, every update and every start.
#
# The browser reaches the API on the page's own origin (/api through nginx),
# so the name matters for mDNS only: it is what people type to find the unit.
# A unit opened by its IP works the same.
#
# ── WHO CALLS IT, AND HOW ───────────────────────────────────────────────────
#
#   update.sh, before the stop:   --prepare --advisory [--offline]
#       Installs avahi-utils if it is missing (network; skipped under
#       --offline), the alias script, its systemd unit, the NetworkManager
#       dispatcher hook, and the dtk.service drop-in that runs --repair.
#       Renames nothing.
#   update.sh, with dtk stopped:  --switch --advisory
#       The rename, below. Advisory because a unit that cannot be renamed
#       today keeps working as digitool, and that must not cost the update.
#   dtk.service, before start:    --repair --advisory
#       Finishes or undoes a switch that a power cut interrupted.
#   setup.sh:                     --name NAME
#       Names a new card (captua, or DTK_HOSTNAME for a site with two units).
#
#   With none of --prepare, --switch, --repair or --name it prepares and
#   switches, for a run by hand.
#
# ── THE SWITCH ──────────────────────────────────────────────────────────────
#
# Only a unit whose hostname is exactly digitool AND whose .env has
# HOST_IP=digitool.local is renamed. Anything else was named by hand and is
# left alone. In order:
#
#   1. Record the switch as pending (/etc/dtk/hostname-switch) and keep a copy
#      of /etc/hosts.
#   2. /etc/hosts: 127.0.1.1 captua digitool. Valid under either hostname, so
#      a cut between this step and the next leaves a working unit.
#   3. hostnamectl set-hostname captua; restart avahi-daemon, which publishes
#      the new name and stops claiming digitool.local.
#   4. Enable and start dtk-mdns-alias, which publishes digitool.local. Only
#      now: while the host itself claims digitool.local, a second record for
#      the name is a collision.
#   5. Check that captua.local and digitool.local both resolve, to one of
#      this unit's own addresses. If either does not (or resolves to another
#      device on the network), undo steps 1 to 4 and leave .env untouched.
#   6. Rewrite .env: HOST_IP=captua.local, and CORS_ORIGINS gains
#      http://captua.local and keeps (or gains) http://digitool.local.
#   7. Record the switch as done.
#
# .env is rewritten whole, through a temporary file renamed over it, with its
# owner and mode, and every other line byte for byte. generate-secrets.sh is
# the other writer of .env; it runs from dtk-secrets.service, before dtk
# starts, and so never at the same time as an update or this script's
# --repair, which runs inside dtk's own start.
#
# ── WHY HOST_IP AND CORS STILL CHANGE ───────────────────────────────────────
#
# The code from 0.1.0 on does not depend on HOST_IP for the API. The code a
# rollback restores does: its frontend calls http://${HOST_IP}/api, so HOST_IP
# must name something that resolves, and the page's own origin (digitool.local
# or captua.local) must be in CORS_ORIGINS. update.sh and rollback-update.sh
# restore neither .env nor /etc/hostname, /etc/hosts or avahi, so what this
# script writes has to work with both versions, and does.
#
# ── WHAT IT DOES NOT TOUCH ──────────────────────────────────────────────────
#
# Tailscale. A unit's Tailscale name is pinned by hand with
# `tailscale set --hostname=<name>` before the rename; otherwise Tailscale
# follows the new hostname (docs/developers/updating_a_unit.qmd).
#
# It does not start, stop or restart dtk.
#
# --advisory changes the exit status only: a failure prints the same
# diagnosis and exits 0.
#
# --prefix DIR relocates every system path it reads or writes (tests);
# --env-file FILE names the .env (default: the checkout's). Both are
# arguments, not environment variables, because update.sh exports every .env
# key before calling this script.

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OLD_NAME="digitool"
NEW_NAME="captua"
ALIAS_UNIT_NAME="dtk-mdns-alias.service"
# Seconds to wait for both names to resolve after the switch: avahi probes a
# name for a few seconds before it announces it.
WAIT_SECONDS=20

ADVISORY=0
OFFLINE=0
DO_PREPARE=0
DO_SWITCH=0
DO_REPAIR=0
SET_NAME=""
PREFIX=""
ENV_FILE="$PROJECT_ROOT/.env"

usage() {
    echo "  Usage: provision-hostname.sh [--prepare] [--switch] [--repair] [--name NAME]"
    echo "                               [--advisory] [--offline] [--prefix DIR]"
    echo "                               [--env-file FILE] [--wait SECONDS]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prepare) DO_PREPARE=1 ;;
        --switch) DO_SWITCH=1 ;;
        --repair) DO_REPAIR=1 ;;
        --advisory) ADVISORY=1 ;;
        --offline) OFFLINE=1 ;;
        --name|--prefix|--env-file|--wait)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "✗ provision-hostname.sh: $1 needs a value."
                usage
                exit 1
            fi
            case "$1" in
                --name) SET_NAME="$2" ;;
                --prefix) PREFIX="$2" ;;
                --env-file) ENV_FILE="$2" ;;
                --wait) WAIT_SECONDS="$2" ;;
            esac
            shift
            ;;
        # A mistyped flag is a bug at the call site; guessing would turn a
        # caller that believes it is advisory into one that is not.
        *)
            echo "✗ provision-hostname.sh: unknown argument '$1'."
            usage
            exit 1
            ;;
    esac
    shift
done

if [ -n "$SET_NAME" ] && ! [[ "$SET_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "✗ provision-hostname.sh: '$SET_NAME' is not a valid host name"
    echo "  (lowercase letters, digits and hyphens, not starting or ending with one)."
    exit 1
fi
if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "✗ provision-hostname.sh: --wait needs a whole number of seconds."
    exit 1
fi
if [ "$DO_PREPARE$DO_SWITCH$DO_REPAIR" = 000 ] && [ -z "$SET_NAME" ]; then
    DO_PREPARE=1
    DO_SWITCH=1
fi

ETC_HOSTNAME="$PREFIX/etc/hostname"
ETC_HOSTS="$PREFIX/etc/hosts"
STATE_DIR="$PREFIX/etc/dtk"
MARKER="$STATE_DIR/hostname-switch"
HOSTS_BACKUP="$STATE_DIR/hosts.before-hostname-switch"
ALIAS_BIN="$PREFIX/usr/local/sbin/dtk-mdns-alias"
ALIAS_UNIT="$PREFIX/etc/systemd/system/$ALIAS_UNIT_NAME"
DISPATCHER="$PREFIX/etc/NetworkManager/dispatcher.d/90-dtk-mdns-alias"
REPAIR_DROPIN="$PREFIX/etc/systemd/system/dtk.service.d/hostname-repair.conf"

# The exit status: 0 unless something failed. A skip (offline, a unit named
# by hand) is not a failure.
FAILED=0
finish() {
    if [ "$FAILED" -ne 0 ] && [ "$ADVISORY" -eq 1 ]; then
        echo "  (advisory: the unit keeps working under its current name; exit status 0)"
        exit 0
    fi
    exit "$FAILED"
}

# ── Reading the unit's state ────────────────────────────────────────────────

current_hostname() {
    tr -d '[:space:]' < "$ETC_HOSTNAME" 2>/dev/null || true
}

# The value of KEY in .env as docker compose and python-dotenv read the
# simple forms written by setup.sh and by hand: the last KEY= line, without
# a trailing comment, surrounding blanks or one pair of quotes.
env_value() {
    local line
    line="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n 1)"
    [ -n "$line" ] || return 0
    line="${line#*=}"
    line="$(printf '%s' "$line" | sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in
        \"*\") line="${line#\"}"; line="${line%\"}" ;;
        \'*\') line="${line#\'}"; line="${line%\'}" ;;
    esac
    printf '%s' "$line"
}

marker_field() {
    sed -n "s/^$1=//p" "$MARKER" 2>/dev/null | tail -n 1
}

# ── Writing files ───────────────────────────────────────────────────────────

# replace_file TARGET < content: the new content goes to a temporary file in
# the same directory, which takes TARGET's mode and owner (cp -p) before it
# is renamed over it, so a reader sees the old file or the new one, never
# half of either.
replace_file() {
    local target="$1" tmp
    tmp="$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")" || return 1
    if [ -e "$target" ]; then
        cp -p "$target" "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# install_file SRC DEST MODE: copies SRC over DEST only when they differ.
# Returns 0 when it wrote, 1 when it did not need to, 2 on failure.
install_file() {
    local src="$1" dest="$2" mode="$3" tmp
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        return 1
    fi
    mkdir -p "$(dirname "$dest")" || return 2
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 2
    if cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 2
}

# write_hosts NAMES: the 127.0.1.1 line names NAMES; every other line is kept.
# The line stays where the first 127.0.1.1 line was, or is appended.
write_hosts() {
    local names="$1"
    awk -v names="$names" '
        $1 == "127.0.1.1" { if (!done) { print "127.0.1.1\t" names; done = 1 } ; next }
        { print }
        END { if (!done) print "127.0.1.1\t" names }
    ' "$ETC_HOSTS" | replace_file "$ETC_HOSTS"
}

# rewrite_env HOST ORIGIN...: HOST_IP=HOST, and every CORS_ORIGINS line holds
# each ORIGIN, added at the end of its JSON list when missing. With no
# CORS_ORIGINS line, one is added: the backend's default list plus the
# origins. Refuses (and writes nothing) when a CORS_ORIGINS line is not a JSON
# list it can extend, or when the result does not read back as intended.
rewrite_env() {
    local host="$1" origins tmp o
    shift
    origins="$*"
    tmp="$(mktemp "$(dirname "$ENV_FILE")/.env.hostname.XXXXXX")" || return 1
    if ! cp -p "$ENV_FILE" "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if ! awk -v host="$host" -v origins="$origins" '
        function extend(line,   n, i, o, lb, rest, rb, inner) {
            n = split(origins, list, " ")
            for (i = 1; i <= n; i++) {
                o = "\"" list[i] "\""
                if (index(line, o)) continue
                lb = index(line, "[")
                if (!lb) { bad = 1; return line }
                rest = substr(line, lb + 1)
                rb = index(rest, "]")
                if (!rb) { bad = 1; return line }
                inner = substr(rest, 1, rb - 1)
                if (inner ~ /^[ \t]*$/) inner = o
                else inner = inner "," o
                line = substr(line, 1, lb) inner substr(rest, rb)
            }
            return line
        }
        /^HOST_IP=/ { print "HOST_IP=" host; next }
        /^CORS_ORIGINS=/ { print extend($0); cors = 1; next }
        { print }
        END {
            if (!cors) {
                line = "CORS_ORIGINS=[\"http://localhost:5173\",\"http://localhost:3000\"]"
                print extend(line)
            }
            if (bad) exit 3
        }
    ' "$ENV_FILE" > "$tmp"; then
        echo "  ✗ CORS_ORIGINS in $ENV_FILE is not a JSON list this script can extend;"
        echo "    .env left as it was."
        rm -f "$tmp"; return 1
    fi
    # A file with no HOST_IP line gets one.
    if ! grep -q '^HOST_IP=' "$tmp"; then
        printf 'HOST_IP=%s\n' "$host" >> "$tmp"
    fi
    for o in $origins; do
        if ! grep '^CORS_ORIGINS=' "$tmp" | grep -qF "\"$o\""; then
            echo "  ✗ The rewritten .env does not list $o in CORS_ORIGINS; .env left as it was."
            rm -f "$tmp"; return 1
        fi
    done
    if [ "$(grep '^HOST_IP=' "$tmp" | tail -n 1)" != "HOST_IP=$host" ]; then
        echo "  ✗ The rewritten .env does not read HOST_IP=$host; .env left as it was."
        rm -f "$tmp"; return 1
    fi
    if ! mv -f "$tmp" "$ENV_FILE"; then
        rm -f "$tmp"; return 1
    fi
}

write_marker() {  # write_marker STATE
    mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR" || return 1
    printf 'state=%s\nfrom=%s\nto=%s\n' "$1" "$OLD_NAME" "$NEW_NAME" | replace_file "$MARKER"
}

alias_enabled() {
    systemctl is-enabled --quiet "$ALIAS_UNIT_NAME" 2>/dev/null
}

# ── --prepare ───────────────────────────────────────────────────────────────

prepare() {
    local changed=0 rc dropin_src failed_before="$FAILED"
    echo "→ Unit name: preparing the mDNS alias for digitool.local..."
    if ! command -v avahi-publish >/dev/null 2>&1; then
        if [ "$OFFLINE" -eq 1 ]; then
            echo "  avahi-utils is not installed and this run is offline: the rename to"
            echo "  $NEW_NAME waits for an update with a connection. The unit keeps its name."
        else
            echo "  Installing avahi-utils (avahi-publish)..."
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends avahi-utils >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends avahi-utils >/dev/null 2>&1 || true
            fi
            if command -v avahi-publish >/dev/null 2>&1; then
                echo "  avahi-utils  ✓"
            else
                echo "  ✗ Could not install avahi-utils (no connection, or apt is busy). The"
                echo "    unit keeps its name; the next update with a connection renames it."
                FAILED=1
            fi
        fi
    fi

    install_file "$SCRIPT_DIR/dtk-mdns-alias" "$ALIAS_BIN" 0755; rc=$?
    [ "$rc" -eq 2 ] && { echo "  ✗ Could not install $ALIAS_BIN"; FAILED=1; }
    install_file "$SCRIPT_DIR/dtk-mdns-alias.service" "$ALIAS_UNIT" 0644; rc=$?
    [ "$rc" -eq 0 ] && changed=1
    [ "$rc" -eq 2 ] && { echo "  ✗ Could not install $ALIAS_UNIT"; FAILED=1; }
    install_file "$SCRIPT_DIR/dtk-mdns-alias.dispatcher" "$DISPATCHER" 0755; rc=$?
    [ "$rc" -eq 2 ] && { echo "  ✗ Could not install $DISPATCHER"; FAILED=1; }

    # The drop-in runs --repair before every start of dtk. The test lets dtk
    # start on code that predates this script (after a rollback), which has
    # no such file.
    dropin_src="$(mktemp "${TMPDIR:-/tmp}/hostname-repair.XXXXXX")" || { FAILED=1; return; }
    {
        echo "# Written by scripts/provision-hostname.sh. Before dtk starts, finishes or"
        echo "# undoes a rename to $NEW_NAME that a power cut interrupted. The test keeps"
        echo "# dtk starting on a checkout without the script (a rollback to older code)."
        echo "[Service]"
        echo "ExecStartPre=-+/bin/sh -c 'if [ -x $SCRIPT_DIR/provision-hostname.sh ]; then exec $SCRIPT_DIR/provision-hostname.sh --repair --advisory; fi'"
    } > "$dropin_src"
    install_file "$dropin_src" "$REPAIR_DROPIN" 0644; rc=$?
    rm -f "$dropin_src"
    [ "$rc" -eq 0 ] && changed=1
    [ "$rc" -eq 2 ] && { echo "  ✗ Could not install $REPAIR_DROPIN"; FAILED=1; }

    if [ "$changed" -eq 1 ]; then
        systemctl daemon-reload || { echo "  ✗ systemctl daemon-reload failed"; FAILED=1; }
    fi
    if [ "$FAILED" -eq "$failed_before" ]; then
        echo "  alias script, unit, dispatcher hook and repair drop-in in place  ✓"
    fi
}

# ── The switch, its undo and its repair ─────────────────────────────────────

# Puts back the name, /etc/hosts and avahi as they were before the switch,
# and stops the alias. .env is never touched here: the switch writes it last.
revert_switch() {
    echo "  Undoing the rename: the unit goes back to $OLD_NAME."
    systemctl disable --now "$ALIAS_UNIT_NAME" >/dev/null 2>&1 \
        || echo "  ⚠ Could not stop and disable $ALIAS_UNIT_NAME."
    if [ "$(current_hostname)" != "$OLD_NAME" ]; then
        hostnamectl set-hostname "$OLD_NAME" || echo "  ⚠ hostnamectl set-hostname $OLD_NAME failed."
    fi
    if [ -f "$HOSTS_BACKUP" ]; then
        replace_file "$ETC_HOSTS" < "$HOSTS_BACKUP" || echo "  ⚠ Could not restore $ETC_HOSTS from $HOSTS_BACKUP."
    fi
    systemctl restart avahi-daemon >/dev/null 2>&1 || echo "  ⚠ Could not restart avahi-daemon."
    rm -f "$MARKER" "$HOSTS_BACKUP"
}

# This unit's own addresses, every family and interface.
local_addresses() {
    ip -o addr show 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }'
}

# resolves_here NAME: NAME resolves, to one of this unit's addresses. A name
# that resolves elsewhere is another device's (two units on one network, or
# avahi having published this one under a suffixed name after a collision).
resolves_here() {
    local addr
    addr="$(getent hosts "$1" 2>/dev/null | awk '{ print $1; exit }')"
    [ -n "$addr" ] || { WHY_NOT="$1 does not resolve"; return 1; }
    if ! local_addresses | grep -qxF -- "$addr"; then
        WHY_NOT="$1 resolves to $addr, which is not this unit"
        return 1
    fi
}

names_resolve() {
    local i=0
    while :; do
        WHY_NOT=""
        if resolves_here "$NEW_NAME.local" && resolves_here "$OLD_NAME.local"; then
            return 0
        fi
        i=$((i + 1))
        [ "$i" -lt "$WAIT_SECONDS" ] || return 1
        sleep 1
    done
}

repair() {
    local state host hip
    [ -f "$MARKER" ] || return 0
    state="$(marker_field state)"
    host="$(current_hostname)"
    hip="$(env_value HOST_IP)"
    case "$state" in
        pending)
            if [ "$host" = "$NEW_NAME" ]; then
                # Cut after the hostname changed: the host answers as captua.
                # Forward is safe without the resolution check, since both the
                # old code and the new work with either value of HOST_IP.
                echo "→ Unit name: finishing the rename to $NEW_NAME that was interrupted..."
                systemctl enable --now "$ALIAS_UNIT_NAME" >/dev/null 2>&1 \
                    || { echo "  ✗ Could not enable $ALIAS_UNIT_NAME."; FAILED=1; }
                if [ "$hip" = "$OLD_NAME.local" ]; then
                    rewrite_env "$NEW_NAME.local" "http://$NEW_NAME.local" "http://$OLD_NAME.local" \
                        || { echo "  ✗ Could not rewrite $ENV_FILE."; FAILED=1; return; }
                fi
                write_marker done || { echo "  ✗ Could not record the rename as done."; FAILED=1; return; }
                rm -f "$HOSTS_BACKUP"
                echo "  The unit is $NEW_NAME, and answers as $OLD_NAME.local too  ✓"
            else
                # Cut before the hostname changed: nothing depends on the
                # switch yet, so it is undone and the next update tries again.
                echo "→ Unit name: a rename to $NEW_NAME was interrupted before it took effect."
                revert_switch
                echo "  The unit is $OLD_NAME, as before  ✓"
            fi
            ;;
        done)
            if [ "$host" = "$NEW_NAME" ] && [ "$hip" = "$OLD_NAME.local" ]; then
                echo "→ Unit name: .env names $OLD_NAME.local again; pointing it at $NEW_NAME.local..."
                rewrite_env "$NEW_NAME.local" "http://$NEW_NAME.local" "http://$OLD_NAME.local" \
                    || { echo "  ✗ Could not rewrite $ENV_FILE."; FAILED=1; }
            fi
            if [ "$host" = "$NEW_NAME" ] && [ -f "$ALIAS_UNIT" ] && ! alias_enabled; then
                systemctl enable --now "$ALIAS_UNIT_NAME" >/dev/null 2>&1 \
                    || { echo "  ✗ Could not enable $ALIAS_UNIT_NAME."; FAILED=1; }
            fi
            ;;
        *)
            echo "  ⚠ $MARKER records an unknown state '$state'; left as it is."
            ;;
    esac
}

switch_name() {
    local host hip
    host="$(current_hostname)"
    hip="$(env_value HOST_IP)"
    echo "→ Unit name: renaming $OLD_NAME to $NEW_NAME..."
    if [ "$host" = "$NEW_NAME" ]; then
        echo "  The unit is already $NEW_NAME; nothing to do."
        return 0
    fi
    if [ "$host" != "$OLD_NAME" ]; then
        echo "  The hostname is '$host', not $OLD_NAME: named by hand, left alone."
        return 0
    fi
    if [ "$hip" != "$OLD_NAME.local" ]; then
        echo "  HOST_IP in .env is '$hip', not $OLD_NAME.local: set by hand, left alone."
        return 0
    fi
    if ! command -v avahi-publish >/dev/null 2>&1 || [ ! -x "$ALIAS_BIN" ] || [ ! -f "$ALIAS_UNIT" ]; then
        echo "  The mDNS alias is not installed (avahi-utils missing: offline?). The unit"
        echo "  keeps the name $OLD_NAME; the next update with a connection renames it."
        return 0
    fi
    if ! systemctl is-active --quiet avahi-daemon; then
        echo "  ✗ avahi-daemon is not running, so neither name could be checked. The unit"
        echo "    keeps the name $OLD_NAME."
        FAILED=1
        return 0
    fi

    if ! { mkdir -p "$STATE_DIR" && chmod 0700 "$STATE_DIR" && cp -p "$ETC_HOSTS" "$HOSTS_BACKUP"; }; then
        echo "  ✗ Could not keep a copy of $ETC_HOSTS; not renaming."
        FAILED=1
        return 0
    fi
    if ! write_marker pending; then
        echo "  ✗ Could not record the rename; not renaming."
        rm -f "$HOSTS_BACKUP"
        FAILED=1
        return 0
    fi

    if ! write_hosts "$NEW_NAME $OLD_NAME"; then
        echo "  ✗ Could not write $ETC_HOSTS."
        revert_switch; FAILED=1; return 0
    fi
    if ! hostnamectl set-hostname "$NEW_NAME"; then
        echo "  ✗ hostnamectl set-hostname $NEW_NAME failed."
        revert_switch; FAILED=1; return 0
    fi
    if ! systemctl restart avahi-daemon; then
        echo "  ✗ Could not restart avahi-daemon."
        revert_switch; FAILED=1; return 0
    fi
    if ! systemctl enable --now "$ALIAS_UNIT_NAME"; then
        echo "  ✗ Could not start $ALIAS_UNIT_NAME, which keeps $OLD_NAME.local answering."
        revert_switch; FAILED=1; return 0
    fi
    if ! names_resolve; then
        echo "  ✗ After ${WAIT_SECONDS}s, $NEW_NAME.local and $OLD_NAME.local did not both resolve to"
        echo "    this unit (getent hosts): ${WHY_NOT}. Another unit on this network may"
        echo "    have the name. Check: journalctl -u avahi-daemon -u $ALIAS_UNIT_NAME"
        revert_switch; FAILED=1; return 0
    fi
    if ! rewrite_env "$NEW_NAME.local" "http://$NEW_NAME.local" "http://$OLD_NAME.local"; then
        echo "  ✗ Could not rewrite $ENV_FILE."
        revert_switch; FAILED=1; return 0
    fi
    if ! write_marker done; then
        # The rename itself is complete and checked; only the record is
        # missing, and --repair has nothing left to finish.
        echo "  ⚠ Could not record the rename as done in $MARKER."
    fi
    rm -f "$HOSTS_BACKUP"
    echo "  The unit is $NEW_NAME.local, and still answers as $OLD_NAME.local  ✓"
}

# ── --name (setup.sh) ───────────────────────────────────────────────────────

set_name() {
    local name="$1" host hip
    host="$(current_hostname)"
    hip="$(env_value HOST_IP)"
    if [ "$host" = "$OLD_NAME" ] && [ "$hip" = "$OLD_NAME.local" ] && [ "$name" = "$NEW_NAME" ]; then
        # A unit already in service as digitool: the rename keeps the old
        # name answering.
        switch_name
        return
    fi
    echo "→ Unit name: $name..."
    if [ "$host" != "$name" ]; then
        if ! write_hosts "$name"; then
            echo "  ✗ Could not write $ETC_HOSTS."; FAILED=1; return
        fi
        if ! hostnamectl set-hostname "$name"; then
            echo "  ✗ hostnamectl set-hostname $name failed."; FAILED=1; return
        fi
        systemctl restart avahi-daemon >/dev/null 2>&1 \
            || echo "  ⚠ Could not restart avahi-daemon; the name is published after a reboot."
    fi
    # HOST_IP as .env.example ships it, or naming the previous hostname, is
    # pointed at the new name; a value set by hand (an IP) is kept.
    case "$hip" in
        ""|localhost|"$host.local"|"$name.local")
            if ! rewrite_env "$name.local" "http://$name.local"; then
                echo "  ✗ Could not rewrite $ENV_FILE."; FAILED=1; return
            fi
            ;;
        *)
            echo "  HOST_IP in .env is '$hip', set by hand: left as it is."
            ;;
    esac
    echo "  The unit is $name.local  ✓"
}

# ── Main ────────────────────────────────────────────────────────────────────

if [ "$DO_REPAIR" -eq 1 ]; then
    repair
fi
if [ "$DO_PREPARE" -eq 1 ] || [ -n "$SET_NAME" ]; then
    prepare
fi
if [ "$DO_SWITCH" -eq 1 ]; then
    # A switch left half-done by an earlier run is settled first.
    repair
    switch_name
fi
if [ -n "$SET_NAME" ]; then
    repair
    set_name "$SET_NAME"
fi
finish
