#!/bin/bash
# Update Digitization Toolkit to the latest committed code.
#
# This script guards IRREPLACEABLE archival data. It is designed to be safe to
# run on a live Pi at a remote venue, possibly by non-technical staff:
#
#   • All network / compile work (frontend build, pixi install) happens BEFORE
#     the running service is stopped, so a failure there leaves the old, working
#     stack untouched and still serving.
#   • Before any migration a timestamped pg_dump is taken with the backend
#     stopped, so nothing written before the stop is missing from it, and
#     verified non-empty (a trial dump while still serving checks pg_dump and
#     free space before any downtime, and is deleted once that one verifies);
#     the pre-update superproject commit is recorded so a botched update can be
#     rolled back with scripts/rollback-update.sh.
#   • Before anything changes, it records what is running: the deployed commit,
#     the frontend image (kept under a pre-update-<timestamp> tag) and the
#     backend lock. If anything fails after the code has moved, an EXIT trap
#     restores the previous version: the checkout and submodules, the frontend
#     image, the pixi environment, and the database from that stopped-backend
#     dump if a migration had begun. It starts the service only once those are
#     back, and says the unit is online only when the backend answers /health.
#     Once the new version has been started (step 8), nothing is restored
#     automatically: it may have saved data. The script stops it, leaves the
#     unit stopped on the new code and migrated database, and prints the
#     rollback command with its data-loss warning instead.
#   • Before starting, it checks whether the update changed dependency manifests
#     (which need the npm / conda registries) and, if so, warns the operator that
#     internet is required and lets them abort.
#
# For a network-connected Pi (fetch the latest tested code this repo pins):
#   sudo ./scripts/update.sh
# The script pulls and syncs submodules itself, and sets aside any local
# modifications first (NEH-270) — the operator no longer has to run git.
#
# For an offline update from a USB drive, copy the new repo content into place
# first, then run with --no-pull so the script does not try to reach the
# remote.
#
# Usage: sudo ./scripts/update.sh [--yes] [--no-pull]
#        sudo ./scripts/update.sh --resolve-forward
#   --yes       Skip the "this update needs internet" confirmation prompt
#               (for scripted / unattended use).
#   --no-pull   Do not fetch; update to whatever is already checked out.
#               For offline updates, and for testing a specific commit.
#   --resolve-forward
#               After an update that failed once its new version had started
#               (see UNRESOLVED_FILE below), accept that version as deployed
#               instead of rolling back: checked only, then recorded, then
#               started. It changes no code and no data.
#
# Test only: DTK_UPDATE_FAIL_AT=<point> makes the script fail on purpose at
# one point, so the restore path can be exercised on a bench unit without a
# broken migration or a broken build. The points, in order:
#   fetched   after the fast-forward and submodule sync (pull path only)
#   build     after the frontend image is rebuilt
#   pixi      after the pixi environment is reinstalled
#   stopped   after the service is stopped
#   dumped    after the backup taken with the backend stopped
#   migrate   after the migrations have run
#   started   after the new version is started, before its health check
#   served    after the new version has answered /health
# Never set it on an appliance in service.
#
# Also tunable: DTK_UPDATE_HEALTH_TIMEOUT (seconds to wait for /health after a
# start, default 300) and DTK_UPDATE_HEALTH_POLL (seconds between tries,
# default 5).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ASSUME_YES=0
DO_PULL=1
RESOLVE_FORWARD=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-pull) DO_PULL=0 ;;
        --resolve-forward) RESOLVE_FORWARD=1 ;;
        *) echo "Unknown argument: $arg"; echo "Usage: sudo ./scripts/update.sh [--yes] [--no-pull] | --resolve-forward"; exit 2 ;;
    esac
done

FAIL_AT="${DTK_UPDATE_FAIL_AT:-}"
case "$FAIL_AT" in
    ""|fetched|build|pixi|stopped|dumped|migrate|started|served) ;;
    *) echo "✗ DTK_UPDATE_FAIL_AT='$FAIL_AT' is not a failure point this script knows."
       echo "  Known: fetched build pixi stopped dumped migrate started served (test only)."
       exit 2 ;;
esac
HEALTH_TIMEOUT="${DTK_UPDATE_HEALTH_TIMEOUT:-300}"
HEALTH_POLL="${DTK_UPDATE_HEALTH_POLL:-5}"

# Load DB credentials the same way docker compose does: from the project .env.
# The bare ${VAR:-default} fallbacks below only apply if .env is absent, so the
# pg_dump and pg_isready calls talk to the DB with the SAME user the container
# was created with.
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_ROOT/.env"
    set +a
fi
DATABASE_USER="${DATABASE_USER:-user}"
DATABASE_NAME="${DATABASE_NAME:-digitization_toolkit}"

# Resolve real user. The fallback is the CHECKOUT'S OWNER, not whoami: with no
# SUDO_USER -- a systemd unit, NEH-186's admin-triggered path -- whoami is root,
# and then PIXI_BIN below becomes /root/.pixi/bin/pixi, which does not exist on
# a unit where pixi was installed for the appliance user. Confirmed on the bench
# unit 2026-10-20: the frontend image rebuilt and the deploy then stopped at
# `pixi install` with "env: '/root/.pixi/bin/pixi': No such file or directory".
# Routing git through the checkout's owner (REPO_USER below) fixed the git half
# of this; the pixi and migration calls still went through DTK_USER.
if [ -n "$SUDO_USER" ]; then
    DTK_USER="$SUDO_USER"
else
    DTK_USER="$(stat -c %U "$PROJECT_ROOT" 2>/dev/null || whoami)"
fi
DTK_USER_HOME=$(eval echo "~$DTK_USER")
PIXI_BIN="$DTK_USER_HOME/.pixi/bin/pixi"

run_as_user() {
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" PATH="$DTK_USER_HOME/.pixi/bin:$PATH" "$@"
}

# Who git must run as: the repository's actual owner, asked of the filesystem
# rather than inferred. DTK_USER comes from SUDO_USER and falls back to
# whoami, so in a service context with no SUDO_USER it resolves to root — and
# `sudo -u root git` then hits exactly the dubious-ownership failure that
# routing git through a helper was supposed to avoid (NEH-271), because root's
# global config carries no safe.directory. The owner's HOME also matters: the
# insteadOf rewrite that lets .gitmodules' SSH URLs resolve (NEH-217) lives in
# that user's global config, not root's.
REPO_USER="$(stat -c %U "$PROJECT_ROOT" 2>/dev/null || true)"
[ -n "$REPO_USER" ] || REPO_USER="$DTK_USER"
REPO_USER_HOME=$(eval echo "~$REPO_USER")
run_as_repo_owner() {
    sudo -u "$REPO_USER" env HOME="$REPO_USER_HOME" "$@"
}

COMPOSE="docker compose -f $PROJECT_ROOT/docker-compose.yml -f $PROJECT_ROOT/docker-compose.pi.yml"

# Backup location (also used by rollback-update.sh — keep these in sync).
BACKUP_DIR="/var/lib/dtk/backups"
SHA_FILE="$BACKUP_DIR/pre-update-SHA"
REF_FILE="$BACKUP_DIR/pre-update-ref"
# Written when an update fails after the new version was started: the code is
# the new version's and the database is migrated for it, while
# last-deployed-SHA still names the previous version. Until it is resolved
# (rollback-update.sh removes it after a successful rollback), this script
# refuses to run: a retry would take the previous version as its restore
# target and restore or start it over a database migrated for the new one.
# rollback-update.sh reads the same path; keep the two in sync.
UNRESOLVED_FILE="$BACKUP_DIR/unresolved-deployment"
# Frontend image that was serving when LAST_DEPLOYED_SHA_FILE's commit was
# successfully deployed ("sha:" and "image:" lines; written only on success).
LAST_DEPLOYED_FRONTEND_FILE="$BACKUP_DIR/last-deployed-frontend"
LAST_DEPLOYED_SHA_FILE="$BACKUP_DIR/last-deployed-SHA"
KEEP_DUMPS=5
# State kept outside the checkout. rollback-update.sh keeps its copy of itself
# here; update.sh puts one there before a restore moves scripts/ (below).
STATE_DIR="/var/lib/dtk"
ROLLBACK_SCRIPT_COPY="$STATE_DIR/rollback-update.sh"

# The dumps hold every account's password hash (users.hashed_password), so
# the directory and the dumps in it are root's alone. Until October 2026 the
# dumps were written under root's default umask, 0644 in a 0755 directory,
# readable by any local user; found on the bench unit. Nothing that runs as
# another user reads this directory: update.sh and rollback-update.sh both run
# as root, setup.sh writes last-deployed-SHA as root, and the backend writes
# its own catalogue dumps to /var/lib/dtk/tmp (backend
# app/core/catalogue_backup.py, _dump_dir), not here. So the state files
# beside the dumps (pre-update-SHA, pre-update-ref, pre-update-state-*,
# last-deployed-*) keep their 0644 and are private through the directory.
#
# secure_backup_dir: create the directory, or find it, and make it root:root
# 0700. A symlink or a non-directory at the path is refused: chown and chmod
# follow a symlink and would act on whatever it names.
secure_backup_dir() {
    if [ -L "$BACKUP_DIR" ]; then
        echo "✗ $BACKUP_DIR is a symbolic link. The pre-update backups hold"
        echo "  password hashes and must be in a directory of their own. Move the"
        echo "  link aside and run this again."
        return 1
    fi
    if [ -e "$BACKUP_DIR" ] && [ ! -d "$BACKUP_DIR" ]; then
        echo "✗ $BACKUP_DIR exists and is not a directory. Move it aside and run"
        echo "  this again."
        return 1
    fi
    local was_open=0
    if [ -d "$BACKUP_DIR" ] && [ -z "$(find "$BACKUP_DIR" -maxdepth 0 -perm 0700 2>/dev/null)" ]; then
        was_open=1
    fi
    if ! { mkdir -p "$BACKUP_DIR" && chown root:root "$BACKUP_DIR" && chmod 0700 "$BACKUP_DIR"; }; then
        echo "✗ Could not make $BACKUP_DIR private (root:root, mode 0700)."
        echo "  Aborting before a new backup is written into it."
        return 1
    fi
    if [ "$was_open" -eq 1 ]; then
        echo "  Backup directory $BACKUP_DIR set to owner root, mode 0700:"
        echo "  it was readable by other local users."
    fi
}

# tighten_existing_dumps: set every dump already in the directory to 0600.
# Dumps from earlier updates were written 0644. Symlinks are skipped (find
# does not follow them), so nothing outside the directory is changed.
tighten_existing_dumps() {
    local open count=0 f
    open="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'pre-update-*.sql.gz' ! -perm 0600 2>/dev/null)"
    [ -n "$open" ] || return 0
    while IFS= read -r f; do
        if chmod 0600 "$f"; then
            count=$((count + 1))
        else
            echo "  ⚠ Could not set $f to mode 0600."
        fi
    done <<< "$open"
    if [ "$count" -gt 0 ]; then
        echo "  Tightened $count earlier pre-update backups to mode 0600: they hold"
        echo "  every account's password hash and were readable by other local users."
    fi
}

# write_dump <file> <command...>: run the command and write its output,
# gzipped, to <file>, created 0600 from the start. The umask is set in a
# subshell for this pipeline only, so the file is never readable by others,
# not even while it is being written; chmod after the write would leave that
# window. pipefail so a failing command fails the call although gzip exits 0.
write_dump() {
    local file="$1"
    shift
    ( umask 077; set -o pipefail; "$@" | gzip > "$file" )
}

