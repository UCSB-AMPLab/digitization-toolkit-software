#!/bin/bash
# Tests for scripts/provision-hostname.sh: the rename from digitool to captua,
# its undo, its repair after a power cut, and the naming of a new card.
#
#   bash scripts/tests/provision-hostname.test.sh
#
# Each case runs the real script under --prefix against a fresh temporary
# root holding etc/hostname, etc/hosts and a .env, with a PATH of fakes in
# front of the system's:
#
#   hostnamectl    `set-hostname N` writes N to <root>/etc/hostname, and fails
#                  instead when N is FAKE_HOSTNAMECTL_FAIL_TO.
#   systemctl      records every call. `enable --now dtk-mdns-alias.service`
#                  marks the alias enabled (fails under FAKE_ALIAS_FAIL),
#                  `disable --now` unmarks it; `is-active avahi-daemon`
#                  succeeds unless FAKE_AVAHI_DOWN.
#   getent         as avahi answers: N.local resolves to this unit's address
#                  (192.0.2.10) when the hostname is N, and digitool.local
#                  also while the alias is enabled. Names in FAKE_UNRESOLVED
#                  never resolve; names in FAKE_FOREIGN resolve to another
#                  device's address.
#                  `getent passwd pi` names <root>/home/pi as pi's home.
#   ip             `-o addr show` lists 127.0.0.1, 192.0.2.10 and fe80::1.
#   apt-get        records the call; installs a fake avahi-publish when
#                  FAKE_APT_OK is set, and fails otherwise.
#   avahi-publish  present when a case puts it in <root>/avahibin.
#   sleep          sleeps a twentieth of a second, so that a wait bounded by
#                  wall time ends quickly but does end.
#
# The cases that expect the names not to resolve pass --wait 1.
#
# Nothing touches the machine's own hostname, hosts file, avahi or systemd.
#
# Version: 0.1.0-beta

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(dirname "$HERE")/provision-hostname.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/provision-hostname-test.XXXXXX")"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""
ok()   { PASS=$((PASS + 1)); echo "  ok    $CASE: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $CASE: $1"; }
eq()   { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3: got '$1', expected '$2'"; fi; }
has()  { case "$OUT" in *"$1"*) ok "says: $1" ;; *) fail "does not say: $1 (output: $OUT)" ;; esac; }
logged()   { if grep -qF -- "$1" "$R/log" 2>/dev/null; then ok "ran: $1"; else fail "did not run: $1"; fi; }
unlogged() { if grep -qF -- "$1" "$R/log" 2>/dev/null; then fail "ran: $1"; else ok "did not run: $1"; fi; }

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
uid_of()  { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
sum_of()  { cksum < "$1"; }

# ── Fakes ───────────────────────────────────────────────────────────────────
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/hostnamectl" <<'EOF'
#!/bin/sh
echo "hostnamectl $*" >> "$R/log"
if [ "$1" = set-hostname ]; then
    [ "$2" != "${FAKE_HOSTNAMECTL_FAIL_TO:-}" ] || exit 1
    printf '%s\n' "$2" > "$R/etc/hostname"
fi
exit 0
EOF
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$R/log"
case "$*" in
    "is-active --quiet avahi-daemon") [ -z "${FAKE_AVAHI_DOWN:-}" ] ;;
    "is-enabled --quiet dtk-mdns-alias.service") [ -f "$R/alias-enabled" ] ;;
    "enable --now dtk-mdns-alias.service")
        [ -z "${FAKE_ALIAS_FAIL:-}" ] || exit 1
        touch "$R/alias-enabled" ;;
    "disable --now dtk-mdns-alias.service") rm -f "$R/alias-enabled" ;;
    *) exit 0 ;;
esac
EOF
cat > "$FAKEBIN/getent" <<'EOF'
#!/bin/sh
if [ "$1" = passwd ]; then
    [ "$2" = pi ] && echo "pi:x:1000:1000::$R/home/pi:/bin/bash" && exit 0
    exit 2
fi
echo "getent $*" >> "$R/log"
for n in ${FAKE_UNRESOLVED:-}; do [ "$n" = "$2" ] && exit 2; done
for n in ${FAKE_FOREIGN:-}; do [ "$n" = "$2" ] && { echo "198.51.100.7    $2"; exit 0; }; done
host="$(tr -d '[:space:]' < "$R/etc/hostname")"
if [ "$2" = "$host.local" ] || { [ "$2" = digitool.local ] && [ -f "$R/alias-enabled" ]; }; then
    echo "192.0.2.10      $2"
    exit 0
fi
exit 2
EOF
# This unit's addresses, as `ip -o addr show` prints them.
cat > "$FAKEBIN/ip" <<'EOF'
#!/bin/sh
echo "1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever"
echo "2: wlan0    inet 192.0.2.10/24 brd 192.0.2.255 scope global dynamic wlan0\       valid_lft 86000sec"
echo "2: wlan0    inet6 fe80::1/64 scope link \       valid_lft forever preferred_lft forever"
EOF
cat > "$FAKEBIN/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$R/log"
[ -n "${FAKE_APT_OK:-}" ] || exit 100
case "$*" in
    *"install"*avahi-utils*)
        printf '#!/bin/sh\nexit 0\n' > "$R/avahibin/avahi-publish"
        chmod +x "$R/avahibin/avahi-publish" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexec /bin/sleep 0.05\n' > "$FAKEBIN/sleep"
