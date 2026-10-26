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
#       Installs avahi-utils from apt if it is missing, the alias script,
#       its systemd unit, the NetworkManager dispatcher hook, and the
#       dtk.service drop-in that runs --repair. Renames nothing. apt is tried
#       whenever it is not --offline, update.sh --no-pull included: that flag
#       means the code was fetched by hand, not that the unit has no network.
#       Only update.sh --offline passes --offline. Without avahi-utils the
#       rename waits, and the unit keeps its name.
#   update.sh, with dtk stopped:  --switch --advisory
#       The rename, below. Advisory because a unit that cannot be renamed
#       today keeps working as digitool, and that must not cost the update.
#   dtk.service, before start:    --repair --advisory
#       Finishes or undoes a switch that a power cut interrupted, and
#       removes the temporary files the cut left.
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
# --repair, and --switch on a unit already called captua, finish a switch
# whose hostname step happened: the /etc/hosts line, the alias, the check of
# step 5 and .env. A unit called captua with HOST_IP=digitool.local is
# finished this way whatever the record says (missing, empty after a power
# cut, unknown), since digitool.local answers there only through the alias.
# If the check finds captua.local on another device and a record exists, the
# switch is undone instead.
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
#
# Version: 0.1.0-beta

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OLD_NAME="digitool"
NEW_NAME="captua"
ALIAS_UNIT_NAME="dtk-mdns-alias.service"
# Seconds of wall time to keep trying both names after the switch: avahi
# probes a name for a few seconds before it announces it. A lookup that is
# already running when they run out is let finish (nss-mdns gives up on its
# own after a few seconds).
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
KIOSK_AUTOLOGIN="$PREFIX/etc/systemd/system/getty@tty1.service.d/autologin.conf"

# Temporary files this run created, removed on any exit. A signal ends the
# run through exit, so that the EXIT trap runs; a power cut leaves them, and
# remove_stale_temps finds them on the next --repair or --prepare.
TEMPS=()
remove_temps() {
    local f
    for f in ${TEMPS[@]+"${TEMPS[@]}"}; do
        rm -f "$f"
    done
}
trap remove_temps EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# new_temp TEMPLATE: mktemp TEMPLATE, recorded for removal. Sets NEW_TEMP
# rather than printing it, because a command substitution runs in a subshell
# and its record would be lost.
new_temp() {
    NEW_TEMP="$(mktemp "$1")" || return 1
    TEMPS+=("$NEW_TEMP")
}

# The mktemp templates, by the file each one replaces: .<name>.XXXXXX in the
# same directory (replace_file, install_file), and .env.hostname.XXXXXX next
# to .env (rewrite_env). remove_stale_temps matches exactly these, six
# random characters each.
temp_template() {
    printf '%s/.%s.XXXXXX' "$(dirname "$1")" "$(basename "$1")"
}
remove_stale_temps() {
    local f
    for f in "$(dirname "$ENV_FILE")"/.env.hostname.?????? \
             "$(dirname "$ETC_HOSTS")/.$(basename "$ETC_HOSTS")".?????? \
             "$STATE_DIR/.$(basename "$MARKER")".?????? \
             "$(dirname "$ALIAS_BIN")/.$(basename "$ALIAS_BIN")".?????? \
             "$(dirname "$ALIAS_UNIT")/.$(basename "$ALIAS_UNIT")".?????? \
             "$(dirname "$DISPATCHER")/.$(basename "$DISPATCHER")".?????? \
             "$(dirname "$REPAIR_DROPIN")/.$(basename "$REPAIR_DROPIN")".??????; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then
            rm -f "$f" && echo "  Removed $f, left by an interrupted run."
        fi
    done
}

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
    new_temp "$(temp_template "$target")" || return 1
    tmp="$NEW_TEMP"
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
    new_temp "$(temp_template "$dest")" || return 2
    tmp="$NEW_TEMP"
    if cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 2
}