cd "$PROJECT_ROOT"

# An earlier update was left unresolved (see UNRESOLVED_FILE). Refuse before
# anything is fetched, built, stopped or written. The record has two kinds:
#   started-failed  the new version was started and the update then failed;
#                   the database is migrated for it (the default for records
#                   written before the field existed)
#   restore-failed  the automatic database restore failed after the database
#                   had been dropped; only the rollback can repair it
record_field() {
    sed -n "s/^$1: //p" "$UNRESOLVED_FILE" 2>/dev/null | head -n 1
}
UNRESOLVED_KIND=""
if [ -e "$UNRESOLVED_FILE" ] || [ -L "$UNRESOLVED_FILE" ]; then
    UNRESOLVED_KIND="$(record_field kind)"
    [ -n "$UNRESOLVED_KIND" ] || UNRESOLVED_KIND=started-failed
fi
if [ -n "$UNRESOLVED_KIND" ] && [ "$RESOLVE_FORWARD" -ne 1 ]; then
    echo "✗ An earlier update was left unresolved, so this update will not run."
    echo ""
    if [ "$UNRESOLVED_KIND" = restore-failed ]; then
        echo "  That update failed, and restoring the database from its backup then"
        echo "  failed too: the database may be empty or partly restored. The unit"
        echo "  was left stopped. It recorded, in $UNRESOLVED_FILE:"
    else
        echo "  That update started the new version and then failed. The unit was"
        echo "  left stopped, on the new code, with the database migrated for it. It"
        echo "  recorded, in $UNRESOLVED_FILE:"
    fi
    sed 's/^/      /' "$UNRESOLVED_FILE" 2>/dev/null || echo "      (the record could not be read)"
    echo ""
    if [ "$UNRESOLVED_KIND" = restore-failed ]; then
        echo "  The way forward is to restore the database from that backup, with:"
        echo "       $(record_field rollback-command)"
        echo "  It removes this record when it succeeds."
    else
        echo "  Two ways forward:"
        echo "  1. Return to the previous version, code and database:"
        echo "       $(record_field rollback-command)"
        echo "     It discards everything written since that backup. It removes this"
        echo "     record when it succeeds."
        echo "  2. Keep the failed version, once whatever stopped it is fixed:"
        echo "       sudo $SCRIPT_DIR/update.sh --resolve-forward"
        echo "     It checks that the code is that version and that the database is at"
        echo "     its migration head, records it as deployed and starts it."
    fi
    exit 1
fi
if [ "$RESOLVE_FORWARD" -eq 1 ] && [ -z "$UNRESOLVED_KIND" ]; then
    echo "✗ --resolve-forward: there is no unresolved update to resolve"
    echo "  ($UNRESOLVED_FILE does not exist)."
    exit 2
fi
if [ "$RESOLVE_FORWARD" -eq 1 ] && [ "$UNRESOLVED_KIND" != started-failed ]; then
    echo "✗ --resolve-forward cannot resolve this record (kind: $UNRESOLVED_KIND)."
    echo "  The database restore failed, so there is no version to keep. Restore"
    echo "  the database with:"
    echo "       $(record_field rollback-command)"
    exit 1
fi

echo "=========================================="
echo " Digitization Toolkit — Update"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 0. Safety net. A failure after the code has moved puts the previous
#    version back (step 0a records it). Before the service is stopped, the
#    checkout, frontend image and pixi environment are put back under the
#    version still running. After, the stopped unit also gets its database
#    back from this run's dump if a migration began, and is started on the
#    previous version and checked against /health. The restarted NEW version
#    is never what the trap brings up: after a failed migration it refuses an
#    unmigrated schema and loops under Restart=on-failure.
# ---------------------------------------------------------------------------
SERVICE_STOPPED=0
UPDATE_OK=0
DB_STARTED_BY_US=0
# Set when step 0b discarded local modifications after saving them. The abort
# message must not then say "nothing changed" — same standard as NEH-215.
TREE_TOUCHED=0
MODS_DIR=""
# Set the moment anything changes container state before the service stop —
# the abort message must never claim "nothing changed" after that (NEH-215).
STACK_TOUCHED=0
DUMP_FILE=""
BACKUP_VERIFIED=0

# What this run has changed, so a failure undoes exactly that (see 0a).
# RESTORE_ARMED: the checkout may no longer be the version that is running —
# set just before the fast-forward, and before the build on --no-pull.
RESTORE_ARMED=0
BUILD_STARTED=0
PIXI_INSTALL_STARTED=0
MIGRATION_STARTED=0
# The dump a failed update restores (step 7, backend stopped), and whether the
# new version has served since step 8 started it.
RESTORE_DUMP=""
RESTORE_DUMP_VERIFIED=0
NEW_STARTED_AT=""
NEW_SERVED=0
MIGRATED_REVISION=""
# Filled in by step 0a.
RESTORE_SHA=""
RESTORE_SHA_SOURCE=""
SAVED_FRONTEND_IMAGE=""
SAVED_FRONTEND_TAG=""
FRONTEND_IMAGE=""
NEW_LOCK_DIGEST=""
# What the restore did and did not do, printed together at the end.
RESTORED_LINES=""
NOT_RESTORED_LINES=""
CODE_RESTORED=0
ROLLBACK_CMD="sudo $SCRIPT_DIR/rollback-update.sh"

note_restored()    { RESTORED_LINES="${RESTORED_LINES}    • $1"$'\n'; }
note_not_restored() { NOT_RESTORED_LINES="${NOT_RESTORED_LINES}    • $1"$'\n'; }

# Test only (see the header): fail here when DTK_UPDATE_FAIL_AT names this point.
fail_point() {
    if [ "$FAIL_AT" = "$1" ]; then
        echo "✗ DTK_UPDATE_FAIL_AT=$1: failing here on purpose (test only)."
        exit 1
    fi
}

file_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    fi
}

# lock_digest_at <superproject commit>: digest of backend/pixi.lock as that
# commit pins it, read from the backend submodule's objects; empty when the
# pin or the file cannot be read.
lock_digest_at() {
    local pin
    [ -n "$1" ] || return 1
    pin="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$1:backend" 2>/dev/null)" || return 1
    run_as_repo_owner git -C "$PROJECT_ROOT/backend" cat-file -e "$pin:pixi.lock" 2>/dev/null || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        run_as_repo_owner git -C "$PROJECT_ROOT/backend" show "$pin:pixi.lock" 2>/dev/null | sha256sum | cut -d' ' -f1
    else
        run_as_repo_owner git -C "$PROJECT_ROOT/backend" show "$pin:pixi.lock" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
    fi
}

# The name Compose tags the frontend build with. The frontend service has no
# image: key, so the name is implicit (<project>-frontend), and not every
# Compose version reports an implicit name from `config --images`: the bench
# unit's v5.3.1 does. Asked three ways, in order: `config --images frontend`;
# the image reference the running frontend container was created from
# (.Config.Image, which Compose sets to that same name); and <project>-frontend
# from the project name Compose itself resolved (`config`'s name: line, already
# normalised from COMPOSE_PROJECT_NAME or the directory). Empty if none answers.
frontend_image_name() {
    local name cid project
    name="$($COMPOSE config --images frontend 2>/dev/null | head -n 1)"
    if [ -z "$name" ]; then
        cid="$($COMPOSE ps -q frontend 2>/dev/null | head -n 1)"
        [ -n "$cid" ] && name="$(docker container inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)"
    fi
    case "$name" in sha256:*) name="" ;; esac
    if [ -z "$name" ]; then
        project="$($COMPOSE config 2>/dev/null | sed -n 's/^name: *//p' | head -n 1)"
        [ -n "$project" ] && name="$project-frontend"
    fi
    printf '%s' "$name"
}

# Immutable image id of the running frontend container; empty on any error.
frontend_image_id() {
    local cid
    cid="$($COMPOSE ps -q frontend 2>/dev/null | head -n 1)" || return 1
    [ -n "$cid" ] || return 1
    docker container inspect --format '{{.Image}}' "$cid" 2>/dev/null
}

# Is the unit serving? The service active AND the backend answering /health.
# is-active alone is not enough: a backend that refuses to start (a schema
# not at head, assert_schema_at_head in backend app/main.py) exits and is
# started again under Restart=on-failure, and the unit reads as active for
# part of every attempt. ExecStartPost (check-stack-health.sh) keeps the unit
# "activating" until the containers are up, so is-active covers the db and
# frontend; /health covers the backend, which answers only once its startup
# checks have passed.
backend_healthy() {
    systemctl is-active --quiet dtk 2>/dev/null || return 1
    curl -fsS --max-time 5 http://127.0.0.1:8000/health 2>/dev/null | grep -q '"status": *"ok"'
}

# wait_for_health [timeout-seconds]: poll backend_healthy until it holds or
# the timeout passes.
wait_for_health() {
    local timeout="${1:-$HEALTH_TIMEOUT}" start now
    start="$(date +%s)"
    while :; do
        if backend_healthy; then
            return 0
        fi
        now="$(date +%s)"
        if [ $((now - start)) -ge "$timeout" ]; then
            return 1
        fi
        sleep "$HEALTH_POLL"
    done
}

# Tracked files modified anywhere in the checkout? 0 clean, 1 modified,
# anything else a read that failed (treated as modified). Superproject files
# with submodules ignored, then each submodule's own files: a submodule that is
# merely on a different commit is what an interrupted update leaves, and the
# restore moves it; a modified file inside it is someone's work, and the
# restore will not discard it. The same refusal rollback-update.sh makes.
tracked_files_modified() {
    local rc=0 subs sub
    run_as_repo_owner git -C "$PROJECT_ROOT" diff HEAD --quiet --ignore-submodules=all 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    subs="$(run_as_repo_owner git -C "$PROJECT_ROOT" submodule foreach --quiet --recursive 'printf "%s\n" "$displaypath"' 2>/dev/null)" || return 2
    for sub in $subs; do
        run_as_repo_owner git -C "$PROJECT_ROOT/$sub" diff HEAD --quiet 2>/dev/null || rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
    done
    return 0
}