chmod +x "$FAKEBIN"/*

HOSTS_STOCK='127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters

127.0.1.1		digitool
192.0.2.99	archive-nas   # added by hand'

ENV_STOCK='# Database Configuration
DATABASE_NAME=digitoolkit
SECRET_KEY=0123456789abcdef
APP_ENV=production

# Frontend Configuration
HOST_IP=digitool.local
CORS_ORIGINS=["http://digitool.local","http://localhost","http://localhost:5173","http://localhost:3000"]
PUBLIC_API_BASE=http://${HOST_IP}/api
DTK_OFFSITE_BWLIMIT=750k'

# new_unit <name> [hostname] [env text]: a fresh root for one case, R.
new_unit() {
    CASE="$1"
    R="$WORK/cases/$(echo "$CASE" | tr ' /,' '___')"
    mkdir -p "$R/etc" "$R/dtk" "$R/avahibin"
    printf '%s\n' "${2:-digitool}" > "$R/etc/hostname"
    printf '%s\n' "$HOSTS_STOCK" > "$R/etc/hosts"
    printf '%s\n' "${3:-$ENV_STOCK}" > "$R/dtk/.env"
    chmod 0640 "$R/dtk/.env"
    : > "$R/log"
    export R
}
with_avahi() {
    printf '#!/bin/sh\nexit 0\n' > "$R/avahibin/avahi-publish"
    chmod +x "$R/avahibin/avahi-publish"
}
run() {
    OUT="$(PATH="$FAKEBIN:$R/avahibin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$SCRIPT" --prefix "$R" --env-file "$R/dtk/.env" "$@" 2>&1 </dev/null)"
    RC=$?
}
env_line() { grep "^$1=" "$R/dtk/.env" | tail -n 1; }
hosts_line() { grep '^127\.0\.1\.1' "$R/etc/hosts"; }
hostname_is() { eq "$(cat "$R/etc/hostname")" "$1" "hostname is $1"; }
# The .env lines other than HOST_IP and CORS_ORIGINS, byte for byte.
other_env() { grep -v -e '^HOST_IP=' -e '^CORS_ORIGINS=' "$1"; }
count_of() { grep -o -F -- "$2" "$1" | wc -l | tr -d ' '; }
alias_on()  { if [ -f "$R/alias-enabled" ]; then ok "the alias is enabled"; else fail "the alias is not enabled"; fi; }
alias_off() { if [ -f "$R/alias-enabled" ]; then fail "the alias is enabled"; else ok "the alias is not enabled"; fi; }
marker_state() { sed -n 's/^state=//p' "$R/etc/dtk/hostname-switch" 2>/dev/null; }
# prepared: the alias installed, as update.sh's --prepare leaves it; the log
# starts empty after it.
prepared() { run --prepare --advisory; : > "$R/log"; }

echo "provision-hostname.sh"

# ── A unit in service as digitool, online ───────────────────────────────────
new_unit "fresh digitool unit"
with_avahi
ENV_BEFORE="$(other_env "$R/dtk/.env")"
UID_BEFORE="$(uid_of "$R/dtk/.env")"
run --wait 3
eq "$RC" 0 "exit status"
hostname_is captua
eq "$(hosts_line)" "$(printf '127.0.1.1\tcaptua digitool')" "/etc/hosts names captua and digitool"
eq "$(grep -c . "$R/etc/hosts")" 6 "/etc/hosts keeps its other lines"
if grep -qF '192.0.2.99	archive-nas   # added by hand' "$R/etc/hosts"; then ok "a line added by hand is kept"; else fail "a line added by hand is lost"; fi
eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP"
eq "$(env_line CORS_ORIGINS)" 'CORS_ORIGINS=["http://digitool.local","http://localhost","http://localhost:5173","http://localhost:3000","http://captua.local"]' "CORS_ORIGINS gains captua.local and keeps the rest"
eq "$(other_env "$R/dtk/.env")" "$ENV_BEFORE" "every other .env line is byte-identical"
eq "$(mode_of "$R/dtk/.env")" 640 ".env keeps its mode"
eq "$(uid_of "$R/dtk/.env")" "$UID_BEFORE" ".env keeps its owner"
alias_on
eq "$(marker_state)" done "the switch is recorded as done"
if [ -e "$R/etc/dtk/hosts.before-hostname-switch" ]; then fail "the /etc/hosts copy is left behind"; else ok "the /etc/hosts copy is removed"; fi
if [ -x "$R/usr/local/sbin/dtk-mdns-alias" ]; then ok "alias script installed, executable"; else fail "alias script missing"; fi
if [ -f "$R/etc/systemd/system/dtk-mdns-alias.service" ]; then ok "alias unit installed"; else fail "alias unit missing"; fi
if [ -x "$R/etc/NetworkManager/dispatcher.d/90-dtk-mdns-alias" ]; then ok "dispatcher hook installed"; else fail "dispatcher hook missing"; fi
if grep -q -- '--repair --advisory' "$R/etc/systemd/system/dtk.service.d/hostname-repair.conf" 2>/dev/null; then ok "dtk drop-in runs --repair"; else fail "dtk drop-in missing"; fi
if grep -q '^ExecStartPre=-+/bin/sh -c ' "$R/etc/systemd/system/dtk.service.d/hostname-repair.conf" 2>/dev/null; then ok "the drop-in runs as root and never fails the start"; else fail "drop-in ExecStartPre is not -+"; fi
logged "systemctl daemon-reload"
logged "systemctl reset-failed dtk-mdns-alias.service"
unlogged "apt-get"
# Order: the alias starts only after the host stopped claiming digitool.local.
order="$(grep -n -e 'hostnamectl set-hostname captua' -e 'systemctl restart avahi-daemon' -e 'systemctl enable --now dtk-mdns-alias' "$R/log" | cut -d: -f1 | tr '\n' ' ')"
first="$(grep -n 'hostnamectl set-hostname captua' "$R/log" | cut -d: -f1)"
restart="$(grep -n 'systemctl restart avahi-daemon' "$R/log" | head -n 1 | cut -d: -f1)"
enable="$(grep -n 'systemctl enable --now dtk-mdns-alias' "$R/log" | cut -d: -f1)"
if [ -n "$first" ] && [ -n "$restart" ] && [ -n "$enable" ] && [ "$first" -lt "$restart" ] && [ "$restart" -lt "$enable" ]; then
    ok "hostname, then avahi restart, then the alias ($order)"
else
    fail "order of hostname, avahi restart and alias: $order"
fi
logged "getent hosts captua.local"
logged "getent hosts digitool.local"

# ── The same unit again: nothing changes ────────────────────────────────────
CASE="fresh digitool unit, run again"
ENV_SUM="$(sum_of "$R/dtk/.env")"; HOSTS_SUM="$(sum_of "$R/etc/hosts")"
: > "$R/log"
run --wait 3
eq "$RC" 0 "exit status"
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env unchanged"
eq "$(sum_of "$R/etc/hosts")" "$HOSTS_SUM" "/etc/hosts unchanged"
unlogged "hostnamectl"
unlogged "systemctl restart avahi-daemon"
unlogged "systemctl daemon-reload"
has "already captua"
eq "$(count_of "$R/dtk/.env" '"http://captua.local"')" 1 "captua.local listed once"

# ── A hostname set by hand is left alone ────────────────────────────────────
new_unit "custom hostname" scanner-2
with_avahi
ENV_SUM="$(sum_of "$R/dtk/.env")"
run --wait 3
eq "$RC" 0 "exit status"
hostname_is scanner-2
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env unchanged"
unlogged "hostnamectl"
alias_off
has "named by hand, left alone"

# ── HOST_IP set to an IP is left alone ──────────────────────────────────────
new_unit "IP HOST_IP" digitool "$(printf '%s\n' "$ENV_STOCK" | sed 's/^HOST_IP=.*/HOST_IP=192.168.1.50/')"
with_avahi
ENV_SUM="$(sum_of "$R/dtk/.env")"
run --wait 3
eq "$RC" 0 "exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env unchanged"
unlogged "hostnamectl"
has "set by hand, left alone"