# write_hosts NAMES: the 127.0.1.1 line names NAMES; every other line is kept.
# The line stays where the first 127.0.1.1 line was, or is appended. Process
# substitution, not a pipe, keeps replace_file in this shell, where its
# temporary file is recorded for the EXIT trap.
write_hosts() {
    local names="$1"
    replace_file "$ETC_HOSTS" < <(awk -v names="$names" '
        $1 == "127.0.1.1" { if (!done) { print "127.0.1.1\t" names; done = 1 } ; next }
        { print }
        END { if (!done) print "127.0.1.1\t" names }
    ' "$ETC_HOSTS")
}

# The names on the first 127.0.1.1 line of /etc/hosts, separated by one space.
hosts_names() {
    awk '$1 == "127.0.1.1" { $1 = ""; sub(/^ +/, ""); print; exit }' "$ETC_HOSTS" 2>/dev/null
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
    new_temp "$(dirname "$ENV_FILE")/.env.hostname.XXXXXX" || return 1
    tmp="$NEW_TEMP"
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
    replace_file "$MARKER" < <(printf 'state=%s\nfrom=%s\nto=%s\n' "$1" "$OLD_NAME" "$NEW_NAME")
}

alias_enabled() {
    systemctl is-enabled --quiet "$ALIAS_UNIT_NAME" 2>/dev/null
}

alias_installed() {
    command -v avahi-publish >/dev/null 2>&1 && [ -x "$ALIAS_BIN" ] && [ -f "$ALIAS_UNIT" ]
}

# The kiosk's Chromium profile: that of the user the tty1 autologin runs
# the kiosk as (install-kiosk-service.sh), the directory start-kiosk.sh
# passes as --user-data-dir. Empty on a unit without the kiosk.
kiosk_profile() {
    local user home
    user="$(sed -n 's/.*--autologin[ =]\([^ ]*\).*/\1/p' "$KIOSK_AUTOLOGIN" 2>/dev/null | head -n 1)"
    [ -n "$user" ] || return 0
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [ -n "$home" ] && [ -d "$home/.config/chromium" ] && printf '%s' "$home/.config/chromium"
}

# repoint_kiosk_lock FROM TO: Chromium's profile lock, SingletonLock, is a
# symlink to <hostname>-<pid>, and Chromium refuses a profile whose lock
# names another host. When the hostname changes under a running kiosk, its
# lock is pointed at the new name with the same pid, so that the next
# Chromium, launched by whichever start-kiosk.sh is on disk (a restore or a
# rollback brings back one without the cleanup in the current one), finds a
# lock of this host and a pid that is no longer running, which it takes over.
repoint_kiosk_lock() {
    local from="$1" to="$2" profile target pid
    profile="$(kiosk_profile)"
    [ -n "$profile" ] && [ -L "$profile/SingletonLock" ] || return 0
    target="$(readlink "$profile/SingletonLock")"
    pid="${target#"$from"-}"
    [ "$pid" != "$target" ] && [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if ln -sfn "$to-$pid" "$profile/SingletonLock"; then
        chown -h --reference="$profile" "$profile/SingletonLock" 2>/dev/null || true
        echo "  Kiosk profile lock now names $to."
    else
        echo "  ⚠ Could not point the kiosk's profile lock at $to; start-kiosk.sh removes it."
    fi
}

# ── --prepare ───────────────────────────────────────────────────────────────

prepare() {
    local changed=0 rc dropin_src failed_before="$FAILED"
    echo "→ Unit name: preparing the mDNS alias for digitool.local..."
    remove_stale_temps
    if ! command -v avahi-publish >/dev/null 2>&1; then
        if [ "$OFFLINE" -eq 1 ]; then
            echo "  avahi-utils is not installed, and this run is --offline, so apt is not"
            echo "  tried. The rename to $NEW_NAME waits for avahi-utils: the unit keeps its"
            echo "  name until an update that can reach apt installs it."
        else
            # A first try without apt-get update: on a unit whose package
            # lists are current that is all it needs, and it is quicker.
            echo "  Installing avahi-utils (avahi-publish) from apt..."
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends avahi-utils >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends avahi-utils >/dev/null 2>&1 || true
            fi
            if command -v avahi-publish >/dev/null 2>&1; then
                echo "  avahi-utils  ✓"
            else
                echo "  ✗ Could not install avahi-utils (apt cannot reach its sources, or is"
                echo "    busy). The rename to $NEW_NAME waits for avahi-utils: the unit keeps"
                echo "    its name until an update that can reach apt installs it."
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
    new_temp "${TMPDIR:-/tmp}/hostname-repair.XXXXXX" || { FAILED=1; return; }
    dropin_src="$NEW_TEMP"
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
    # A unit that hit the start limit stays failed, and restart requests from
    # the dispatcher hook do not clear that state.
    systemctl reset-failed "$ALIAS_UNIT_NAME" >/dev/null 2>&1 || true
    if [ "$FAILED" -eq "$failed_before" ]; then
        echo "  alias script, unit, dispatcher hook and repair drop-in in place  ✓"
    fi
}

# ── The switch, its undo and its repair ─────────────────────────────────────

# Puts back the name, /etc/hosts and avahi as they were before the switch,
# stops the alias and removes the record. .env is not touched here: the
# switch writes it last, and a repair that undoes a switch puts HOST_IP back
# itself (undo_from_repair).
#
# The hostname comes first, and the rest only once it is digitool again:
# /etc/hosts without captua, or no alias, under the hostname captua would
# leave the unit answering to neither name. When the hostname cannot be set
# back, everything stays as it is, the record included, so that the next
# start of dtk tries again. Returns 1 then.
revert_switch() {
    echo "  Undoing the rename: the unit goes back to $OLD_NAME."
    if [ "$(current_hostname)" != "$OLD_NAME" ]; then
        hostnamectl set-hostname "$OLD_NAME" || echo "  ⚠ hostnamectl set-hostname $OLD_NAME failed."
    fi
    if [ "$(current_hostname)" != "$OLD_NAME" ]; then
        echo "  ✗ The hostname is still '$(current_hostname)'. /etc/hosts, the alias and"
        echo "    the record of the rename are kept, so the unit still answers to both"
        echo "    names; the next start of dtk tries the undo again."
        FAILED=1
        return 1
    fi
    repoint_kiosk_lock "$NEW_NAME" "$OLD_NAME"
    systemctl disable --now "$ALIAS_UNIT_NAME" >/dev/null 2>&1 \
        || echo "  ⚠ Could not stop and disable $ALIAS_UNIT_NAME."
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
# avahi having published this one under a suffixed name after a collision);
# FOREIGN then names it.
resolves_here() {
    local addr
    addr="$(getent hosts "$1" 2>/dev/null | awk '{ print $1; exit }')"
    [ -n "$addr" ] || { WHY_NOT="$1 does not resolve"; return 1; }
    if ! local_addresses | grep -qxF -- "$addr"; then
        WHY_NOT="$1 resolves to $addr, which is not this unit"
        FOREIGN="$1"
        return 1
    fi
}

# Both names, tried until WAIT_SECONDS of wall time have passed since the
# first try. WHY_NOT and FOREIGN describe the last try.
names_resolve() {
    local deadline=$((SECONDS + WAIT_SECONDS))
    while :; do
        WHY_NOT=""
        FOREIGN=""
        if resolves_here "$NEW_NAME.local" && resolves_here "$OLD_NAME.local"; then
            return 0
        fi
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 1
    done
}

# A repair that undoes the switch: HOST_IP back to digitool.local if the
# switch had got as far as .env, then revert_switch. .env first, while the
# record still exists: revert_switch removes it, and a repair without one
# would never come back to a HOST_IP left on captua.local. digitool.local
# keeps answering meanwhile: through the alias while the hostname is captua
# (revert_switch stops it only once the hostname is digitool).
undo_from_repair() {
    if [ "$(env_value HOST_IP)" = "$NEW_NAME.local" ]; then
        rewrite_env "$OLD_NAME.local" "http://$OLD_NAME.local" \
            || { echo "  ✗ Could not point HOST_IP in $ENV_FILE back at $OLD_NAME.local; the undo waits for the next start."; FAILED=1; return; }
    fi
    revert_switch || return
    echo "  The unit is $OLD_NAME, as before  ✓"
}

# finish_forward: the hostname is already captua; bring the rest of the
# switch in line with it, check it as the switch does, and record it.
#   both names resolve here      .env forward, recorded as done
#   captua.local is elsewhere    undone, if a record of the switch exists
#                                (another device has the name); without one,
#                                reported and left
#   otherwise (no network yet)   .env forward, recorded as pending, so that
#                                the next start or update checks again
# HOST_IP=captua.local is right in the last case too: the hostname is
# captua, so the name resolves as soon as avahi announces it.
finish_forward() {
    local resolved=0
    echo "→ Unit name: finishing the rename to $NEW_NAME..."
    repoint_kiosk_lock "$OLD_NAME" "$NEW_NAME"
    if [ "$(hosts_names)" != "$NEW_NAME $OLD_NAME" ]; then
        write_hosts "$NEW_NAME $OLD_NAME" \
            || { echo "  ✗ Could not write $ETC_HOSTS."; FAILED=1; }
    fi
    if alias_installed; then
        systemctl enable --now "$ALIAS_UNIT_NAME" >/dev/null 2>&1 \
            || { echo "  ✗ Could not enable $ALIAS_UNIT_NAME."; FAILED=1; }
    else
        echo "  ✗ The mDNS alias is not installed (avahi-utils missing?), so $OLD_NAME.local"
        echo "    does not answer; the next update that can reach apt installs it."
        FAILED=1
    fi
    if names_resolve; then
        resolved=1
    elif [ "$FOREIGN" = "$NEW_NAME.local" ]; then
        echo "  ✗ $WHY_NOT: another device on this network has the name."
        if [ -f "$MARKER" ]; then
            undo_from_repair
        else
            echo "    No rename was recorded on this unit, so its name is left as it is."
            FAILED=1
        fi
        return
    else
        echo "  ✗ Within ${WAIT_SECONDS}s, $NEW_NAME.local and $OLD_NAME.local did not both resolve"
        echo "    to this unit (getent hosts): ${WHY_NOT}. The rename stays pending; the"
        echo "    next start of dtk, or the next update, checks again."
        FAILED=1
    fi
    if [ "$(env_value HOST_IP)" = "$OLD_NAME.local" ]; then
        rewrite_env "$NEW_NAME.local" "http://$NEW_NAME.local" "http://$OLD_NAME.local" \
            || { echo "  ✗ Could not rewrite $ENV_FILE."; FAILED=1; return; }
    fi
    if [ "$resolved" -eq 1 ]; then
        write_marker done || { echo "  ✗ Could not record the rename as done."; FAILED=1; return; }
        rm -f "$HOSTS_BACKUP"
        echo "  The unit is $NEW_NAME, and answers as $OLD_NAME.local too  ✓"
    else
        write_marker pending || echo "  ⚠ Could not record the rename as pending in $MARKER."
    fi
}

repair() {
    local state host hip
    remove_stale_temps
    host="$(current_hostname)"
    hip="$(env_value HOST_IP)"
    if [ ! -f "$MARKER" ]; then
        if [ "$host" = "$NEW_NAME" ] && [ "$hip" = "$OLD_NAME.local" ]; then
            finish_forward
        fi
        return 0
    fi
    state="$(marker_field state)"
    case "$state" in
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
            # pending, and a record that is empty (its data lost to a power
            # cut) or unreadable: the hostname says how far the switch got.
            # done is only ever written once the hostname is captua.
            [ "$state" = pending ] \
                || echo "  ⚠ $MARKER records no known state ('$state'); the hostname decides."
            if [ "$host" = "$NEW_NAME" ]; then
                finish_forward
            elif [ "$host" = "$OLD_NAME" ]; then
                # Cut before the hostname changed: nothing depends on the
                # switch yet, so it is undone and the next update tries again.
                echo "→ Unit name: a rename to $NEW_NAME was interrupted before it took effect."
                undo_from_repair
            else
                # Named since by hand (--name): that name stands, and the
                # record no longer describes this unit.
                echo "→ Unit name: the hostname is '$host', set after the rename to $NEW_NAME"
                echo "  began; the record of that rename is removed and the name kept."
                rm -f "$MARKER" "$HOSTS_BACKUP"
            fi
            ;;
    esac
}

switch_name() {
    local host hip
    host="$(current_hostname)"
    hip="$(env_value HOST_IP)"
    echo "→ Unit name: renaming $OLD_NAME to $NEW_NAME..."
    if [ "$host" = "$NEW_NAME" ]; then
        # With HOST_IP=digitool.local, digitool.local must keep answering
        # through the alias; the repair above has usually finished this.
        if [ "$hip" = "$OLD_NAME.local" ]; then
            finish_forward
        else
            echo "  The unit is already $NEW_NAME; nothing to do."
        fi
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
    if ! alias_installed; then
        echo "  The mDNS alias is not installed (avahi-utils missing). The rename waits for"
        echo "  avahi-utils: the unit keeps the name $OLD_NAME until an update that can"
        echo "  reach apt installs it."
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
    repoint_kiosk_lock "$OLD_NAME" "$NEW_NAME"
    if ! systemctl restart avahi-daemon; then
        echo "  ✗ Could not restart avahi-daemon."
        revert_switch; FAILED=1; return 0
    fi
    if ! systemctl enable --now "$ALIAS_UNIT_NAME"; then
        echo "  ✗ Could not start $ALIAS_UNIT_NAME, which keeps $OLD_NAME.local answering."
        revert_switch; FAILED=1; return 0
    fi
    if ! names_resolve; then
        echo "  ✗ Within ${WAIT_SECONDS}s, $NEW_NAME.local and $OLD_NAME.local did not both resolve to"
        echo "    this unit (getent hosts): ${WHY_NOT}. Another unit on this network may"
        echo "    have the name. Check: journalctl -u avahi-daemon -u $ALIAS_UNIT_NAME"
        revert_switch; FAILED=1; return 0
    fi
    if ! rewrite_env "$NEW_NAME.local" "http://$NEW_NAME.local" "http://$OLD_NAME.local"; then
        echo "  ✗ Could not rewrite $ENV_FILE."
        revert_switch; FAILED=1; return 0
    fi
    if ! write_marker done; then
        # The rename itself is complete and checked; only the record still
        # says pending, and --repair, under the hostname captua, checks the
        # names again and records it.
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
        repoint_kiosk_lock "$host" "$name"
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