# Return the checkout to RESTORE_SHA with its submodules on that commit's
# pins, by the mechanism rollback-update.sh uses (step 3 there): git as the
# checkout's owner, `checkout --no-overwrite-ignore -B <branch>` so the branch
# moves and HEAD stays attached, `submodule update --init --recursive` with no
# --remote, then HEAD and every submodule verified rather than inferred from
# exit statuses. That script's functions are written against its own globals
# and it runs from a copy of itself outside the checkout, so they are not
# sourced from here.
restore_code() {
    local now branch sub_status rc keep
    if [ -z "$RESTORE_SHA" ]; then
        note_not_restored "code: there is no record of the version that was running, so the checkout was left where it is"
        return 1
    fi
    now="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)"
    if [ -z "$now" ]; then
        note_not_restored "code: git could not read the checkout at $PROJECT_ROOT"
        return 1
    fi
    rc=0
    tracked_files_modified || rc=$?
    if [ "$rc" -ne 0 ]; then
        note_not_restored "code: the checkout has modified tracked files (or could not be read), and this script does not discard them; it is still on $now"
        return 1
    fi
    if [ "$now" = "$RESTORE_SHA" ] \
            && sub_status="$(run_as_repo_owner git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null)" \
            && ! printf '%s\n' "$sub_status" | grep -qv '^ '; then
        CODE_RESTORED=1
        note_restored "code: still on $RESTORE_SHA with submodules on its pins; the update had not moved it"
        return 0
    fi
    if [ "$now" != "$RESTORE_SHA" ]; then
        # The commit being left must stay reachable by name. On the pull path
        # it is the remote's; on --no-pull it may exist only here.
        if [ -z "$(run_as_repo_owner git -C "$PROJECT_ROOT" branch -r --contains "$now" 2>/dev/null)" ]; then
            keep="failed-update/$(date +%Y%m%d-%H%M%S)"
            if run_as_repo_owner git -C "$PROJECT_ROOT" branch "$keep" "$now" 2>/dev/null; then
                echo "  The new version $now is kept as branch '$keep'."
            else
                echo "  ⚠ Could not keep $now as a branch; note it down."
            fi
        fi
        branch="$(run_as_repo_owner git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        if [ -n "$branch" ]; then
            run_as_repo_owner git -C "$PROJECT_ROOT" checkout --quiet --no-overwrite-ignore -B "$branch" "$RESTORE_SHA" || {
                note_not_restored "code: the checkout to $RESTORE_SHA failed (git says why above)"
                return 1
            }
        else
            run_as_repo_owner git -C "$PROJECT_ROOT" checkout --quiet --no-overwrite-ignore "$RESTORE_SHA" || {
                note_not_restored "code: the checkout to $RESTORE_SHA failed (git says why above)"
                return 1
            }
        fi
    fi
    run_as_repo_owner git -C "$PROJECT_ROOT" submodule update --init --recursive || {
        note_not_restored "code: the superproject is on $RESTORE_SHA but the submodules could not be synced to its pins"
        return 1
    }
    now="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)"
    if [ "$now" != "$RESTORE_SHA" ]; then
        note_not_restored "code: HEAD is at '${now:-unreadable}', not at $RESTORE_SHA"
        return 1
    fi
    if ! sub_status="$(run_as_repo_owner git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null)"; then
        note_not_restored "code: on $RESTORE_SHA, but the submodule state could not be read"
        return 1
    fi
    if [ -n "$sub_status" ] && printf '%s\n' "$sub_status" | grep -qv '^ '; then
        note_not_restored "code: on $RESTORE_SHA, but a submodule is not at the commit it pins: $(printf '%s' "$sub_status" | grep -v '^ ' | tr '\n' ';')"
        return 1
    fi
    CODE_RESTORED=1
    note_restored "code: $RESTORE_SHA ($RESTORE_SHA_SOURCE), submodules on its pins:"$'\n'"$(printf '%s\n' "$sub_status" | sed 's/^ */        /')"
    return 0
}

# Point the compose image name back at the image saved in 0a.
restore_frontend_image() {
    [ "$BUILD_STARTED" -eq 1 ] || return 0
    if [ -z "$SAVED_FRONTEND_IMAGE" ] || [ -z "$FRONTEND_IMAGE" ]; then
        note_not_restored "frontend image: no image was recorded before the rebuild, so '${FRONTEND_IMAGE:-the frontend image}' may be the new build. To rebuild it for the restored code: $COMPOSE build frontend (needs the npm registry)"
        return 1
    fi
    if docker tag "$SAVED_FRONTEND_IMAGE" "$FRONTEND_IMAGE" >/dev/null 2>&1; then
        note_restored "frontend image: $FRONTEND_IMAGE is $SAVED_FRONTEND_IMAGE again (also tagged $SAVED_FRONTEND_TAG)"
        return 0
    fi
    note_not_restored "frontend image: could not retag $SAVED_FRONTEND_IMAGE as $FRONTEND_IMAGE. By hand: docker tag ${SAVED_FRONTEND_TAG:-$SAVED_FRONTEND_IMAGE} $FRONTEND_IMAGE"
    return 1
}

# Reinstall the pixi environment for the restored lock, if this run
# reinstalled it for a different one.
restore_pixi() {
    local now_lock
    [ "$PIXI_INSTALL_STARTED" -eq 1 ] || return 0
    if [ "$CODE_RESTORED" -ne 1 ]; then
        note_not_restored "pixi environment: left as this update installed it, because the code was not restored"
        return 1
    fi
    now_lock="$(file_digest "$PROJECT_ROOT/backend/pixi.lock" || true)"
    if [ -n "$now_lock" ] && [ "$now_lock" = "$NEW_LOCK_DIGEST" ]; then
        note_restored "pixi environment: backend/pixi.lock is the same in both versions, so the environment already matches"
        return 0
    fi
    echo "→ Reinstalling the pixi environment for the restored backend/pixi.lock..."
    if ( cd "$PROJECT_ROOT/backend" && run_as_user "$PIXI_BIN" install --locked ); then
        note_restored "pixi environment: reinstalled for the restored backend/pixi.lock"
        return 0
    fi
    echo ""
    echo "  ⚠⚠ THE PIXI ENVIRONMENT COULD NOT BE REINSTALLED FOR THE RESTORED LOCK."
    echo "     backend/pixi.lock changed in this update, and putting the old"
    echo "     environment back needs the conda registry unless every package is"
    echo "     still in pixi's cache. If this unit is offline, that is why. Until it"
    echo "     is reinstalled the backend may not start."
    echo ""
    note_not_restored "pixi environment: reinstall for the restored lock FAILED (offline?). With internet: cd $PROJECT_ROOT/backend && sudo -u $DTK_USER $PIXI_BIN install --locked"
    return 1
}

# Restore the dump taken in step 7 with the backend stopped (RESTORE_DUMP),
# never step 5's trial dump, as rollback-update.sh step 4 does: db container up,
# other sessions ended, the database dropped and recreated, the dump loaded
# with ON_ERROR_STOP, the container stopped again.
restore_database() {
    local i
    [ -n "$RESTORE_DUMP" ] && [ "$RESTORE_DUMP_VERIFIED" -eq 1 ] || return 1
    echo "→ Restoring the database from $RESTORE_DUMP ..."
    $COMPOSE up -d db || return 1
    for i in $(seq 1 30); do
        if $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
            break
        fi
        [ "$i" -lt 30 ] || return 1
        sleep 2
    done
    $COMPOSE exec -T db psql -U "$DATABASE_USER" -d postgres -v ON_ERROR_STOP=1 \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DATABASE_NAME' AND pid <> pg_backend_pid();" \
        >/dev/null || return 1
    $COMPOSE exec -T db psql -U "$DATABASE_USER" -d postgres -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS \"$DATABASE_NAME\";" \
        -c "CREATE DATABASE \"$DATABASE_NAME\" OWNER \"$DATABASE_USER\";" \
        >/dev/null || return 1
    ( set -o pipefail
      gunzip -c "$RESTORE_DUMP" | $COMPOSE exec -T db psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -v ON_ERROR_STOP=1 >/dev/null ) || return 1
    $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    return 0
}

# A copy of rollback-update.sh outside the checkout, taken while scripts/ is
# still the new version's: the manual command printed on a failed restore has
# to name a script the restore cannot have replaced. Same path and same
# tmp-and-rename as rollback-update.sh's own copy.
keep_rollback_copy() {
    if cp "$SCRIPT_DIR/rollback-update.sh" "$ROLLBACK_SCRIPT_COPY.tmp" 2>/dev/null \
            && chmod 755 "$ROLLBACK_SCRIPT_COPY.tmp" 2>/dev/null \
            && mv -f "$ROLLBACK_SCRIPT_COPY.tmp" "$ROLLBACK_SCRIPT_COPY" 2>/dev/null; then
        ROLLBACK_CMD="sudo $ROLLBACK_SCRIPT_COPY --project-root=$PROJECT_ROOT --yes $RESTORE_DUMP"
    else
        rm -f "$ROLLBACK_SCRIPT_COPY.tmp" 2>/dev/null || true
        ROLLBACK_CMD="sudo $SCRIPT_DIR/rollback-update.sh --yes $RESTORE_DUMP"
    fi
}

print_restore_summary() {
    echo ""
    if [ -n "$RESTORED_LINES" ]; then
        echo "  Restored to the previous version:"
        printf '%s' "$RESTORED_LINES"
    fi
    if [ -n "$NOT_RESTORED_LINES" ]; then
        echo "  NOT restored:"
        printf '%s' "$NOT_RESTORED_LINES"
    fi
    if [ "$PIXI_INSTALL_STARTED" -eq 1 ] || [ "$BUILD_STARTED" -eq 1 ]; then
        echo "  Not undone: the CHDK USB rule and the rclone install (steps 4b and 4c)"
        echo "  if they ran; both leave the running service alone."
    fi
    if [ -n "$MODS_DIR" ]; then
        echo "  Not put back: the local modifications set aside before the update,"
        echo "  saved in $MODS_DIR"
    fi
}

# Is the new backend fully stopped? The unit inactive or failed with no main
# process, and no uvicorn left for it (stop.sh, the unit's ExecStop, finds the
# backend by "uvicorn app.main:app" and SIGTERMs it, then SIGKILLs it after
# 2s). The bracket keeps pgrep from matching a command line that merely
# contains the pattern.
backend_fully_stopped() {
    local state pid
    state="$(systemctl show dtk -p ActiveState --value 2>/dev/null)"
    case "$state" in inactive|failed) ;; *) return 1 ;; esac
    pid="$(systemctl show dtk -p MainPID --value 2>/dev/null)"
    [ -z "$pid" ] || [ "$pid" = 0 ] || return 1
    ! pgrep -f '[u]vicorn app[.]main:app' >/dev/null 2>&1
}

wait_backend_stopped() {
    local i
    for i in $(seq 1 30); do
        backend_fully_stopped && return 0
        sleep 2
    done
    return 1
}

# The new version was started in step 8 and the update then failed. From its
# start it could take writes, and nothing on the unit can prove it did not: a
# handler commits before it responds, uvicorn logs the request only on the
# response, and stop.sh kills the backend 2s after asking it to stop. So the
# database is never restored automatically from here, and the code is not
# moved back either, because the old code cannot run over the migrated
# database. The new version is stopped, fully, and the unit left stopped.
# Record the unresolved state (see UNRESOLVED_FILE): root's alone, 0600 from
# the start, written to a temporary name and renamed.
# write_unresolved_marker [started-failed|restore-failed]
write_unresolved_marker() {
    local kind="${1:-started-failed}"
    if ( umask 077
         {
             echo "kind: $kind"
             if [ "$kind" = restore-failed ]; then
                 echo "code-commit: $(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
                 echo "dump-to-restore: $RESTORE_DUMP"
             else
                 echo "failed-commit: $CURRENT_SHA"
                 echo "restore-target: ${PREV_DEPLOYED_SHA:-$RESTORE_SHA}"
                 echo "migrated-revision: ${MIGRATED_REVISION:-(unknown)}"
             fi
             echo "dump: $RESTORE_DUMP"
             echo "rollback-command: $ROLLBACK_CMD"
             echo "recorded-at: $(date +%Y-%m-%dT%H:%M:%S%z)"
         } > "$UNRESOLVED_FILE.tmp" ) 2>/dev/null \
         && mv -f "$UNRESOLVED_FILE.tmp" "$UNRESOLVED_FILE" 2>/dev/null; then
        return 0
    fi
    rm -f "$UNRESOLVED_FILE.tmp" 2>/dev/null || true
    return 1
}