# ── Offline, without avahi-utils: skipped, nothing changes ──────────────────
new_unit "offline skip"
ENV_SUM="$(sum_of "$R/dtk/.env")"; HOSTS_SUM="$(sum_of "$R/etc/hosts")"
run --prepare --advisory --offline
eq "$RC" 0 "prepare: exit status"
unlogged "apt-get"
has "this run is --offline, so apt is not"
has "The rename to captua waits for avahi-utils"
run --switch --advisory --wait 3
eq "$RC" 0 "switch: exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env unchanged"
eq "$(sum_of "$R/etc/hosts")" "$HOSTS_SUM" "/etc/hosts unchanged"
unlogged "hostnamectl"
has "keeps the name digitool"

# ── Online, without avahi-utils: installed, then renamed ────────────────────
new_unit "online install"
FAKE_APT_OK=1 run --prepare --advisory
eq "$RC" 0 "prepare: exit status"
logged "apt-get install -y --no-install-recommends avahi-utils"
run --switch --advisory --wait 3
eq "$RC" 0 "switch: exit status"
hostname_is captua

# ── apt fails: advisory exits 0, plain exits 1, nothing renamed ─────────────
new_unit "apt fails"
run --prepare --advisory
eq "$RC" 0 "--advisory: exit status"
has "Could not install avahi-utils"
has "The rename to captua waits for avahi-utils"
run --prepare
eq "$RC" 1 "without --advisory: exit status"
run --switch --advisory --wait 3
hostname_is digitool

# ── A name that does not resolve: everything undone, .env untouched ─────────
new_unit "getent fails"
with_avahi
ENV_SUM="$(sum_of "$R/dtk/.env")"; HOSTS_SUM="$(sum_of "$R/etc/hosts")"
FAKE_UNRESOLVED="digitool.local" run --advisory --wait 1
eq "$RC" 0 "--advisory: exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env byte-identical"
eq "$(sum_of "$R/etc/hosts")" "$HOSTS_SUM" "/etc/hosts restored byte for byte"
alias_off
eq "$(marker_state)" "" "no switch recorded"
has "did not both resolve"
has "advisory"
logged "systemctl disable --now dtk-mdns-alias.service"
eq "$(grep -c 'systemctl restart avahi-daemon' "$R/log")" 2 "avahi restarted for the switch and again for the undo"
CASE="getent fails, without --advisory"
FAKE_UNRESOLVED="captua.local" run --switch --wait 1
eq "$RC" 1 "exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env byte-identical"

# ── A name that resolves to another device: undone ──────────────────────────
new_unit "name resolves elsewhere"
with_avahi
ENV_SUM="$(sum_of "$R/dtk/.env")"
FAKE_FOREIGN="captua.local" run --advisory --wait 1
eq "$RC" 0 "exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env byte-identical"
alias_off
has "resolves to 198.51.100.7, which is not this unit"

# ── The alias does not start: undone ────────────────────────────────────────
new_unit "alias fails to start"
with_avahi
ENV_SUM="$(sum_of "$R/dtk/.env")"
FAKE_ALIAS_FAIL=1 run --advisory --wait 3
eq "$RC" 0 "exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env byte-identical"
unlogged "getent"

# ── avahi not running: not renamed ──────────────────────────────────────────
new_unit "avahi down"
with_avahi
FAKE_AVAHI_DOWN=1 run --switch --advisory --wait 3
eq "$RC" 0 "exit status"
hostname_is digitool
unlogged "hostnamectl"

# ── CORS already lists captua.local: no duplicate ───────────────────────────
new_unit "no duplicate CORS" digitool "$(printf '%s\n' "$ENV_STOCK" | sed 's#^CORS_ORIGINS=.*#CORS_ORIGINS=["http://captua.local","http://localhost:3000"]#')"
with_avahi
run --wait 3
eq "$RC" 0 "exit status"
eq "$(count_of "$R/dtk/.env" '"http://captua.local"')" 1 "captua.local listed once"
eq "$(env_line CORS_ORIGINS)" 'CORS_ORIGINS=["http://captua.local","http://localhost:3000","http://digitool.local"]' "digitool.local added, since the old code needs it"

