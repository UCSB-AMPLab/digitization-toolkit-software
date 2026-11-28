#!/bin/bash
# Tests for scripts/dtk.service: the unit turns on Python's faulthandler, so a
# backend that dies on a fatal signal (segfault in a camera library, abort)
# leaves a Python stack trace in the journal (NEH-429).
#
#   bash scripts/tests/dtk-service.test.sh
#
# The unit file is read as text; nothing is installed or started.
#
# Version: 0.4.0

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="$(dirname "$HERE")/dtk.service"
INSTALLER="$(dirname "$HERE")/install-service.sh"
START="$(dirname "$HERE")/start.sh"

PASS=0
FAIL=0
CASE=""
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL [$CASE] $1"; }

# The [Service] section's lines, comments removed.
service_lines() {
    awk '/^\[/ { in_svc = ($0 == "[Service]") ; next } in_svc && !/^[[:space:]]*#/' "$UNIT"
}

CASE="faulthandler is on in [Service]"
if service_lines | grep -Eq '^Environment=("?)PYTHONFAULTHANDLER=1\1$'; then ok; else bad "no Environment=PYTHONFAULTHANDLER=1 in [Service]"; fi

CASE="PATH assignment is kept"
if service_lines | grep -q '^Environment="PATH=/home/pi/.pixi/bin:'; then ok; else bad "the PATH Environment line is gone"; fi

CASE="stderr still goes to the journal"
if service_lines | grep -q '^StandardError=journal$'; then ok; else bad "StandardError=journal is missing"; fi

CASE="install-service.sh copies the unit file"
if grep -q 'cp "\$SERVICE_FILE" "\$SYSTEMD_DIR/dtk.service"' "$INSTALLER"; then ok; else bad "install-service.sh no longer copies dtk.service"; fi

CASE="start.sh exports faulthandler before the backend starts"
exp="$(grep -n '^export PYTHONFAULTHANDLER=1$' "$START" | head -1 | cut -d: -f1)"
run="$(grep -n 'run start' "$START" | head -1 | cut -d: -f1)"
if [ -n "$exp" ] && [ -n "$run" ] && [ "$exp" -lt "$run" ]; then ok; else bad "no export PYTHONFAULTHANDLER=1 before the pixi run start line"; fi

echo "dtk-service: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
