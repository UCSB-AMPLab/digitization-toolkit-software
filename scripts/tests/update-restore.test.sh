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
        rm -f "$S/active"; exit 0 ;;
    start)
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
        if [ -n "${FAKE_PIXI_FAIL_LOCK:-}" ] && [ "$lock" = "$FAKE_PIXI_FAIL_LOCK" ]; then
            echo "pixi: cannot reach the registry" >&2; exit 1
        fi
        echo "$lock" > "$CASE_DIR/pixi_env" ;;
    run)
        if [ "$2" = alembic ] && [ "$3" = heads ]; then
            echo "${FAKE_ALEMBIC_HEAD:-rev-B} (head)"
        fi
        if [ "$2" = db-upgrade ]; then
            echo migrated > "$CASE_DIR/db_state"
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
                    if [ -t 0 ]; then :; else
                        input="$(cat)"
                        if [ -n "$input" ]; then
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
cat > "$FAKEBIN/pgrep" <<'EOF2'
#!/bin/sh
[ -n "${FAKE_PGREP_STUCK:-}" ] && { echo 4243; exit 0; }
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
sed "s#/var/lib/dtk#\$DTK_TEST_STATE#g" "$SCRIPTS/update.sh" > "$UP/super/scripts/update.sh"
sed "s#/var/lib/dtk#\$DTK_TEST_STATE#g" "$SCRIPTS/rollback-update.sh" > "$UP/super/scripts/rollback-update.sh"
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

# The unit: a clone on dev at A, tracking the remote's dev (at B).
TEMPLATE="$WORK/template"
git clone -q "$UP/super" "$TEMPLATE" 2>/dev/null
g -C "$TEMPLATE" reset --hard "$SHA_A"
g -C "$TEMPLATE" submodule update --init --recursive
if [ "$(git -C "$TEMPLATE" rev-parse HEAD)" != "$SHA_A" ] || [ ! -f "$TEMPLATE/backend/pixi.lock" ]; then
    echo "fixture: could not build the unit checkout"; exit 1
fi

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

FAKE_HEALTHY_VERSIONS="A" FAKE_PGREP_STUCK=1 run_case "backend does not stop" --yes
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
