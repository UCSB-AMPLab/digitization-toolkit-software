#!/bin/bash
# Tests for what scripts/update.sh does when an update fails: it must put the
# previous version back (code, frontend image, pixi environment, and the
# database if a migration began), start that version, and say the unit is
# online only when the backend answers /health.
#
#   bash scripts/tests/update-restore.test.sh
#
# update.sh is run whole, against a real git checkout built in a temporary
# directory: a superproject with backend and frontend submodules, a deployed
# commit A and a newer commit B on the remote. The script under test is
# committed into that fixture with /var/lib/dtk pointed at a temporary state
# directory. Everything else it calls is a fake, first on PATH:
#
#   sudo       drops `-u <user>` and runs the command as the current user;
#              a command named pixi goes to the fake below.
#   systemctl  keeps the dtk unit's state in a file. `start dtk` records the
#              VERSION file of the checkout it started (A or B), brings the
#              db up and recreates the frontend container from the current tag.
#   docker     keeps tags, the frontend container's image and whether db is
#              running in files. `compose build frontend` points the tag at a
#              new image id; `exec ... psql` saves what it is fed.
#   pixi       records each call with the lock it saw; `run db-upgrade` marks
#              the database migrated.
#   curl       answers /health when the unit is active and the version
#              started is one the case calls healthy.
#   chown, sleep, ss   do nothing (ss reports the db port listening).
#   install    GNU-style install -D, which macOS lacks.
#   pgrep      finds no backend process, unless a case says one is stuck.
#
# Each case states the failure it injects, through the fakes or through
# update.sh's test-only DTK_UPDATE_FAIL_AT.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/update-restore-test.XXXXXX")"
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""
ok()   { PASS=$((PASS + 1)); echo "  ok    $CASE: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $CASE: $1"; }

OLD_IMG="sha256:$(printf 'a%.0s' $(seq 1 64))"
NEW_IMG="sha256:$(printf 'b%.0s' $(seq 1 64))"

# ── Git, isolated from the user's configuration ─────────────────────────────
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
    name = Test
    email = test@example.invalid
[protocol "file"]
    allow = always
[init]
    defaultBranch = dev
[advice]
    detachedHead = false
EOF
g() { git "$@" >/dev/null 2>&1; }

# ── Fakes ───────────────────────────────────────────────────────────────────
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/sudo" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && shift 2
[ "$1" = "-n" ] && shift
vars=()
if [ "$1" = "env" ]; then
    shift
    while [[ "$1" == *=* ]]; do vars+=("$1"); shift; done
fi
cmd="$1"; shift
[ "$(basename "$cmd")" = pixi ] && cmd="$FAKEBIN/pixi"
exec env "${vars[@]}" "$cmd" "$@"
EOF

for f in chown sleep; do
    printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$f"
done
printf '#!/bin/sh\necho "LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*"\n' > "$FAKEBIN/ss"
# flock -n <fd>, as util-linux has it (macOS has none): a BSD flock on the
# caller's inherited descriptor, which outlives this process because the
# caller keeps the descriptor open.
cat > "$FAKEBIN/flock" <<'EOF'
#!/usr/bin/perl
use Fcntl qw(:flock);
my $fd = $ARGV[-1];
open(my $fh, "+<&=", $fd) or exit 2;
exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1);
EOF
# GNU install -D <src> <dest> (step 0b's copy of a modified file); BSD install
# on macOS has no -D.
printf '#!/bin/sh\n[ "$1" = -D ] && shift\nmkdir -p "$(dirname "$2")" && cp "$1" "$2"\n' > "$FAKEBIN/install"

cat > "$FAKEBIN/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CASE_DIR/log"
S="$CASE_DIR/sys"
case "$1" in
    is-active) [ -f "$S/active" ] ;;
    show)
        case "$*" in
            *ActiveState*) if [ -f "$S/active" ]; then echo active; else echo inactive; fi ;;
            *MainPID*) if [ -f "$S/active" ]; then echo 4242; else echo 0; fi ;;
        esac
        exit 0 ;;
    stop)
        # The old version serves until here: a write it accepted after the
        # trial dump must survive a restore.
        if [ -f "$S/active" ] && [ -n "${FAKE_WRITE_BEFORE_STOP:-}" ] && [ ! -f "$S/wrote" ]; then
            echo "row written at $(date +%s) before the stop" >> "$CASE_DIR/db_rows"
            touch "$S/wrote"
        fi
        if [ -n "${FAKE_DIRTY_ON_STOP:-}" ] && [ ! -f "$CASE_DIR/dirtied" ]; then
            echo "hand edit" >> "$PROJECT_ROOT/README"; touch "$CASE_DIR/dirtied"
        fi
        rm -f "$S/active"; exit 0 ;;
    start)
        # The drop-in's ConditionPathExists=!<flag>: systemd skips the start.
        if [ -f "$DTK_TEST_STATE/systemd/dtk.service.d/unresolved.conf" ] \
           && [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then
            echo "condition failed: start skipped" >> "$CASE_DIR/log"
            exit 0
        fi
        echo "$(date +%s) Started dtk.service - Digitization Toolkit." >> "$CASE_DIR/journal"
        cat "$PROJECT_ROOT/VERSION" >> "$S/started"
        touch "$S/active" "$CASE_DIR/docker/db_running"
        cp "$CASE_DIR/docker/tag_dtk-frontend_latest" "$CASE_DIR/docker/frontend_container"
        exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$CASE_DIR/log"
# FAKE_KILL_ON_HEALTH: a power cut while update.sh waits for B's /health.
if [ -n "${FAKE_KILL_ON_HEALTH:-}" ] && grep -qx B "$CASE_DIR/sys/started" 2>/dev/null; then
    kill -KILL "$PPID"; exit 7
fi
S="$CASE_DIR/sys"
[ -f "$S/active" ] || exit 7
last="$(tail -n 1 "$S/started" 2>/dev/null)"
case " ${FAKE_HEALTHY_VERSIONS:-A B} " in
    *" $last "*) echo '{"status":"ok"}' ;;
    *) exit 22 ;;
esac
EOF

cat > "$FAKEBIN/pixi" <<'EOF'
#!/bin/bash
lock="$(cat pixi.lock 2>/dev/null)"
echo "pixi $* lock=$lock" >> "$CASE_DIR/log"
case "$1" in
    --version) echo "pixi 0.0.0" ;;
    install)
        [ -z "${FAKE_SLOW_INSTALL:-}" ] || perl -e 'select(undef,undef,undef,2)'
        if [ -n "${FAKE_PIXI_FAIL_LOCK:-}" ] && [ "$lock" = "$FAKE_PIXI_FAIL_LOCK" ]; then
            echo "pixi: cannot reach the registry" >&2; exit 1
        fi
        echo "$lock" > "$CASE_DIR/pixi_env"
        if [ -n "${FAKE_DIRTY_ON_PIXI_INSTALL:-}" ] && [ ! -f "$CASE_DIR/dirtied" ]; then
            echo "hand edit" >> "$PROJECT_ROOT/README"; touch "$CASE_DIR/dirtied"
        fi ;;
    run)
        if [ "$2" = alembic ] && [ "$3" = heads ]; then
            echo "${FAKE_ALEMBIC_HEAD:-rev-B} (head)"
        fi
        if [ "$2" = db-upgrade ]; then
            [ -z "${FAKE_KILL_ON_MIGRATE:-}" ] || { kill-update KILL "$PPID"; sleep 1; }
            echo migrated > "$CASE_DIR/db_state"
            [ -z "${FAKE_HUP_ON_MIGRATE:-}" ] || kill-update HUP "$PPID"
            if [ -n "${FAKE_BLOCK_GUARD_ON_MIGRATE:-}" ]; then
                # A file where the drop-in's directory goes: from here the
                # start guard cannot be installed.
                rm -rf "$DTK_TEST_STATE/systemd/dtk.service.d"; : > "$DTK_TEST_STATE/systemd/dtk.service.d"
            fi
            if [ -n "${FAKE_LOCK_SUBMODULE_ON_MIGRATE:-}" ]; then
                touch "$PROJECT_ROOT/.git/modules/backend/index.lock"
            fi
            if [ -n "${FAKE_DIRTY_ON_MIGRATE:-}" ]; then
                echo "hand edit" >> "$PROJECT_ROOT/README"
            fi
            [ -z "${FAKE_MIGRATE_FAIL:-}" ] || { echo "alembic: boom" >&2; exit 1; }
        fi ;;
