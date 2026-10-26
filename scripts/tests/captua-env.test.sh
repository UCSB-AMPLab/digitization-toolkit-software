#!/bin/bash
# Tests for the CAPTUA_ / DTK_ settings rule in scripts/captua-env.sh and for
# one real read site in each script that applies it.
#
#   bash scripts/tests/captua-env.test.sh
#
# The scripts need root, docker and systemd, so they are not run whole. The
# helper is sourced, and the lines or functions that read a setting are taken
# out of the real scripts and run, so a read site changed back to a bare DTK_
# name fails here.
#
# Version: 0.1.0-beta

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/captua-env-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok    $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

check() {  # check <what> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# shellcheck source=../captua-env.sh
. "$SCRIPTS/captua-env.sh"

# Runs the helper in a clean environment with the given variables, so that
# nothing in the caller's environment leaks into a case.
helper() {  # helper <VAR=value>... -- <suffix> [default]
    local -a vars=()
    while [ "$1" != "--" ]; do vars+=("$1"); shift; done
    shift
    env -i PATH="$PATH" ${vars[@]+"${vars[@]}"} bash -c '. "$1"; shift; captua_env "$@"' _ "$SCRIPTS/captua-env.sh" "$@" 2>"$WORK/err"
}

echo "== the helper =="
check "CAPTUA_ only"            "new"  "$(helper CAPTUA_X=new -- X old-default)"
check "DTK_ only"               "old"  "$(helper DTK_X=old -- X dflt)"
check "neither: the default"    "dflt" "$(helper -- X dflt)"
check "neither, no default"     ""     "$(helper -- X)"
check "both equal"              "same" "$(helper CAPTUA_X=same DTK_X=same -- X)"
check "both equal: no warning"  ""     "$(cat "$WORK/err")"
check "both different: CAPTUA_ wins" "new" "$(helper CAPTUA_X=new DTK_X=old -- X)"
warning="$(cat "$WORK/err")"
check "both different: one line" "1" "$(printf '%s\n' "$warning" | grep -c .)"
case "$warning" in
    *CAPTUA_X*DTK_X*) ok "the warning names both variables" ;;
    *) fail "the warning does not name both variables: '$warning'" ;;
esac
case "$warning" in
    *new*|*old*) fail "the warning carries a value: '$warning'" ;;
    *) ok "the warning carries no value" ;;
esac
check "empty CAPTUA_ falls back to DTK_" "old" "$(helper CAPTUA_X= DTK_X=old -- X)"
check "empty DTK_ is unset"      "new"  "$(helper CAPTUA_X=new DTK_X= -- X)"
check "empty CAPTUA_ and DTK_ give no warning" "" "$(helper CAPTUA_X= DTK_X=old -- X >/dev/null; cat "$WORK/err")"
check "a value with spaces is kept whole" "a b  c" "$(helper CAPTUA_X="a b  c" -- X)"

