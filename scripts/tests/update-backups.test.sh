#!/bin/bash
# Tests for the permissions of the pre-update backups that scripts/update.sh
# writes under /var/lib/dtk/backups.
#
#   bash scripts/tests/update-backups.test.sh
#
# update.sh needs root, docker compose, systemd, git and pixi, so it is not run
# whole. The functions that decide the permissions are taken out of the real
# scripts by name and run against a temporary directory, with a PATH of fakes
# in front of the system's:
#
#   chown    does nothing, so the cases run as an ordinary user.
#
# The call sites are checked by reading the scripts: that update.sh secures the
# directory and tightens old dumps before it writes a new one, that the dump is
# written through write_dump, and that setup.sh creates the directory as
# root:root 0700.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
UPDATE="$SCRIPTS/update.sh"
SETUP="$SCRIPTS/setup.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/update-backups-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKEBIN/chown"
PATH="$FAKEBIN:$PATH"

# ── Helpers ─────────────────────────────────────────────────────────────────
ok()   { PASS=$((PASS + 1)); echo "  ok    $CASE: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $CASE: $1"; }

# Permission bits of a path, as three octal digits, on GNU or BSD stat.
mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

expect_mode() {  # expect_mode <path> <mode> <what>
    local got
    got="$(mode_of "$1")"
    if [ "$got" = "$2" ]; then ok "$3 is $2"; else fail "$3 is $got, expected $2"; fi
}

# The text of one top-level function, from "name() {" to the first "}" in
# column one.
extract() {  # extract <script> <function>
    awk -v f="$2" '
        $0 ~ "^" f "\\(\\) \\{" { on = 1 }
        on { print }
        on && /^\}/ { exit }
    ' "$1"
}

load() {  # load <script> <function>...
    local script="$1" fn body
    shift
    for fn in "$@"; do
        body="$(extract "$script" "$fn")"
        if [ -z "$body" ]; then
            fail "no function $fn in $(basename "$script")"
            return 1
        fi
        eval "$body"
    done
}

fresh() {  # fresh <case name>: a new BACKUP_DIR under WORK, not yet created
    CASE="$1"
    BACKUP_DIR="$WORK/$(echo "$1" | tr -c 'a-z0-9' '-')/var/lib/dtk/backups"
    mkdir -p "$(dirname "$BACKUP_DIR")"
}

# ── Functions under test ────────────────────────────────────────────────────
load "$UPDATE" secure_backup_dir tighten_existing_dumps write_dump || exit 1

# The shell's umask is the one a root shell normally has, so a file the
# script does not protect comes out 0644 as it did on the bench unit.
umask 022

# ── Directory ───────────────────────────────────────────────────────────────
fresh "directory created"
out="$(secure_backup_dir 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "returns 0"; else fail "returned $rc: $out"; fi
expect_mode "$BACKUP_DIR" 700 "new directory"

fresh "directory found open"
mkdir -p "$BACKUP_DIR"; chmod 0755 "$BACKUP_DIR"
out="$(secure_backup_dir 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "returns 0"; else fail "returned $rc: $out"; fi
expect_mode "$BACKUP_DIR" 700 "existing 0755 directory"
case "$out" in
    *"0700"*) ok "says the directory was made private" ;;
    *) fail "no report of the change in: $out" ;;
esac

fresh "directory already private"
mkdir -p "$BACKUP_DIR"; chmod 0700 "$BACKUP_DIR"
out="$(secure_backup_dir 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "returns 0 and says nothing"; else fail "rc=$rc out=$out"; fi

fresh "directory is a symlink"
mkdir -p "$WORK/elsewhere"; chmod 0755 "$WORK/elsewhere"
ln -s "$WORK/elsewhere" "$BACKUP_DIR"
out="$(secure_backup_dir 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "refuses"; else fail "accepted a symlink: $out"; fi
expect_mode "$WORK/elsewhere" 755 "the symlink's target"

fresh "directory is a file"
: > "$BACKUP_DIR"
out="$(secure_backup_dir 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "refuses"; else fail "accepted a file: $out"; fi

# ── Existing dumps ──────────────────────────────────────────────────────────
fresh "existing dumps tightened"
mkdir -p "$BACKUP_DIR"
for ts in 20261001-120000 20261002-120000; do
    printf 'x%.0s' $(seq 1 200) > "$BACKUP_DIR/pre-update-$ts.sql.gz"
    chmod 0644 "$BACKUP_DIR/pre-update-$ts.sql.gz"
done
printf 'already private' > "$BACKUP_DIR/pre-update-20261003-120000.sql.gz"
chmod 0600 "$BACKUP_DIR/pre-update-20261003-120000.sql.gz"
echo "abc123" > "$BACKUP_DIR/last-deployed-SHA"; chmod 0644 "$BACKUP_DIR/last-deployed-SHA"
mkdir -p "$WORK/outside"; echo secret > "$WORK/outside/target"; chmod 0644 "$WORK/outside/target"
ln -s "$WORK/outside/target" "$BACKUP_DIR/pre-update-20261004-120000.sql.gz"
out="$(tighten_existing_dumps 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "returns 0"; else fail "returned $rc: $out"; fi
expect_mode "$BACKUP_DIR/pre-update-20261001-120000.sql.gz" 600 "first 0644 dump"
expect_mode "$BACKUP_DIR/pre-update-20261002-120000.sql.gz" 600 "second 0644 dump"
expect_mode "$BACKUP_DIR/pre-update-20261003-120000.sql.gz" 600 "already-private dump"
expect_mode "$BACKUP_DIR/last-deployed-SHA" 644 "last-deployed-SHA (not a dump)"
expect_mode "$WORK/outside/target" 644 "a symlinked dump's target"
case "$out" in
    *"2 earlier"*) ok "reports the two it tightened" ;;
    *) fail "count not reported in: $out" ;;