esac
exit 0
EOF

cat > "$FAKEBIN/docker" <<'EOF'
#!/bin/bash
D="$CASE_DIR/docker"
echo "docker $*" >> "$CASE_DIR/log"
norm() {  # name -> file key; ids pass through
    case "$1" in sha256:*) echo "$1"; return ;; esac
    local n="$1"
    case "${n##*/}" in *:*) ;; *) n="$n:latest" ;; esac
    echo "tag_$(echo "$n" | tr ':/' '__')"
}
resolve() {  # name or id -> id
    case "$1" in sha256:*) [ -f "$D/known_$1" ] && echo "$1"; return ;; esac
    cat "$D/$(norm "$1")" 2>/dev/null
}
if [ "$1" = compose ]; then
    shift
    while [ "$1" = "-f" ]; do shift 2; done
    sub="$1"; shift
    case "$sub" in
        config)
            # FAKE_NO_CONFIG_IMAGES: a Compose that gives no implicit name for
            # the build-only frontend; FAKE_NO_PROJECT_NAME: no name: line.
            if [ "${1:-}" = "--images" ]; then
                [ -n "${FAKE_NO_CONFIG_IMAGES:-}" ] || echo "dtk-frontend"
            else
                [ -n "${FAKE_NO_PROJECT_NAME:-}" ] || echo "name: dtk"
            fi ;;
        ps)
            case "$*" in
                *"--services --status running"*) [ -f "$D/db_running" ] && echo db; [ -f "$D/frontend_container" ] && echo frontend ;;
                *"-q frontend"*) [ -f "$D/frontend_container" ] && echo cid-frontend ;;
            esac
            exit 0 ;;
        build)
            [ -z "${FAKE_BUILD_FAIL:-}" ] || { echo "npm ERR! network" >&2; exit 1; }
            echo "$NEW_IMG" > "$D/tag_dtk-frontend_latest"; touch "$D/known_$NEW_IMG" ;;
        up) touch "$D/db_running" ;;
        down) rm -f "$D/db_running" "$D/frontend_container" ;;
        stop) rm -f "$D/db_running" ;;
        exec)
            [ "$1" = "-T" ] && shift
            shift   # service
            case "$1" in
                pg_isready) exit 0 ;;
                pg_dump)
                    n=$(( $(cat "$CASE_DIR/dumps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE_DIR/dumps"
                    if [ -n "${FAKE_DUMP_FAIL_AT:-}" ] && [ "$n" = "$FAKE_DUMP_FAIL_AT" ]; then
                        echo "pg_dump: error" >&2; exit 1
                    fi
                    echo "-- dump $n of the database at schema A"
                    cat "$CASE_DIR/db_rows" 2>/dev/null
                    seq 1 300 ;;
                psql)
                    case "$*" in *alembic_version*) echo "${FAKE_DB_REV:-rev-B}"; exit 0 ;; esac
                    case "$*" in *"DROP DATABASE"*)
                        echo "psql DROP" >> "$CASE_DIR/log"
                        [ -z "${FAKE_KILL_ON_DROP:-}" ] || { kill-update KILL "$PPID"; sleep 1; } ;;
                    esac
                    if [ -t 0 ]; then :; else
                        input="$(cat)"
                        if [ -n "$input" ]; then
                            # The load runs in a subshell of update.sh.
                            [ -z "${FAKE_HUP_DURING_RESTORE:-}" ] || kill-update HUP "$(ps -o ppid= -p "$PPID" | tr -d ' ')"
                            [ -z "${FAKE_RESTORE_FAIL:-}" ] || exit 3
                            printf '%s\n' "$input" > "$CASE_DIR/restored.sql"
                            echo restored > "$CASE_DIR/db_state"
                        fi
                    fi ;;
            esac ;;
    esac
    exit 0
fi
case "$1" in
    tag)
        if [ -n "${FAKE_RETAG_FAIL:-}" ] && [ "$3" = dtk-frontend ]; then exit 1; fi
        id="$(resolve "$2")"; [ -n "$id" ] || exit 1
        echo "$id" > "$D/$(norm "$3")" ;;
    image)
        case "$2" in
            inspect) id="$(resolve "${!#}")"; [ -n "$id" ] && echo "$id" || exit 1 ;;
            ls) for f in "$D"/tag_dtk-frontend_*; do [ -e "$f" ] && echo "${f##*/tag_dtk-frontend_}"; done ;;
            rm) rm -f "$D/$(norm "$3")" ;;
        esac ;;
    container)
        [ -f "$D/frontend_container" ] || exit 1
        case "$*" in
            *Config.Image*) [ -z "${FAKE_NO_CONTAINER_NAME:-}" ] || exit 1; echo "dtk-frontend" ;;
            *) cat "$D/frontend_container" ;;
        esac ;;
    ps) exit 0 ;;
    network) exit 1 ;;
esac
exit 0
EOF
cat > "$FAKEBIN/journalctl" <<'EOF2'
#!/bin/sh
# Lines are "<epoch> <message>"; --since @<epoch> is honoured.
since=0
while [ $# -gt 0 ]; do
    case "$1" in --since) since="${2#@}"; shift ;; esac
    shift
done
awk -v s="$since" '$1 >= s' "$CASE_DIR/journal" 2>/dev/null
exit 0
EOF2
# kill-update <signal> <pid>: signal the running update.sh, which the
# caller names by its parent chain (pgrep is a fake).
cat > "$FAKEBIN/kill-update" <<'EOF2'
#!/bin/sh
kill "-$1" "$2" 2>/dev/null
EOF2
cat > "$FAKEBIN/pgrep" <<'EOF2'
#!/bin/sh
# FAKE_PGREP_STUCK: a backend survives every stop. FAKE_PGREP_STUCK_AFTER_B:
# only once B has been started. FAKE_PGREP_STUCK_AFTER_MIGRATE: once the
# database is migrated.
[ -n "${FAKE_PGREP_STUCK:-}" ] && { echo 4243; exit 0; }
if [ -n "${FAKE_PGREP_STUCK_AFTER_MIGRATE:-}" ] && grep -qx migrated "$CASE_DIR/db_state" 2>/dev/null; then
    echo 4243; exit 0
fi
if [ -n "${FAKE_PGREP_STUCK_AFTER_B:-}" ] && grep -qx B "$CASE_DIR/sys/started" 2>/dev/null; then
    echo 4243; exit 0