echo "== rollback-update.sh carries the same function =="
fn() { awk '/^captua_env\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$1"; }
check "same text as captua-env.sh" "$(fn "$SCRIPTS/captua-env.sh")" "$(fn "$SCRIPTS/rollback-update.sh")"

# Evaluates the first line of a script that begins with <prefix>, in a clean
# environment with the given variables, and prints the variable it sets.
read_site() {  # read_site <script> <prefix> <var> <VAR=value>... 
    local script="$1" prefix="$2" var="$3" line
    shift 3
    line="$(awk -v p="$prefix" 'index($0, p) == 1 { print; exit }' "$script")"
    [ -n "$line" ] || { echo "NO-LINE"; return; }
    env -i PATH="$PATH" "$@" bash -c '. "$1"; eval "$2"; printf "%s" "${!3}"' _ "$SCRIPTS/captua-env.sh" "$line" "$var" 2>/dev/null
}

echo "== check-stack-health.sh =="
S="$SCRIPTS/check-stack-health.sh"
check "default"             "30" "$(read_site "$S" 'MAX_TRIES=' MAX_TRIES)"
check "DTK_ name"           "7"  "$(read_site "$S" 'MAX_TRIES=' MAX_TRIES DTK_HEALTH_MAX_TRIES=7)"
check "CAPTUA_ name"        "9"  "$(read_site "$S" 'MAX_TRIES=' MAX_TRIES CAPTUA_HEALTH_MAX_TRIES=9)"
check "sleep: CAPTUA_ wins" "4"  "$(read_site "$S" 'SLEEP_SECS=' SLEEP_SECS CAPTUA_HEALTH_SLEEP_SECS=4 DTK_HEALTH_SLEEP_SECS=8)"

echo "== update.sh =="
S="$SCRIPTS/update.sh"
check "timeout default"     "300" "$(read_site "$S" 'HEALTH_TIMEOUT=' HEALTH_TIMEOUT)"
check "timeout: DTK_ name"  "11"  "$(read_site "$S" 'HEALTH_TIMEOUT=' HEALTH_TIMEOUT DTK_UPDATE_HEALTH_TIMEOUT=11)"
check "poll: CAPTUA_ name"  "2"   "$(read_site "$S" 'HEALTH_POLL=' HEALTH_POLL CAPTUA_UPDATE_HEALTH_POLL=2)"
check "fail point: CAPTUA_" "build" "$(read_site "$S" 'FAIL_AT=' FAIL_AT CAPTUA_UPDATE_FAIL_AT=build)"
check "fail point: DTK_"    "pixi"  "$(read_site "$S" 'FAIL_AT=' FAIL_AT DTK_UPDATE_FAIL_AT=pixi)"

echo "== setup.sh =="
S="$SCRIPTS/setup.sh"
check "hostname default"    "captua"   "$(read_site "$S" 'UNIT_HOSTNAME=' UNIT_HOSTNAME)"
check "hostname: DTK_ name" "captua-2" "$(read_site "$S" 'UNIT_HOSTNAME=' UNIT_HOSTNAME DTK_HOSTNAME=captua-2)"
check "hostname: CAPTUA_"   "captua-3" "$(read_site "$S" 'UNIT_HOSTNAME=' UNIT_HOSTNAME CAPTUA_HOSTNAME=captua-3 DTK_HOSTNAME=captua-2)"

echo "== provision-rclone.sh =="
S="$SCRIPTS/provision-rclone.sh"
check "key file: DTK_ name" "/k1" "$(read_site "$S" 'OFFSITE_KEY_FILE="$(captua_env' OFFSITE_KEY_FILE DTK_OFFSITE_KEY_FILE=/k1)"
check "key file: CAPTUA_"   "/k2" "$(read_site "$S" 'OFFSITE_KEY_FILE="$(captua_env' OFFSITE_KEY_FILE CAPTUA_OFFSITE_KEY_FILE=/k2)"
check "bucket: DTK_ name"   "bk"  "$(read_site "$S" 'B2_BUCKET="$(captua_env' B2_BUCKET DTK_OFFSITE_BUCKET=bk)"
check "app key: CAPTUA_"    "ak"  "$(read_site "$S" 'B2_APP_KEY="$(captua_env' B2_APP_KEY CAPTUA_B2_APP_KEY=ak)"
# The warning must not carry a key even when both names differ.
out="$(env -i PATH="$PATH" CAPTUA_B2_APP_KEY=secretnew DTK_B2_APP_KEY=secretold bash -c '. "$1"; captua_env B2_APP_KEY' _ "$SCRIPTS/captua-env.sh" 2>&1 >/dev/null)"
case "$out" in
    *secret*) fail "the warning for an application key carries a value" ;;
    *) ok "a conflicting application key is not printed" ;;
esac

echo "== rollback-update.sh =="
S="$SCRIPTS/rollback-update.sh"
stem() {  # stem <VAR=value>...
    env -i PATH="$PATH" PROJECT_ROOT=/proj STORAGE_OVERRIDE_FILE=/nonexistent "$@" bash -c '
        eval "$(awk "/^captua_env\\(\\) \\{/ {on=1} on {print} on && /^\\}/ {exit}" "$1")"
        eval "$(awk "/^backend_path\\(\\) \\{/ {on=1} on {print} on && /^\\}/ {exit}" "$1")"
        eval "$(awk "/^stem_roots\\(\\) \\{/ {on=1} on {print} on && /^\\}/ {exit}" "$1")"
        stem_roots' _ "$S" 2>/dev/null
}
check "data dir default"     "/var/lib/dtk/projects" "$(stem)"
check "data dir: DTK_ name"  "/d1/projects" "$(stem DTK_DATA_DIR=/d1)"
check "data dir: CAPTUA_"    "/d2/projects" "$(stem CAPTUA_DATA_DIR=/d2 DTK_DATA_DIR=/d1)"

echo "== install-kiosk-service.sh (helpers installed on their own) =="
S="$SCRIPTS/install-kiosk-service.sh"
check "socket default"       "/run/thd.socket" "$(read_site "$S" 'SOCK=' SOCK)"
check "socket: DTK_ name"    "/s1" "$(read_site "$S" 'SOCK=' SOCK DTK_THD_SOCKET=/s1)"
check "socket: CAPTUA_ wins" "/s2" "$(read_site "$S" 'SOCK=' SOCK CAPTUA_THD_SOCKET=/s2 DTK_THD_SOCKET=/s1)"
check "enqueue bound: CAPTUA_" "5" "$(read_site "$S" 'BOUND="${CAPTUA_ENQUEUE' BOUND CAPTUA_ENQUEUE_TIMEOUT=5)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