# ── No CORS_ORIGINS line: one is written ────────────────────────────────────
new_unit "no CORS line" digitool "$(printf '%s\n' "$ENV_STOCK" | grep -v '^CORS_ORIGINS=')"
with_avahi
run --wait 3
eq "$RC" 0 "exit status"
eq "$(env_line CORS_ORIGINS)" 'CORS_ORIGINS=["http://localhost:5173","http://localhost:3000","http://captua.local","http://digitool.local"]' "the backend defaults plus both names"

# ── CORS_ORIGINS that is not a JSON list: undone ────────────────────────────
new_unit "CORS not a list" digitool "$(printf '%s\n' "$ENV_STOCK" | sed 's#^CORS_ORIGINS=.*#CORS_ORIGINS=http://digitool.local#')"
with_avahi
ENV_SUM="$(sum_of "$R/dtk/.env")"
run --advisory --wait 3
eq "$RC" 0 "exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env byte-identical"
has "not a JSON list"
if ls -A "$R/dtk" | grep -q '^\.env\.hostname\.'; then fail "a temporary file is left behind"; else ok "no temporary file left behind"; fi

# ── --repair ────────────────────────────────────────────────────────────────
new_unit "repair, nothing pending"
run --repair --advisory
eq "$RC" 0 "exit status"
eq "$(cat "$R/log")" "" "no command run"

# Cut after hostnamectl: forward.
new_unit "repair, cut after the hostname changed"
with_avahi
prepared
mkdir -p "$R/etc/dtk"
cp "$R/etc/hosts" "$R/etc/dtk/hosts.before-hostname-switch"
printf 'state=pending\nfrom=digitool\nto=captua\n' > "$R/etc/dtk/hostname-switch"
printf 'captua\n' > "$R/etc/hostname"
ENV_BEFORE="$(other_env "$R/dtk/.env")"
run --repair --advisory
eq "$RC" 0 "exit status"
hostname_is captua
eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP finished"
eq "$(other_env "$R/dtk/.env")" "$ENV_BEFORE" "every other .env line is byte-identical"
eq "$(mode_of "$R/dtk/.env")" 640 ".env keeps its mode"
alias_on
eq "$(marker_state)" done "recorded as done"
eq "$(hosts_line)" "$(printf '127.0.1.1\tcaptua digitool')" "/etc/hosts names captua and digitool again"
logged "getent hosts captua.local"
logged "getent hosts digitool.local"

# Cut before hostnamectl: undone.
new_unit "repair, cut before the hostname changed"
with_avahi
HOSTS_SUM="$(sum_of "$R/etc/hosts")"
ENV_SUM="$(sum_of "$R/dtk/.env")"
mkdir -p "$R/etc/dtk"
cp "$R/etc/hosts" "$R/etc/dtk/hosts.before-hostname-switch"
printf 'state=pending\nfrom=digitool\nto=captua\n' > "$R/etc/dtk/hostname-switch"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tcaptua digitool\n' > "$R/etc/hosts"
run --repair --advisory
eq "$RC" 0 "exit status"
hostname_is digitool
eq "$(sum_of "$R/etc/hosts")" "$HOSTS_SUM" "/etc/hosts restored"
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env untouched"
alias_off
eq "$(marker_state)" "" "the record is removed"
CASE="repair, cut before the hostname changed: the next update"
run --advisory --wait 3
hostname_is captua

# Done, then .env put back by hand: pointed forward again.
new_unit "repair, done but .env names digitool again"
with_avahi
run --wait 3
cp "$R/dtk/.env" "$R/env.after"
sed 's/^HOST_IP=.*/HOST_IP=digitool.local/' "$R/env.after" > "$R/dtk/.env"
run --repair --advisory
eq "$RC" 0 "exit status"
eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP forward again"
eq "$(count_of "$R/dtk/.env" '"http://captua.local"')" 1 "captua.local listed once"

# A pending switch with the hostname captua, but captua.local answering from
# another device: undone, and HOST_IP, which the switch had already
# rewritten, put back.
new_unit "repair, pending, captua.local is another device's"
with_avahi
prepared
HOSTS_SUM="$(sum_of "$R/etc/hosts")"
mkdir -p "$R/etc/dtk"
cp "$R/etc/hosts" "$R/etc/dtk/hosts.before-hostname-switch"
printf 'state=pending\nfrom=digitool\nto=captua\n' > "$R/etc/dtk/hostname-switch"
printf 'captua\n' > "$R/etc/hostname"
sed -i.bak 's/^HOST_IP=.*/HOST_IP=captua.local/' "$R/dtk/.env" && rm -f "$R/dtk/.env.bak"
FAKE_FOREIGN="captua.local" run --repair --advisory --wait 1
eq "$RC" 0 "exit status"
hostname_is digitool
eq "$(sum_of "$R/etc/hosts")" "$HOSTS_SUM" "/etc/hosts restored"
eq "$(env_line HOST_IP)" "HOST_IP=digitool.local" "HOST_IP back to digitool.local"
alias_off
eq "$(marker_state)" "" "the record is removed"
has "another device on this network has the name"

# The same, but .env cannot be pointed back (CORS_ORIGINS is not a list):
# nothing is undone and the record stays, so the next start tries again.
new_unit "repair, pending, captua.local elsewhere, .env cannot be restored"
with_avahi
prepared
mkdir -p "$R/etc/dtk"
cp "$R/etc/hosts" "$R/etc/dtk/hosts.before-hostname-switch"
printf 'state=pending\nfrom=digitool\nto=captua\n' > "$R/etc/dtk/hostname-switch"
printf 'captua\n' > "$R/etc/hostname"
sed -i.bak -e 's/^HOST_IP=.*/HOST_IP=captua.local/' -e 's#^CORS_ORIGINS=.*#CORS_ORIGINS=http://captua.local#' "$R/dtk/.env" && rm -f "$R/dtk/.env.bak"
FAKE_FOREIGN="captua.local" run --repair --advisory --wait 1
eq "$RC" 0 "exit status"
hostname_is captua
eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP unchanged"
alias_on
eq "$(marker_state)" pending "the record stays"
has "the undo waits for the next start"

