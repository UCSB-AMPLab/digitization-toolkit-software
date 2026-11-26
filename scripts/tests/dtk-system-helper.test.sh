#!/bin/bash
# Tests for scripts/dtk-system-helper: argument handling for the verbs that
# take no arguments (poweroff, reboot, restart-backend), the update-page verbs
# (update-page-start, update-page-stop) and the usage text.
#
#   bash scripts/tests/dtk-system-helper.test.sh
#
# The helper sets its own PATH (/usr/sbin:/usr/bin:/sbin:/bin) so that a
# caller cannot redirect the tools it runs. A stub on the caller's PATH would
# therefore never be reached, so each case runs a COPY of the helper whose
# PATH line puts a directory of stubs first. Everything else in the copy is
# the helper as shipped. The stub systemctl records its arguments and runs
# nothing. The mount verbs are not covered here.
#
# For the update-page verbs the copy's fixed paths (the marker update.sh and
# rollback-update.sh write, the uid it must belong to, the unresolved-deployment
# flag, the installed page, its runtime copy, python3) point into the test's
# temporary directory too. The marker's owner is the uid running the test, as
# root is on a unit; a second copy expects another uid, for a marker that
# belongs to someone else. Further stubs: systemd-run records its arguments;
# ss reports port 80 bound when asked to, and can hold the helper where it
# calls it (after the early checks) until the test releases it; flock is a
# small Python stand-in for util-linux flock(1) over the real flock(2), so
# two helper processes exclude each other as they do on a unit. The lock
# wait is shortened to 1 s in the copies.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$(dirname "$HERE")/dtk-system-helper"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dtk-system-helper-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL [$CASE] $1"; }

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/systemctl" <<'STUB'
#!/bin/sh
# Records its arguments; FAKE_SYSTEMCTL_STATUS=<n> makes it exit with n.
# `is-active [--quiet] <unit>` answers 0 for a unit named in FAKE_ACTIVE
# (space-separated) and 3 for any other.
# A unit's state is the content of $FAKE_STATE_DIR/<unit> when that file
# exists ("error" makes the call fail with no output), else "active" for a
# unit named in FAKE_ACTIVE, else "inactive".
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
if [ "$1" = is-active ]; then
    shift
    quiet=0
    [ "$1" = --quiet ] && { quiet=1; shift; }
    if [ -n "${FAKE_STATE_DIR:-}" ] && [ -f "$FAKE_STATE_DIR/$1" ]; then
        state="$(cat "$FAKE_STATE_DIR/$1")"
    else
        state=inactive
        case " ${FAKE_ACTIVE:-} " in *" $1 "*) state=active ;; esac
    fi
    [ "$state" = error ] && exit 1
    [ "$quiet" = 1 ] || echo "$state"
    [ "$state" = active ] || [ "$state" = reloading ]
    exit $?