report_started_failure() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  UPDATE FAILED after the new version was started"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    if [ "$NEW_SERVED" -eq 1 ]; then
        echo "  The new version ($CURRENT_SHA) answered /health, and the update"
        echo "  failed after that."
    else
        echo "  The new version ($CURRENT_SHA) did not become healthy: the backend"
        echo "  did not answer /health."
    fi
    echo ""
    echo "  State of the unit:"
    if [ "$1" = stopped ]; then
        echo "    • dtk service: STOPPED, with no backend process left running"
    else
        echo "    • dtk service: asked to stop, but the backend was still running after"
        echo "      60s. Check: systemctl status dtk"
    fi
    echo "    • code: the new version, $CURRENT_SHA (not moved back: the previous"
    echo "      code cannot run over the migrated database)"
    echo "    • database: migrated for the new version, NOT restored. The new"
    echo "      version was running and may have saved data that a restore would"
    echo "      discard, so this script does not restore it on its own."
    echo ""
    echo "  To return to the previous version, code and database, run:"
    echo "      $ROLLBACK_CMD"
    echo "  ⚠ That restores $RESTORE_DUMP,"
    echo "    taken with the backend stopped before the migration, and DISCARDS"
    echo "    everything written since, which may include writes the new version"
    echo "    accepted before it failed."
    if write_unresolved_marker; then
        echo "  Until this is resolved, update.sh refuses to run; the record is"
        echo "  $UNRESOLVED_FILE, and the rollback removes it when it succeeds."
    else
        echo "  ⚠ Could not write $UNRESOLVED_FILE. Do NOT run update.sh again"
        echo "    before the rollback: it would treat the previous version as current."
    fi
    echo ""
}

# The failure came after the service was stopped. Put the previous version
# back, component by component, and start it only when the code is back and,
# if a migration began, the database too: starting the new code after a failed
# migration is what left units looping on a backend that refuses an unmigrated
# schema while this script said they were online. Only for a failure before
# step 8 started the new version; after that, see report_started_failure.
restore_after_stop() {
    local db_ok=1
    if [ -n "$RESTORE_DUMP" ] && [ "$RESTORE_DUMP_VERIFIED" -eq 0 ]; then
        rm -f "$RESTORE_DUMP"
    fi
    if [ -n "$NEW_STARTED_AT" ]; then
        keep_rollback_copy
        systemctl stop dtk 2>/dev/null || true
        if wait_backend_stopped; then
            $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
            report_started_failure stopped
        else
            report_started_failure running
        fi
        return
    fi
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  UPDATE FAILED — restoring the previous version"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    [ "$MIGRATION_STARTED" -eq 1 ] && keep_rollback_copy
    # Make sure nothing is up before anything moves under it (the unit is
    # stopped already; this is belt and braces for the containers).
    # --remove-orphans: containers from services dropped between releases must
    # go too, or they keep an endpoint on the project network and wedge the
    # restart (NEH-214).
    systemctl stop dtk 2>/dev/null || true
    $COMPOSE down --remove-orphans >/dev/null 2>&1 || true

    if ! restore_code; then
        print_restore_summary
        echo ""
        echo "  ✗ The appliance has NOT been started: the code is not back on the"
        echo "    previous version, and starting what is checked out would run the"
        echo "    new version."
        if [ "$MIGRATION_STARTED" -eq 1 ]; then
            echo "    The database may be partly or fully migrated and has NOT been"
            echo "    restored. This run's backup is $RESTORE_DUMP. Once the reason the"
            echo "    code could not move is cleared, this restores code and database:"
            echo "      $ROLLBACK_CMD"
        else
            echo "    The database was not changed by this update. To move the code"
            echo "    back by hand, then start the unit:"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT checkout -B <branch> ${RESTORE_SHA:-<previous commit>}"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule update --init --recursive"
            echo "      sudo systemctl start dtk"
        fi
        echo ""
        return
    fi
    restore_frontend_image || true
    restore_pixi || true
    if [ "$MIGRATION_STARTED" -eq 1 ]; then
        if restore_database; then
            note_restored "database: restored from this run's backup $RESTORE_DUMP (taken with the backend stopped, before the migration)"
        else
            db_ok=0
            $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
            note_not_restored "database: the restore from $RESTORE_DUMP FAILED; the database may be partly migrated or partly restored"
        fi
    else
        note_restored "database: untouched (the failure came before any migration ran)"
    fi

    if [ "$db_ok" -ne 1 ]; then
        print_restore_summary
        echo ""
        echo "  ✗ The appliance has NOT been started: the database is not in a known"
        echo "    state. The backup is intact. To restore code and database by hand:"
        echo "      $ROLLBACK_CMD"
        if write_unresolved_marker restore-failed; then
            echo "  Until that succeeds, update.sh refuses to run; the record is"
            echo "  $UNRESOLVED_FILE, and the rollback removes it."
        else
            echo "  ⚠ Could not write $UNRESOLVED_FILE. Do NOT run update.sh again"
            echo "    before the rollback."
        fi
        echo ""
        return
    fi

    echo "→ Starting the previous version..."
    systemctl start dtk 2>/dev/null || true
    echo "  Waiting up to ${HEALTH_TIMEOUT}s for the backend to answer /health..."
    if wait_for_health "$HEALTH_TIMEOUT"; then
        print_restore_summary
        echo ""
        echo "  ✓ The appliance is back online on the previous version"
        echo "    ($RESTORE_SHA): the service is active and the backend answers /health."
    else
        print_restore_summary
        echo ""
        echo "  ✗ The previous version did NOT come back up: the backend did not"
        echo "    answer /health within ${HEALTH_TIMEOUT}s."
        echo "    Check logs:  journalctl -u dtk -n 50"
        if [ "$MIGRATION_STARTED" -eq 1 ]; then
            echo "    This run's backup is $RESTORE_DUMP. To restore code and database again:"
            echo "      $ROLLBACK_CMD"
        fi
    fi
    echo ""
}

# The failure came before the service was stopped, after the code moved. The
# previous version is still running from what it loaded at its last start;
# put the checkout, image and environment back under it, so that its next
# restart starts the same version against the same, unmigrated database.
restore_before_stop() {
    echo ""
    echo "→ Update failed before the service was stopped. Putting back what it"
    echo "  had changed, under the version that is still running..."
    if restore_code; then
        restore_frontend_image || true
        restore_pixi || true
    else
        if [ "$BUILD_STARTED" -eq 1 ]; then
            note_not_restored "frontend image: left as rebuilt, because the code was not restored (saved as ${SAVED_FRONTEND_TAG:-nothing})"
        fi
        if [ "$PIXI_INSTALL_STARTED" -eq 1 ]; then
            note_not_restored "pixi environment: left as this update installed it, because the code was not restored"
        fi
    fi
    note_restored "database: untouched (the service was never stopped and no migration ran)"
}

# Positive listen check on the db's published port (127.0.0.1:5432,
# docker-compose.yml). The container-internal healthcheck can pass while the
# port is dead on the host — the Rionegro 2026-08-03 failure mode. grep
# without -q reads to EOF, so the pipeline status is grep's own.
db_port_listening() {
    ss -ltn 2>/dev/null | grep -E '[:.]5432[[:space:]]' >/dev/null
}

# The abort happened after container state had already been changed (the db
# was started for the backup) but before the service was stopped. Undo what
# is safe to undo, then report the REAL state of the unit. Never print
# "nothing changed" from here: Rionegro got exactly that message on
# 2026-08-03 while its database sat stopped and detached from the network.
report_touched_abort() {
    if [ -n "$DUMP_FILE" ] && [ "$BACKUP_VERIFIED" -eq 0 ]; then
        rm -f "$DUMP_FILE"
    fi
    local svc_active=0
    if systemctl is-active --quiet dtk 2>/dev/null; then
        svc_active=1
    fi
    if [ "$DB_STARTED_BY_US" -eq 1 ] && [ "$svc_active" -eq 0 ]; then
        # We started db and the service is down: stopping db returns the unit
        # to its pre-update state. When the service IS active, db stays up —
        # the backend needs it, and it can only have been down before because
        # the unit was already degraded.
        $COMPOSE stop db >/dev/null 2>&1 || true
    fi
    echo ""
    echo "✗ Update aborted AFTER container state had been touched."
    echo "  Actual state of this unit right now:"
    if [ "$svc_active" -eq 1 ]; then
        echo "    • dtk service:  active"
    else
        echo "    • dtk service:  NOT active"
    fi
    echo "    • containers:"
    $COMPOSE ps --format '        {{.Service}}: {{.State}}' 2>/dev/null \
        || echo "        (docker compose ps failed)"
    if ! command -v ss >/dev/null 2>&1; then
        echo "    • database:     (cannot check port 5432 — ss unavailable)"
    elif db_port_listening; then
        echo "    • database:     listening on 127.0.0.1:5432 ✓"
    else
        echo "    • database:     NOT listening on 127.0.0.1:5432 ✗"
        echo ""
        echo "  The database is not serving. To recover, run:"
        echo "    sudo $SCRIPT_DIR/stop.sh && sudo systemctl start dtk"
    fi
    echo ""
}

# After a full teardown nothing from this compose project may survive: a
# leftover container from a service that no longer exists in the compose
# files keeps an endpoint on the project network, and the next start then
# brings up a db detached from its published port (NEH-214). Failing here
# (under set -e) trips the EXIT trap, which restores the previous stack.
assert_stack_gone() {
    local project leftovers
    project="$($COMPOSE config 2>/dev/null | sed -n 's/^name: *//p' | head -n 1)"
    if [ -z "$project" ]; then
        echo "  ⚠ Could not determine the compose project name — skipping the"
        echo "    teardown completeness check."
        return 0
    fi
    leftovers="$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)"
    if [ -n "$leftovers" ]; then
        echo "✗ Teardown incomplete — containers from project '$project' survive:"
        docker ps -a --filter "label=com.docker.compose.project=$project" \
            --format '    {{.Names}}  ({{.Status}})' 2>/dev/null || true
        return 1
    fi
    if docker network inspect "${project}_default" >/dev/null 2>&1; then
        echo "✗ Teardown incomplete — network ${project}_default still exists"
        echo "  (something outside this compose project is attached to it)."
        return 1
    fi
    return 0
}