# Pending, hostname captua, and neither name resolving yet (the network not
# up at boot): .env goes forward, the record stays pending.
new_unit "repair, pending, names not resolving yet"
with_avahi
prepared
mkdir -p "$R/etc/dtk"
printf 'state=pending\nfrom=digitool\nto=captua\n' > "$R/etc/dtk/hostname-switch"
printf 'captua\n' > "$R/etc/hostname"
FAKE_UNRESOLVED="captua.local digitool.local" run --repair --advisory --wait 1
eq "$RC" 0 "exit status"
hostname_is captua
eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP forward"
alias_on
eq "$(marker_state)" pending "still pending"
has "The rename stays pending"
CASE="repair, pending, names not resolving yet: the next start"
run --repair --advisory --wait 3
eq "$(marker_state)" done "recorded as done once both names resolve"

# Pending, then named by hand (--name captua-2) before the names resolved:
# the next start keeps that name.
new_unit "repair, pending, then named by hand"
with_avahi
prepared
mkdir -p "$R/etc/dtk"
printf 'state=pending\nfrom=digitool\nto=captua\n' > "$R/etc/dtk/hostname-switch"
printf 'captua\n' > "$R/etc/hostname"
FAKE_UNRESOLVED="captua.local digitool.local" run --name captua-2 --advisory --wait 1
hostname_is captua-2
CASE="repair, pending, then named by hand: the next start"
: > "$R/log"
run --repair --advisory --wait 1
eq "$RC" 0 "exit status"
hostname_is captua-2
eq "$(env_line HOST_IP)" "HOST_IP=captua-2.local" "HOST_IP kept"
eq "$(marker_state)" "" "the record is removed"
unlogged "hostnamectl"
has "the name kept"

# A record whose data a power cut lost (empty), and one with a state this
# script does not know: the hostname decides.
for rec in empty garbled; do
    new_unit "repair, $rec record, hostname captua"
    with_avahi
    prepared
    mkdir -p "$R/etc/dtk"
    if [ "$rec" = empty ]; then : > "$R/etc/dtk/hostname-switch"; else printf 'state=garbled\n' > "$R/etc/dtk/hostname-switch"; fi
    printf 'captua\n' > "$R/etc/hostname"
    run --repair --advisory --wait 3
    eq "$RC" 0 "exit status"
    hostname_is captua
    eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP finished"
    eq "$(hosts_line)" "$(printf '127.0.1.1\tcaptua digitool')" "/etc/hosts names captua and digitool"
    alias_on
    eq "$(marker_state)" done "recorded as done"
    has "the hostname decides"

    new_unit "repair, $rec record, hostname digitool"
    with_avahi
    HOSTS_SUM="$(sum_of "$R/etc/hosts")"; ENV_SUM="$(sum_of "$R/dtk/.env")"
    mkdir -p "$R/etc/dtk"
    cp "$R/etc/hosts" "$R/etc/dtk/hosts.before-hostname-switch"
    if [ "$rec" = empty ]; then : > "$R/etc/dtk/hostname-switch"; else printf 'state=garbled\n' > "$R/etc/dtk/hostname-switch"; fi
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tcaptua digitool\n' > "$R/etc/hosts"
    run --repair --advisory
    eq "$RC" 0 "exit status"
    hostname_is digitool
    eq "$(sum_of "$R/etc/hosts")" "$HOSTS_SUM" "/etc/hosts restored"
    eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env untouched"
    eq "$(marker_state)" "" "the record is removed"
done

# Hostname captua with HOST_IP=digitool.local and no record at all: without
# the alias, digitool.local would be dead. Both --repair and --switch finish
# the switch.
for how in --repair --switch; do
    new_unit "no record, hostname captua, HOST_IP digitool.local ($how)" captua
    with_avahi
    prepared
    run "$how" --advisory --wait 3
    eq "$RC" 0 "exit status"
    hostname_is captua
    alias_on
    eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP forward"
    eq "$(hosts_line)" "$(printf '127.0.1.1\tcaptua digitool')" "/etc/hosts names captua and digitool"
    if env_line CORS_ORIGINS | grep -qF '"http://captua.local"'; then ok "CORS_ORIGINS lists captua.local"; else fail "CORS_ORIGINS lacks captua.local"; fi
    eq "$(marker_state)" done "recorded as done"
done

# The same, but captua.local is another device's: with no record of a
# rename on this unit, nothing is undone; it is reported.
new_unit "no record, hostname captua, captua.local elsewhere" captua
with_avahi
run --prepare --advisory
FAKE_FOREIGN="captua.local" run --repair --wait 1
eq "$RC" 1 "exit status"
hostname_is captua
has "No rename was recorded on this unit"

# ── The undo cannot set the hostname back ───────────────────────────────────
new_unit "hostnamectl fails during the undo"
with_avahi
HOSTS_SUM="$(sum_of "$R/etc/hosts")"; ENV_SUM="$(sum_of "$R/dtk/.env")"
FAKE_FOREIGN="captua.local" FAKE_HOSTNAMECTL_FAIL_TO=digitool run --advisory --wait 1
eq "$RC" 0 "--advisory: exit status"
hostname_is captua
eq "$(hosts_line)" "$(printf '127.0.1.1\tcaptua digitool')" "/etc/hosts still names both, valid under captua"
alias_on
eq "$(marker_state)" pending "the record stays, for the next start"
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env untouched"
has "The hostname is still 'captua'"
CASE="hostnamectl fails during the undo: the next start"
FAKE_FOREIGN="captua.local" run --repair --advisory --wait 1
hostname_is digitool
eq "$(sum_of "$R/etc/hosts")" "$HOSTS_SUM" "/etc/hosts restored once the hostname is back"
alias_off
eq "$(marker_state)" "" "the record is removed"

