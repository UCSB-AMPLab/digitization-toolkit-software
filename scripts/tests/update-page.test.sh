#!/bin/bash
# Tests for the callers of the update page (dtk-system-helper's
# update-page-start and update-page-stop):
#   - stop.sh never asks for the page: a stop, a crash and systemd's restart
#     of dtk show nothing; start.sh asks for it to go before its compose up,
#     and does not fail when the helper refuses the verb;
#   - install-system-helper.sh installs the page beside the helper, and the
#     dtk.service drop-in that stops the page before every start of dtk;
#   - update.sh and rollback-update.sh own the page: each writes its marker
#     once, immediately before its stop of dtk, asks for the page after the
#     stack is down, asks for it to go immediately before every start of dtk,
#     and on exit leaves it up in its failed state when the unresolved flag
#     remains, or stops it. Their page functions are lifted out by name and
#     run with their paths pointed into the work directory; where they are
#     called from is checked against the scripts' text. update-restore.test.sh
#     checks the same order in whole runs.
#
#   bash scripts/tests/update-page.test.sh
#
# stop.sh and start.sh run as shipped, from the checkout, with fakes first on
# PATH: docker, sudo and pixi record their arguments in one log, in order; ps
# lists no backend. A case can make the fake sudo fail. install-system-helper.sh
# runs as shipped with fakes for install (records), visudo and mktemp. The two
# hook functions are lifted out of update.sh and rollback-update.sh by name and
# run with their paths pointed into the work directory; where they are called
# from is checked against the scripts' text.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/update-page-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""
ok()    { PASS=$((PASS + 1)); }
bad()   { FAIL=$((FAIL + 1)); echo "FAIL [$CASE] $1"; }
case_() { CASE="$1"; }

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
LOG="$WORK/log"
for cmd in docker pixi; do
    cat > "$FAKEBIN/$cmd" <<EOF
#!/bin/sh
printf '%s\n' "$cmd \$*" >> "\$CALL_LOG"
exit 0
EOF
    chmod +x "$FAKEBIN/$cmd"
done
cat > "$FAKEBIN/sudo" <<'EOF'
#!/bin/sh
# Records the call; FAKE_SUDO_STATUS=<n> makes it fail as a helper without
# the verb would (unknown verb, status 1).
printf '%s\n' "sudo $*" >> "$CALL_LOG"
if [ "${FAKE_SUDO_STATUS:-0}" -ne 0 ]; then
    echo "dtk-system-helper: unknown verb: $3" >&2
    exit "$FAKE_SUDO_STATUS"
fi
exit 0
EOF
chmod +x "$FAKEBIN/sudo"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/ps"; chmod +x "$FAKEBIN/ps"

OUT=""
STATUS=0
run_script() {   # run_script [VAR=value ...] -- <script>
    local -a envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    rm -f "$LOG"
    OUT="$(env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$WORK/home" CALL_LOG="$LOG" \
        ${envs[@]+"${envs[@]}"} /bin/bash "$1" 2>&1)"
    STATUS=$?
}
line_of() { grep -nF -- "$1" "$LOG" 2>/dev/null | head -n 1 | cut -d: -f1; }
expect_status() { if [ "$STATUS" -eq "$1" ]; then ok; else bad "exit status $STATUS, wanted $1 (output: $OUT)"; fi; }
expect_before() {   # expect_before <first> <second>: both logged, first earlier
    local a b
    a="$(line_of "$1")"; b="$(line_of "$2")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else
        bad "'$1' (line ${a:-none}) is not logged before '$2' (line ${b:-none}); log: $(cat "$LOG" 2>/dev/null)"
    fi
}

HELPER_START="sudo -n /usr/local/bin/dtk-system-helper update-page-start"
HELPER_STOP="sudo -n /usr/local/bin/dtk-system-helper update-page-stop"

# ── stop.sh ─────────────────────────────────────────────────────────────────
case_ "stop.sh does not ask for the update page"
run_script -- "$SCRIPTS/stop.sh"
expect_status 0
if grep -q "dtk-system-helper" "$LOG"; then bad "stop.sh called the helper: $(cat "$LOG")"; else ok; fi
if grep -q "update-page" "$SCRIPTS/stop.sh"; then bad "stop.sh mentions update-page"; else ok; fi