on_exit() {
    local rc=$?
    if [ "$UPDATE_OK" -eq 1 ]; then
        return 0
    fi
    # Every step below handles its own failures; one failing must not abort
    # the rest of the restore.
    set +e
    if [ "$SERVICE_STOPPED" -eq 1 ]; then
        restore_after_stop
        exit "$rc"
    fi
    if [ "$RESTORE_ARMED" -eq 1 ]; then
        restore_before_stop
    fi
    if [ "$STACK_TOUCHED" -eq 1 ]; then
        report_touched_abort
    else
        # Pre-stop failure with container state untouched: clean up only what
        # this script itself created.
        if [ -n "$DUMP_FILE" ] && [ "$BACKUP_VERIFIED" -eq 0 ]; then
            # Never leave a partial/unverified dump behind — rollback-update.sh
            # picks the newest dump and must not find a broken one.
            rm -f "$DUMP_FILE"
        fi
        echo ""
        echo "✗ Update aborted before the running service was touched."
        if [ "$RESTORE_ARMED" -ne 1 ]; then
            echo "  The appliance is still serving the current version."
            if [ "$TREE_TOUCHED" -eq 1 ]; then
                echo ""
                echo "  One thing DID change: this unit's local modifications were set"
                echo "  aside before the failure. They are saved in:"
                echo "    $MODS_DIR"
            else
                echo "  Nothing changed."
            fi
            echo ""
        fi
    fi
    if [ "$RESTORE_ARMED" -eq 1 ]; then
        print_restore_summary
        echo ""
        if [ "$CODE_RESTORED" -ne 1 ]; then
            echo "  ✗ The checkout is NOT on the version that is running. The service"
            echo "    was not restarted, so it still serves what it loaded at its last"
            echo "    start, but its next restart would start the code checked out"
            echo "    now, against a database this update did not migrate."
            echo "    To move the code back by hand:"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT checkout -B <branch> ${RESTORE_SHA:-<previous commit>}"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule update --init --recursive"
        elif backend_healthy; then
            echo "  ✓ The service was not restarted and is still serving the previous"
            echo "    version ($RESTORE_SHA): it is active and the backend answers /health."
        else
            echo "  ⚠ The checkout is back on the previous version ($RESTORE_SHA), but"
            echo "    the service is not answering /health. It was not stopped by this"
            echo "    update; it may already have been down. Check:"
            echo "      systemctl status dtk;  journalctl -u dtk -n 50"
        fi
        echo ""
    fi
    exit "$rc"
}
# ---------------------------------------------------------------------------
# --resolve-forward: accept the version a started-then-failed update left in
# place, instead of rolling back. Nothing is changed until everything checks:
#   • HEAD is exactly the record's failed commit, every submodule is on its
#     pin and no tracked file is modified (a different commit would need its
#     own update, with its own backup and migration);
#   • the database's alembic_version equals the migration head of the backend
#     checked out, read with only the db container running, as in step 7.
# Then last-deployed-SHA names that commit, so the next update restores to it
# and not to the version before, the record is removed, and the unit is
# started and checked against /health: it was left stopped, and resolving
# forward is the decision to run this version.
# ---------------------------------------------------------------------------
resolve_forward() {
    local want now sub_status db_rev heads i
    want="$(record_field failed-commit)"
    now="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)"
    echo "→ Resolving forward to the failed update's version: ${want:-(not recorded)}"
    if [ -z "$want" ] || [ "$now" != "$want" ]; then
        echo "✗ The checkout is on ${now:-(unreadable)}, not on the recorded version"
        echo "  ${want:-(none recorded)}. Check that version out, then run this again."
        return 1
    fi
    if ! tracked_files_modified; then
        echo "✗ The checkout has modified tracked files. Resolve them first:"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT status"
        return 1
    fi
    if ! sub_status="$(run_as_repo_owner git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null)" \
            || printf '%s\n' "$sub_status" | grep -qv '^ '; then
        echo "✗ A submodule is not on the commit $want pins (or could not be read):"
        printf '%s\n' "$sub_status" | sed 's/^/      /'
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule update --init --recursive"
        return 1
    fi
    if systemctl is-active --quiet dtk 2>/dev/null; then
        echo "✗ dtk is running. Stop it first: sudo systemctl stop dtk"
        return 1
    fi
    heads="$(cd "$PROJECT_ROOT/backend" && run_as_user "$PIXI_BIN" run alembic heads 2>/dev/null \
        | awk '/\(head\)/ {print $1}' | sort | tr '\n' ' ' | sed 's/ *$//')"
    if [ -z "$heads" ]; then
        echo "✗ Could not read the backend's migration head (pixi run alembic heads)."
        return 1
    fi
    $COMPOSE up -d db >/dev/null 2>&1 || { echo "✗ Could not start the db container."; return 1; }
    for i in $(seq 1 30); do
        $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1 && break
        [ "$i" -lt 30 ] || { echo "✗ The database did not become ready."; $COMPOSE down --remove-orphans >/dev/null 2>&1; return 1; }
        sleep 2
    done
    db_rev="$($COMPOSE exec -T db psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -Atc 'SELECT version_num FROM alembic_version' 2>/dev/null \
        | sort | tr '\n' ' ' | sed 's/ *$//')"
    $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    echo "  Database revision: ${db_rev:-(unreadable)}; backend head: $heads"
    if [ -z "$db_rev" ] || [ "$db_rev" != "$heads" ]; then
        echo "✗ The database is not at the migration head of the checked-out backend,"
        echo "  so this version cannot be accepted as deployed. Nothing was changed."
        echo "  The record stays; the rollback is: $(record_field rollback-command)"
        return 1
    fi
    if ! printf '%s\n' "$want" > "$LAST_DEPLOYED_SHA_FILE"; then
        echo "✗ Could not write $LAST_DEPLOYED_SHA_FILE. Nothing else was changed."
        return 1
    fi
    rm -f "$UNRESOLVED_FILE"
    echo "  ✓ Recorded $want as the deployed version; $UNRESOLVED_FILE removed."
    echo "→ Starting the service..."
    systemctl start dtk 2>/dev/null || true
    echo "  Waiting up to ${HEALTH_TIMEOUT}s for the backend to answer /health..."
    if wait_for_health "$HEALTH_TIMEOUT"; then
        echo "  ✓ The appliance is online on $want: the backend answers /health."
        return 0
    fi
    echo "  ✗ The service did not answer /health within ${HEALTH_TIMEOUT}s. The code"
    echo "    and the database agree and are recorded as deployed, so update.sh"
    echo "    can be run again once the cause is found: journalctl -u dtk -n 50"
    return 1
}
if [ "$RESOLVE_FORWARD" -eq 1 ]; then
    if resolve_forward; then exit 0; else exit 1; fi
fi

trap on_exit EXIT

if [ -n "$FAIL_AT" ]; then
    echo "⚠ DTK_UPDATE_FAIL_AT=$FAIL_AT is set: this run will fail on purpose (test only)."
    echo ""
fi

# ---------------------------------------------------------------------------
# 0a. Record what is running, before anything changes, so that a failure
#     later can put it back (the EXIT trap above).
#
#     The version to return to is the last successfully deployed commit
#     (last-deployed-SHA, which only a successful update or a rollback
#     writes), not HEAD: with --no-pull, or after an earlier failed update,
#     HEAD can already be newer code than the processes running. The checkout's
#     own HEAD is the fallback when there is no usable record.
#
#     The frontend image is the running container's, or the tag's when no
#     container runs, kept under a pre-update-<timestamp> tag so that the
#     rebuild in step 3 cannot leave it untagged and prunable.
# ---------------------------------------------------------------------------
RUN_TS="$(date +%Y%m%d-%H%M%S)"
PRE_HEAD="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"

# A file that cannot be read is not a file that is not there, and step 2's
# messages used to say the latter for both. PREV_RECORD_STATE carries which it
# was so the diagnosis there can be true.
PREV_DEPLOYED_SHA=""
if [ ! -e "$LAST_DEPLOYED_SHA_FILE" ]; then
    PREV_RECORD_STATE=absent
elif ! PREV_DEPLOYED_SHA="$(cat "$LAST_DEPLOYED_SHA_FILE" 2>/dev/null)"; then
    PREV_RECORD_STATE=unreadable
    PREV_DEPLOYED_SHA=""
elif [ -z "$PREV_DEPLOYED_SHA" ]; then
    PREV_RECORD_STATE=empty
else
    PREV_RECORD_STATE=present
fi

if [ "$PREV_RECORD_STATE" = present ] \
        && RESOLVED="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$PREV_DEPLOYED_SHA^{commit}" 2>/dev/null)" \
        && [ -n "$RESOLVED" ]; then
    RESTORE_SHA="$RESOLVED"
    RESTORE_SHA_SOURCE="the last deployed version"
elif [ -n "$PRE_HEAD" ]; then
    RESTORE_SHA="$PRE_HEAD"
    RESTORE_SHA_SOURCE="the commit checked out before this update; there was no usable record of the last deployed version"
fi

FRONTEND_IMAGE="$(frontend_image_name || true)"
SAVED_FRONTEND_IMAGE="$(frontend_image_id || true)"
if [ -z "$SAVED_FRONTEND_IMAGE" ] && [ -n "$FRONTEND_IMAGE" ]; then
    SAVED_FRONTEND_IMAGE="$(docker image inspect --format '{{.Id}}' "$FRONTEND_IMAGE" 2>/dev/null || true)"
fi
if [ -n "$SAVED_FRONTEND_IMAGE" ] && [ -n "$FRONTEND_IMAGE" ]; then
    # The repository part of the name: no digest, and no tag after the last
    # slash (a registry host may carry a port).
    FRONTEND_REPO="${FRONTEND_IMAGE%%@*}"
    case "${FRONTEND_REPO##*/}" in
        *:*) FRONTEND_REPO="${FRONTEND_REPO%:*}" ;;
    esac
    SAVED_FRONTEND_TAG="$FRONTEND_REPO:pre-update-$RUN_TS"
    if docker tag "$SAVED_FRONTEND_IMAGE" "$SAVED_FRONTEND_TAG" >/dev/null 2>&1; then
        # The newest few, as with the dumps.
        docker image ls "$FRONTEND_REPO" --format '{{.Tag}}' 2>/dev/null \
            | grep '^pre-update-' | sort -r | tail -n +$((KEEP_DUMPS + 1)) \
            | while read -r old_tag; do
                docker image rm "$FRONTEND_REPO:$old_tag" >/dev/null 2>&1 || true
            done
    else
        SAVED_FRONTEND_TAG=""
    fi
fi

echo "→ Recorded what is running, to put back if the update fails:"
echo "    code:     ${RESTORE_SHA:-(unknown — a failure will leave the checkout where it is)}"
if [ -n "$SAVED_FRONTEND_TAG" ]; then
    echo "    frontend: $SAVED_FRONTEND_IMAGE (kept as $SAVED_FRONTEND_TAG)"
elif [ -n "$SAVED_FRONTEND_IMAGE" ]; then
    echo "    frontend: $SAVED_FRONTEND_IMAGE (could not be tagged; it may be pruned)"
else
    echo "    frontend: (unknown)"
fi
if [ -z "$SAVED_FRONTEND_TAG" ]; then
    echo ""
    echo "  ⚠⚠ THE FRONTEND IMAGE COULD NOT BE KEPT: $( [ -z "$FRONTEND_IMAGE" ] && echo "Compose did not give its name" || echo "no image for $FRONTEND_IMAGE could be found or tagged")."
    echo "     If this update fails after the rebuild, the frontend will NOT be put"
    echo "     back, and the restored version will run with the new build's frontend."
fi
echo ""