# ── Temporary files ─────────────────────────────────────────────────────────
new_unit "stale temporary files, --repair"
mkdir -p "$R/etc/dtk"
touch "$R/dtk/.env.hostname.a1B2c3" "$R/etc/.hosts.Zz9yX8" "$R/etc/dtk/.hostname-switch.q1w2e3"
# Not this script's: other names, or other lengths.
touch "$R/dtk/.env.hostname.toolong7" "$R/dtk/.env.backup" "$R/etc/.hosts.ab12"
run --repair --advisory
eq "$RC" 0 "exit status"
for f in dtk/.env.hostname.a1B2c3 etc/.hosts.Zz9yX8 etc/dtk/.hostname-switch.q1w2e3; do
    if [ -e "$R/$f" ]; then fail "$f is left"; else ok "$f removed"; fi
done
for f in dtk/.env.hostname.toolong7 dtk/.env.backup etc/.hosts.ab12; do
    if [ -e "$R/$f" ]; then ok "$f kept"; else fail "$f removed"; fi
done

new_unit "stale temporary files, --prepare"
with_avahi
mkdir -p "$R/etc/systemd/system" "$R/etc/NetworkManager/dispatcher.d"
touch "$R/etc/systemd/system/.dtk-mdns-alias.service.k9j8h7" "$R/etc/NetworkManager/dispatcher.d/.90-dtk-mdns-alias.m1n2b3"
run --prepare --advisory
eq "$RC" 0 "exit status"
for f in etc/systemd/system/.dtk-mdns-alias.service.k9j8h7 etc/NetworkManager/dispatcher.d/.90-dtk-mdns-alias.m1n2b3; do
    if [ -e "$R/$f" ]; then fail "$f is left"; else ok "$f removed"; fi
done

# A run ended by a signal between mktemp and the rename: the EXIT trap
# removes its temporary file. The cp that fills /etc/hosts' temporary copy
# signals the script.
new_unit "signal mid-write"
with_avahi
prepared
mkdir -p "$R/sigbin"
cat > "$R/sigbin/cp" <<'EOF'
#!/bin/sh
/bin/cp "$@"
case "$*" in *"/.hosts."*) kill -TERM "$PPID" ;; esac
exit 0
EOF
chmod +x "$R/sigbin/cp"
OUT="$(PATH="$R/sigbin:$FAKEBIN:$R/avahibin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPT" --prefix "$R" --env-file "$R/dtk/.env" --switch --wait 1 2>&1 </dev/null)"
RC=$?
eq "$RC" 143 "exit status"
if ls -A "$R/etc" | grep -q '^\.hosts\.'; then fail "the temporary copy of /etc/hosts is left"; else ok "the temporary copy of /etc/hosts is removed"; fi
eq "$(marker_state)" pending "the switch is recorded as pending, as after a power cut"
CASE="signal mid-write: the next start"
run --repair --advisory
hostname_is digitool
eq "$(marker_state)" "" "undone"

# A clean run leaves no temporary file anywhere under the root.
new_unit "no temporary files after a run"
with_avahi
run --wait 3
eq "$RC" 0 "exit status"
eq "$(find "$R" -name '.*.??????' | wc -l | tr -d ' ')" 0 "no .<name>.XXXXXX file left"

# ── The wait for the names is bounded by wall time ──────────────────────────
new_unit "wait bounded by wall time"
with_avahi
START=$SECONDS
FAKE_UNRESOLVED="captua.local" run --advisory --wait 2
ELAPSED=$((SECONDS - START))
if [ "$ELAPSED" -ge 1 ] && [ "$ELAPSED" -le 6 ]; then ok "ended after ${ELAPSED}s for --wait 2"; else fail "ended after ${ELAPSED}s for --wait 2"; fi
TRIES="$(grep -c 'getent hosts captua.local' "$R/log")"
if [ "$TRIES" -gt 2 ]; then ok "tried $TRIES times, not --wait times"; else fail "tried $TRIES times"; fi
has "Within 2s"
hostname_is digitool

# ── The kiosk's Chromium profile lock follows the hostname ─────────────────
# with_kiosk: a tty1 autologin for pi, and a running kiosk's lock.
with_kiosk() {
    mkdir -p "$R/etc/systemd/system/getty@tty1.service.d" "$R/home/pi/.config/chromium"
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin pi --noclear %%I $TERM\n' \
        > "$R/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    ln -s digitool-3437 "$R/home/pi/.config/chromium/SingletonLock"
}
lock_is() { eq "$(readlink "$R/home/pi/.config/chromium/SingletonLock")" "$1" "the kiosk's lock names $1"; }

new_unit "kiosk lock, renamed"
with_avahi
with_kiosk
run --advisory --wait 3
hostname_is captua
lock_is captua-3437

new_unit "kiosk lock, rename undone"
with_avahi
with_kiosk
FAKE_FOREIGN="captua.local" run --advisory --wait 1
hostname_is digitool
lock_is digitool-3437

new_unit "kiosk lock, cut after the hostname changed"
with_avahi
with_kiosk
prepared
mkdir -p "$R/etc/dtk"
printf 'state=pending\nfrom=digitool\nto=captua\n' > "$R/etc/dtk/hostname-switch"
printf 'captua\n' > "$R/etc/hostname"
run --repair --advisory --wait 3
lock_is captua-3437

new_unit "kiosk lock of another host is left alone"
with_avahi
with_kiosk
ln -sfn otherbox-77 "$R/home/pi/.config/chromium/SingletonLock"
run --advisory --wait 3
hostname_is captua
lock_is otherbox-77