# ── start.sh ────────────────────────────────────────────────────────────────
case_ "start.sh stops the update page before compose up"
run_script -- "$SCRIPTS/start.sh"
expect_status 0
expect_before "$HELPER_STOP" "docker compose -f docker-compose.yml -f docker-compose.pi.yml up"
expect_before "docker compose" "pixi run start"

case_ "start.sh carries on when the helper refuses the verb"
run_script FAKE_SUDO_STATUS=1 -- "$SCRIPTS/start.sh"
expect_status 0
expect_before "$HELPER_STOP" "docker compose"
expect_before "docker compose" "pixi run start"

# ── install-system-helper.sh ────────────────────────────────────────────────
INSTALL_FAKES="$WORK/install-fakes"
mkdir -p "$INSTALL_FAKES"
cat > "$INSTALL_FAKES/install" <<'EOF'
#!/bin/sh
printf '%s\n' "install $*" >> "$CALL_LOG"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$INSTALL_FAKES/visudo"
printf '#!/bin/sh\nprintf "%%s\\n" "systemctl $*" >> "$CALL_LOG"\nexit 0\n' > "$INSTALL_FAKES/systemctl"
printf '#!/bin/sh\n: > "$CALL_LOG.tmpfile"; echo "$CALL_LOG.tmpfile"\n' > "$INSTALL_FAKES/mktemp"
chmod +x "$INSTALL_FAKES"/*

case_ "install-system-helper.sh installs the page and its server, root's, read-only"
rm -f "$LOG"
OUT="$(env -i PATH="$INSTALL_FAKES:/usr/bin:/bin" CALL_LOG="$LOG" /bin/bash "$SCRIPTS/install-system-helper.sh" 2>&1)"
STATUS=$?
expect_status 0
expect_before "install -o root -g root -m 0755 $SCRIPTS/dtk-system-helper /usr/local/bin/dtk-system-helper" \
    "install -o root -g root -m 0755 -d /usr/local/share/dtk-update-page"
for f in index.html serve.py; do
    if grep -qxF "install -o root -g root -m 0644 $SCRIPTS/update-page/$f /usr/local/share/dtk-update-page/$f" "$LOG"; then ok; else
        bad "$f is not installed into /usr/local/share/dtk-update-page; log: $(cat "$LOG")"
    fi
done

case_ "install-system-helper.sh installs the update-page drop-in for dtk.service, then reloads systemd"
expect_before "install -o root -g root -m 0755 -d /etc/systemd/system/dtk.service.d" \
    "install -o root -g root -m 0644 $SCRIPTS/dtk-update-page.conf /etc/systemd/system/dtk.service.d/update-page.conf"
expect_before "install -o root -g root -m 0644 $SCRIPTS/dtk-update-page.conf /etc/systemd/system/dtk.service.d/update-page.conf" \
    "systemctl daemon-reload"

case_ "the drop-in stops the page before every start, as root, never failing the start"
if [ "$(grep -v '^#' "$SCRIPTS/dtk-update-page.conf" 2>/dev/null | grep -v '^$')" = "[Service]
ExecStartPre=+-/usr/local/bin/dtk-system-helper update-page-stop" ]; then ok; else
    bad "dtk-update-page.conf is: $(cat "$SCRIPTS/dtk-update-page.conf" 2>&1)"
fi

case_ "install-system-helper.sh does not fail without systemctl"
NOSYS="$WORK/nosys-fakes"; mkdir -p "$NOSYS"; cp "$INSTALL_FAKES/install" "$INSTALL_FAKES/visudo" "$INSTALL_FAKES/mktemp" "$NOSYS/"
rm -f "$LOG"
OUT="$(env -i PATH="$NOSYS:/usr/bin:/bin" CALL_LOG="$LOG" /bin/bash "$SCRIPTS/install-system-helper.sh" 2>&1)"
STATUS=$?
expect_status 0
if grep -q "update-page.conf" "$LOG"; then ok; else bad "the drop-in was not installed"; fi

# uninstall-service.sh runs as a copy whose fixed paths (/etc/systemd/system,
# /etc/dtk, /run, the helper) point into the work directory and whose root
# check is removed; systemctl and the helper are fakes that record calls.
U="$WORK/uninstall"
rm -rf "$U"; mkdir -p "$U/systemd/dtk.service.d" "$U/etc-dtk" "$U/run/dtk-update-page" "$U/bin" "$U/fakes"
sed -e 's#"\$EUID" -ne 0#0 -ne 0#' \
    -e "s#/etc/systemd/system#$U/systemd#g" -e "s#/etc/dtk#$U/etc-dtk#g" \
    -e "s#/run/dtk-update-page#$U/run/dtk-update-page#g" \
    -e "s#/usr/local/bin/dtk-system-helper#$U/bin/dtk-system-helper#g" \
    "$SCRIPTS/uninstall-service.sh" > "$U/uninstall-service.sh"
cat > "$U/bin/dtk-system-helper" <<EOF
#!/bin/sh
printf '%s\n' "helper \$*" >> "\$CALL_LOG"
[ -e "$U/systemd/dtk.service.d/update-page.conf" ] && echo "drop-in present" >> "\$CALL_LOG"
exit "\${FAKE_HELPER_STATUS:-0}"
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "systemctl $*" >> "$CALL_LOG"\n[ "$1" = is-active ] && exit 3\n[ "$1" = is-enabled ] && exit 1\nexit 0\n' > "$U/fakes/systemctl"
chmod +x "$U/bin/dtk-system-helper" "$U/fakes/systemctl"
uninstall_fixture() {
    : > "$U/systemd/dtk.service.d/update-page.conf"
    : > "$U/systemd/dtk.service.d/unresolved.conf"
    mkdir -p "$U/run/dtk-update-page" "$U/etc-dtk"; : > "$U/run/dtk-update-page/state.json"
    : > "$U/run/dtk-update-page.wanted"; : > "$U/run/dtk-update-page.lock"; : > "$U/etc-dtk/unresolved-deployment"
}

case_ "uninstall-service.sh stops the page first, through the helper and directly, and removes it"
if grep -q "$U/run/dtk-update-page" "$U/uninstall-service.sh"; then ok; else bad "the copy has no page paths to redirect"; fi
uninstall_fixture
rm -f "$LOG"
OUT="$(env -i PATH="$U/fakes:/usr/bin:/bin" CALL_LOG="$LOG" /bin/bash "$U/uninstall-service.sh" 2>&1)"
STATUS=$?
expect_status 0
expect_before "helper update-page-stop" "drop-in present"
expect_before "helper update-page-stop" "systemctl stop dtk-update-page.service"
expect_before "systemctl stop dtk-update-page.service" "systemctl daemon-reload"
for f in "$U/run/dtk-update-page" "$U/run/dtk-update-page.wanted" "$U/run/dtk-update-page.lock" \
         "$U/systemd/dtk.service.d/update-page.conf"; do
    if [ ! -e "$f" ]; then ok; else bad "$f remains"; fi
done

case_ "uninstall-service.sh stops the page even when the helper refuses the verb, or is missing"
uninstall_fixture
rm -f "$LOG"
OUT="$(env -i PATH="$U/fakes:/usr/bin:/bin" CALL_LOG="$LOG" FAKE_HELPER_STATUS=1 /bin/bash "$U/uninstall-service.sh" 2>&1)"
STATUS=$?
expect_status 0
if grep -qx "systemctl stop dtk-update-page.service" "$LOG"; then ok; else bad "no direct stop: $(cat "$LOG")"; fi
uninstall_fixture
mv "$U/bin/dtk-system-helper" "$U/bin/away"
rm -f "$LOG"
OUT="$(env -i PATH="$U/fakes:/usr/bin:/bin" CALL_LOG="$LOG" /bin/bash "$U/uninstall-service.sh" 2>&1)"
STATUS=$?
mv "$U/bin/away" "$U/bin/dtk-system-helper"
expect_status 0
if grep -qx "systemctl stop dtk-update-page.service" "$LOG"; then ok; else bad "no direct stop: $(cat "$LOG")"; fi
if [ ! -e "$U/run/dtk-update-page" ]; then ok; else bad "the runtime copy remains"; fi

case_ "install-system-helper.sh does not fail without the page"
cp "$SCRIPTS/install-system-helper.sh" "$SCRIPTS/dtk-system-helper" "$WORK/"
rm -f "$LOG"
OUT="$(env -i PATH="$INSTALL_FAKES:/usr/bin:/bin" CALL_LOG="$LOG" /bin/bash "$WORK/install-system-helper.sh" 2>&1)"
STATUS=$?
expect_status 0
case "$OUT" in *"update page"*) ok ;; *) bad "no warning about the missing page (output: $OUT)" ;; esac
rm -f "$WORK/install-system-helper.sh" "$WORK/dtk-system-helper"

# ── The page in update.sh and rollback-update.sh ────────────────────────────
FLAG="$WORK/unresolved-deployment"
MARKER="$WORK/dtk-update-page.wanted"
FAKE_HELPER="$WORK/fake-helper"
cat > "$FAKE_HELPER" <<'EOF'
#!/bin/sh
printf '%s\n' "helper $*" >> "$CALL_LOG"
exit "${FAKE_HELPER_STATUS:-0}"
EOF
chmod +x "$FAKE_HELPER"
PAGE_FUNCS="mark_update_page show_update_page end_update_page show_update_page_if_unresolved"

lift() {   # lift <script> <function>: the function's definition, from the script
    sed -n "/^$2() {\$/,/^}\$/p" "$1"
}
run_page_fn() {   # run_page_fn <script> <function> [VAR=value ...]
    local script="$1" fn="$2" def="" f one
    shift 2
    rm -f "$LOG"
    for f in $PAGE_FUNCS; do
        one="$(lift "$script" "$f")"
        if [ -z "$one" ]; then STATUS=127; OUT="no $f() in $script"; return; fi
        def="$def$one
"
    done
    OUT="$(env -i PATH="/usr/bin:/bin" CALL_LOG="$LOG" "$@" /bin/bash -c '
        set -e -o pipefail
        UNRESOLVED_FLAG="$1"; UPDATE_PAGE_MARKER="$2"; SYSTEM_HELPER="$3"
        eval "$4"
        "$5"
        echo "returned $?"' _ "$FLAG" "$MARKER" "$FAKE_HELPER" "$def" "$fn" 2>&1)"
    STATUS=$?
}
expect_calls() {   # expect_calls <exact helper call lines, newline-separated, or empty>
    local got=""
    [ -f "$LOG" ] && got="$(cat "$LOG")"
    if [ "$got" = "$1" ]; then ok; else bad "helper calls '$got', wanted '$1' (output: $OUT)"; fi
}
expect_returned() { case "$OUT" in *"returned 0"*) ok ;; *) bad "did not return 0: $OUT (status $STATUS)" ;; esac; }
expect_marker()   {   # expect_marker <present|absent>
    if [ -e "$MARKER" ]; then got=present; else got=absent; fi
    if [ "$got" = "$1" ]; then ok; else bad "marker is $got, wanted $1"; fi
}

for script in update.sh rollback-update.sh; do
    S="$SCRIPTS/$script"

    case_ "$script: mark_update_page writes the marker and calls nothing"
    rm -f "$MARKER" "$FLAG"
    run_page_fn "$S" mark_update_page
    expect_returned
    expect_marker present
    expect_calls ""

    case_ "$script: show_update_page asks the helper for the page"
    run_page_fn "$S" show_update_page
    expect_returned
    expect_calls "helper update-page-start"

    case_ "$script: end_update_page stops the page and removes the marker"
    : > "$MARKER"
    run_page_fn "$S" end_update_page
    expect_returned
    expect_calls "helper update-page-stop"
    expect_marker absent

    case_ "$script: on exit with the unresolved flag, the page is left up as failed"
    : > "$FLAG"; : > "$MARKER"
    run_page_fn "$S" show_update_page_if_unresolved
    expect_returned
    expect_calls "helper update-page-start"
    expect_marker absent

    case_ "$script: on exit without the flag, a page that was wanted is stopped"
    rm -f "$FLAG"; : > "$MARKER"
    run_page_fn "$S" show_update_page_if_unresolved
    expect_returned
    expect_calls "helper update-page-stop"
    expect_marker absent

    case_ "$script: on exit with neither, nothing is called"
    rm -f "$FLAG" "$MARKER"
    run_page_fn "$S" show_update_page_if_unresolved
    expect_returned
    expect_calls ""

    for fn in show_update_page end_update_page show_update_page_if_unresolved; do
        case_ "$script: $fn survives a helper that refuses the verb, under set -e and pipefail"
        : > "$FLAG"; : > "$MARKER"
        run_page_fn "$S" "$fn" FAKE_HELPER_STATUS=1
        expect_returned
    done

    case_ "$script: the exit hook survives a missing helper"
    FAKE_HELPER_SAVED="$FAKE_HELPER"; FAKE_HELPER="$WORK/no-such-helper"
    run_page_fn "$S" show_update_page_if_unresolved
    FAKE_HELPER="$FAKE_HELPER_SAVED"
    expect_returned
    rm -f "$FLAG" "$MARKER"

    case_ "$script: the helper and the marker are the installed ones"
    if grep -qx 'SYSTEM_HELPER="/usr/local/bin/dtk-system-helper"' "$S"; then ok; else
        bad "no SYSTEM_HELPER=\"/usr/local/bin/dtk-system-helper\" line"
    fi
    if grep -qx 'UPDATE_PAGE_MARKER="/run/dtk-update-page.wanted"' "$S"; then ok; else
        bad "no UPDATE_PAGE_MARKER=\"/run/dtk-update-page.wanted\" line"
    fi

    # The calls, in the script's text (outside the function definitions).
    case_ "$script: the marker is written once, on the line before the stop of dtk"
    N="$(grep -c '^[[:space:]]*mark_update_page$' "$S")"
    M="$(grep -n '^[[:space:]]*mark_update_page$' "$S" | head -n 1 | cut -d: -f1)"
    STOP="$(grep -n '^systemctl stop dtk' "$S" | head -n 1 | cut -d: -f1)"
    if [ "$N" = 1 ] && [ -n "$M" ] && [ -n "$STOP" ] && [ "$((M + 1))" -eq "$STOP" ]; then ok; else
        bad "mark_update_page calls: $N, at ${M:-none}; deliberate stop at ${STOP:-none}"
    fi

    case_ "$script: the page is asked for once, after the stop, the teardown and the check that the backend stopped"
    N="$(grep -c '^show_update_page$' "$S")"
    P="$(grep -n '^show_update_page$' "$S" | head -n 1 | cut -d: -f1)"
    DOWN="$(awk -v s="${STOP:-0}" 'NR > s && /^\$COMPOSE down --remove-orphans/ { print NR; exit }' "$S")"
    WAIT="$(awk -v s="${STOP:-0}" 'NR > s && /^if ! wait_backend_stopped; then$/ { print NR; exit }' "$S")"
    FI="$(awk -v s="${WAIT:-0}" 'NR > s && /^fi$/ { print NR; exit }' "$S")"
    if [ "$N" = 1 ] && [ -n "$P" ] && [ -n "$DOWN" ] && [ -n "$FI" ] && [ "$P" -gt "$DOWN" ] && [ "$P" -gt "$FI" ]; then ok; else
        bad "show_update_page calls: $N, at ${P:-none}; teardown at ${DOWN:-none}; backend check ends at ${FI:-none}"
    fi

    case_ "$script: every start of dtk follows end_update_page on the line before"
    STARTS="$(grep -n 'systemctl start dtk' "$S" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'echo ' | cut -d: -f1)"
    if [ -z "$STARTS" ]; then bad "no start of dtk found"; fi
    for l in $STARTS; do
        prev="$(sed -n "$((l - 1))p" "$S" | sed 's/^[[:space:]]*//')"
        if [ "$prev" = "end_update_page" ]; then ok; else bad "line $l: '$(sed -n "${l}p" "$S" | sed 's/^[[:space:]]*//')' follows '$prev'"; fi
    done