# ---------------------------------------------------------------------------
# 0b. Fetch the new code (NEH-270).
#
#     This was the operator's job until now. The header documented
#       git pull && git submodule update --init --recursive && sudo ./scripts/update.sh
#     and on a unit that has been fixed by hand in the field that first
#     command aborts — "Your local changes to the following files would be
#     overwritten by merge" — then tells the operator to "commit or stash",
#     which is not an instruction an archive can act on. Doing it here means
#     the dirty-tree case is handled once, in the open, and the same way
#     whether a person or NEH-186's admin-triggered update started this.
#
#     Local modifications are COPIED ASIDE, never discarded unseen: every
#     modified tracked file, in the superproject and in each submodule, is
#     saved under /var/lib/dtk/local-mods-<timestamp>/ with a patch per level
#     that reproduces the whole set. Untracked files are left where they are.
#     On an appliance an unknown file may be the only copy of something, so
#     this script never deletes one — a pull that an untracked file would
#     block is reported, not forced.
#
#     Runs before anything is built or stopped, so any failure here leaves
#     the unit serving the current version (the EXIT trap's "nothing
#     changed" branch).
# ---------------------------------------------------------------------------
if [ "$DO_PULL" -eq 1 ]; then
    echo "→ Fetching the new code..."

    # A detached HEAD has no branch to pull into. rollback-update.sh before
    # NEH-273 left exactly that behind, so a rolled-back unit arrives here.
    PULL_BRANCH="$(run_as_repo_owner git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ -z "$PULL_BRANCH" ]; then
        echo "✗ This repository is not on a branch, so there is nothing to pull into."
        echo "  A rollback on an older unit leaves it this way. To recover:"
        echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT checkout dev"
        echo "  then run this script again."
        exit 1
    fi
    PULL_UPSTREAM="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -z "$PULL_UPSTREAM" ]; then
        echo "✗ Branch '$PULL_BRANCH' is not tracking a remote branch, so there is"
        echo "  nothing to pull from. Set one, e.g.:"
        echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT branch --set-upstream-to=origin/$PULL_BRANCH"
        echo "  or run with --no-pull to update to what is already checked out."
        exit 1
    fi
    echo "  Branch: $PULL_BRANCH → $PULL_UPSTREAM"

    # Network first, working tree afterwards. Everything up to the merge is
    # read-only, so an unreachable remote or a diverged history aborts with
    # the unit exactly as it was — local modifications included. Discarding
    # work and THEN discovering there is no network would be the wrong order.
    if ! run_as_repo_owner git -C "$PROJECT_ROOT" fetch origin; then
        echo ""
        echo "✗ Could not reach the remote to fetch. If this unit is offline,"
        echo "  copy the new code into place and re-run with --no-pull."
        exit 1
    fi
    if ! run_as_repo_owner git -C "$PROJECT_ROOT" merge-base --is-ancestor HEAD "$PULL_UPSTREAM"; then
        echo ""
        echo "✗ '$PULL_BRANCH' cannot be fast-forwarded to $PULL_UPSTREAM: this unit"
        echo "  has commits of its own that the remote does not. Someone has to"
        echo "  decide what to keep — this script will not merge or discard"
        echo "  committed work. Nothing has been changed."
        exit 1
    fi

    # Modified tracked files, superproject and submodules.
    #
    # --ignore-submodules=dirty, not =all: =all hides a submodule gitlink that
    # has been STAGED to a different commit, and `submodule update` later
    # follows the index, so the unit would install that staged pointer's code
    # while CURRENT_SHA recorded the superproject commit that pins a different
    # one — an older backend's migrations against a newer database. Verified:
    # with =all the staged gitlink reports clean, with =dirty it is named.
    # =dirty still keeps a merely-dirty submodule from being counted twice,
    # which is what the loop below handles.
    #
    # Captured by assignment, never inside `[ -n "$(...)" ]`. A git failure
    # there yields empty stdout, reads as "clean", and set -e does not fire on
    # a substitution inside a test — verified with a diff exiting 128. A
    # repository we cannot interrogate must abort, not be reset unsaved.
    SUPER_DIRTY="$(run_as_repo_owner git -C "$PROJECT_ROOT" diff HEAD --name-only --ignore-submodules=dirty)"
    SUB_PATHS="$(run_as_repo_owner git -C "$PROJECT_ROOT" submodule foreach --quiet --recursive 'printf "%s\n" "$displaypath"')"
    SUB_DIRTY=""
    for sub in $SUB_PATHS; do
        SUB_STATUS="$(run_as_repo_owner git -C "$PROJECT_ROOT/$sub" diff HEAD --name-only)"
        if [ -n "$SUB_STATUS" ]; then
            SUB_DIRTY="$SUB_DIRTY $sub"
        fi
    done

    if [ -n "$SUPER_DIRTY" ] || [ -n "$SUB_DIRTY" ]; then
        MODS_DIR="/var/lib/dtk/local-mods-$(date +%Y%m%d-%H%M%S)"
        echo ""
        echo "  ⚠ This unit has locally modified files. Saving them to:"
        echo "      $MODS_DIR"
        mkdir -p "$MODS_DIR"

        # save_local_level <repo-dir> <label> [extra git diff args...]
        # A copy of each modified file under its own path, plus one patch
        # that reproduces the level. Either alone recovers the work; together
        # they also show what it was applied to.
        #
        # Deliberately strict — no `|| true` anywhere in here. If a diff
        # cannot be read or a copy cannot be written, this fails while the
        # working tree is still intact, and the reset below never runs. A
        # failure to save must not be followed by a discard.
        save_local_level() {
            local dir="$1" label="$2"; shift 2
            local dest="$MODS_DIR/$label" f index_entry
            mkdir -p "$dest"
            # --binary so a changed binary file's bytes survive in the patch
            # as well as in the copy below.
            run_as_repo_owner git -C "$dir" diff HEAD --binary "$@" > "$dest/local.patch"
            # -z into a file, because a NUL-delimited list cannot be held in a
            # shell variable and `--name-only` alone returns non-ASCII paths
            # git-quoted ("caf\303\251.txt"), which no file test then matches
            # — the file would be silently skipped and then reset away.
            # Redirecting to a file keeps the git call's own exit status under
            # set -e, unlike a pipe.
            run_as_repo_owner git -C "$dir" diff HEAD --name-only -z "$@" > "$dest/.names"
            while IFS= read -r -d "" f; do
                [ -n "$f" ] || continue
                # A submodule gitlink is a directory by nature, so it must
                # not trip the check below. Its own modifications are saved by
                # that submodule's own pass, and the commit a staged pointer
                # named still exists in the submodule's object store, so the
                # superproject reset loses nothing recoverable.
                # --literal-pathspecs is a TOP-LEVEL git option, not an
                # ls-files one. Placed after the subcommand, git errors out and
                # the mode reads as empty, which silently defeats this check
                # and sends every gitlink into the refusal below. Captured by
                # assignment with no pipe, so a git failure aborts rather than
                # being read as "not a gitlink".
                index_entry="$(run_as_repo_owner git -C "$dir" --literal-pathspecs ls-files --stage -- "$f")"
                if [ "${index_entry%% *}" = "160000" ]; then
                    echo "      $label: $f (submodule pointer)"
                    continue
                fi
                if [ -e "$dir/$f" ] && [ ! -f "$dir/$f" ]; then
                    # The tracked path has been replaced by a directory (or
                    # something else). `reset --hard` would delete whatever is
                    # inside it to restore the tracked file, and there is no
                    # copy to make — so refuse. Verified: a tracked file
                    # replaced by a directory holding an untracked file loses
                    # that file to the reset.
                    echo ""
                    echo "✗ '$label/$f' is tracked as a file but is now something else"
                    echo "  on this unit. Restoring the tracked file would delete"
                    echo "  whatever is there, and this script does not delete what it"
                    echo "  cannot save. Move it aside by hand, then run this again."
                    rm -f "$dest/.names"
                    return 1
                fi
                # A locally DELETED tracked file has nothing to copy; the
                # patch above still records the deletion.
                [ -f "$dir/$f" ] || continue
                install -D "$dir/$f" "$dest/files/$f"
                echo "      $label: $f"
            done < "$dest/.names"
            rm -f "$dest/.names"
        }

        if [ -n "$SUPER_DIRTY" ]; then
            save_local_level "$PROJECT_ROOT" superproject --ignore-submodules=dirty
        fi
        for sub in $SUB_DIRTY; do
            save_local_level "$PROJECT_ROOT/$sub" "$sub"
        done

        # Now discard them, so the unit ends up running the commit it says it
        # is running. Only tracked files are touched: untracked files are left
        # alone, because on an appliance an unknown file may be the only copy
        # of something and this script will not delete one.
        # Set BEFORE the first reset, not after the last. With it after, a
        # superproject reset that succeeded followed by a submodule reset that
        # failed (a stale index.lock will do it) left the flag at zero, and
        # the trap then printed "nothing changed" having already discarded
        # modifications — the exact thing NEH-215 exists to prevent.
        TREE_TOUCHED=1
        run_as_repo_owner git -C "$PROJECT_ROOT" reset --hard HEAD >/dev/null
        run_as_repo_owner git -C "$PROJECT_ROOT" submodule foreach --quiet --recursive 'git reset --hard HEAD' >/dev/null
        echo "  ✓ Saved and reset. To see what was set aside:"
        echo "      ls -R $MODS_DIR"
    fi

    echo ""
    # From here the checkout may stop matching what is running: a failure
    # anywhere below puts it back (0a, and the EXIT trap).
    RESTORE_ARMED=1
    if ! run_as_repo_owner git -C "$PROJECT_ROOT" merge --ff-only "$PULL_UPSTREAM"; then
        echo ""
        echo "✗ Fast-forward to $PULL_UPSTREAM failed. The usual cause left at this"
        echo "  point is an untracked file on the unit that the update would"
        echo "  overwrite — git names it above. Move it aside by hand; this"
        echo "  script will not delete a file it did not put there."
        exit 1
    fi
    run_as_repo_owner git -C "$PROJECT_ROOT" submodule update --init --recursive
    echo ""
    fail_point fetched
fi

# ---------------------------------------------------------------------------
# 1. Note the commit being installed. Step 0b has already pulled (or --no-pull
#    said the new code is in place), so HEAD is the NEW version; the rollback
#    target is the previously deployed commit, handled in step 5.
# ---------------------------------------------------------------------------
secure_backup_dir || exit 1
tighten_existing_dumps || true
# git runs as the repo owner: root-run git can fail dubious-ownership on the
# user-cloned repo, and "unknown" here would poison both the snapshot and
# (on success) last-deployed-SHA.
CURRENT_SHA="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
echo "→ Version being installed: $CURRENT_SHA"

# Manual-recovery snapshot, taken BEFORE any build or dependency work so the
# pre-update state is knowable even if this update aborts early (NEH-216).
# Best-effort: a failure to write it never aborts an update. The only reader
# is rollback-update.sh, which uses it solely to say in its summary which
# components (pixi environment, frontend image) still correspond to the
# restored version (NEH-218); it never changes what rollback does. Its
# inputs — the dump and pre-update-SHA — are still written together in
# step 5, so the NEWEST dump and the recorded SHA correspond; older retained
# dumps do not (rollback-update.sh warns when an older dump is selected).
# Recording pre-update-SHA this early instead would let an abort-during-build
# pair a fresh SHA with a stale dump.
#
# The lock digest is of backend/pixi.lock as checked out NOW, i.e. the NEW
# lock the pixi step below installs; the pre-update lock is no longer in the
# tree when this script runs. The frontend image recorded here is the one
# that was serving when the PREVIOUS commit was successfully deployed (the
# last-deployed-frontend record, accepted only if it names that same commit).
# It is NOT read from the running container: an update that failed after
# rebuilding leaves the unit serving a new-code image under the old
# last-deployed-SHA, so "what is serving now" does not belong to that commit.
# Empty when there is no record (e.g. a unit provisioned before this field
# existed); rollback then reports the image as unknown.
#
# Several records can share one previously-deployed value (an update that
# aborts before step 5 writes a record but advances nothing), so a record is
# identified by its own file name, which step 5 stores in pre-update-ref
# together with the dump name.
previous_frontend_image() {
    local want
    want="$(cat "$LAST_DEPLOYED_SHA_FILE" 2>/dev/null)" || return 1
    [ -n "$want" ] || return 1
    [ "$(sed -n 's/^sha: //p' "$LAST_DEPLOYED_FRONTEND_FILE" 2>/dev/null | head -n 1)" = "$want" ] || return 1
    # Only a complete image id counts. A record truncated mid-write leaves a
    # short but non-empty value, and a prefix compared against a full id reads
    # as a definite mismatch — the kind of false certainty this whole record
    # exists to remove. Incomplete evidence must reach rollback as nothing.
    img="$(sed -n 's/^image: //p' "$LAST_DEPLOYED_FRONTEND_FILE" 2>/dev/null | head -n 1)"
    case "$img" in
        sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$img"
}
STATE_FILE="$BACKUP_DIR/pre-update-state-$(date +%Y%m%d-%H%M%S)"
if {
    echo "recorded-at: $(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "installing-superproject: $CURRENT_SHA"
    if [ -f "$LAST_DEPLOYED_SHA_FILE" ]; then
        echo "previously-deployed: $(cat "$LAST_DEPLOYED_SHA_FILE")"
    else
        echo "previously-deployed: (no record)"
    fi
    echo "submodules:"
    run_as_repo_owner git -C "$PROJECT_ROOT" submodule status 2>/dev/null || echo "  (unavailable)"
    echo "pixi: $(run_as_user "$PIXI_BIN" --version 2>/dev/null || echo '(unavailable)')"
    echo "installing-pixi-lock-sha256: $(file_digest "$PROJECT_ROOT/backend/pixi.lock" || true)"
    echo "previously-deployed-frontend-image: $(previous_frontend_image || true)"
} > "$STATE_FILE" 2>/dev/null; then
    echo "  Pre-update state recorded: $STATE_FILE"
