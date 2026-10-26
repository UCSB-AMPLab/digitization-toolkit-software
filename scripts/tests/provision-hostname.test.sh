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
#   hostnamectl    `set-hostname N` writes N to <root>/etc/hostname.
#   systemctl      records every call. `enable --now dtk-mdns-alias.service`
#                  marks the alias enabled (fails under FAKE_ALIAS_FAIL),
#                  `disable --now` unmarks it; `is-active avahi-daemon`
#                  succeeds unless FAKE_AVAHI_DOWN.
#   getent         resolves every name except those in FAKE_UNRESOLVED.
#   apt-get        records the call; installs a fake avahi-publish when
#                  FAKE_APT_OK is set, and fails otherwise.
#   avahi-publish  present when a case puts it in <root>/avahibin.
#   sleep          returns at once.
#
# Nothing touches the machine's own hostname, hosts file, avahi or systemd.

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
[ "$1" = set-hostname ] && printf '%s\n' "$2" > "$R/etc/hostname"
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
echo "getent $*" >> "$R/log"
for n in ${FAKE_UNRESOLVED:-}; do [ "$n" = "$2" ] && exit 2; done
echo "192.0.2.10      $2"
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
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/sleep"
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
has "this run is offline"
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
run --prepare
eq "$RC" 1 "without --advisory: exit status"
run --switch --advisory --wait 3
hostname_is digitool

# ── A name that does not resolve: everything undone, .env untouched ─────────
new_unit "getent fails"
with_avahi
ENV_SUM="$(sum_of "$R/dtk/.env")"; HOSTS_SUM="$(sum_of "$R/etc/hosts")"
FAKE_UNRESOLVED="digitool.local" run --advisory --wait 3
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
FAKE_UNRESOLVED="captua.local" run --switch --wait 3
eq "$RC" 1 "exit status"
hostname_is digitool
eq "$(sum_of "$R/dtk/.env")" "$ENV_SUM" ".env byte-identical"

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
unlogged "getent"

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

# ── Arguments ───────────────────────────────────────────────────────────────
new_unit "unknown argument"
run --advisroy
eq "$RC" 1 "exit status"
has "unknown argument"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