done

case_ "update.sh: on_exit calls the exit hook after restore_after_stop, before end_trap"
BODY="$(lift "$SCRIPTS/update.sh" on_exit)"
R="$(printf '%s\n' "$BODY" | grep -n '^        restore_after_stop$' | head -n 1 | cut -d: -f1)"
H="$(printf '%s\n' "$BODY" | grep -n '^        show_update_page_if_unresolved$' | head -n 1 | cut -d: -f1)"
E="$(printf '%s\n' "$BODY" | grep -n '^        end_trap "\$rc"$' | head -n 1 | cut -d: -f1)"
if [ -n "$R" ] && [ -n "$H" ] && [ -n "$E" ] && [ "$R" -lt "$H" ] && [ "$H" -lt "$E" ]; then ok; else
    bad "restore_after_stop at ${R:-none}, hook at ${H:-none}, end_trap at ${E:-none}"
fi

case_ "update.sh: --resolve-forward --no-start, which leaves dtk stopped with the flag cleared, stops the page"
BODY="$(lift "$SCRIPTS/update.sh" resolve_forward)"
NS="$(printf '%s\n' "$BODY" | grep -n 'RESOLVE_NO_START" -eq 1' | head -n 1 | cut -d: -f1)"
EP="$(printf '%s\n' "$BODY" | awk -v s="${NS:-0}" 'NR > s && /^        end_update_page$/ { print NR; exit }')"
RT="$(printf '%s\n' "$BODY" | awk -v s="${NS:-0}" 'NR > s && /^        return 0$/ { print NR; exit }')"
if [ -n "$NS" ] && [ -n "$EP" ] && [ -n "$RT" ] && [ "$EP" -lt "$RT" ]; then ok; else
    bad "--no-start branch at ${NS:-none}, end_update_page at ${EP:-none}, return at ${RT:-none}"
