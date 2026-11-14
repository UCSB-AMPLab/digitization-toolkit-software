#!/bin/bash
# Tests for scripts/dtk-system-helper: argument handling for the verbs that
# take no arguments (poweroff, reboot, restart-backend) and the usage text.
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
# Version: 0.1.0-beta

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
cat > "$STUBS/systemctl" <<'EOF'
#!/bin/sh
# Records its arguments; FAKE_SYSTEMCTL_STATUS=<n> makes it exit with n.
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit "${FAKE_SYSTEMCTL_STATUS:-0}"
EOF
chmod +x "$STUBS/systemctl"

COPY="$WORK/dtk-system-helper"
sed "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$STUBS:/usr/sbin:/usr/bin:/sbin:/bin#" "$HELPER" > "$COPY"
chmod +x "$COPY"
if grep -q "^PATH=$STUBS:" "$COPY"; then ok; else
    echo "FAIL [setup] the helper's PATH line was not found; the cases below would call the real systemctl"
    exit 1
fi

SYSTEMCTL_LOG="$WORK/systemctl.log"
OUT=""
STATUS=0
run() {   # run [VAR=value ...] -- [helper args...]
    local -a envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    rm -f "$SYSTEMCTL_LOG"
    OUT="$(env -i SYSTEMCTL_LOG="$SYSTEMCTL_LOG" ${envs[@]+"${envs[@]}"} /bin/bash "$COPY" "$@" 2>&1)"
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

echo ""
echo "dtk-system-helper tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