else
    echo "  ⚠ Could not write the pre-update state file ($STATE_FILE) —"
    echo "    check free space on /var/lib/dtk. Continuing; the file is"
    echo "    informational only."
    rm -f "$STATE_FILE"
fi
# Same retention policy as the dumps.
# shellcheck disable=SC2012
ls -1t "$BACKUP_DIR"/pre-update-state-* 2>/dev/null | tail -n +$((KEEP_DUMPS + 1)) | while read -r old; do
    rm -f "$old"
done
echo ""

# ---------------------------------------------------------------------------
# 2. Honesty check: does this update need the internet?
#    package.json / pixi.toml live INSIDE the frontend & backend submodules,
#    so in the superproject a dependency change shows up as a moved submodule
#    pointer. We compare the last successfully-deployed commit against HEAD.
#    If a submodule pointer moved we warn — and, when the submodule contents
#    are available locally, we confirm precisely whether a manifest changed.
#
#    Every git call below runs as the repo owner. Root-run git fails
#    dubious-ownership on a user-cloned repo unless SUDO_UID happens to name
#    the owner, which holds for an interactive `sudo ./scripts/update.sh` and
#    not in a service context. With stderr discarded that failure was
#    invisible and the script reported "no previous-deploy record found" —
#    false, with the record present and correct — so the offline
#    determination was never reached (NEH-271). The same reasoning already
#    governs CURRENT_SHA above and rollback-update.sh's checkout.
# ---------------------------------------------------------------------------
NEEDS_INTERNET=0
# PREV_DEPLOYED_SHA and PREV_RECORD_STATE were read in step 0a, before the
# fetch.

# Likewise for the object check: cat-file -e exits 1 when the object is really
# absent and 128 when it could not be run or read. Only the first justifies
# saying the commit is not in this repository.
PREV_OBJ_STATE=skipped
if [ "$PREV_RECORD_STATE" = present ] && [ "$PREV_DEPLOYED_SHA" != "$CURRENT_SHA" ]; then
    PREV_OBJ_STATUS=0
    run_as_repo_owner git -C "$PROJECT_ROOT" cat-file -e "$PREV_DEPLOYED_SHA^{commit}" 2>/dev/null \
        || PREV_OBJ_STATUS=$?
    case "$PREV_OBJ_STATUS" in
        0) PREV_OBJ_STATE=present ;;
        1) PREV_OBJ_STATE=missing ;;
        *) PREV_OBJ_STATE=uncheckable ;;
    esac
fi

if [ "$PREV_OBJ_STATE" = present ]; then
    CHANGED_GITLINKS="$(run_as_repo_owner git -C "$PROJECT_ROOT" diff --name-only "$PREV_DEPLOYED_SHA" "$CURRENT_SHA" -- frontend backend 2>/dev/null || echo "")"
    if [ -n "$CHANGED_GITLINKS" ]; then
        # A submodule pointer moved. Try to confirm whether a dependency
        # manifest actually changed inside it; fall back to a conservative
        # warning if we cannot resolve the submodule commits offline.
        for sub in frontend backend; do
            case "$sub" in
                frontend) manifests="package.json package-lock.json" ;;
                backend)  manifests="pixi.toml pixi.lock package.json package-lock.json" ;;
            esac
            OLD_SUB="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse "$PREV_DEPLOYED_SHA:$sub" 2>/dev/null || echo "")"
            NEW_SUB="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse "$CURRENT_SHA:$sub" 2>/dev/null || echo "")"
            [ "$OLD_SUB" = "$NEW_SUB" ] && continue
            if [ -d "$PROJECT_ROOT/$sub/.git" ] || [ -f "$PROJECT_ROOT/$sub/.git" ]; then
                if run_as_repo_owner git -C "$PROJECT_ROOT/$sub" cat-file -e "$OLD_SUB^{commit}" 2>/dev/null \
                   && run_as_repo_owner git -C "$PROJECT_ROOT/$sub" cat-file -e "$NEW_SUB^{commit}" 2>/dev/null; then
                    # $manifests is a space-separated list of pathspecs; word
                    # splitting is intended here.
                    # shellcheck disable=SC2086
                    if [ -n "$(run_as_repo_owner git -C "$PROJECT_ROOT/$sub" diff --name-only "$OLD_SUB" "$NEW_SUB" -- $manifests 2>/dev/null)" ]; then
                        NEEDS_INTERNET=1
                        echo "  • $sub dependencies changed ($manifests)."
                    fi
                    continue
                fi
            fi
            # Could not resolve the submodule commits locally — be conservative.
            NEEDS_INTERNET=1
            echo "  • $sub pointer moved; cannot confirm dependencies offline."
        done
    fi
else
    # Three different situations reach this branch, and only the first is a
    # missing record. Saying "not found" for all three told an operator the
    # record was missing when it was present and correct, in the one situation
    # she is most likely to be anxious about: an ordinary redeploy of the
    # commit already checked out.
    #
    # The conservative NEEDS_INTERNET=1 stays in all three. For a redeploy of
    # the same commit nothing can have changed, so it is arguably stricter
    # than it needs to be; changing what the script DOES is a separate
    # decision from correcting what it SAYS, and this is the latter.
    NEEDS_INTERNET=1
    case "$PREV_RECORD_STATE:$PREV_OBJ_STATE" in
        absent:*)
            echo "  • No previous-deploy record found — cannot confirm this update is offline-safe." ;;
        unreadable:*)
            echo "  • The previous-deploy record exists but could not be read, so the"
            echo "    change cannot be inspected — cannot confirm this update is"
            echo "    offline-safe." ;;
        empty:*)
            echo "  • The previous-deploy record is empty — cannot confirm this update"
            echo "    is offline-safe." ;;
        *:missing)
            echo "  • The recorded previous deploy ($PREV_DEPLOYED_SHA) is not in this"
            echo "    repository, so the change cannot be inspected — cannot confirm"
            echo "    this update is offline-safe." ;;
        *:uncheckable)
            echo "  • Could not check whether the recorded previous deploy"
            echo "    ($PREV_DEPLOYED_SHA) is in this repository, so the change cannot be"
            echo "    inspected — cannot confirm this update is offline-safe." ;;
        *)
            # The record is present and equals HEAD: an ordinary redeploy of the
            # commit already deployed. The record is correct; there is simply no
            # change to inspect.
            echo "  • Already deployed at this commit, so there is no change to inspect;"
            echo "    treating the update as possibly needing internet anyway." ;;
    esac
fi

if [ "$NEEDS_INTERNET" -eq 1 ]; then
    echo ""
    echo "⚠  This update may need INTERNET access."
    echo "   It rebuilds the frontend and/or re-solves backend dependencies,"
    echo "   which can reach the npm / conda registries. If this appliance is"
    echo "   offline right now, the update will likely fail partway."
    echo ""
    if [ "$ASSUME_YES" -eq 1 ]; then
        echo "   --yes given: continuing without prompting."
        echo ""
    elif [ ! -t 0 ]; then
        echo "✗ No terminal to confirm on, and --yes was not given. Aborting."
        echo "  Re-run with internet available, or pass --yes to proceed anyway."
        exit 1
    else
        printf "   Continue anyway? [y/N] "
        read -r reply
        case "$reply" in
            y|Y|yes|YES) echo "" ;;
            *) echo ""
               if [ "$RESTORE_ARMED" -eq 1 ]; then
                   echo "Aborted by operator. Putting the code back..."
               else
                   echo "Aborted by operator. Nothing changed."
               fi
               exit 1 ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# 3. Rebuild frontend image (network/compile risk — done BEFORE stopping).
# ---------------------------------------------------------------------------
# On --no-pull the checkout was already new when this script started; from
# here this script changes things under it, so a failure puts the code back
# with them.
RESTORE_ARMED=1
echo "→ Rebuilding frontend image..."
BUILD_STARTED=1
$COMPOSE build frontend
echo ""
fail_point build

# ---------------------------------------------------------------------------
# 4. Update pixi environment (network risk — done BEFORE stopping).
# ---------------------------------------------------------------------------
echo "→ Updating backend dependencies (pixi)..."
NEW_LOCK_DIGEST="$(file_digest "$PROJECT_ROOT/backend/pixi.lock" || true)"
PREV_LOCK_DIGEST="$(lock_digest_at "$RESTORE_SHA" || true)"
if [ -n "$PREV_LOCK_DIGEST" ] && [ "$PREV_LOCK_DIGEST" = "$NEW_LOCK_DIGEST" ]; then
    echo "  backend/pixi.lock is unchanged by this update."
else
    echo "  backend/pixi.lock changes in this update (or could not be compared). If"
    echo "  the update fails, putting the old environment back may need the network."
fi
cd "$PROJECT_ROOT/backend"
PIXI_INSTALL_STARTED=1
run_as_user "$PIXI_BIN" install --locked
cd "$PROJECT_ROOT"
echo ""
fail_point pixi

# ---------------------------------------------------------------------------
# 4b. CHDK camera USB access (libusb + udev rule + group membership).
#     setup.sh only runs once, at first provisioning — this is the only path
#     an appliance already in the field takes to a new release. Without it
#     here too, an appliance upgrading to a release with the CHDK backend
#     would still have no udev rule and no group membership, and a camera
#     that cannot be opened would look exactly like a broken backend.
#     Shared with setup.sh via scripts/provision-chdk-usb.sh (idempotent,
#     touches neither the running service nor anything this script restarts).
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/provision-chdk-usb.sh"

# ---------------------------------------------------------------------------
# 4c. Offsite catalogue backup: pinned rclone + the per-unit B2 remote.
#     Same reasoning as 4b. setup.sh runs once, at first provisioning, so this
#     is the only path an appliance already in the field takes to a release
#     whose backend uploads through rclone. Without it here, such a unit would
#     run a backup path with no rclone to run it.
#
#     Idempotent. It uses the network in two cases only: to fetch the pinned
#     build when the rclone present is missing or below the floor, and to
#     check a newly written credential against its bucket. A unit that
#     already has a good rclone takes neither path here — step 2 finds the
#     existing credential and never probes — so on a provisioned unit this
#     is a no-op costing one version check.
#
#     --advisory, unlike setup.sh's plain call: here a merely-offline unit must
#     not lose an otherwise fine update over a backup binary it could not
#     fetch. The full diagnosis is printed either way; only the exit status
#     differs, and the next update with a connection provisions it.
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/provision-rclone.sh" --advisory