fi
exit "${FAKE_SYSTEMCTL_STATUS:-0}"
STUB
cat > "$STUBS/systemd-run" <<'STUB'
#!/bin/sh
# Records its arguments; FAKE_SYSTEMD_RUN_STATUS=<n> makes it exit with n.
printf '%s\n' "$*" >> "$SYSTEMD_RUN_LOG"
exit "${FAKE_SYSTEMD_RUN_STATUS:-0}"
STUB
cat > "$STUBS/ss" <<'STUB'
#!/bin/sh
# Lists a listener on port 80 when FAKE_PORT80_BOUND=1, none otherwise.
# With FAKE_SS_HOLD=<dir>, it first creates <dir>/reached and waits (10 s at
# most) for <dir>/release.
if [ -n "${FAKE_SS_HOLD:-}" ]; then
    : > "$FAKE_SS_HOLD/reached"
    i=0
    while [ ! -e "$FAKE_SS_HOLD/release" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
fi
[ "${FAKE_PORT80_BOUND:-0}" = 1 ] && echo "LISTEN 0 511 0.0.0.0:80 0.0.0.0:*"
exit 0
STUB
cat > "$STUBS/flock" <<'STUB'
#!/usr/bin/python3 -I
# flock(1) over flock(2): `flock [-n] [-w SECONDS] FD` and
# `flock [-n] [-w SECONDS] FILE CMD...`. Exit 1 when the lock is not had.
import fcntl, os, subprocess, sys, time
args = sys.argv[1:]
wait = None
while args and args[0].startswith("-"):
    a = args.pop(0)
    if a in ("-n", "--nonblock"):
        wait = 0.0
    elif a in ("-w", "--timeout"):
        wait = float(args.pop(0))
    else:
        sys.exit(64)
target = args.pop(0)
fd = int(target) if (target.isdigit() and not args) else os.open(target, os.O_RDONLY | os.O_CREAT, 0o644)
deadline = None if wait is None else time.monotonic() + wait
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if deadline is not None and time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.02)
sys.exit(subprocess.call(args) if args else 0)
STUB
chmod +x "$STUBS"/*

# The update page's fixed paths, inside the work directory.
T_MARKER="$WORK/run/dtk-update-page.wanted"
T_FLAG="$WORK/etc/dtk/unresolved-deployment"
T_SRC="$WORK/share/dtk-update-page"
T_RUN="$WORK/run/dtk-update-page"
T_LOCK="$WORK/run/dtk-update-page.lock"
mkdir -p "$WORK/run" "$WORK/etc/dtk" "$T_SRC"
cp "$(dirname "$HERE")/update-page/index.html" "$(dirname "$HERE")/update-page/serve.py" "$T_SRC/"

make_copy() {   # make_copy <dest> <python3 path> <marker owner uid>
    sed -e "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$STUBS:/usr/sbin:/usr/bin:/sbin:/bin#" \
        -e "s#^readonly UPDATE_PAGE_MARKER=.*#readonly UPDATE_PAGE_MARKER=\"$T_MARKER\"#" \
        -e "s#^readonly UPDATE_PAGE_MARKER_UID=.*#readonly UPDATE_PAGE_MARKER_UID=\"$3\"#" \
        -e "s#^readonly UNRESOLVED_FLAG=.*#readonly UNRESOLVED_FLAG=\"$T_FLAG\"#" \
        -e "s#^readonly UPDATE_PAGE_SRC=.*#readonly UPDATE_PAGE_SRC=\"$T_SRC\"#" \
        -e "s#^readonly UPDATE_PAGE_RUN=.*#readonly UPDATE_PAGE_RUN=\"$T_RUN\"#" \
        -e "s#^readonly UPDATE_PAGE_PYTHON=.*#readonly UPDATE_PAGE_PYTHON=\"$2\"#" \
        -e "s#^readonly UPDATE_PAGE_LOCK=.*#readonly UPDATE_PAGE_LOCK=\"$T_LOCK\"#" \
        -e "s#^readonly UPDATE_PAGE_LOCK_WAIT=.*#readonly UPDATE_PAGE_LOCK_WAIT=1#" \
        "$HELPER" > "$1"
    chmod +x "$1"
}
ME="$(id -u)"
COPY="$WORK/dtk-system-helper"
make_copy "$COPY" /usr/bin/python3 "$ME"
NOPY_COPY="$WORK/dtk-system-helper-nopython"
make_copy "$NOPY_COPY" "$WORK/no-such-python3" "$ME"
OTHER_COPY="$WORK/dtk-system-helper-otheruid"
make_copy "$OTHER_COPY" /usr/bin/python3 "$((ME + 1))"
if grep -q "^PATH=$STUBS:" "$COPY"; then ok; else
    echo "FAIL [setup] the helper's PATH line was not found; the cases below would call the real systemctl"
    exit 1
fi
# Every fixed path of the update page must have been redirected. A helper
# that has the verbs but kept a real path would touch /run or /etc, so the
# update-page cases are then not run at all.
PAGE_CASES=1
setup_bad() {
    FAIL=$((FAIL + 1)); echo "FAIL [setup] $1"
    if grep -q 'update-page-start)' "$HELPER"; then PAGE_CASES=0; fi
}
for name in UPDATE_PAGE_MARKER UNRESOLVED_FLAG UPDATE_PAGE_SRC UPDATE_PAGE_RUN UPDATE_PAGE_PYTHON UPDATE_PAGE_LOCK; do
    # python3 stays the real one in COPY; NOPY_COPY shows the line was found.
    if grep -q "^readonly $name=\"$WORK" "$NOPY_COPY"; then ok; else
        setup_bad "the helper has no line 'readonly $name=...' to redirect"
    fi
done
if grep -q "^readonly UPDATE_PAGE_MARKER_UID=\"$ME\"\$" "$COPY"; then ok; else
    setup_bad "the helper has no line 'readonly UPDATE_PAGE_MARKER_UID=...' to redirect"
fi
if grep -q "^readonly UPDATE_PAGE_LOCK_WAIT=1\$" "$COPY"; then ok; else
    setup_bad "the helper has no line 'readonly UPDATE_PAGE_LOCK_WAIT=...' to shorten"
fi

SYSTEMCTL_LOG="$WORK/systemctl.log"
SYSTEMD_RUN_LOG="$WORK/systemd-run.log"
FAKE_STATE_DIR="$WORK/states"
mkdir -p "$FAKE_STATE_DIR"
OUT=""
STATUS=0
RUN_COPY="$COPY"
run() {   # run [VAR=value ...] -- [helper args...]
    local -a envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    rm -f "$SYSTEMCTL_LOG" "$SYSTEMD_RUN_LOG"
    OUT="$(env -i SYSTEMCTL_LOG="$SYSTEMCTL_LOG" SYSTEMD_RUN_LOG="$SYSTEMD_RUN_LOG" FAKE_STATE_DIR="$FAKE_STATE_DIR" \
        ${envs[@]+"${envs[@]}"} /bin/bash "$RUN_COPY" "$@" 2>&1)"
    STATUS=$?
}
expect_status() { if [ "$STATUS" -eq "$1" ]; then ok; else bad "exit status $STATUS, wanted $1 (output: $OUT)"; fi; }
expect_out()    { case "$OUT" in *"$1"*) ok ;; *) bad "output lacks: $1 (output: $OUT)" ;; esac; }
expect_calls()  {   # expect_calls <exact systemctl argument line, or empty for none>
    local got=""
    [ -f "$SYSTEMCTL_LOG" ] && got="$(cat "$SYSTEMCTL_LOG")"
    if [ "$got" = "$1" ]; then ok; else bad "systemctl called with '$got', wanted '$1'"; fi
}

# ── restart-backend ─────────────────────────────────────────────────────────
case_() { CASE="$1"; }

case_ "restart-backend restarts dtk without blocking, and nothing else"
run -- restart-backend
expect_status 0
expect_calls "--no-block restart dtk"

case_ "restart-backend refuses an argument"
run -- restart-backend now
expect_status 1
expect_out "usage: restart-backend"
expect_calls ""

case_ "restart-backend refuses a unit name"
run -- restart-backend nginx
expect_status 1
expect_calls ""

case_ "restart-backend passes on systemctl's failure"
run FAKE_SYSTEMCTL_STATUS=5 -- restart-backend
expect_status 5
expect_calls "--no-block restart dtk"

# ── The existing argument-less verbs keep their contract ────────────────────
case_ "reboot"
run -- reboot
expect_status 0
expect_calls "reboot"

case_ "reboot refuses an argument"
run -- reboot now
expect_status 1
expect_out "usage: reboot"
expect_calls ""

case_ "poweroff refuses an argument"
run -- poweroff now
expect_status 1
expect_calls ""

# ── Usage ───────────────────────────────────────────────────────────────────
case_ "--help lists restart-backend and exits 0"
run -- --help
expect_status 0
expect_out "restart-backend"
expect_out "usage: dtk-system-helper <verb> [args...]"
expect_calls ""

case_ "no verb is a usage error"
run --
expect_status 1
expect_out "usage: dtk-system-helper <verb> [args...]"

case_ "an unknown verb is refused"
run -- restart
expect_status 1
expect_out "unknown verb: restart"
expect_calls ""

# ── update-page-start / update-page-stop ───────────────────────────────────
expect_no_run()  { if [ ! -s "$SYSTEMD_RUN_LOG" ]; then ok; else bad "systemd-run was called: $(cat "$SYSTEMD_RUN_LOG")"; fi; }
expect_run_has() {   # expect_run_has <word> ...: each word is one argument of the systemd-run call
    local w got
    got=" $(cat "$SYSTEMD_RUN_LOG" 2>/dev/null) "
    [ -s "$SYSTEMD_RUN_LOG" ] || { bad "systemd-run was not called"; return; }
    for w in "$@"; do
        case "$got" in *" $w "*) ok ;; *) bad "systemd-run lacks '$w' (got:$got)" ;; esac
    done
}
expect_state()   {   # expect_state <updating|failed|none>
    local got="none"
    [ -f "$T_RUN/state.json" ] && got="$(cat "$T_RUN/state.json")"
    case "$1" in
        none) if [ "$got" = none ]; then ok; else bad "state.json exists: $got"; fi ;;
        *)    if [ "$got" = "{\"state\":\"$1\"}" ]; then ok; else bad "state.json is '$got', wanted state $1"; fi ;;
    esac
}
expect_page_copied() {
    if cmp -s "$T_SRC/index.html" "$T_RUN/index.html"; then ok; else bad "index.html was not copied into $T_RUN"; fi
}
reset_page() { rm -rf "$T_RUN" "$T_MARKER" "$WORK/elsewhere" "$FAKE_STATE_DIR"/*; rm -f "$T_FLAG"; }
wait_for() {   # wait_for <file> <tenths of a second>: true once it exists
    local i=0
    while [ ! -e "$1" ] && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done
    [ -e "$1" ]
}

if [ "$PAGE_CASES" -eq 1 ]; then

case_ "update-page-start with neither the marker nor the flag does nothing"
reset_page
run -- update-page-start
expect_status 0
expect_no_run
expect_state none
expect_calls ""
if [ "$OUT" = "" ]; then ok; else bad "printed '$OUT'; it must stay silent"; fi

case_ "update-page-start with the marker, owned as required, serves the page, state updating"
reset_page
: > "$T_MARKER"
run -- update-page-start
expect_status 0
expect_state updating
expect_page_copied
expect_run_has --unit=dtk-update-page --collect --quiet \
    --property=DynamicUser=yes \
    --property=AmbientCapabilities=CAP_NET_BIND_SERVICE \
    --property=CapabilityBoundingSet=CAP_NET_BIND_SERVICE \
    --property=NoNewPrivileges=yes --property=ProtectSystem=strict \
    --property=ProtectHome=yes --property=PrivateDevices=yes \
    --property=MemoryMax=64M --property=TasksMax=48 \
    /usr/bin/python3 -I -B "$T_SRC/serve.py" --root "$T_RUN" --port 80

case_ "the page's unit has no tie to dtk.service, no restart, and is not detached"
for w in Conflicts Before After BindsTo PartOf Requires Wants Restart --no-block; do
    case "$(cat "$SYSTEMD_RUN_LOG" 2>/dev/null)" in
        *"$w"*) bad "systemd-run has '$w'" ;;
        *) ok ;;
    esac
done

case_ "a marker owned by another user does nothing"
reset_page
: > "$T_MARKER"
RUN_COPY="$OTHER_COPY"
run -- update-page-start
RUN_COPY="$COPY"
expect_status 0
expect_no_run
expect_state none

case_ "a marker that is a symlink does nothing"
reset_page
mkdir -p "$WORK/elsewhere"; : > "$WORK/elsewhere/target"
ln -s "$WORK/elsewhere/target" "$T_MARKER"
run -- update-page-start
expect_status 0
expect_no_run
expect_state none

case_ "a marker that is a directory does nothing"
reset_page
mkdir -p "$T_MARKER"
run -- update-page-start
expect_status 0
expect_no_run
expect_state none

case_ "update-page-start with the unresolved flag serves the page, state failed"
reset_page
: > "$T_FLAG"
run -- update-page-start
expect_status 0
expect_state failed
expect_run_has --unit=dtk-update-page

case_ "the unresolved flag wins over the marker: state failed"
reset_page
: > "$T_FLAG"
: > "$T_MARKER"
run -- update-page-start
expect_state failed

case_ "update-page-start starts the page only while dtk is inactive or failed"
for st in inactive failed; do
    reset_page; : > "$T_MARKER"; echo "$st" > "$FAKE_STATE_DIR/dtk.service"
    run -- update-page-start
    if [ -s "$SYSTEMD_RUN_LOG" ]; then ok; else bad "dtk $st: the page was not started"; fi
done
for st in activating active deactivating reloading error; do
    reset_page; : > "$T_MARKER"; echo "$st" > "$FAKE_STATE_DIR/dtk.service"
    run -- update-page-start
    expect_status 0
    if [ ! -s "$SYSTEMD_RUN_LOG" ]; then ok; else bad "dtk $st: the page was started"; fi
done

case_ "update-page-start that cannot have the lock does nothing; update-page-stop stops the page anyway"
reset_page
: > "$T_MARKER"
HOLD="$WORK/holder"; rm -rf "$HOLD"; mkdir -p "$HOLD"
PATH="$STUBS:$PATH" /bin/bash -c 'exec 8>"$1"; flock 8 || exit 1; : > "$2/locked"
    i=0; while [ ! -e "$2/release" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done' \
    _ "$T_LOCK" "$HOLD" &
HOLDER=$!
if wait_for "$HOLD/locked" 50; then ok; else bad "the holder did not take the lock"; fi
run -- update-page-start
expect_status 0
expect_no_run
expect_state none
run -- update-page-stop
expect_status 0
expect_calls "stop dtk-update-page.service"
: > "$HOLD/release"; wait "$HOLDER" 2>/dev/null

case_ "a start held after its checks, a stop and a start of dtk meanwhile: the page is not started"
reset_page
: > "$T_MARKER"
HOLD="$WORK/hold"; rm -rf "$HOLD"; mkdir -p "$HOLD"
rm -f "$SYSTEMCTL_LOG" "$SYSTEMD_RUN_LOG"
env -i SYSTEMCTL_LOG="$SYSTEMCTL_LOG" SYSTEMD_RUN_LOG="$SYSTEMD_RUN_LOG" FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_SS_HOLD="$HOLD" /bin/bash "$COPY" update-page-start > "$WORK/start.out" 2>&1 &
START_PID=$!
if wait_for "$HOLD/reached" 50; then ok; else bad "the start never reached its port check"; fi
# The updater's stop, then systemd's start of dtk: activating while its
# ExecStartPre's stop waits for the lock the held start has.
env -i SYSTEMCTL_LOG="$SYSTEMCTL_LOG" SYSTEMD_RUN_LOG="$SYSTEMD_RUN_LOG" FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    /bin/bash "$COPY" update-page-stop > "$WORK/stop.out" 2>&1 &
STOP_PID=$!
echo activating > "$FAKE_STATE_DIR/dtk.service"
sleep 0.3
if grep -qx 'stop dtk-update-page.service' "$SYSTEMCTL_LOG" 2>/dev/null; then
    bad "the stop ran while the start held the lock"
else ok; fi
: > "$HOLD/release"
wait "$START_PID"; START_RC=$?
wait "$STOP_PID"; STOP_RC=$?
if [ "$START_RC" -eq 0 ] && [ "$STOP_RC" -eq 0 ]; then ok; else bad "start $START_RC, stop $STOP_RC"; fi
expect_no_run
if grep -qx 'stop dtk-update-page.service' "$SYSTEMCTL_LOG"; then ok; else bad "the stop never ran: $(cat "$SYSTEMCTL_LOG")"; fi
if [ ! -e "$T_RUN" ]; then ok; else bad "the runtime copy remains"; fi

case_ "update-page-start when the page is already up rewrites the state and starts nothing"
reset_page
: > "$T_MARKER"
run -- update-page-start
expect_state updating
: > "$T_FLAG"
run FAKE_ACTIVE=dtk-update-page.service -- update-page-start
expect_status 0
expect_no_run
expect_state failed

case_ "update-page-start while dtk is running starts nothing"
reset_page
: > "$T_FLAG"
run FAKE_ACTIVE=dtk.service -- update-page-start
expect_status 0
expect_no_run
expect_state none

case_ "update-page-start without python3 exits 0 with a log line"
reset_page
: > "$T_FLAG"
RUN_COPY="$NOPY_COPY"
run -- update-page-start
RUN_COPY="$COPY"
expect_status 0
expect_no_run
expect_out "python3"

case_ "update-page-start with port 80 already bound exits 0 with a log line"
reset_page
: > "$T_FLAG"
run FAKE_PORT80_BOUND=1 -- update-page-start
expect_status 0
expect_no_run
expect_out "port 80"

case_ "update-page-start without the installed page exits 0 with a log line"
reset_page
: > "$T_FLAG"
mv "$T_SRC" "$T_SRC.away"
run -- update-page-start
mv "$T_SRC.away" "$T_SRC"
expect_status 0
expect_no_run
expect_out "$T_SRC"

case_ "update-page-start refuses a symlinked page"
reset_page
: > "$T_FLAG"
mv "$T_SRC/index.html" "$WORK/index.real"
ln -s "$WORK/index.real" "$T_SRC/index.html"
run -- update-page-start
rm -f "$T_SRC/index.html"; mv "$WORK/index.real" "$T_SRC/index.html"
expect_status 0
expect_no_run

case_ "update-page-start exits 0 when systemd-run fails"
reset_page
: > "$T_FLAG"
run FAKE_SYSTEMD_RUN_STATUS=1 -- update-page-start
expect_status 0
expect_out "systemd-run"

case_ "update-page-stop when nothing runs exits 0"
reset_page
run FAKE_SYSTEMCTL_STATUS=5 -- update-page-stop
expect_status 0
expect_calls "stop dtk-update-page.service"

case_ "update-page-stop stops the unit and removes the runtime copy"
reset_page
mkdir -p "$T_RUN"; : > "$T_RUN/index.html"
run -- update-page-stop
expect_status 0
expect_calls "stop dtk-update-page.service"
if [ ! -e "$T_RUN" ]; then ok; else bad "$T_RUN was not removed"; fi

fi   # PAGE_CASES

case_ "update-page-start refuses an argument"
run -- update-page-start now
expect_status 1
expect_out "usage: update-page-start"
expect_no_run

case_ "update-page-stop refuses an argument"
run -- update-page-stop dtk
expect_status 1
expect_out "usage: update-page-stop"
expect_calls ""

case_ "--help lists the update-page verbs"
run -- --help
expect_out "update-page-start"
expect_out "update-page-stop"

# ── Who installs the helper ────────────────────────────────────────────────
# setup.sh and install-service.sh install it on a new unit. update.sh
# reinstalls it, so a unit already in the field receives new verbs.
SCRIPTS="$(dirname "$HERE")"
CALL_RE='^[[:space:]]*"\$SCRIPT_DIR/install-system-helper\.sh"$'
for f in setup.sh install-service.sh update.sh; do
  case_ "$f calls install-system-helper.sh, bare"
  if grep -E "$CALL_RE" "$SCRIPTS/$f" >/dev/null 2>&1; then
    ok
  else
    bad "$f has no bare, uncommented call to install-system-helper.sh"
  fi
done

case_ "update.sh reinstalls the helper before it stops the service"
CALL_LINE="$(grep -nE "$CALL_RE" "$SCRIPTS/update.sh" | head -n 1 | cut -d: -f1)"
STOP_LINE="$(grep -nE '^[[:space:]]*SERVICE_STOPPED=1' "$SCRIPTS/update.sh" | head -n 1 | cut -d: -f1)"
if [ -n "$CALL_LINE" ] && [ -n "$STOP_LINE" ] && [ "$CALL_LINE" -lt "$STOP_LINE" ]; then
  ok
else
  bad "update.sh call line '$CALL_LINE' is not before the first SERVICE_STOPPED=1 '$STOP_LINE'"
fi

echo ""
echo "dtk-system-helper tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