fi

case_ "rollback-update.sh: the exit hook is its EXIT trap, set before the marker"
CLEAR="$(grep -n '^trap - EXIT$' "$SCRIPTS/rollback-update.sh" | tail -n 1 | cut -d: -f1)"
SET="$(grep -n "^trap 'show_update_page_if_unresolved' EXIT\$" "$SCRIPTS/rollback-update.sh" | head -n 1 | cut -d: -f1)"
MK="$(grep -n '^mark_update_page$' "$SCRIPTS/rollback-update.sh" | head -n 1 | cut -d: -f1)"
LATER="$(awk -v from="${SET:-0}" 'NR > from && /^[[:space:]]*trap .*EXIT/ { print NR }' "$SCRIPTS/rollback-update.sh" | head -n 1)"
if [ -n "$CLEAR" ] && [ -n "$SET" ] && [ -n "$MK" ] && [ "$CLEAR" -lt "$SET" ] && [ "$SET" -lt "$MK" ] && [ -z "$LATER" ]; then ok; else
    bad "trap - EXIT at ${CLEAR:-none}, hook trap at ${SET:-none}, marker at ${MK:-none}, a later EXIT trap at ${LATER:-none}"
fi

case_ "the page's unit does not depend on dtk, so a start of dtk skipped by the flag leaves the page up"
# A start of dtk while the flag exists is skipped by the drop-in's
# ConditionPathExists: no ExecStart (so no start.sh, no update-page-stop)
# runs. systemd itself cannot run here; what can be checked is that the
# condition is the one installed and that nothing ties the page's unit to
# dtk.service, which would otherwise stop it.
if grep -qx 'ConditionPathExists=!/etc/dtk/unresolved-deployment' "$SCRIPTS/dtk-unresolved.conf"; then ok; else bad "dtk-unresolved.conf has no ConditionPathExists on the flag"; fi
if grep -nE 'Conflicts=|BindsTo=|PartOf=|Before=dtk|After=dtk' "$SCRIPTS/dtk-system-helper" >/dev/null; then
    bad "dtk-system-helper ties the page to another unit: $(grep -nE 'Conflicts=|BindsTo=|PartOf=|Before=dtk|After=dtk' "$SCRIPTS/dtk-system-helper")"
else ok; fi

echo ""
echo "update-page tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