# ---------------------------------------------------------------------------
# 5. Trial backup, while the old stack is STILL RUNNING. pg_dump takes one
#    transactional snapshot, so this is safe on a live database, and a backup
#    that cannot be written (no space, a broken pg_dump) then aborts the update
#    with the appliance untouched, before any downtime.
#
#    This dump is NOT what a failed update restores: the unit keeps serving
#    until step 6, and anything written after the snapshot would be lost by
#    restoring it. The dump the restore uses is taken in step 7, with the
#    backend stopped, and replaces this one once it is verified.
# ---------------------------------------------------------------------------
echo "→ Making sure the database is up so we can back it up..."
# Probe container state WITHOUT mutating anything. The old unconditional
# `up -d db` here could recreate a running db container — and try to recreate
# the project network under the live stack — whenever the new code changed
# the compose config or image: that is what took Rionegro down on 2026-08-03.
# If db is already running we use it as-is; only when it is not do we start
# it, with --no-recreate so a pending config/image change cannot recreate
# containers while the old stack may still be serving. (--no-recreate is
# container-scoped; the full, clean recreate happens after the service is
# stopped, in step 7.)
if ! RUNNING_SERVICES="$($COMPOSE ps --services --status running 2>/dev/null)"; then
    echo "✗ Cannot determine container state (docker compose ps failed)."
    echo "  Aborting before touching anything."
    exit 1
fi
if ! echo "$RUNNING_SERVICES" | grep -qx db; then
    DB_STARTED_BY_US=1
    STACK_TOUCHED=1
    $COMPOSE up -d --no-recreate db
fi

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s — cannot take a safe backup."
        echo "  Aborting the update."
        exit 1   # EXIT trap reports the actual state (touched or untouched)
    fi
    sleep 2
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DUMP_FILE="$BACKUP_DIR/pre-update-$TIMESTAMP.sql.gz"
echo "→ Trial backup while the unit still serves (checks pg_dump and free space;"
echo "  replaced by the backup taken with the backend stopped in step 7):"
echo "    $DUMP_FILE"
# Through write_dump: created 0600, and a pg_dump failure fails the line even
# though gzip exits 0.
write_dump "$DUMP_FILE" $COMPOSE exec -T db pg_dump -U "$DATABASE_USER" -d "$DATABASE_NAME"

# A failed pg_dump can still leave a tiny valid gzip (an empty stream gzips to
# ~20 bytes). Refuse to proceed if the dump looks empty — better to abort than
# to migrate with no real safety net.
DUMP_BYTES="$(wc -c < "$DUMP_FILE" | tr -d ' ')"
if [ "${DUMP_BYTES:-0}" -lt 100 ]; then
    echo "✗ Backup looks empty (${DUMP_BYTES} bytes) — pg_dump likely failed."
    echo "  Refusing to migrate without a real backup. Aborting."
    exit 1   # EXIT trap removes the bad dump and reports the actual state
fi
BACKUP_VERIFIED=1
echo "  ✓ Backup written (${DUMP_BYTES} bytes)."

# Record the commit to roll back to, next to the dump, for rollback-update.sh.
# IMPORTANT: this script runs AFTER the operator has already pulled / checked
# out the new code (see header), so HEAD ($CURRENT_SHA) is the NEW version.
# The rollback target is the commit that was RUNNING before this update — the
# one the last successful update recorded in last-deployed-SHA — never HEAD.
if [ -n "$PREV_DEPLOYED_SHA" ]; then
    echo "$PREV_DEPLOYED_SHA" > "$SHA_FILE"
    echo "  Rollback target recorded: $PREV_DEPLOYED_SHA"
else
    # No record of the previously deployed version. Writing HEAD here would
    # make rollback-update.sh "roll back" to the very version being installed,
    # so record nothing: the DB restore still works without it.
    rm -f "$SHA_FILE"
    echo "  ⚠ No record of the previously deployed version — if this update"
    echo "    needs rolling back, rollback-update.sh will restore the database"
    echo "    but cannot switch the code back automatically."
fi

# Bind this attempt's state record to this attempt's dump, so rollback can
# tell which record describes the dump it restores (several attempts can
# share one previously-deployed commit). No record written, no reference:
# rollback then reports the pixi environment and frontend image as unknown.
if [ -f "$STATE_FILE" ]; then
    if ! {
        echo "state: $(basename "$STATE_FILE")"
        echo "dump: $(basename "$DUMP_FILE")"
    } > "$REF_FILE" 2>/dev/null; then
        rm -f "$REF_FILE" || true
    fi
else
    rm -f "$REF_FILE" || true
fi

# Retention: keep only the newest $KEEP_DUMPS dumps.
echo "→ Pruning old backups (keeping newest $KEEP_DUMPS)..."
# Filenames are our own fixed timestamped pattern; ls -t sorting is safe here.
# shellcheck disable=SC2012
ls -1t "$BACKUP_DIR"/pre-update-*.sql.gz 2>/dev/null | tail -n +$((KEEP_DUMPS + 1)) | while read -r old; do
    echo "    removing $old"
    rm -f "$old"
done
echo ""

# ---------------------------------------------------------------------------
# 6. Stop the service. From HERE the EXIT trap restores the previous version
#    and starts it on any failure. (The db container — whether it was already up under the service
#    or started by us for the backup — is stopped by systemd's stop path via
#    docker compose; we bring it back for the migration below.)
# ---------------------------------------------------------------------------
echo "→ Stopping service to apply migrations..."
SERVICE_STOPPED=1
systemctl stop dtk 2>/dev/null || true
# systemd runs ExecStop (stop.sh) only for an ACTIVE unit. If dtk was already
# failed or inactive, the containers can still be up under their
# restart: unless-stopped policy — so tear down explicitly here.
# --remove-orphans also clears containers whose service no longer exists in
# the compose files; without it a stale container keeps an endpoint on the
# project network and wedges every later network operation (NEH-214).
$COMPOSE down --remove-orphans
assert_stack_gone
echo ""
fail_point stopped

# ---------------------------------------------------------------------------
# 7. Apply DB migrations.
# ---------------------------------------------------------------------------
echo "→ Starting database for migrations..."
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s."
        exit 1   # EXIT trap restores the previous version
    fi
    sleep 2
done

# The backup a failed update restores, taken now that nothing writes: the
# backend is stopped and only the db container runs. Same write_dump (0600
# from the start) and the same size check as the trial dump in step 5.
RESTORE_DUMP="$BACKUP_DIR/pre-update-$(date +%Y%m%d-%H%M%S).sql.gz"
if [ "$RESTORE_DUMP" = "$DUMP_FILE" ]; then
    RESTORE_DUMP="$BACKUP_DIR/pre-update-$(date +%Y%m%d-%H%M%S)-stopped.sql.gz"
fi
echo "→ Backing up the database with the backend stopped, to:"
echo "    $RESTORE_DUMP"
DUMP_STARTED_AT="$(date +%s)"
write_dump "$RESTORE_DUMP" $COMPOSE exec -T db pg_dump -U "$DATABASE_USER" -d "$DATABASE_NAME"
RESTORE_DUMP_BYTES="$(wc -c < "$RESTORE_DUMP" | tr -d ' ')"
if [ "${RESTORE_DUMP_BYTES:-0}" -lt 100 ]; then
    echo "✗ Backup looks empty (${RESTORE_DUMP_BYTES} bytes) — pg_dump likely failed."
    echo "  Refusing to migrate without a real backup."
    exit 1   # EXIT trap removes it; no migration ran, so the database is untouched
fi
RESTORE_DUMP_VERIFIED=1
echo "  ✓ Backup written (${RESTORE_DUMP_BYTES} bytes, $(( $(date +%s) - DUMP_STARTED_AT ))s)."
# It replaces the trial dump: rollback-update.sh takes the newest dump and the
# one pre-update-ref names, and both must now be this one.
if [ -f "$STATE_FILE" ]; then
    if ! {
        echo "state: $(basename "$STATE_FILE")"
        echo "dump: $(basename "$RESTORE_DUMP")"
    } > "$REF_FILE" 2>/dev/null; then
        rm -f "$REF_FILE" || true
    fi
fi
rm -f "$DUMP_FILE"
DUMP_FILE="$RESTORE_DUMP"
fail_point dumped

echo "→ Applying migrations..."
cd "$PROJECT_ROOT/backend"
# Set before the call: a migration that fails part-way can leave the database
# changed, and the restore then loads this run's dump.
MIGRATION_STARTED=1
run_as_user "$PIXI_BIN" run db-upgrade
cd "$PROJECT_ROOT"
echo ""
# The revision the database is now at, for the record a later failure writes.
MIGRATED_REVISION="$($COMPOSE exec -T db psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -Atc 'SELECT version_num FROM alembic_version' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)"
fail_point migrate

echo "→ Stopping database..."
$COMPOSE down --remove-orphans
assert_stack_gone
echo ""

# ---------------------------------------------------------------------------
# 8. Restart the service on the new version.
# ---------------------------------------------------------------------------
echo "→ Starting service..."
NEW_STARTED_AT="$(date +%s)"
systemctl start dtk
fail_point started
echo "  Waiting up to ${HEALTH_TIMEOUT}s for the backend to answer /health..."
if wait_for_health "$HEALTH_TIMEOUT"; then
    NEW_SERVED=1
    echo "  Service running and the backend answers /health ✓"
    fail_point served
else
    echo "✗ The new version did not come up: the backend did not answer /health"
    echo "  within ${HEALTH_TIMEOUT}s."
    exit 1   # EXIT trap restores the previous version
fi
echo ""

# Success: record this commit as the last good deploy, and disarm the trap.
# Never write "unknown" — that would destroy a valid record (from
# provisioning or a previous update) and break the next rollback.
if [ "$CURRENT_SHA" != "unknown" ]; then
    echo "$CURRENT_SHA" > "$LAST_DEPLOYED_SHA_FILE"
    # Record the image that is serving now, against this commit, where the
    # provenance is known. Best-effort: a missing record only makes a later
    # rollback report the image as unknown.
    DEPLOYED_IMAGE="$(frontend_image_id || true)"
    if [ -n "$DEPLOYED_IMAGE" ] && {
        echo "sha: $CURRENT_SHA"
        echo "image: $DEPLOYED_IMAGE"
    } > "$LAST_DEPLOYED_FRONTEND_FILE" 2>/dev/null; then
        :
    else
        rm -f "$LAST_DEPLOYED_FRONTEND_FILE" || true
    fi
else
    echo "⚠ Could not resolve the installed commit; last-deployed-SHA left unchanged."
fi
UPDATE_OK=1
SERVICE_STOPPED=0

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "=========================================="
echo " Update complete!"
echo "=========================================="
echo ""
echo "  Now running version: $CURRENT_SHA"
echo "  A pre-update backup was saved at:"
echo "    $DUMP_FILE"
echo "  If something looks wrong, you can roll back with:"
echo "    sudo $SCRIPT_DIR/rollback-update.sh"
echo ""
echo "  Frontend: http://localhost:3000"
echo "  Backend:  http://localhost:8000/health"
echo "  Logs:     journalctl -u dtk -f"
echo ""