fi
exit 1
EOF2
chmod +x "$FAKEBIN"/*
export FAKEBIN OLD_IMG NEW_IMG

# ── Fixture: superproject with submodules, deployed A, remote at B ──────────
UP="$WORK/up"
mkdir -p "$UP"
for sub in backend frontend; do
    git init -q "$UP/$sub"
done
echo "lock-A" > "$UP/backend/pixi.lock"; g -C "$UP/backend" add -A; g -C "$UP/backend" commit -m A
echo "fe-A" > "$UP/frontend/app";        g -C "$UP/frontend" add -A; g -C "$UP/frontend" commit -m A

STATE_DIR_T="$WORK/STATE"   # stand-in for /var/lib/dtk, per case (see run_case)
git init -q "$UP/super"
mkdir -p "$UP/super/scripts"
# /var/lib/dtk, /etc/dtk and /etc/systemd/system all point into the case's
# state directory.
TESTPATHS='s#/var/lib/dtk#$DTK_TEST_STATE#g; s#/etc/dtk#$DTK_TEST_STATE/etc-dtk#g; s#/etc/systemd/system#$DTK_TEST_STATE/systemd#g; s#/run/dtk-update.lock#$DTK_TEST_STATE/dtk-update.lock#g'
sed "$TESTPATHS" "$SCRIPTS/update.sh" > "$UP/super/scripts/update.sh"
sed "$TESTPATHS" "$SCRIPTS/rollback-update.sh" > "$UP/super/scripts/rollback-update.sh"
printf '#!/bin/sh\nexit 0\n' > "$UP/super/scripts/provision-chdk-usb.sh"
printf '#!/bin/sh\nexit 0\n' > "$UP/super/scripts/provision-rclone.sh"
chmod +x "$UP/super/scripts/"*.sh
echo "services: {}" > "$UP/super/docker-compose.yml"
echo "services: {}" > "$UP/super/docker-compose.pi.yml"
echo "readme" > "$UP/super/README"
echo "A" > "$UP/super/VERSION"
g -C "$UP/super" submodule add "$UP/backend" backend
g -C "$UP/super" submodule add "$UP/frontend" frontend
g -C "$UP/super" add -A; g -C "$UP/super" commit -m A
SHA_A="$(git -C "$UP/super" rev-parse HEAD)"
BACKEND_A="$(git -C "$UP/backend" rev-parse HEAD)"

echo "lock-B" > "$UP/backend/pixi.lock"; g -C "$UP/backend" commit -am B
echo "fe-B" > "$UP/frontend/app";        g -C "$UP/frontend" commit -am B
g -C "$UP/super/backend" pull -q origin dev
g -C "$UP/super/frontend" pull -q origin dev
echo "B" > "$UP/super/VERSION"
g -C "$UP/super" add -A; g -C "$UP/super" commit -m B
SHA_B="$(git -C "$UP/super" rev-parse HEAD)"
BACKEND_B="$(git -C "$UP/backend" rev-parse HEAD)"

# An older deployed version, A_OLD: A with an update.sh that predates the
# unresolved-deployment record (as 0.0.0-pre.3's does).
g -C "$UP/super" checkout -q -b old "$SHA_A"
printf '#!/bin/bash\necho "an update.sh from before the record"\n' > "$UP/super/scripts/update.sh"
g -C "$UP/super" commit -qam "A with an old update.sh"
SHA_A_OLD="$(git -C "$UP/super" rev-parse HEAD)"
g -C "$UP/super" checkout -q dev

# The unit: a clone on dev at A, tracking the remote's dev (at B).
TEMPLATE="$WORK/template"
git clone -q "$UP/super" "$TEMPLATE" 2>/dev/null
g -C "$TEMPLATE" reset --hard "$SHA_A"
g -C "$TEMPLATE" submodule update --init --recursive
if [ "$(git -C "$TEMPLATE" rev-parse HEAD)" != "$SHA_A" ] || [ ! -f "$TEMPLATE/backend/pixi.lock" ]; then
    echo "fixture: could not build the unit checkout"; exit 1
fi

# stage_backend_pin <sha>: check the backend submodule out at <sha> and stage
# that commit as the superproject's backend gitlink, leaving HEAD's gitlink as
# it was. `git submodule status` compares against the index and reports the
# submodule as on its pin; only a comparison with HEAD's tree shows otherwise.
stage_backend_pin() {
    g -C "$PROJECT_ROOT/backend" checkout -q "$1"
    g -C "$PROJECT_ROOT" update-index --cacheinfo "160000,$1,backend"
}

# ── Running one case ────────────────────────────────────────────────────────
# run_case <name> [update.sh args...]; the case's fake settings are in the
# environment of the call. Leaves OUT (the script's output), RC, and the
# case directory in CASE_DIR.
run_case() {
    CASE="$1"; shift
    CASE_DIR="$WORK/cases/$(echo "$CASE" | tr ' /' '__')"
    mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"
    export CASE_DIR
    PROJECT_ROOT="$CASE_DIR/dtk"
    export PROJECT_ROOT
    cp -R "$TEMPLATE" "$PROJECT_ROOT"
    [ -z "${FAKE_BREAK_ORIGIN:-}" ] || g -C "$PROJECT_ROOT" remote set-url origin "$WORK/nonexistent"
    [ -z "${FAKE_STAGE_BACKEND_PIN:-}" ] || stage_backend_pin "$FAKE_STAGE_BACKEND_PIN"
    export DTK_TEST_STATE="$CASE_DIR/state"
    mkdir -p "$DTK_TEST_STATE/backups"
    echo "$SHA_A" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
    printf 'sha: %s\nimage: %s\n' "$SHA_A" "$OLD_IMG" > "$DTK_TEST_STATE/backups/last-deployed-frontend"
    # The previous version is running: unit active, db up, frontend on the old image.
    touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
    echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"
    echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
    echo "A" > "$CASE_DIR/sys/started"
    echo "lock-A" > "$CASE_DIR/pixi_env"
    echo "schema-A" > "$CASE_DIR/db_state"
    OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 \
        bash "$PROJECT_ROOT/scripts/update.sh" "$@" 2>&1 </dev/null)"
    RC=$?
    echo "$OUT" > "$CASE_DIR/out"
}

has()     { case "$OUT" in *"$1"*) ok "says: $1" ;; *) fail "does not say: $1 (output in $CASE_DIR/out)" ;; esac; }
hasnt()   { case "$OUT" in *"$1"*) fail "says: $1" ;; *) ok "does not say: $1" ;; esac; }
eq()      { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3: got '$1', expected '$2'"; fi; }
logged()  { if grep -qF -- "$1" "$CASE_DIR/log" 2>/dev/null; then ok "ran: $1"; else fail "did not run: $1"; fi; }
unlogged(){ if grep -qF -- "$1" "$CASE_DIR/log" 2>/dev/null; then fail "ran: $1"; else ok "did not run: $1"; fi; }
head_is() { eq "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" "$1" "checkout is on $2"; }
backend_is() { eq "$(git -C "$PROJECT_ROOT/backend" rev-parse HEAD)" "$1" "backend submodule is on $2's pin"; }
tag_is()  { eq "$(cat "$CASE_DIR/docker/tag_dtk-frontend_latest")" "$1" "dtk-frontend points at $2"; }
db_is()   { eq "$(cat "$CASE_DIR/db_state")" "$1" "database is $1"; }
started() { eq "$(tr '\n' ' ' < "$CASE_DIR/sys/started")" "$1" "versions started: $1"; }
active()  { if [ -f "$CASE_DIR/sys/active" ]; then ok "dtk is active"; else fail "dtk is not active"; fi; }
inactive(){ if [ -f "$CASE_DIR/sys/active" ]; then fail "dtk is active"; else ok "dtk is not active"; fi; }
# run_again <script> [args...]: run another script in the current case's
# unit, with the same fakes; replaces OUT and RC.
run_again() {
    local script="$1"; shift
    : > "$CASE_DIR/log"
    OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 \
        bash "$script" "$@" 2>&1 </dev/null)"
    RC=$?
    echo "$OUT" >> "$CASE_DIR/out"
}
MARKER_REL="backups/unresolved-deployment"
marker_has() { if grep -qxF -- "$1" "$DTK_TEST_STATE/$MARKER_REL" 2>/dev/null; then ok "marker records: $1"; else fail "marker does not record: $1"; fi; }
no_marker() { if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then fail "an unresolved-deployment marker exists"; else ok "no unresolved-deployment marker"; fi; }
dump_name() { ls "$DTK_TEST_STATE/backups"/pre-update-*.sql.gz 2>/dev/null | head -n 1; }

echo "update.sh restore paths"

# ── Success path ────────────────────────────────────────────────────────────
run_case "success" --yes
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
backend_is "$(git -C "$UP/backend" rev-parse HEAD)" B
tag_is "$NEW_IMG" "the new build"
db_is migrated
started "A B "
active
has "Update complete!"
has "Service running and the backend answers /health"
hasnt "UPDATE FAILED"
hasnt "Restored to the previous version"
no_marker
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_B" "last-deployed-SHA names B"
eq "$(sed -n 's/^image: //p' "$DTK_TEST_STATE/backups/last-deployed-frontend")" "$NEW_IMG" "last-deployed-frontend names the new image"
eq "$(cat "$CASE_DIR/docker/tag_dtk-frontend_pre-update-"* 2>/dev/null)" "$OLD_IMG" "the old image is kept under a pre-update tag"
eq "$(cat "$CASE_DIR/dumps")" 2 "two dumps taken: the trial and the one with the backend stopped"
eq "$(ls "$DTK_TEST_STATE/backups"/pre-update-*.sql.gz | wc -l | tr -d ' ')" 1 "only the stopped-backend dump is kept"
eq "$(sed -n 's/^dump: //p' "$DTK_TEST_STATE/backups/pre-update-ref")" "$(basename "$(dump_name)")" "pre-update-ref names it"
if gunzip -c "$(dump_name)" | grep -q "^-- dump 2 "; then ok "the kept dump is the second"; else fail "the kept dump is not the second"; fi

# ── Failure in the frontend build (before the stop) ─────────────────────────
FAKE_BUILD_FAIL=1 run_case "build fails" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
backend_is "$BACKEND_A" A
tag_is "$OLD_IMG" "the old image"
db_is schema-A
started "A "
active
unlogged "systemctl stop"
unlogged "systemctl start"
unlogged "pixi install"
unlogged "psql"
has "code: $SHA_A"
has "database: untouched"
has "still serving the previous"
hasnt "Nothing changed."
hasnt "back online"

# ── Failure after a successful build (before the stop) ──────────────────────
DTK_UPDATE_FAIL_AT=build run_case "fail after build" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
tag_is "$OLD_IMG" "the old image again"
logged "docker tag $OLD_IMG dtk-frontend"
db_is schema-A
started "A "
active
unlogged "systemctl stop"
has "frontend image: dtk-frontend is $OLD_IMG again"

# ── rollback-update.sh keeps the record unless code AND database came back ──
FAKE_HEALTHY_VERSIONS="A" run_case "rollback without a recorded commit" --yes
rm -f "$DTK_TEST_STATE/backups/pre-update-SHA"
CASE="rollback without a recorded commit: the rollback"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
head_is "$SHA_B" "B (no commit to return to)"
db_is migrated
has "this rollback would return it to"
inactive
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi

FAKE_HEALTHY_VERSIONS="A" run_case "rollback whose code move fails" --yes
printf '#!/bin/sh\nexit 1\n' > "$PROJECT_ROOT/.git/hooks/post-checkout"; chmod +x "$PROJECT_ROOT/.git/hooks/post-checkout"
CASE="rollback whose code move fails: the rollback"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "The code could not be moved"
db_is migrated
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi

# ── Resolving forward after a started-then-failed update ────────────────────
FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward" --yes
marker_has "kind: started-failed"
CASE="resolve forward: database not at head"
FAKE_ALEMBIC_HEAD=rev-C run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
has "Database revision: rev-B; backend head: rev-C"
has "not at the migration head"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_A" "last-deployed-SHA still names A"
inactive

CASE="resolve forward: checkout not on the failed commit"
g -C "$PROJECT_ROOT" checkout -q "$SHA_A"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
has "not on the recorded version"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi
g -C "$PROJECT_ROOT" checkout -q dev

CASE="resolve forward: accepted"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 0 "exit status"
has "Recorded $SHA_B as the deployed version"
has "online on $SHA_B"
no_marker
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_B" "last-deployed-SHA names B"
eq "$(sed -n 's/^sha: //p' "$DTK_TEST_STATE/backups/last-deployed-frontend")" "$SHA_B" "last-deployed-frontend names B"
eq "$(sed -n 's/^image: //p' "$DTK_TEST_STATE/backups/last-deployed-frontend")" "$NEW_IMG" "last-deployed-frontend names B's running image"
head_is "$SHA_B" B
active
unlogged "DROP DATABASE"

CASE="resolve forward: a later failed update restores to B"
DTK_UPDATE_FAIL_AT=build run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_B" B
has "code: still on $SHA_B"
hasnt "code: $SHA_A"

CASE="resolve forward with nothing to resolve"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 2 "exit status"
has "there is no unresolved update"

# ── The automatic database restore fails: a restore-failed record ───────────
FAKE_MIGRATE_FAIL=1 FAKE_RESTORE_FAIL=1 run_case "restore-failed record" --yes
eq "$RC" 1 "exit status"
marker_has "kind: restore-failed"
marker_has "code-commit: $SHA_A"
marker_has "dump-to-restore: $(dump_name)"
has "update.sh refuses to run"
CASE="restore-failed record: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "restoring the database from its backup then"
has "--yes $(dump_name)"
hasnt "--resolve-forward"
unlogged "git"
CASE="restore-failed record: --resolve-forward refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
has "cannot resolve this record (kind: restore-failed)"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi
CASE="restore-failed record: the rollback clears it"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
db_is restored
head_is "$SHA_A" A
no_marker
active

# ── The frontend image name, when Compose does not report it ────────────────
FAKE_NO_CONFIG_IMAGES=1 DTK_UPDATE_FAIL_AT=build run_case "name from the running container" --yes
tag_is "$OLD_IMG" "the old image again"
logged "docker tag $OLD_IMG dtk-frontend"
logged "--format {{.Config.Image}}"
hasnt "COULD NOT BE KEPT"

FAKE_NO_CONFIG_IMAGES=1 FAKE_NO_CONTAINER_NAME=1 DTK_UPDATE_FAIL_AT=build run_case "name from the project" --yes
tag_is "$OLD_IMG" "the old image again"
has "kept as dtk-frontend:pre-update-"
hasnt "COULD NOT BE KEPT"

FAKE_NO_CONFIG_IMAGES=1 FAKE_NO_CONTAINER_NAME=1 FAKE_NO_PROJECT_NAME=1 DTK_UPDATE_FAIL_AT=build run_case "no name at all" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
tag_is "$NEW_IMG" "the new build (could not be put back)"
has "THE FRONTEND IMAGE COULD NOT BE KEPT: Compose did not give its name"
has "frontend image: no image was recorded before the rebuild"

FAKE_HEALTHY_VERSIONS="A" run_case "rollback with no frontend name" --yes
CASE="rollback with no frontend name: the rollback"
FAKE_NO_CONFIG_IMAGES=1 FAKE_NO_CONTAINER_NAME=1 FAKE_NO_PROJECT_NAME=1 \
    run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
head_is "$SHA_A" A
has "THE FRONTEND IMAGE WAS NOT PUT BACK: Compose did not give the frontend image's name"
tag_is "$NEW_IMG" "the new build (not put back)"
no_marker

# ── Failure after pixi reinstalled (before the stop) ────────────────────────
DTK_UPDATE_FAIL_AT=pixi run_case "fail after pixi" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
tag_is "$OLD_IMG" "the old image"
eq "$(cat "$CASE_DIR/pixi_env")" "lock-A" "pixi environment is A's again"
logged "pixi install --locked lock=lock-B"
logged "pixi install --locked lock=lock-A"
db_is schema-A
unlogged "systemctl stop"
has "pixi environment: reinstalled for the restored backend/pixi.lock"

# ── Failure right after the fast-forward ────────────────────────────────────
DTK_UPDATE_FAIL_AT=fetched run_case "fail after fetch" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
backend_is "$BACKEND_A" A
unlogged "build frontend"
unlogged "systemctl stop"
has "code: $SHA_A"
hasnt "Nothing changed."

# ── Failure in the migration ────────────────────────────────────────────────
FAKE_MIGRATE_FAIL=1 FAKE_WRITE_BEFORE_STOP=1 run_case "migration fails" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
backend_is "$BACKEND_A" A
tag_is "$OLD_IMG" "the old image"
eq "$(cat "$CASE_DIR/pixi_env")" "lock-A" "pixi environment is A's again"
db_is restored
if grep -q "^-- dump 2 of the database at schema A" "$CASE_DIR/restored.sql" 2>/dev/null; then
    ok "the database was loaded from the dump taken with the backend stopped"
else
    fail "the database was not loaded from the dump taken with the backend stopped"
fi
if grep -q "before the stop" "$CASE_DIR/restored.sql" 2>/dev/null; then
    ok "a write accepted after the trial dump, before the stop, survives the restore"
else
    fail "a write accepted after the trial dump, before the stop, was lost"
fi
logged "DROP DATABASE IF EXISTS"
started "A A "
active
logged "curl -fsS --max-time 5 http://127.0.0.1:8000/health"
has "database: restored from this run's backup $(dump_name)"
has "back online on the previous version"
no_marker

# ── The new version starts but never answers /health ────────────────────────
# Once started it may have taken writes: nothing is restored, the unit stops.
started_failure_checks() {
    eq "$RC" 1 "exit status"
    head_is "$SHA_B" "B (not moved back)"
    tag_is "$NEW_IMG" "the new build (not moved back)"
    db_is migrated
    unlogged "DROP DATABASE"
    unlogged "pixi install --locked lock=lock-A"
    started "A B "
    inactive
    has "UPDATE FAILED after the new version was started"
    has "dtk service: STOPPED, with no backend process left running"
    has "database: migrated for the new version, NOT restored"
    has "rollback-update.sh --project-root="
    has "--yes $(dump_name)"
    has "DISCARDS"
    has "writes the new version"
    hasnt "back online"
    eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_A" "last-deployed-SHA still names A"
    marker_has "failed-commit: $SHA_B"
    marker_has "restore-target: $SHA_A"
    marker_has "migrated-revision: rev-B"
    marker_has "dump: $(dump_name)"
    eq "$(stat -c %a "$DTK_TEST_STATE/$MARKER_REL" 2>/dev/null || stat -f %Lp "$DTK_TEST_STATE/$MARKER_REL")" 600 "marker is mode 600"
    has "update.sh refuses to run"
}
FAKE_HEALTHY_VERSIONS="A" run_case "health fails after start" --yes
started_failure_checks
has "did not become healthy"

CASE="then update.sh again"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "An earlier update was left unresolved"
has "failed-commit: $SHA_B"
has "update.sh --resolve-forward"
hasnt "sudo rm"
has "rollback-update.sh --project-root="
head_is "$SHA_B" "B (untouched)"
unlogged "git"
unlogged "docker"
unlogged "systemctl"
db_is migrated

CASE="then a rollback that fails"
FAKE_RESTORE_FAIL=1 run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the marker is kept"; else fail "the marker was removed by a failed rollback"; fi

CASE="then the rollback"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
head_is "$SHA_A" A
db_is restored
tag_is "$OLD_IMG" "the image recorded for A"
has "Frontend image put back"
has "removed; update.sh will run again"
no_marker
active
started "A B A "

CASE="then update.sh runs again"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
no_marker

DTK_UPDATE_FAIL_AT=started run_case "fails right after start" --yes
started_failure_checks

DTK_UPDATE_FAIL_AT=served run_case "fails after serving" --yes
started_failure_checks
has "answered /health, and the update"

FAKE_HEALTHY_VERSIONS="A" FAKE_PGREP_STUCK_AFTER_B=1 run_case "backend does not stop" --yes
eq "$RC" 1 "exit status"
db_is migrated
unlogged "DROP DATABASE"
has "still running after"
has "--yes $(dump_name)"
hasnt "back online"

# ── Migration fails and the previous version does not come back healthy ─────
FAKE_MIGRATE_FAIL=1 FAKE_HEALTHY_VERSIONS="none" run_case "previous version unhealthy" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
db_is restored
started "A A "
hasnt "back online"
has "The previous version did NOT come back up"
has "--yes $(dump_name)"

# ── The dump with the backend stopped fails: no migration, database untouched ─
FAKE_DUMP_FAIL_AT=2 run_case "stopped-backend dump fails" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
db_is schema-A
unlogged "DROP DATABASE"
unlogged "pixi run db-upgrade"
started "A A "
active
has "database: untouched"
has "back online on the previous version"

# ── Restore fails: the code cannot be moved back ────────────────────────────
FAKE_MIGRATE_FAIL=1 FAKE_DIRTY_ON_MIGRATE=1 run_case "code restore refused" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_B" "B (left where it was)"
db_is migrated
started "A "
inactive
unlogged "DROP DATABASE"
has "modified tracked files"
has "has NOT been started"
has "rollback-update.sh --project-root="
has "--yes $(dump_name)"
hasnt "back online"
if [ -x "$DTK_TEST_STATE/rollback-update.sh" ] && cmp -s "$DTK_TEST_STATE/rollback-update.sh" "$UP/super/scripts/rollback-update.sh"; then
    ok "rollback-update.sh copied outside the checkout"
else
    fail "rollback-update.sh not copied outside the checkout"
fi
marker_has "kind: migrated-not-restored"
marker_has "failed-commit: $SHA_B"
marker_has "restore-target: $SHA_A"
marker_has "dump: $(dump_name)"
CASE="code restore refused: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "the code was not moved back"
has "--resolve-forward"
unlogged "git"
CASE="code restore refused: the rollback refuses the modified checkout and keeps the record"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "has local changes"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi
CASE="code restore refused: a rollback from another dump keeps the record"
g -C "$PROJECT_ROOT" checkout -- README
OTHER_DUMP="$DTK_TEST_STATE/backups/pre-update-19990101-000000.sql.gz"
cp "$(dump_name)" "$OTHER_DUMP"; touch -t 199901010000 "$OTHER_DUMP"
REAL_DUMP="$(ls -t "$DTK_TEST_STATE/backups"/pre-update-*.sql.gz | head -n 1)"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$OTHER_DUMP"
eq "$RC" 1 "exit status"
has "names the backup to restore"
db_is migrated
inactive
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi
CASE="code restore refused: the rollback from the named dump clears it"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$REAL_DUMP"
eq "$RC" 0 "exit status"
head_is "$SHA_A" A
db_is restored
no_marker

# ── The backend survives the stop: no backup, no migration ──────────────────
FAKE_PGREP_STUCK=1 FAKE_MIGRATE_FAIL=1 run_case "backend survives the stop" --yes
eq "$RC" 1 "exit status"
has "The backend did not stop"
has "Aborting before the backup and the migration"
eq "$(cat "$CASE_DIR/dumps")" 1 "only the trial dump was taken"
unlogged "pixi run db-upgrade"
unlogged "DROP DATABASE"
db_is schema-A
head_is "$SHA_A" A
has "database: untouched"
no_marker

# ── The restored code's update.sh predates the record ───────────────────────
# B's update.sh is run by hand (--no-pull) on a unit last deployed at A_OLD;
# the migration fails, and so does the database restore after the code is
# back on A_OLD.
CASE_DIR="$WORK/cases/old-update-script"
mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"; export CASE_DIR
PROJECT_ROOT="$CASE_DIR/dtk"; export PROJECT_ROOT
cp -R "$TEMPLATE" "$PROJECT_ROOT"
g -C "$PROJECT_ROOT" fetch origin
g -C "$PROJECT_ROOT" merge --ff-only origin/dev
g -C "$PROJECT_ROOT" submodule update --init --recursive
export DTK_TEST_STATE="$CASE_DIR/state"
mkdir -p "$DTK_TEST_STATE/backups"
echo "$SHA_A_OLD" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"
echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
echo "A" > "$CASE_DIR/sys/started"
echo "schema-A" > "$CASE_DIR/db_state"
CASE="restored update.sh predates the record"
: > "$CASE_DIR/log"
OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 FAKE_MIGRATE_FAIL=1 FAKE_RESTORE_FAIL=1 \
    bash "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes 2>&1 </dev/null)"
RC=$?
echo "$OUT" > "$CASE_DIR/out"
eq "$RC" 1 "exit status"
head_is "$SHA_A_OLD" "A_OLD"
marker_has "kind: restore-failed"
has "DO NOT RUN scripts/update.sh ON THIS UNIT UNTIL THE ROLLBACK HAS SUCCEEDED"
has "predates the unresolved-deployment record"

CASE="restored update.sh has the guard: no warning"
FAKE_MIGRATE_FAIL=1 FAKE_RESTORE_FAIL=1 run_case "restored update.sh has the guard" --yes
marker_has "kind: restore-failed"
hasnt "DO NOT RUN scripts/update.sh"

# ── 1. Signals, and records before irreversible steps ───────────────────────
FAKE_HUP_ON_MIGRATE=1 run_case "SIGHUP during the migration" --yes
eq "$RC" 129 "exit status (129, never 0)"
head_is "$SHA_A" A
db_is restored
hasnt "Update complete!"
no_marker

FAKE_MIGRATE_FAIL=1 FAKE_HUP_DURING_RESTORE=1 run_case "SIGHUP during the trap's restore" --yes
eq "$RC" 1 "exit status"
db_is restored
has "back online on the previous version"
no_marker

FAKE_MIGRATE_FAIL=1 FAKE_KILL_ON_DROP=1 run_case "killed right after the DROP" --yes
marker_has "kind: restore-failed"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the start flag exists"; else fail "no start flag"; fi

FAKE_KILL_ON_MIGRATE=1 run_case "killed during the migration" --yes
marker_has "kind: migrated-not-restored"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the start flag exists"; else fail "no start flag"; fi
CASE="killed during the migration: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "An earlier update was left unresolved"

# ── 2. The start flag and drop-in ───────────────────────────────────────────
FAKE_HEALTHY_VERSIONS="A" run_case "the flag keeps dtk from starting" --yes
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the start flag exists"; else fail "no start flag"; fi
eq "$(cat "$DTK_TEST_STATE/systemd/dtk.service.d/unresolved.conf" 2>/dev/null | grep ConditionPathExists)" \
   "ConditionPathExists=!$DTK_TEST_STATE/etc-dtk/unresolved-deployment" "drop-in names the flag"
logged "systemctl daemon-reload"
CASE="the flag keeps dtk from starting: a reboot's start"
: > "$CASE_DIR/log"
PATH="$FAKEBIN:$PATH" systemctl start dtk
inactive
logged "condition failed: start skipped"
CASE="the flag keeps dtk from starting: refusal says whether dtk started since"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
has "old."
has "dtk has not been started since it was written"
CASE="the flag keeps dtk from starting: the rollback clears it"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the start flag remains"; else ok "the start flag is removed"; fi
active
no_marker

FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward clears the flag" --yes
CASE="resolve forward clears the flag: resolve"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 0 "exit status"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the start flag remains"; else ok "the start flag is removed"; fi
active

CASE="the drop-in update.sh writes is the one install-service.sh installs"
eq "$(cat "$DTK_TEST_STATE/systemd/dtk.service.d/unresolved.conf")" \
   "$(sed "$TESTPATHS" "$SCRIPTS/dtk-unresolved.conf" | sed "s#\$DTK_TEST_STATE#$DTK_TEST_STATE#g")" "same content"
for f in install-service.sh; do
    if grep -q 'dtk-unresolved.conf' "$SCRIPTS/$f"; then ok "$f installs it"; else fail "$f does not install it"; fi
done
if grep -q 'dtk.service.d/unresolved.conf' "$SCRIPTS/uninstall-service.sh" && grep -q 'rm -rf /etc/dtk' "$SCRIPTS/uninstall-service.sh"; then
    ok "uninstall-service.sh removes it and /etc/dtk"
else
    fail "uninstall-service.sh does not remove it and /etc/dtk"
fi

run_case "success leaves no flag" --yes
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "a start flag remains"; else ok "no start flag"; fi
no_marker

# ── 3. --no-pull with no usable deploy record: no restore target ────────────
setup_no_pull_case() {  # setup_no_pull_case <dir-name> [last-deployed-SHA content]
    CASE_DIR="$WORK/cases/$1"
    mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"; export CASE_DIR
    PROJECT_ROOT="$CASE_DIR/dtk"; export PROJECT_ROOT
    cp -R "$TEMPLATE" "$PROJECT_ROOT"
    g -C "$PROJECT_ROOT" fetch origin
    g -C "$PROJECT_ROOT" merge --ff-only origin/dev
    g -C "$PROJECT_ROOT" submodule update --init --recursive
    export DTK_TEST_STATE="$CASE_DIR/state"
    mkdir -p "$DTK_TEST_STATE/backups"
    [ -z "${2:-}" ] || echo "$2" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
    touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
    echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"
    echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
    echo "A" > "$CASE_DIR/sys/started"
    echo "schema-A" > "$CASE_DIR/db_state"
    : > "$CASE_DIR/log"
}
run_no_pull() {
    OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 \
        bash "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes 2>&1 </dev/null)"
    RC=$?
    echo "$OUT" > "$CASE_DIR/out"
}
for rec in "" "unknown"; do
    setup_no_pull_case "no-pull-record-${rec:-absent}" "$rec"
    CASE="--no-pull, deploy record '${rec:-absent}': refused before any change"
    FAKE_MIGRATE_FAIL=1 run_no_pull
    eq "$RC" 1 "exit status"
    head_is "$SHA_B" "B (as put in place)"
    has "There is no record of which version this unit is running"
    has "sudo tee $DTK_TEST_STATE/backups/last-deployed-SHA"
    unlogged "build frontend"
    unlogged "systemctl stop"
    unlogged "docker tag"
    db_is schema-A
    no_marker
done
setup_no_pull_case "no-pull-record-full" "$SHA_A"
CASE="--no-pull, a deploy record as older update.sh writes it (full SHA)"
DTK_UPDATE_FAIL_AT=build run_no_pull
head_is "$SHA_A" A
has "code: $SHA_A (the last deployed version)"

# ── 4/5. rollback-update.sh refusals ────────────────────────────────────────
FAKE_HEALTHY_VERSIONS="A" run_case "rollback with a backend that will not stop" --yes
CASE="rollback with a backend that will not stop: the rollback"
FAKE_PGREP_STUCK=1 run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "The backend did not stop"
unlogged "psql DROP"
db_is migrated
head_is "$SHA_B" "B (nothing moved)"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi

FAKE_MIGRATE_FAIL=1 FAKE_PGREP_STUCK_AFTER_MIGRATE=1 run_case "update.sh restore with a backend running" --yes
eq "$RC" 1 "exit status"
unlogged "psql DROP"
db_is migrated
has "a backend was running; nothing was dropped"
marker_has "kind: restore-refused"
inactive

# ── 6. Partial code restore: superproject back, a submodule not ─────────────
FAKE_MIGRATE_FAIL=1 FAKE_LOCK_SUBMODULE_ON_MIGRATE=1 run_case "partial code restore" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" "A (superproject)"
marker_has "kind: migrated-not-restored"
marker_has "code-commit: $SHA_A"
CASE="partial code restore: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
has "only part-way"
CASE="partial code restore: the rollback names the off-pin submodule"
rm -f "$PROJECT_ROOT/.git/modules/backend/index.lock"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "A submodule is not on the commit the superproject pins"
CASE="partial code restore: after the submodules are put on their pins"
g -C "$PROJECT_ROOT" submodule update --init --recursive
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
db_is restored
no_marker
active

# ── 8/10. --resolve-forward checks ──────────────────────────────────────────
FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward with a backend process left" --yes
CASE="resolve forward with a backend process left: resolve"
FAKE_PGREP_STUCK=1 run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
has "a backend process is running"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi

FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward with a staged change" --yes
echo "staged edit" >> "$PROJECT_ROOT/README"
g -C "$PROJECT_ROOT" add README
git -C "$PROJECT_ROOT" show HEAD:README > "$PROJECT_ROOT/README"
CASE="resolve forward with a staged change: resolve"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
has "modified tracked files"

# ── rollback-update.sh writes the record before its own DROP ───────────────
run_case "rollback killed after its DROP" --yes
CASE="rollback killed after its DROP: the rollback"
FAKE_KILL_ON_DROP=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
marker_has "kind: restore-failed"
marker_has "code-commit: $SHA_A"
marker_has "dump-to-restore: $(dump_name)"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the start flag exists"; else fail "no start flag"; fi
CASE="rollback killed after its DROP: a reboot's start"
rm -f "$CASE_DIR/sys/active"; : > "$CASE_DIR/log"
PATH="$FAKEBIN:$PATH" systemctl start dtk
inactive
CASE="rollback killed after its DROP: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "An earlier update was left unresolved"
has "A rollback dropped the database and did not finish loading its backup"
CASE="rollback killed after its DROP: a second rollback completes"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
db_is restored
no_marker
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the start flag remains"; else ok "the start flag is removed"; fi
active

run_case "rollback whose load fails" --yes
CASE="rollback whose load fails: the rollback"
FAKE_RESTORE_FAIL=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
marker_has "kind: restore-failed"
has "update.sh refuses to run and dtk will"
inactive
CASE="rollback whose load fails: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
CASE="rollback whose load fails: the retry"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
no_marker
active

run_case "rollback that succeeds leaves nothing" --yes
CASE="rollback that succeeds leaves nothing: the rollback"
run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
no_marker
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "a start flag remains"; else ok "no start flag"; fi
active

# ── 3. After step 8 starts B: the record says so, flag or not ───────────────
FAKE_KILL_ON_HEALTH=1 run_case "power cut while waiting for health" --yes
marker_has "kind: started-failed"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "a start flag exists"; else ok "no start flag (B was started)"; fi
CASE="power cut while waiting for health: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "The unit was NOT kept stopped"
has "may have taken writes"
hasnt "The unit was left stopped."

CASE_DIR="$WORK/cases/pipe-closes"; mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"; export CASE_DIR
PROJECT_ROOT="$CASE_DIR/dtk"; export PROJECT_ROOT; cp -R "$TEMPLATE" "$PROJECT_ROOT"
export DTK_TEST_STATE="$CASE_DIR/state"; mkdir -p "$DTK_TEST_STATE/backups"
echo "$SHA_A" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"; echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
echo A > "$CASE_DIR/sys/started"; echo schema-A > "$CASE_DIR/db_state"
CASE="output closes after B fails health"
PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 FAKE_HEALTHY_VERSIONS=A \
    bash -c 'bash "$PROJECT_ROOT/scripts/update.sh" --yes </dev/null 2>&1; echo $? > "$CASE_DIR/rc"' \
    | awk '/did not come up/ {exit}'
for i in $(seq 1 50); do [ -s "$CASE_DIR/rc" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
eq "$(cat "$CASE_DIR/rc")" 1 "exit status (not killed by SIGPIPE)"
marker_has "kind: started-failed"
eq "$(grep -cv '^[a-z-]*: ' "$DTK_TEST_STATE/$MARKER_REL")" 0 "the record holds only its fields (no output leaked into it)"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the start flag exists"; else fail "no start flag"; fi
inactive
if ls "$DTK_TEST_STATE/backups"/update-failure-*.log >/dev/null 2>&1 \
   && grep -q "UPDATE FAILED after the new version was started" "$DTK_TEST_STATE/backups"/update-failure-*.log; then
    ok "the trap's output is in the failure log"
else
    fail "no failure log with the trap's output"
fi

# ── 4. A flag without a record ──────────────────────────────────────────────
CASE_DIR="$WORK/cases/record_cannot_be_written_before_the_migration"; mkdir -p "$CASE_DIR"
export DTK_TEST_STATE="$CASE_DIR/state"
mkdir -p "$DTK_TEST_STATE/backups/unresolved-deployment.tmp"   # blocks the record's write
run_case "record cannot be written before the migration" --yes
eq "$RC" 1 "exit status"
has "not migrating without them"
unlogged "pixi run db-upgrade"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the start flag remains"; else ok "the start flag is removed"; fi
started "A A "
active
has "back online on the previous version"
rmdir "$DTK_TEST_STATE/backups/unresolved-deployment.tmp"

run_case "flag without a record" --yes
mkdir -p "$DTK_TEST_STATE/etc-dtk"; : > "$DTK_TEST_STATE/etc-dtk/unresolved-deployment"
CASE="flag without a record: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "exists without its record"
has "sudo rm $DTK_TEST_STATE/etc-dtk/unresolved-deployment"
unlogged "git"

# ── 5. The pull path with no deploy record: the rollback target is recorded ─
CASE_DIR="$WORK/cases/pull-no-record"; mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"; export CASE_DIR
PROJECT_ROOT="$CASE_DIR/dtk"; export PROJECT_ROOT; cp -R "$TEMPLATE" "$PROJECT_ROOT"
export DTK_TEST_STATE="$CASE_DIR/state"; mkdir -p "$DTK_TEST_STATE/backups"
touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"; echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
echo A > "$CASE_DIR/sys/started"; echo schema-A > "$CASE_DIR/db_state"
CASE="pull path, no deploy record, migration and restore fail"
FAKE_MIGRATE_FAIL=1 FAKE_RESTORE_FAIL=1 run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
eq "$(cat "$DTK_TEST_STATE/backups/pre-update-SHA" 2>/dev/null)" "$SHA_A" "pre-update-SHA names the commit restored to"
marker_has "kind: restore-failed"
CASE="pull path, no deploy record: the rollback completes"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
head_is "$SHA_A" A
db_is restored
no_marker
active

# ── 6. A refused restore has its own kind ───────────────────────────────────
FAKE_MIGRATE_FAIL=1 FAKE_PGREP_STUCK_AFTER_MIGRATE=1 run_case "restore refused, its record" --yes
marker_has "kind: restore-refused"
marker_has "code-commit: $SHA_A"
CASE="restore refused, its record: update.sh refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
has "the database restore was"
has "nothing was dropped"
hasnt "may be empty or partly restored"
CASE="restore refused, its record: --resolve-forward refuses"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
has "kind: restore-refused"

# ── 7. --resolve-forward --no-start ─────────────────────────────────────────
FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward without starting" --yes
CASE="resolve forward without starting: resolve"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward --no-start
eq "$RC" 0 "exit status"
no_marker
inactive
unlogged "systemctl start"
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_B" "last-deployed-SHA names B"
if [ -e "$DTK_TEST_STATE/backups/last-deployed-frontend" ]; then fail "a frontend record remains"; else ok "no frontend record for an unstarted version"; fi
has "Deploy the fixed version"
CASE="resolve forward without starting: an ordinary update then runs"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 0 "exit status"
has "Update complete!"
active
CASE="--no-start alone"
run_again "$PROJECT_ROOT/scripts/update.sh" --no-start
eq "$RC" 2 "exit status"

# ── The start guard cannot be put in place: no migration, no DROP ──────────
for blocker in etc-dtk systemd/dtk.service.d; do
    name="guard blocked by $blocker"
    CASE_DIR="$WORK/cases/$(echo "$name" | tr ' /' '__')"; mkdir -p "$CASE_DIR/state/$(dirname "$blocker")"
    : > "$CASE_DIR/state/$blocker"      # a file where a directory must go
    FAKE_MIGRATE_FAIL=1 run_case "$name" --yes
    eq "$RC" 1 "exit status"
    has "not migrating without them"
    unlogged "pixi run db-upgrade"
    unlogged "psql DROP"
    db_is schema-A
    no_marker
    head_is "$SHA_A" A
    started "A A "
    active
done

# The drop-in's directory blocked only once the migration has run.
CASE_DIR="$WORK/cases/guard-at-drop"; mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"; export CASE_DIR
PROJECT_ROOT="$CASE_DIR/dtk"; export PROJECT_ROOT; cp -R "$TEMPLATE" "$PROJECT_ROOT"
export DTK_TEST_STATE="$CASE_DIR/state"; mkdir -p "$DTK_TEST_STATE/backups"
echo "$SHA_A" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"; echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
echo A > "$CASE_DIR/sys/started"; echo schema-A > "$CASE_DIR/db_state"
CASE="guard fails at the restore's DROP"
FAKE_MIGRATE_FAIL=1 FAKE_BLOCK_GUARD_ON_MIGRATE=1 run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
unlogged "psql DROP"
db_is migrated
marker_has "kind: restore-refused"
marker_has "refused-because: the start guard (flag or drop-in) could not be put in place"
has "nothing was dropped"
inactive

# ── The restore target when last-deployed-SHA does not resolve ──────────────
FAKE_HEALTHY_VERSIONS="A" run_case "deploy record that is not a commit" --yes   # builds the case
rm -rf "$CASE_DIR"; mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"
cp -R "$TEMPLATE" "$PROJECT_ROOT"; mkdir -p "$DTK_TEST_STATE/backups"
echo "0000000000000000000000000000000000000000" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"; echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
echo A > "$CASE_DIR/sys/started"; echo schema-A > "$CASE_DIR/db_state"
CASE="deploy record that is not a commit: started-failed"
FAKE_HEALTHY_VERSIONS="A" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
marker_has "restore-target: $SHA_A"
eq "$(cat "$DTK_TEST_STATE/backups/pre-update-SHA")" "$SHA_A" "pre-update-SHA agrees with the record"
CASE="deploy record that is not a commit: the rollback accepts the record"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
head_is "$SHA_A" A
no_marker

# ── Staged submodule pointers are not the commit's pins ────────────────────
# Restore target A is already checked out (--no-pull, a redeploy), but the
# backend gitlink is staged to B's pin with the submodule on it: the restore
# must not certify "still on A with submodules on its pins".
FAKE_STAGE_BACKEND_PIN="$BACKEND_B" DTK_UPDATE_FAIL_AT=build run_case "staged gitlink at the restore" --no-pull --yes
eq "$RC" 1 "exit status"
hasnt "code: still on $SHA_A with submodules on its pins"
has "code: the checkout has modified tracked files"
eq "$(git -C "$PROJECT_ROOT/backend" rev-parse HEAD)" "$BACKEND_B" "the staged pin was not discarded"

FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward with a staged gitlink" --yes
stage_backend_pin "$BACKEND_A"
CASE="resolve forward with a staged gitlink: resolve"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
hasnt "Recorded $SHA_B as the deployed version"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_A" "last-deployed-SHA still names A"

FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward with a submodule off HEAD's pin" --yes
# The index matches HEAD; only the submodule's own checkout differs.
g -C "$PROJECT_ROOT/backend" checkout -q "$BACKEND_A"
CASE="resolve forward with a submodule off HEAD's pin: resolve"
run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 1 "exit status"
hasnt "Recorded $SHA_B as the deployed version"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi

FAKE_HEALTHY_VERSIONS="A" run_case "rollback with a staged gitlink" --yes
stage_backend_pin "$BACKEND_A"
CASE="rollback with a staged gitlink: the rollback"
run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "has local changes"
unlogged "psql DROP"
if [ -e "$DTK_TEST_STATE/$MARKER_REL" ]; then ok "the record stays"; else fail "the record was removed"; fi

# ── One update or rollback at a time ────────────────────────────────────────
run_case "two runs at once" --yes   # builds the case; reset to A below
rm -rf "$CASE_DIR"; mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"
cp -R "$TEMPLATE" "$PROJECT_ROOT"
mkdir -p "$DTK_TEST_STATE/backups"; echo "$SHA_A" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"; echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
echo A > "$CASE_DIR/sys/started"; echo schema-A > "$CASE_DIR/db_state"
( PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 FAKE_SLOW_INSTALL=1 \
    bash "$PROJECT_ROOT/scripts/update.sh" --yes > "$CASE_DIR/out1" 2>&1 </dev/null; echo $? > "$CASE_DIR/rc1" ) &
FIRST=$!
for i in $(seq 1 50); do [ -s "$DTK_TEST_STATE/dtk-update.lock" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
CASE="two runs at once: the second update.sh"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "Another update or rollback is running (pid"
unlogged "pixi run db-upgrade"
CASE="two runs at once: a rollback meanwhile"
run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$DTK_TEST_STATE/backups/none.sql.gz"
eq "$RC" 1 "exit status"
has "Another update or rollback is running"
wait "$FIRST"
CASE="two runs at once: the first"
eq "$(cat "$CASE_DIR/rc1")" 0 "the first run completed"
CASE="two runs at once: afterwards"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
hasnt "Another update or rollback is running"

# ── The fetch fails: nothing has moved ──────────────────────────────────────
FAKE_BREAK_ORIGIN=1 run_case "fetch fails" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
db_is schema-A
active
unlogged "systemctl stop"
has "Nothing changed."
no_marker

# ── Before the stop, the code cannot be moved back (no migration) ───────────
# The database and last-deployed-SHA still name A and A is what runs; only the
# checkout is B. No record: a retry is the repair, since its restore target A
# matches the database, and its step 0b sets the modification aside.
FAKE_DIRTY_ON_PIXI_INSTALL=1 DTK_UPDATE_FAIL_AT=pixi run_case "code not restored before the stop" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_B" "B (left in the checkout)"
db_is schema-A
active
unlogged "systemctl stop"
has "The checkout is NOT on the version that is running"
no_marker
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_A" "last-deployed-SHA still names A, which is running"
CASE="code not restored before the stop: a retry"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 0 "exit status"
has "locally modified files"
head_is "$SHA_B" B
db_is migrated
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_B" "last-deployed-SHA names B"

# ── After the stop, before any migration, the code cannot be moved back ─────
FAKE_DIRTY_ON_STOP=1 DTK_UPDATE_FAIL_AT=stopped run_case "code not restored after the stop" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_B" "B (left in the checkout)"
db_is schema-A
inactive
has "The database was not changed by this update"
no_marker
CASE="code not restored after the stop: a retry"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
active
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_B" "last-deployed-SHA names B"

# ── After a migration, the frontend image cannot be put back ────────────────
FAKE_MIGRATE_FAIL=1 FAKE_RETAG_FAIL=1 run_case "frontend not put back after the stop" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
db_is restored
active
if [ -e "$DTK_TEST_STATE/backups/last-deployed-frontend" ]; then fail "last-deployed-frontend still names A's image"; else ok "last-deployed-frontend removed"; fi
has "frontend record:"
eq "$(cat "$DTK_TEST_STATE/backups/last-deployed-SHA")" "$SHA_A" "last-deployed-SHA names A"
no_marker

# ── Restore fails: the database restore fails ───────────────────────────────
FAKE_MIGRATE_FAIL=1 FAKE_RESTORE_FAIL=1 run_case "database restore fails" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
started "A "
inactive
has "database: the restore from $(dump_name) FAILED"
has "has NOT been started"
has "--yes $(dump_name)"
hasnt "back online"

# ── Offline: the old pixi environment cannot be reinstalled ─────────────────
FAKE_MIGRATE_FAIL=1 FAKE_PIXI_FAIL_LOCK=lock-A run_case "pixi restore offline" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
db_is restored
has "THE PIXI ENVIRONMENT COULD NOT BE REINSTALLED"
has "pixi environment: reinstall for the restored lock FAILED"

# ── --no-pull: code put in place by hand, failure after the stop ────────────
CASE_DIR="$WORK/cases/no-pull"
mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"
export CASE_DIR
PROJECT_ROOT="$CASE_DIR/dtk"; export PROJECT_ROOT
cp -R "$TEMPLATE" "$PROJECT_ROOT"
g -C "$PROJECT_ROOT" fetch origin
g -C "$PROJECT_ROOT" merge --ff-only origin/dev
g -C "$PROJECT_ROOT" submodule update --init --recursive
export DTK_TEST_STATE="$CASE_DIR/state"
mkdir -p "$DTK_TEST_STATE/backups"
echo "$SHA_A" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"
echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
echo "A" > "$CASE_DIR/sys/started"
echo "schema-A" > "$CASE_DIR/db_state"
CASE="no-pull, fail after stop"
OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 DTK_UPDATE_FAIL_AT=stopped \
    bash "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes 2>&1 </dev/null)"
RC=$?
echo "$OUT" > "$CASE_DIR/out"
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
backend_is "$BACKEND_A" A
tag_is "$OLD_IMG" "the old image"
db_is schema-A
started "A A "
active
has "database: untouched"
has "back online on the previous version"
if grep -q "fetch" "$CASE_DIR/log" 2>/dev/null; then fail "--no-pull fetched"; else ok "--no-pull did not fetch"; fi

# ── The test-only switch refuses an unknown point ───────────────────────────
DTK_UPDATE_FAIL_AT=nowhere run_case "unknown failure point" --yes
eq "$RC" 2 "exit status"
head_is "$SHA_A" A
has "is not a failure point"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