new_unit "no kiosk"
with_avahi
run --advisory --wait 3
eq "$RC" 0 "exit status"
hostname_is captua

# ── --name, setup.sh on a new card ──────────────────────────────────────────
EXAMPLE_ENV="$(cat "$(dirname "$(dirname "$HERE")")/.env.example")"
new_unit "new card" raspberrypi "$EXAMPLE_ENV"
sed -i.bak 's/digitool/raspberrypi/' "$R/etc/hosts" && rm -f "$R/etc/hosts.bak"
with_avahi
run --name captua
eq "$RC" 0 "exit status"
hostname_is captua
eq "$(hosts_line)" "$(printf '127.0.1.1\tcaptua')" "/etc/hosts names captua only"
eq "$(env_line HOST_IP)" "HOST_IP=captua.local" "HOST_IP"
if env_line CORS_ORIGINS | grep -qF '"http://captua.local"'; then ok "CORS_ORIGINS lists captua.local"; else fail "CORS_ORIGINS lacks captua.local"; fi
if env_line CORS_ORIGINS | grep -qF 'digitool'; then fail "a new card lists digitool"; else ok "a new card does not list digitool"; fi
alias_off
eq "$(marker_state)" "" "no switch recorded"

new_unit "new card, second unit at a site" raspberrypi "$EXAMPLE_ENV"
with_avahi
run --name captua-2
eq "$RC" 0 "exit status"
hostname_is captua-2
eq "$(env_line HOST_IP)" "HOST_IP=captua-2.local" "HOST_IP"

new_unit "new card, invalid name" raspberrypi "$EXAMPLE_ENV"
run --name Captua_2
eq "$RC" 1 "exit status"
hostname_is raspberrypi
has "not a valid host name"

new_unit "setup on a unit in service as digitool"
with_avahi
run --name captua --wait 3
eq "$RC" 0 "exit status"
hostname_is captua
alias_on
if env_line CORS_ORIGINS | grep -qF '"http://digitool.local"'; then ok "digitool.local kept"; else fail "digitool.local dropped"; fi

# ── scripts/start-kiosk.sh: the profile lock ────────────────────────────────
KIOSK="$(dirname "$HERE")/start-kiosk.sh"
KBIN="$WORK/kioskbin"
mkdir -p "$KBIN"
printf '#!/bin/sh\nexit 0\n' > "$KBIN/curl"
# cage records its arguments and which lock files exist when it starts.
cat > "$KBIN/cage" <<'EOF'
#!/bin/sh
echo "cage $*" >> "$KHOME/log"
for f in SingletonLock SingletonCookie SingletonSocket; do
    if [ -e "$KHOME/.config/chromium/$f" ] || [ -L "$KHOME/.config/chromium/$f" ]; then echo "present $f" >> "$KHOME/log"; fi