esac
out="$(tighten_existing_dumps 2>&1)"
if [ -z "$out" ]; then ok "a second run says nothing"; else fail "second run said: $out"; fi

fresh "no dumps yet"
mkdir -p "$BACKUP_DIR"
out="$(tighten_existing_dumps 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "returns 0 and says nothing"; else fail "rc=$rc out=$out"; fi

# ── New dump ────────────────────────────────────────────────────────────────
fresh "new dump"
mkdir -p "$BACKUP_DIR"
DUMP_FILE="$BACKUP_DIR/pre-update-20261024-120000.sql.gz"
# The producer records the dump's mode while it is still being written, to
# show there is no moment at which the file is readable by others.
fake_pg_dump() {
    echo "-- users.hashed_password would be here"
    # The shell opens gzip's output alongside this command; wait for it.
    local i
    for i in $(seq 1 50); do
        [ -e "$DUMP_FILE" ] && break
        perl -e 'select(undef, undef, undef, 0.05)'
    done
    mode_of "$DUMP_FILE" > "$WORK/mode-while-writing"
}
write_dump "$DUMP_FILE" fake_pg_dump; rc=$?
if [ "$rc" -eq 0 ]; then ok "returns 0"; else fail "returned $rc"; fi
expect_mode "$DUMP_FILE" 600 "the finished dump"
if [ "$(cat "$WORK/mode-while-writing")" = "600" ]; then
    ok "the dump is 600 while being written"
else
    fail "the dump was $(cat "$WORK/mode-while-writing") while being written"
fi
if gunzip -c "$DUMP_FILE" | grep -q hashed_password; then ok "content is the producer's, gzipped"; else fail "content wrong"; fi
if [ "$(umask)" = "0022" ]; then ok "the caller's umask is unchanged"; else fail "umask is now $(umask)"; fi

fresh "producer fails"
mkdir -p "$BACKUP_DIR"
DUMP_FILE="$BACKUP_DIR/pre-update-20261024-130000.sql.gz"
failing_pg_dump() { echo partial; return 3; }
write_dump "$DUMP_FILE" failing_pg_dump; rc=$?
if [ "$rc" -ne 0 ]; then ok "returns non-zero (pipefail)"; else fail "returned 0 for a failed producer"; fi

# ── Call sites ──────────────────────────────────────────────────────────────
CASE="update.sh call sites"
line_of() { grep -n -E "$2" "$1" | grep -v -E '^[0-9]+:[[:space:]]*#' | head -n 1 | cut -d: -f1; }
L_SECURE="$(line_of "$UPDATE" '^secure_backup_dir( |$|\|)')"
L_TIGHTEN="$(line_of "$UPDATE" '^tighten_existing_dumps')"
L_STATE="$(line_of "$UPDATE" '^STATE_FILE=')"
L_DUMP="$(line_of "$UPDATE" '^write_dump "\$DUMP_FILE"')"
if [ -n "$L_SECURE" ] && [ -n "$L_STATE" ] && [ "$L_SECURE" -lt "$L_STATE" ]; then
    ok "the directory is secured before the first file is written in it"
else
    fail "secure_backup_dir at line '${L_SECURE}', first state write at '${L_STATE}'"
fi
if [ -n "$L_TIGHTEN" ] && [ -n "$L_DUMP" ] && [ "$L_TIGHTEN" -lt "$L_DUMP" ]; then
    ok "old dumps are tightened before the new one is written"
else
    fail "tighten_existing_dumps at '${L_TIGHTEN}', write_dump at '${L_DUMP}'"
fi
if grep -n -E 'pg_dump.*\| *gzip *>' "$UPDATE" | grep -v -E '^[0-9]+:[[:space:]]*#' >/dev/null; then
    fail "a bare pg_dump | gzip > redirect is still in update.sh"
else
    ok "no dump is written outside write_dump"
fi
if grep -n -E '^[[:space:]]*mkdir -p "\$BACKUP_DIR"' "$UPDATE" >/dev/null; then
    fail "update.sh still creates BACKUP_DIR with a bare mkdir -p"
else
    ok "no bare mkdir -p of BACKUP_DIR"
fi

CASE="setup.sh"
if grep -E '^install -d .*-o root .*-m 0700 .*/var/lib/dtk/backups' "$SETUP" >/dev/null \
        || grep -E '^install -d .*-m 0700 .*-o root .*/var/lib/dtk/backups' "$SETUP" >/dev/null; then
    ok "creates /var/lib/dtk/backups as root, 0700"
else
    fail "setup.sh does not create /var/lib/dtk/backups as root 0700: $(grep -n 'var/lib/dtk/backups' "$SETUP" | head -n 1)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