done
EOF
cat > "$KBIN/pgrep" <<'EOF'
#!/bin/sh
echo "pgrep $*" >> "$KHOME/log"
[ -n "${FAKE_CHROMIUM_RUNNING:-}" ]
EOF
chmod +x "$KBIN"/*
new_kiosk_home() {
    CASE="$1"
    KHOME="$WORK/kiosk/$(echo "$CASE" | tr ' /,' '___')"
    mkdir -p "$KHOME/.config/chromium/Default"
    ln -s digitool-3437 "$KHOME/.config/chromium/SingletonLock"
    ln -s 1234567890 "$KHOME/.config/chromium/SingletonCookie"
    ln -s /tmp/.org.chromium.Chromium.abc/SingletonSocket "$KHOME/.config/chromium/SingletonSocket"
    echo '{}' > "$KHOME/.config/chromium/Default/Preferences"
    echo '{}' > "$KHOME/.config/chromium/Local State"
    : > "$KHOME/log"
    export KHOME
}
run_kiosk() {
    OUT="$(HOME="$KHOME" PATH="$KBIN:/usr/bin:/bin" bash "$KIOSK" 2>&1 </dev/null)"
    RC=$?
}
klogged() { if grep -qF -- "$1" "$KHOME/log"; then ok "$2"; else fail "$2 (log: $(cat "$KHOME/log"))"; fi; }
knot()    { if grep -qF -- "$1" "$KHOME/log"; then fail "$2 (log: $(cat "$KHOME/log"))"; else ok "$2"; fi; }

new_kiosk_home "kiosk, lock from the old hostname"
run_kiosk
eq "$RC" 0 "exit status"
knot "present Singleton" "no Singleton file when cage starts"
klogged "--user-data-dir=$KHOME/.config/chromium" "Chromium opens the profile whose lock was removed"
if [ -f "$KHOME/.config/chromium/Default/Preferences" ] && [ -f "$KHOME/.config/chromium/Local State" ]; then ok "the rest of the profile is kept"; else fail "profile files removed"; fi

new_kiosk_home "kiosk, a Chromium still running"
FAKE_CHROMIUM_RUNNING=1 run_kiosk
klogged "present SingletonLock" "the running Chromium's lock is kept"
has "still running"

# ── scripts/dtk-mdns-alias: which address it publishes ──────────────────────
ALIAS="$(dirname "$HERE")/dtk-mdns-alias"
ABIN="$WORK/aliasbin"
mkdir -p "$ABIN"
# ip: FAKE_ADDRS lines "<if> <addr>"; FAKE_ROUTE_SRC the default route's source.
cat > "$ABIN/ip" <<'EOF'
#!/bin/sh
case "$*" in
    "-4 -o addr show scope global")
        printf '%s\n' "${FAKE_ADDRS:-}" | while read -r ifc addr; do
            [ -n "$ifc" ] && echo "3: $ifc    inet $addr/24 brd x scope global $ifc\       valid_lft forever"
        done ;;
    "-6 -o addr show dev "*" scope global")
        want="$6"
        printf '%s\n' "${FAKE_ADDRS6:-}" | while read -r ifc addr flags; do
            [ "$ifc" = "$want" ] && echo "3: $ifc    inet6 $addr/64 scope global $flags \\       valid_lft forever"
        done ;;
    "-4 route get 1.1.1.1")
        [ -n "${FAKE_ROUTE_SRC:-}" ] || exit 2
        echo "1.1.1.1 via 192.0.2.1 dev wlan0 src $FAKE_ROUTE_SRC uid 0" ;;
esac
EOF
printf '#!/bin/sh\necho "avahi-publish $*"\n' > "$ABIN/avahi-publish"
chmod +x "$ABIN"/*
run_alias() {
    OUT="$(PATH="$ABIN:/usr/bin:/bin" bash "$ALIAS" digitool.local 2>&1 </dev/null)"
    RC=$?
}

CASE="alias, the default route's source"
FAKE_ADDRS="$(printf 'docker0 172.17.0.1\neth0 10.0.0.5\nwlan0 192.0.2.10')" FAKE_ROUTE_SRC=192.0.2.10 run_alias
eq "$RC" 0 "exit status"
has "avahi-publish -a -R digitool.local 192.0.2.10"

CASE="alias, route through the Tailscale tunnel"
FAKE_ADDRS="$(printf 'docker0 172.17.0.1\ntailscale0 100.64.0.9\neth0 10.0.0.5')" FAKE_ROUTE_SRC=100.64.0.9 run_alias
has "avahi-publish -a -R digitool.local 10.0.0.5"

CASE="alias, no default route"
FAKE_ADDRS="$(printf 'br-1a2b 172.18.0.1\nveth9 169.254.3.3\nwlan0 192.0.2.10')" run_alias
has "avahi-publish -a -R digitool.local 192.0.2.10"

CASE="alias, no address on a real interface"
FAKE_ADDRS="$(printf 'docker0 172.17.0.1\nlo 127.0.0.1')" run_alias
eq "$RC" 1 "exit status"
has "no IPv4 address on a real interface yet"
case "$OUT" in *avahi-publish*) fail "published anyway" ;; *) ok "published nothing" ;; esac

CASE="alias, a global IPv6 on the same interface"
FAKE_ADDRS="$(printf 'eth0 10.0.0.5\nwlan0 192.0.2.10')" FAKE_ROUTE_SRC=192.0.2.10 \
    FAKE_ADDRS6="$(printf 'eth0 fd00:1::5\nwlan0 fd00:2::10')" run_alias
eq "$RC" 0 "exit status"
has "avahi-publish -a -R digitool.local 192.0.2.10"
has "avahi-publish -a -R digitool.local fd00:2::10"
case "$OUT" in *fd00:1::5*) fail "took the IPv6 of another interface" ;; *) ok "IPv6 taken from the IPv4 choice's interface" ;; esac

CASE="alias, only link-local IPv6"
FAKE_ADDRS="wlan0 192.0.2.10" FAKE_ROUTE_SRC=192.0.2.10 FAKE_ADDRS6="" run_alias
has "avahi-publish -a -R digitool.local 192.0.2.10"
case "$OUT" in *"digitool.local fe80"*|*"digitool.local fd"*|*"digitool.local 2"*) fail "published an IPv6 address" ;; *) ok "published IPv4 only" ;; esac

CASE="alias, IPv6 temporary or deprecated skipped"
FAKE_ADDRS="wlan0 192.0.2.10" FAKE_ROUTE_SRC=192.0.2.10 \
    FAKE_ADDRS6="$(printf 'wlan0 fd00:2::99 temporary dynamic\nwlan0 fd00:2::98 deprecated\nwlan0 fd00:2::10 dynamic mngtmpaddr')" run_alias
has "avahi-publish -a -R digitool.local fd00:2::10"
case "$OUT" in *fd00:2::99*|*fd00:2::98*) fail "published an unusable IPv6" ;; *) ok "unusable IPv6 skipped" ;; esac

# ── The unit file and the dispatcher hook ───────────────────────────────────
CASE="alias unit file"
SCRIPTS_DIR="$(dirname "$HERE")"
DR="$WORK/dispatcher"; mkdir -p "$DR"
if grep -q '^StartLimitIntervalSec=0$' "$SCRIPTS_DIR/dtk-mdns-alias.service"; then ok "StartLimitIntervalSec=0"; else fail "StartLimitIntervalSec=0 missing"; fi
if grep -q '^Restart=on-failure$' "$SCRIPTS_DIR/dtk-mdns-alias.service" && grep -q '^RestartSec=10s$' "$SCRIPTS_DIR/dtk-mdns-alias.service"; then ok "Restart=on-failure, RestartSec=10s kept"; else fail "restart policy changed"; fi

run_dispatcher() {  # run_dispatcher EVENT
    DBIN="$DR/bin"; mkdir -p "$DBIN"; : > "$DR/dlog"
    printf '#!/bin/sh\necho "$*" >> "%s/dlog"\n' "$DR" > "$DBIN/systemctl"; chmod +x "$DBIN/systemctl"
    PATH="$DBIN:$PATH" sh "$SCRIPTS_DIR/dtk-mdns-alias.dispatcher" eth0 "$1"
}
for ev in up down dhcp4-change dhcp6-change; do
    CASE="dispatcher, $ev"
    run_dispatcher "$ev"
    if grep -qF 'restart --no-block dtk-mdns-alias.service' "$DR/dlog"; then ok "restarts the alias"; else fail "did not restart the alias"; fi
done
for ev in connectivity-change pre-up hostname; do
    CASE="dispatcher, $ev"
    run_dispatcher "$ev"
    if grep -qF 'restart' "$DR/dlog"; then fail "restarted the alias"; else ok "ignored"; fi
done

# ── Arguments ───────────────────────────────────────────────────────────────
new_unit "unknown argument"
run --advisroy
eq "$RC" 1 "exit status"
has "unknown argument"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
