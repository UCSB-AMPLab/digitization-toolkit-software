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
# modifications first (NEH-270); the operator does not run git.
#
# For an offline update from a USB drive, copy the new repo content into place
# first, then run with --no-pull so the script does not try to reach the
# remote.
#
# Usage: sudo ./scripts/update.sh [--yes] [--no-pull [--offline]]
#        sudo ./scripts/update.sh --resolve-forward
#   --yes       Skip the "this update needs internet" confirmation prompt
#               (for scripted / unattended use).
#   --no-pull   Do not fetch; update to whatever is already checked out.
#               For offline updates, for the 0.1.0 install (code fetched by
#               hand first), and for testing a specific commit. The checkout
#               must be clean, with every submodule on its pin, and must
#               descend from the deployed commit (see 0a); otherwise it is
#               refused before anything changes. It skips git only: apt is
#               still tried for avahi-utils (4d).
#   --offline   With --no-pull, for a unit with no network at all: 4d does
#               not try apt, and a unit without avahi-utils keeps its name.
#   --resolve-forward [--no-start]
#               After an update that failed once its new version had started
#               (see UNRESOLVED_FILE below), accept that version as deployed
#               instead of rolling back: checked only, then recorded, then
#               started. It changes no code and no data. With --no-start it
#               records the version and leaves the unit stopped, so that a
#               fixed commit can then be deployed with an ordinary update.
#
# Test only: CAPTUA_UPDATE_FAIL_AT=<point> (DTK_UPDATE_FAIL_AT too) makes the script fail on purpose at
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
# Test only: CAPTUA_UPDATE_KILL_AT=<point> (DTK_UPDATE_KILL_AT too) kills the
# script with SIGKILL at one point of a crossing (step 0b), which no trap
# sees, as a power cut would: cross-recorded (the record says building,
# nothing made yet), cross-built (cloned and verified), cross-copied (.env
# and backend/.pixi copied), cross-synced (the record says exchanging and
# the start guard is set), cross-exchanged (the directories exchanged), cross-renamed
# (the previous checkout renamed .pre-merge), cross-crossed (the record set
# to crossed), cross-stopped (the service stopped, before the exchange
# step), cross-discarding (a discard
# begun: the record says discarding, part of <root>.new removed),
# cross-discard-synced (a discard's removal of <root>.new synced, the record
# not yet removed); and
# cross-exchange-helper kills the exchange helper alone, just after a
# successful exchange. term:<point> sends SIGTERM instead, which the usual
# handler and the EXIT trap see.
#
# Exit status 3: the update was a crossing to the merged layout, which ends
# the run with the checkout holding the new code, not yet installed (see the
# end of step 0b). Run the script again to install it.
#
# Also tunable: CAPTUA_UPDATE_HEALTH_TIMEOUT (seconds to wait for /health after a
# start, default 300) and CAPTUA_UPDATE_HEALTH_POLL (seconds between tries,
# default 5). Both also answer to their DTK_ names.
#
# Version: 0.3.0

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=captua-env.sh
. "$SCRIPT_DIR/captua-env.sh"

ASSUME_YES=0
DO_PULL=1
OFFLINE=0
RESOLVE_FORWARD=0
RESOLVE_NO_START=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-pull) DO_PULL=0 ;;
        --offline) OFFLINE=1 ;;
        --resolve-forward) RESOLVE_FORWARD=1 ;;
        --no-start) RESOLVE_NO_START=1 ;;
        *) echo "Unknown argument: $arg"; echo "Usage: sudo ./scripts/update.sh [--yes] [--no-pull [--offline]] | --resolve-forward"; exit 2 ;;
    esac
done

if [ "$RESOLVE_NO_START" -eq 1 ] && [ "$RESOLVE_FORWARD" -ne 1 ]; then
    echo "✗ --no-start goes with --resolve-forward only."
    exit 2
fi
# Without --no-pull the update fetches, which an offline unit cannot do.
if [ "$OFFLINE" -eq 1 ] && { [ "$DO_PULL" -eq 1 ] || [ "$RESOLVE_FORWARD" -eq 1 ]; }; then
    echo "✗ --offline goes with --no-pull only."
    exit 2
fi

FAIL_AT="$(captua_env UPDATE_FAIL_AT)"
case "$FAIL_AT" in
    ""|fetched|build|pixi|stopped|dumped|migrate|started|served) ;;
    *) echo "✗ DTK_UPDATE_FAIL_AT='$FAIL_AT' is not a failure point this script knows."
       echo "  Known: fetched build pixi stopped dumped migrate started served (test only)."
       exit 2 ;;
esac
KILL_AT="$(captua_env UPDATE_KILL_AT)"
case "$KILL_AT" in
    ""|cross-recorded|cross-built|cross-copied|cross-stopped|cross-synced|cross-exchange-helper|cross-exchanged|cross-renamed|cross-crossed|cross-discarding|cross-discard-synced) ;;
    term:cross-copied|term:cross-stopped|term:cross-synced|term:cross-exchanged|term:cross-renamed|term:cross-crossed) ;;
    *) echo "✗ DTK_UPDATE_KILL_AT='$KILL_AT' is not a point this script knows."
       echo "  Known: cross-recorded cross-built cross-copied cross-stopped cross-synced"
       echo "  cross-exchange-helper cross-exchanged cross-renamed cross-crossed"
       echo "  cross-discarding cross-discard-synced, and term:<point> (test only)."
       exit 2 ;;
esac
HEALTH_TIMEOUT="$(captua_env UPDATE_HEALTH_TIMEOUT 300)"
HEALTH_POLL="$(captua_env UPDATE_HEALTH_POLL 5)"

# One update or rollback at a time. update.sh and rollback-update.sh (and
# its kept copy under /var/lib/dtk) take the same lock, held until they exit,
# so two runs cannot interleave a stop, a backup, a migration and a restore.
# The file is opened without truncating it, so a refused run can read the
# holder's pid; the holder writes its own once it has the lock.
DTK_LOCK_FILE="/run/dtk-update.lock"
take_update_lock() {
    local holder
    if ! command -v flock >/dev/null 2>&1; then
        echo "⚠ flock is not installed: another update or rollback is not ruled out."
        return 0
    fi
    if ! exec 9<>"$DTK_LOCK_FILE"; then
        echo "✗ Could not open $DTK_LOCK_FILE."
        exit 1
    fi
    if ! flock -n 9; then
        holder="$(head -n 1 "$DTK_LOCK_FILE" 2>/dev/null | tr -dc '0-9')"
        echo "✗ Another update or rollback is running (pid ${holder:-unknown}). This one"
        echo "  will not run alongside it; wait for it to finish, then run this again."
        exit 1
    fi
    printf '%s\n' "$$" > "$DTK_LOCK_FILE" 2>/dev/null || true
}
take_update_lock

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
# and then PIXI_BIN below would be /root/.pixi/bin/pixi, which does not exist on
# a unit where pixi was installed for the appliance user: the deploy would stop
# at `pixi install` with "env: '/root/.pixi/bin/pixi': No such file or
# directory". The pixi and migration calls run as DTK_USER; git runs as the
# checkout's owner (REPO_USER below).
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
# rather than inferred. In a service context with no SUDO_USER, git run as
# root hits the dubious-ownership failure (NEH-271), because root's global
# config carries no safe.directory. DTK_USER can still be root when `stat`
# fails and the fallback is whoami, so git does not use it. The owner's HOME
# also matters: the
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
# While a record exists the unit must not start, on a reboot or a restart, so
# the record is mirrored by a flag that a systemd drop-in turns into a start
# condition for dtk.service. Kept outside /var/lib/dtk, in a root-only
# directory. rollback-update.sh and --resolve-forward remove it on success;
# keep these paths in sync with rollback-update.sh.
UNRESOLVED_FLAG_DIR="/etc/dtk"
UNRESOLVED_FLAG="$UNRESOLVED_FLAG_DIR/unresolved-deployment"
UNRESOLVED_DROPIN="/etc/systemd/system/dtk.service.d/unresolved.conf"
SYSTEM_HELPER="/usr/local/bin/dtk-system-helper"
UPDATE_PAGE_MARKER="/run/dtk-update-page.wanted"
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
# the directory and the dumps in it are root's alone. Under root's default
# umask a dump would be 0644 in a 0755 directory, readable by any local
# user. Nothing that runs as
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
# Dumps written before the directory was made private can be 0644. Symlinks
# are skipped (find does not follow them), so nothing outside the directory
# is changed.
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
# anything is fetched, built, stopped or written. The record's kinds:
#   started-failed  the new version was started and the update then failed;
#                   the database is migrated for it (the default for a record
#                   with no kind field)
#   restore-failed  the automatic database restore failed after the database
#                   had been dropped; only the rollback can repair it
#   restore-refused the automatic restore was refused before anything was
#                   dropped; the database is as the migration left it
#   migrated-not-restored
#                   a migration began and the code was not moved back (the
#                   restore failed, or the run was cut off)
record_field() {
    sed -n "s/^$1: //p" "$UNRESOLVED_FILE" 2>/dev/null | head -n 1
}
UNRESOLVED_KIND=""
# A crossing record in the same directory that says the crossing set the
# flag accounts for it: a crossing sets it before its exchange and keeps it
# until the install; crossing_settle, below, checks the record and deals
# with both.
# The record is checked (lstat: a real 0700 directory and a regular 0600
# file, both this user's) before anything reads it: a fifo or a symlink
# there would block a read, or read something else.
if ! { [ -e "$UNRESOLVED_FILE" ] || [ -L "$UNRESOLVED_FILE" ]; } && [ -e "$UNRESOLVED_FLAG" ] \
        && { [ -e "$UNRESOLVED_FLAG_DIR/crossing" ] || [ -L "$UNRESOLVED_FLAG_DIR/crossing" ]; } \
        && ! python3 -c 'import os, stat, sys
d, f = os.path.dirname(sys.argv[1]), sys.argv[1]
st, sf = os.lstat(d), os.lstat(f)
ok = (stat.S_ISDIR(st.st_mode) and st.st_uid == os.geteuid() and stat.S_IMODE(st.st_mode) == 0o700
      and stat.S_ISREG(sf.st_mode) and sf.st_uid == os.geteuid() and stat.S_IMODE(sf.st_mode) == 0o600)
sys.exit(0 if ok else 1)' "$UNRESOLVED_FLAG_DIR/crossing" 2>/dev/null; then
    echo "✗ $UNRESOLVED_FLAG exists, and $UNRESOLVED_FLAG_DIR/crossing is not a crossing"
    echo "  record this script can read (it must be a regular file, this user's, mode"
    echo "  0600, in a 0700 directory: not a symlink, a fifo or anything else). This"
    echo "  update will not run. Look at both, then remove what does not belong:"
    echo "      sudo ls -la $UNRESOLVED_FLAG_DIR"
    exit 1
fi
if ! { [ -e "$UNRESOLVED_FILE" ] || [ -L "$UNRESOLVED_FILE" ]; } && [ -e "$UNRESOLVED_FLAG" ] \
        && ! grep -qx 'flag crossing' "$UNRESOLVED_FLAG_DIR/crossing" 2>/dev/null; then
    echo "✗ $UNRESOLVED_FLAG exists without its record, so this update will not run."
    echo "  An earlier update or rollback could not write $UNRESOLVED_FILE, or it"
    echo "  was removed by hand. While the flag exists systemd does not start dtk."
    echo "  Find out which version the code is on and whether the database matches"
    echo "  it (that run's output, systemctl status dtk) before going on. When"
    echo "  they agree, remove the flag and run this again:"
    echo "      sudo rm $UNRESOLVED_FLAG"
    exit 1
fi
if [ -e "$UNRESOLVED_FILE" ] || [ -L "$UNRESOLVED_FILE" ]; then
    UNRESOLVED_KIND="$(record_field kind)"
    [ -n "$UNRESOLVED_KIND" ] || UNRESOLVED_KIND=started-failed
fi
if [ -n "$UNRESOLVED_KIND" ] && [ "$RESOLVE_FORWARD" -ne 1 ]; then
    echo "✗ An earlier update was left unresolved, so this update will not run."
    echo ""
    if [ "$UNRESOLVED_KIND" = restore-refused ]; then
        echo "  That update failed after its migration, and the database restore was"
        echo "  refused ($(record_field refused-because)): nothing was dropped, and the"
        echo "  database is as the migration left it, while the code is back on"
        echo "  code-commit below. The unit was left stopped. It recorded, in"
        echo "  $UNRESOLVED_FILE:"
    elif [ "$UNRESOLVED_KIND" = restore-failed ] && [ "$(record_field recorded-by)" = rollback-update.sh ]; then
        echo "  A rollback dropped the database and did not finish loading its backup"
        echo "  (it failed or was cut off): the database may be empty or partly"
        echo "  restored. The unit was left stopped. It recorded, in"
        echo "  $UNRESOLVED_FILE:"
    elif [ "$UNRESOLVED_KIND" = restore-failed ]; then
        echo "  That update failed, and restoring the database from its backup then"
        echo "  failed too: the database may be empty or partly restored. The unit"
        echo "  was left stopped. It recorded, in $UNRESOLVED_FILE:"
    elif [ "$UNRESOLVED_KIND" = migrated-not-restored ]; then
        echo "  That update failed after its migration began (or was cut off during"
        echo "  it), and the code was not moved back, or only part-way: code-commit"
        echo "  below is where the superproject is, and a submodule may be off its"
        echo "  pin. The database may be migrated or partly migrated. The unit was"
        echo "  left stopped. It recorded, in $UNRESOLVED_FILE:"
    else
        echo "  That update started the new version and then failed: the code is the"
        echo "  new version's, and the database is migrated for it."
        if [ -e "$UNRESOLVED_FLAG" ]; then
            echo "  The unit was left stopped."
        fi
        echo "  It recorded, in $UNRESOLVED_FILE:"
    fi
    sed 's/^/      /' "$UNRESOLVED_FILE" 2>/dev/null || echo "      (the record could not be read)"
    if [ ! -e "$UNRESOLVED_FLAG" ]; then
        echo "  ⚠ The unit was NOT kept stopped: there is no start flag"
        echo "    ($UNRESOLVED_FLAG), so dtk may have run since, on a reboot or a"
        echo "    restart, and may have taken writes that a rollback would discard."
    fi
    rec_mtime="$(stat -c %Y "$UNRESOLVED_FILE" 2>/dev/null || stat -f %m "$UNRESOLVED_FILE" 2>/dev/null || echo "")"
    if [ -n "$rec_mtime" ]; then
        rec_age=$(( $(date +%s) - rec_mtime ))
        echo "  The record is $((rec_age / 3600))h $(((rec_age % 3600) / 60))m old."
        # From the second after the record: the failed version's own start
        # can share the second the record was written in.
        if rec_starts="$(journalctl -u dtk --since "@$((rec_mtime + 1))" -o cat --no-pager 2>/dev/null)"; then
            if printf '%s\n' "$rec_starts" | grep -q 'Started dtk[.]service'; then
                echo "  ⚠ dtk HAS been started since it was written (journal): the unit may"
                echo "    have run on code and data that do not agree. Check before choosing."
            else
                echo "  dtk has not been started since it was written (journal)."
            fi
        else
            echo "  Whether dtk has been started since could not be read from the journal."
        fi
    fi
    echo ""
    if [ "$UNRESOLVED_KIND" = restore-failed ] || [ "$UNRESOLVED_KIND" = restore-refused ]; then
        echo "  The way forward is to restore the database from that backup, with:"
        echo "       $(record_field rollback-command)"
        echo "  It removes this record when it succeeds."
    else
        echo "  Two ways forward:"
        echo "  1. Return to the previous version, code and database:"
        echo "       $(record_field rollback-command)"
        echo "     It discards everything written since that backup. It removes this"
        echo "     record when it succeeds."
        echo "     (If the checkout has modified files, clear them first: the rollback"
        echo "     refuses a checkout with local changes.)"
        echo "  2. Keep the failed version, once whatever stopped it is fixed:"
        echo "       sudo $SCRIPT_DIR/update.sh --resolve-forward"
        echo "     It checks that the code is that version and that the database is at"
        echo "     its migration head, records it as deployed and starts it. To deploy"
        echo "     a fixed commit instead of starting this one, add --no-start, then"
        echo "     run update.sh as usual."
    fi
    exit 1
fi
if [ "$RESOLVE_FORWARD" -eq 1 ] && [ -z "$UNRESOLVED_KIND" ]; then
    echo "✗ --resolve-forward: there is no unresolved update to resolve"
    echo "  ($UNRESOLVED_FILE does not exist)."
    exit 2
fi
if [ "$RESOLVE_FORWARD" -eq 1 ] && { [ "$UNRESOLVED_KIND" = restore-failed ] || [ "$UNRESOLVED_KIND" = restore-refused ]; }; then
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
# The crossing (step 0b; see crossing_cross): the submodule paths that become
# folders; how far this run has taken it (building, which includes copying,
# then exchanging); the paths and commits its record names; and how the
# exchange came out. A fresh attempt takes its values from
# crossing_begin_attempt alone; crossing_settle empties them
# (crossing_clear_attempt) once it has removed a record.
CROSSING=""
CROSS_PATHS=()
CROSS_STAGE=""
CROSS_ROOT=""
CROSS_ROOT_ID=""
CROSS_NEW=""
CROSS_NEW_ID=""
CROSS_PRE_DIR=""
CROSS_OLD=""
CROSS_TARGET=""
CROSS_FLAG=""
CROSS_RESULT=""
CROSS_WAS_ACTIVE=0
CROSS_SERVICE_STOPPED=0
CROSS_SERVICE=""
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
RESTORE_DB_NOT_DROPPED_WHY=""
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

# Test only (see the header): SIGKILL here when DTK_UPDATE_KILL_AT names this point.
kill_point() {
    if [ "$KILL_AT" = "$1" ]; then
        echo "✗ DTK_UPDATE_KILL_AT=$1: killed here on purpose (test only)."
        kill -KILL $$
    elif [ "$KILL_AT" = "term:$1" ]; then
        echo "✗ DTK_UPDATE_KILL_AT=term:$1: SIGTERM here on purpose (test only)."
        kill -TERM $$
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

# gitlinks_match_head <repo-dir> [checked-out]: 0 when every submodule's
# entry in the index equals the gitlink in HEAD's tree and, with
# "checked-out", the commit checked out in the submodule equals it too
# (recursively); 1 when one differs; 2 when something could not be read.
# `git submodule status` is no substitute: it compares the submodule with the
# index, so a gitlink staged to another commit, with the submodule on that
# commit, reads as on its pin. `diff --cached --ignore-submodules=all` does
# not see a staged gitlink at all.
gitlinks_match_head() {
    local dir="$1" mode="${2:-}" tree line sha path idx cur rc
    tree="$(run_as_repo_owner git -C "$dir" ls-tree -r HEAD 2>/dev/null)" || return 2
    while IFS= read -r line; do
        [ "${line%% *}" = 160000 ] || continue
        sha="$(printf '%s' "${line%%$'\t'*}" | awk '{print $3}')"
        path="${line#*$'\t'}"
        idx="$(run_as_repo_owner git -C "$dir" ls-files -s -- "$path" 2>/dev/null | awk '{print $2}')" || return 2
        [ "$idx" = "$sha" ] || return 1
        if [ "$mode" = checked-out ]; then
            [ -e "$dir/$path/.git" ] || return 1
            cur="$(run_as_repo_owner git -C "$dir/$path" rev-parse HEAD 2>/dev/null)" || return 2
            [ "$cur" = "$sha" ] || return 1
            rc=0
            gitlinks_match_head "$dir/$path" checked-out || rc=$?
            [ "$rc" -eq 0 ] || return "$rc"
        fi
    done <<< "$tree"
    return 0
}

# flagged_index_entries: print "<tag> <path>" for every index entry marked
# assume-unchanged (a lowercase tag in `git ls-files -v`) or skip-worktree
# (S), in the superproject and in every submodule, recursively; submodule
# paths are given from the superproject. Exit 2 when a listing failed. git
# does not report changes to such an entry, so tracked_files_modified cannot
# see them; rollback-update.sh refuses the same flags in its own preflight.
flagged_index_entries() {
    local super subs
    super="$(run_as_repo_owner git -C "$PROJECT_ROOT" ls-files -v 2>/dev/null)" || return 2
    # git's output is held first, so a failed listing fails the foreach
    # rather than the sed that prefixes the paths; nothing is written.
    subs="$(run_as_repo_owner git -C "$PROJECT_ROOT" submodule foreach --quiet --recursive \
        'out="$(git ls-files -v)" || exit 1; printf "%s\n" "$out" | sed "s|^\(.\) |\1 $displaypath/|"' 2>/dev/null)" || return 2
    printf '%s\n%s\n' "$super" "$subs" | grep '^[a-zS] '
    return 0
}

# Tracked files modified anywhere in the checkout? 0 clean, 1 modified,
# anything else a read that failed (treated as modified). Superproject files
# with submodules ignored, then each submodule's own files: a submodule that is
# merely on a different commit is what an interrupted update leaves, and the
# restore moves it; a modified file inside it is someone's work, and the
# restore will not discard it. The same refusal rollback-update.sh makes.
tracked_files_modified() {
    local rc=0 subs sub
    # Working tree against HEAD, then the index against HEAD: `diff HEAD`
    # alone misses a change that is staged and then undone in the file.
    run_as_repo_owner git -C "$PROJECT_ROOT" diff HEAD --quiet --ignore-submodules=all 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    run_as_repo_owner git -C "$PROJECT_ROOT" diff --cached HEAD --quiet --ignore-submodules=all 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    # A gitlink staged to a commit other than HEAD's is a staged change as
    # well, which the line above does not see.
    gitlinks_match_head "$PROJECT_ROOT" || return $?
    subs="$(run_as_repo_owner git -C "$PROJECT_ROOT" submodule foreach --quiet --recursive 'printf "%s\n" "$displaypath"' 2>/dev/null)" || return 2
    for sub in $subs; do
        run_as_repo_owner git -C "$PROJECT_ROOT/$sub" diff HEAD --quiet 2>/dev/null || rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        run_as_repo_owner git -C "$PROJECT_ROOT/$sub" diff --cached HEAD --quiet 2>/dev/null || rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
    done
    return 0
}

# ---------------------------------------------------------------------------
# The crossing: an update whose new code holds the frontend and backend
# submodules as folders of the superproject (detected in step 0b).
#
# At every instant the checkout root ($PROJECT_ROOT, /home/pi/dtk on a unit)
# is a complete checkout, the old one or the new one; the old checkout is
# not changed until the exchange; every state a stop can leave is named by
# which directories exist and their markers, and the next run finishes it or
# undoes it.
#
# Threat model. On a unit pi is root-equivalent (sudoers: `(ALL) NOPASSWD:
# ALL`), so the crossing does not defend against a process running as pi
# that races it, for instance by swapping a path inside <root>.new between a
# check and a write while the copy runs. It defends against runs stopped at
# any point (a signal, SIGKILL, a power cut), stale state, directories made
# by hand, and unusual configuration; and it checks, cheaply, that its record
# and the directory holding it are root's alone.
#
# What the crossing carries from the old checkout is a closed list:
#   .env            at the root: the unit's settings
#   backend/.pixi   the backend's environment
# copied (no file shared, modes and owners kept, symlinks recreated), with
# Python's caches (__pycache__ directories, *.pyc files) left out anywhere:
# Python writes them again. Nothing writes these two while the unit runs (the
# backend reads them), so no writer has to be stopped and the service keeps
# running during the copy. One more untracked path is accepted and not
# carried: wiki, the retired wiki submodule's checkout, which stays as it is
# in the previous checkout (crossing_retired_wiki says when, and why that is
# safe). Every other untracked or ignored path in the checkout or its
# submodules refuses the crossing, named, before anything is written, and
# again each time the copy lists them: data belongs outside the checkout
# (/var/lib/dtk by default).
#
# Immediately before the exchange step the crossing stops the service, only
# so that the running backend cannot import code from the new tree once it
# is at the root (its module paths name <root>/backend); the copy does not
# depend on that stop. A stop that fails means no exchange. After the
# exchange the service stays down, kept there by the flag.
#
# Before the exchange the crossing sets the unresolved-deployment flag
# (set_unresolved_flag: /etc/dtk/unresolved-deployment and the dtk.service
# drop-in that makes it a start condition), so that neither a restart nor a
# reboot starts the exchanged checkout before its install has run. A
# completed crossing leaves the flag set and its record at crossed; the
# install clears both. When the
# exchange did not happen, the discard clears the flag the crossing set (the
# record says so); a refusal or discard before the exchange step never
# touches it.
#
# The new checkout is built beside the old one, in <root>.new: a local clone
# of the target commit from the old checkout's own .git (objects hardlinked,
# no network), with the old checkout's origin and branch configuration. The
# carried files (.env, backend/.pixi; the list above) are copied into it. Then the two
# directories are exchanged in one rename(2), and the old checkout, now at
# <root>.new, is renamed <root>.pre-merge, where it is kept for rolling back.
# Nothing writes into the old checkout: git only reads it, and the copies
# share no file with it.
#
# The state is one record, CROSS_RECORD, outside both checkouts: /etc/dtk
# must be a real directory owned by the user this script runs as (root on a
# unit) with mode 0700, and the record a regular file of that owner with
# mode 0600; anything else is refused, and no symlink is followed. Nothing
# inside either checkout says anything about the crossing. The record names
# the checkout root by its physical path and by the identity it had when
# the crossing began, <root>.new by its path and by the identity its mkdir
# gave it (an identity is the filesystem's UUID and the inode number,
# crossing_id), <root>.pre-merge, the old HEAD, the target and the step.
# A directory is removed or moved only when it is a real directory (lstat)
# at the recorded path with the recorded identity; anything else at the path
# is left alone and the run refuses. The record is written before each step
# begins (a fresh temporary file in /etc/dtk, fsynced, renamed over the
# record, then the directory fsynced), and each step names what may exist:
#   building    <root>.new may exist: this procedure's once the record holds
#               its identity (written right after the mkdir), a clone in
#               progress. Without an identity, only a missing <root>.new is
#               a state this script resolves.
#   copying     <root>.new is the verified clone; the ignored and untracked
#               files are being copied into it.
#   exchanging  <root>.new is complete and on disk; the exchange may or may
#               not have happened. The identities and HEADs decide: <root>
#               with <root>.new's identity at the target, and <root>.new with
#               the old root's identity at the old commit, is exchanged; the
#               two at their own identities is not.
#   renaming    exchanged and on disk; the old checkout is being renamed
#               <root>.pre-merge.
#   crossed     done: the new checkout at the root, the old one at
#               <root>.pre-merge, the start flag the crossing set in place.
#               The record stays until the install (the new code's
#               update.sh) clears the flag and removes it; this script,
#               meeting it, says the install is due and changes nothing
#               (exit 3).
#   discarding  <root>.new, this procedure's, is being removed.
#   discarded   <root>.new is removed and the flag cleared, and the service
#               the crossing stopped could not be started again: the next
#               run tries again, and removes the record once it is active.
# The record's `service stopped` line, written just before the crossing
# stops a running service, makes any discard (in that run or a later one)
# start the service again, on the conditions crossing_restart_if_stopped
# checks, before the record is removed.
# crossing_settle, at the start of every run, validates the whole state the
# record names before it renames or removes anything, then finishes or
# undoes it: building, copying and an exchange that did not happen are
# discarded; an exchange that happened is finished, to crossed; a discard
# resumes; crossed stops the run (the install is due). With no record there
# is no crossing state, whatever directories exist: a
# <root>.new with no record is not this procedure's, is never touched, and a
# crossing refuses while it is there.
# ---------------------------------------------------------------------------
CROSS_RECORD="$UNRESOLVED_FLAG_DIR/crossing"

# crossing_physical <dir>: <dir>'s path with every symlink resolved.
crossing_physical() {
    ( cd "$1" 2>/dev/null && pwd -P ) || true
}

# crossing_id <path>: "<filesystem UUID>:<st_ino>:<generation>" when <path>
# is a real
# directory (lstat: a symlink is not one) on a filesystem with a UUID; empty
# otherwise, with a non-zero status (and nothing printed) for one mounted on its own (findmnt's mount point is
# not its parent's), or one whose inode generation cannot be read. The
# generation (FS_IOC_GETVERSION, which ext4 keeps per inode and changes when
# an inode number is used again) tells a directory from another that was
# later given the same inode number. (Test only: CROSS_GEN_READER=fake, set
# by the suite, reads generations from FAKE_GENERATIONS, and fails for the
# path FAKE_GEN_FAIL names.) Not st_dev: a device's number can change across a
# reboot (a USB disk found as sdb instead of sda); its filesystem's UUID and
# an inode's number do not.
CROSS_GEN_READER="ioctl"
crossing_id() {
    local ino uuid
    ino="$(CROSS_GEN_READER="$CROSS_GEN_READER" python3 -c 'import ctypes, fcntl, os, stat, struct, sys
path = sys.argv[1]
try:
    st = os.lstat(path)
except OSError:
    sys.exit(0)
if not stat.S_ISDIR(st.st_mode):
    sys.exit(0)
if os.environ.get("CROSS_GEN_READER") == "fake":
    # Test only: the suite gives generations by path.
    gen = 1
    if os.environ.get("FAKE_GEN_FAIL") and os.path.realpath(os.environ["FAKE_GEN_FAIL"]) == os.path.realpath(path):
        sys.exit(0)
    for pair in os.environ.get("FAKE_GENERATIONS", "").split(";"):
        p, _, g = pair.rpartition("=")
        if p and p == os.path.realpath(path):
            gen = int(g)
else:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        sys.exit(0)
    try:
        size = ctypes.sizeof(ctypes.c_long)
        FS_IOC_GETVERSION = (2 << 30) | (size << 16) | (ord("v") << 8) | 1
        buf = fcntl.ioctl(fd, FS_IOC_GETVERSION, bytes(size))
        st2 = os.fstat(fd)
    except OSError:
        sys.exit(0)
    finally:
        os.close(fd)
    if st2.st_ino != st.st_ino:
        sys.exit(0)
    gen = struct.unpack("I", buf[:4])[0]
print("%d:%d" % (st.st_ino, gen))' "$1")"
    [ -n "$ino" ] || return 1
    uuid="$(findmnt -n -o UUID -T "$1" 2>/dev/null || true)"
    [ -n "$uuid" ] || return 1
    # And on the filesystem mounted where its parent is, now: a copy of the
    # filesystem (the same UUID and inodes) mounted at the path is not it.
    [ "$(findmnt -n -o TARGET -T "$1" 2>/dev/null)" = "$(findmnt -n -o TARGET -T "$(dirname "$1")" 2>/dev/null)" ] || return 1
    crossing_id_wellformed "$uuid:$ino" || return 1
    echo "$uuid:$ino"
}

# crossing_id_wellformed <id>: <id> has the three parts of an identity, a
# UUID, an inode number and a generation; empty is not one.
crossing_id_wellformed() {
    printf '%s\n' "$1" | grep -Eqx '[^:[:space:]]+:[0-9]+:[0-9]+'
}

# crossing_id_is <path> <id>: <path> has exactly identity <id>. Both sides
# must be read and well formed: an identity that cannot be read, or an empty
# recorded one, never matches, not even another empty one.
crossing_id_is() {
    local id
    crossing_id_wellformed "$2" || return 1
    id="$(crossing_id "$1")" || return 1
    [ "$id" = "$2" ]
}

# crossing_absent <path>: nothing at all is at <path>, not even a symlink.
crossing_absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

# crossing_head <dir>: the HEAD of the repository whose .git is <dir>/.git
# (never one found further up); empty when there is none.
crossing_head() {
    [ -d "$1/.git" ] && [ ! -L "$1/.git" ] || return 0
    run_as_repo_owner git --git-dir="$1/.git" rev-parse --verify --quiet HEAD 2>/dev/null || true
}

# crossing_sync: flush the filesystems to disk (`sync -f` is GNU-only), so
# that nothing the record goes on to say has happened is lost to a power
# cut. Its status is checked at every call.
crossing_sync() {
    python3 -c 'import os; os.sync()' || { echo "✗ Could not flush the filesystems to disk."; return 1; }
}

# The record's directory and file, checked with lstat: a real directory
# owned by the user this script runs as, mode 0700; a regular file of that
# owner, mode 0600. crossing_record_dir_ok makes the directory, 0700, when
# it is missing.
CROSS_PY_CHECK='
import os, stat, sys
def dir_ok(d, make):
    if make and not os.path.lexists(d):
        os.mkdir(d, 0o700)
        os.chmod(d, 0o700)
    st = os.lstat(d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
        sys.exit("%s must be a directory (not a symlink) owned by uid %d with mode 0700" % (d, os.geteuid()))
def file_ok(f):
    st = os.lstat(f)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o600:
        sys.exit("%s must be a regular file (not a symlink) owned by uid %d with mode 0600" % (f, os.geteuid()))
'
crossing_record_ok() {
    python3 -c "$CROSS_PY_CHECK"'
dir_ok(os.path.dirname(sys.argv[1]), False)
file_ok(sys.argv[1])' "$CROSS_RECORD"
}

# crossing_record <step>: write the record at <step> from the CROSS_*
# variables, durably: a fresh temporary file in the record's directory
# (created exclusively, 0600), fsynced, renamed over the record, then the
# directory fsynced. crossing_record_remove removes it the same way.
crossing_record() {
    python3 -c "$CROSS_PY_CHECK"'
path, body = sys.argv[1], sys.argv[2]
d = os.path.dirname(path)
dir_ok(d, True)
if os.path.lexists(path):
    file_ok(path)
tmp = path + ".tmp"
if os.path.lexists(tmp):
    os.unlink(tmp)
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    os.fchmod(fd, 0o600)
    os.write(fd, body.encode())
    os.fsync(fd)
finally:
    os.close(fd)
os.rename(tmp, path)
dfd = os.open(d, os.O_RDONLY)
os.fsync(dfd)
os.close(dfd)
' "$CROSS_RECORD" "$(printf 'captua-crossing 6\nstep %s\nroot %s\nrootid %s\nnew %s\nnewid %s\npre %s\nold %s\ntarget %s\nflag %s\nservice %s\n' \
        "$1" "$CROSS_ROOT" "$CROSS_ROOT_ID" "$CROSS_NEW" "$CROSS_NEW_ID" "$CROSS_PRE_DIR" "$CROSS_OLD" "$CROSS_TARGET" "${CROSS_FLAG:-none}" "${CROSS_SERVICE:-untouched}")"
}
crossing_record_remove() {
    python3 -c "$CROSS_PY_CHECK"'
path = sys.argv[1]
dir_ok(os.path.dirname(path), False)
if os.path.lexists(path):
    file_ok(path)
    os.unlink(path)
dfd = os.open(os.path.dirname(path), os.O_RDONLY)
os.fsync(dfd)
os.close(dfd)
' "$CROSS_RECORD"
}

# crossing_field <field>: the value of a record line.
crossing_field() {
    sed -n "s/^$1 //p" "$CROSS_RECORD" 2>/dev/null | head -n 1
}

# crossing_discard: remove <root>.new, as a step of its own, so that a stop
# in the middle of the removal resumes at the next run; make the removal
# durable; then remove the record. Only a real directory at the recorded
# path with the recorded identity is removed; rm does not follow symlinks
# below it. 1, with the record kept, when something else is at the path.
crossing_discard() {
    local id
    # A crossing stopped before its mkdir has no newid and no .new. Its record
    # (at building, the one step with an empty newid) is removed directly,
    # without discarding: neither the start guard nor the service has been
    # touched before the stop, so neither has anything to undo.
    if [ -z "$CROSS_NEW_ID" ] && crossing_absent "$CROSS_NEW" \
            && crossing_id_is "$CROSS_ROOT" "$CROSS_ROOT_ID" && [ "$(crossing_head "$CROSS_ROOT")" = "$CROSS_OLD" ] \
            && [ "${CROSS_FLAG:-none}" = none ] && [ "${CROSS_SERVICE:-untouched}" = untouched ]; then
        crossing_sync || return 1
        kill_point cross-discard-synced
        crossing_record_remove
        return
    fi
    # Every other discard has a .new this script made and recorded: with no
    # newid, a .new present is refused below as not this script's, and with
    # none present the record is refused here.
    if ! crossing_id_wellformed "$CROSS_NEW_ID" && crossing_absent "$CROSS_NEW"; then
        echo "✗ The crossing record ($CROSS_RECORD) names no identity for $CROSS_NEW,"
        echo "  and $CROSS_ROOT or the record is not as a crossing stopped before its"
        echo "  mkdir leaves them. Nothing has been changed; the record is kept."
        echo "  See:"
        echo "      sudo cat $CROSS_RECORD"
        return 1
    fi
    if ! crossing_absent "$CROSS_NEW"; then
        id="$(crossing_id "$CROSS_NEW" || true)"
        if ! crossing_id_is "$CROSS_NEW" "$CROSS_NEW_ID"; then
            echo "✗ $CROSS_NEW is not the directory this script made (it is ${id:+another directory}${id:-not a directory}),"
            echo "  so it is left as it is. The crossing record ($CROSS_RECORD) is kept."
            echo "  Look at $CROSS_NEW, move it away, then remove the record:"
            echo "      sudo rm $CROSS_RECORD"
            return 1
        fi
    fi
    crossing_record discarding || return 1
    if ! crossing_absent "$CROSS_NEW"; then
        rm -rf -- "${CROSS_NEW:?}/.git"
        kill_point cross-discarding
        rm -rf -- "${CROSS_NEW:?}"
    fi
    if ! crossing_absent "$CROSS_NEW"; then
        echo "✗ Could not remove $CROSS_NEW; the next run of this script tries again."
        return 1
    fi
    crossing_sync || return 1
    kill_point cross-discard-synced
    # Only reached with <root> the previous checkout: a flag this crossing
    # set goes before the record that says so.
    if [ "$CROSS_FLAG" = crossing ]; then
        rm -f "$UNRESOLVED_FLAG" || return 1
        crossing_sync || return 1
    fi
    # A service the crossing stopped (the record says so) is started again,
    # on the conditions crossing_restart_if_stopped checks; the record, at
    # discarded, stays until the service is confirmed active, so that the
    # next run tries again.
    if [ "$CROSS_SERVICE" = stopped ]; then
        crossing_record discarded || return 1
        CROSS_WAS_ACTIVE=1
        if ! crossing_restart_if_stopped; then
            echo "✗ The service, stopped by the crossing, could not be started again. See:"
            echo "      systemctl status dtk;  journalctl -u dtk -n 50"
            echo "  Once whatever stops it is fixed, start it with:"
            echo "      sudo systemctl start dtk"
            echo "  The crossing record ($CROSS_RECORD) is kept, at discarded, until the"
            echo "  service runs; the next run of update.sh starts it again and removes it."
            return 1
        fi
    fi
    crossing_record_remove
}

# crossing_finish: the exchange has happened. The whole state is checked
# first: <root> is the new checkout (its identity, the target), and the old
# checkout (the old root's identity, the old commit) is at <root>.new with
# nothing at <root>.pre-merge, or already at <root>.pre-merge with nothing
# at <root>.new. Only then is it renamed and the record set to crossed. 1, with
# nothing moved and the record kept, for any other state.
crossing_finish() {
    local ok_root=0
    crossing_id_is "$CROSS_ROOT" "$CROSS_NEW_ID" && [ "$(crossing_head "$CROSS_ROOT")" = "$CROSS_TARGET" ] && ok_root=1
    if [ "$ok_root" -eq 1 ] && crossing_id_is "$CROSS_NEW" "$CROSS_ROOT_ID" \
            && [ "$(crossing_head "$CROSS_NEW")" = "$CROSS_OLD" ] && crossing_absent "$CROSS_PRE_DIR"; then
        run_as_repo_owner mv -- "$CROSS_NEW" "$CROSS_PRE_DIR" || return 1
        kill_point cross-renamed
    fi
    if [ "$ok_root" -eq 1 ] && crossing_absent "$CROSS_NEW" \
            && crossing_id_is "$CROSS_PRE_DIR" "$CROSS_ROOT_ID" \
            && [ "$(crossing_head "$CROSS_PRE_DIR")" = "$CROSS_OLD" ]; then
        crossing_sync || return 1
        crossing_record crossed || return 1
        kill_point cross-crossed
        echo "  ✓ The crossing to the merged layout is complete: $CROSS_ROOT is $CROSS_TARGET,"
        echo "    and the previous checkout ($CROSS_OLD) is kept at $CROSS_PRE_DIR."
        return 0
    fi
    echo "✗ The crossing record says the checkouts were exchanged, but $CROSS_ROOT,"
    echo "  $CROSS_NEW and $CROSS_PRE_DIR are not as it says (the new checkout at"
    echo "  $CROSS_TARGET at the root, the previous one at $CROSS_OLD beside it). Nothing"
    echo "  has been moved, and the record ($CROSS_RECORD) is kept. See:"
    echo "      ls -la $(dirname "$CROSS_ROOT")"
    return 1
}

# crossing_after_exchange: decide from the identities and HEADs whether the
# exchange happened, whatever the exchange helper's exit status said. Sets
# CROSS_RESULT to finished, discarded or unknown; 0 only for finished.
crossing_after_exchange() {
    local r n
    r="$(crossing_head "$CROSS_ROOT")"
    n="$(crossing_head "$CROSS_NEW")"
    if crossing_id_is "$CROSS_ROOT" "$CROSS_NEW_ID" && [ "$r" = "$CROSS_TARGET" ] \
            && crossing_id_is "$CROSS_NEW" "$CROSS_ROOT_ID" && [ "$n" = "$CROSS_OLD" ]; then
        crossing_sync && crossing_record renaming || { CROSS_RESULT=unknown; return 1; }
        if crossing_finish; then
            CROSS_RESULT=finished
            return 0
        fi
        CROSS_RESULT=unknown
        return 1
    fi
    if crossing_id_is "$CROSS_ROOT" "$CROSS_ROOT_ID" && [ "$r" = "$CROSS_OLD" ] \
            && { crossing_absent "$CROSS_NEW" || { crossing_id_is "$CROSS_NEW" "$CROSS_NEW_ID" && [ "$n" = "$CROSS_TARGET" ]; }; }; then
        CROSS_RESULT=discarded
        crossing_discard || CROSS_RESULT=unknown
        return 1
    fi
    CROSS_RESULT=unknown
    echo "✗ After the exchange, $CROSS_ROOT and $CROSS_NEW are neither as they were nor"
    echo "  exchanged ($CROSS_ROOT at ${r:-nothing}, $CROSS_NEW at ${n:-nothing}). Nothing"
    echo "  has been removed, and the record ($CROSS_RECORD) is kept."
    return 1
}

# crossing_crossed: the record says crossed. With the whole state as it
# says (the new checkout at the root, the previous one at .pre-merge, no
# .new, the flag the crossing set in place), the install is due, which is
# the new code's update.sh's to do: say so, change nothing, and return 3;
# otherwise 1.
crossing_crossed() {
    if crossing_id_is "$CROSS_ROOT" "$CROSS_NEW_ID" && [ "$(crossing_head "$CROSS_ROOT")" = "$CROSS_TARGET" ] \
            && crossing_absent "$CROSS_NEW" \
            && crossing_id_is "$CROSS_PRE_DIR" "$CROSS_ROOT_ID" && [ "$(crossing_head "$CROSS_PRE_DIR")" = "$CROSS_OLD" ] \
            && [ "$CROSS_FLAG" = crossing ] && [ -e "$UNRESOLVED_FLAG" ]; then
        echo "→ $CROSS_ROOT has crossed to the merged layout ($CROSS_TARGET); its install"
        echo "  is due, and is the new code's to do: this script, from before the"
        echo "  crossing, changes nothing. Run the new code's update.sh, which installs"
        echo "  the new version, clears $UNRESOLVED_FLAG and the record:"
        echo "      sudo $CROSS_ROOT/scripts/update.sh"
        return 3
    fi
    echo "✗ The crossing record says $CROSS_ROOT crossed to $CROSS_TARGET, but the"
    echo "  checkouts or the start flag are not as it says. Nothing has been"
    echo "  changed; the record ($CROSS_RECORD) is kept."
    return 1
}

# crossing_settle: finish or undo the crossing the record names; see the
# steps above. 0 when there is no record, or the crossing was undone; 3 when
# it is (or has just been made) crossed, and the install is due; 1 when the
# record, its directory, or the directories it names are not as it says,
# which this script does not resolve (the record is kept).
crossing_settle_record() {
    local step out
    crossing_absent "$CROSS_RECORD" && return 0
    if ! out="$(crossing_record_ok 2>&1)"; then
        echo "✗ The crossing record cannot be used: $out"
        echo "  Nothing has been changed."
        return 1
    fi
    CROSS_ROOT="$(crossing_field root)"
    CROSS_ROOT_ID="$(crossing_field rootid)"
    CROSS_NEW="$(crossing_field new)"
    CROSS_NEW_ID="$(crossing_field newid)"
    CROSS_PRE_DIR="$(crossing_field pre)"
    CROSS_OLD="$(crossing_field old)"
    CROSS_TARGET="$(crossing_field target)"
    step="$(crossing_field step)"
    CROSS_FLAG="$(crossing_field flag)"
    CROSS_SERVICE="$(crossing_field service)"
    if [ "$(head -n 1 "$CROSS_RECORD" 2>/dev/null)" != "captua-crossing 6" ] \
            || [ -z "$CROSS_ROOT" ] || [ "$CROSS_ROOT" != "$(crossing_physical "$PROJECT_ROOT")" ] \
            || [ -L "$PROJECT_ROOT" ] || [ -z "$CROSS_ROOT_ID" ] \
            || [ "$CROSS_NEW" != "$CROSS_ROOT.new" ] || [ "$CROSS_PRE_DIR" != "$CROSS_ROOT.pre-merge" ] \
            || [ -z "$CROSS_OLD" ] || [ -z "$CROSS_TARGET" ] \
            || ! crossing_id_wellformed "$CROSS_ROOT_ID" \
            || { [ "$step" != building ] && ! crossing_id_wellformed "$CROSS_NEW_ID"; }; then
        echo "✗ $CROSS_RECORD is a crossing record this script cannot use for"
        echo "  $PROJECT_ROOT. Nothing has been changed; the record is kept. See:"
        echo "      sudo cat $CROSS_RECORD"
        if ! crossing_id_wellformed "$CROSS_ROOT_ID" \
                || { [ "$step" != building ] && ! crossing_id_wellformed "$CROSS_NEW_ID"; }; then
            echo "  Its rootid or newid is empty or not a UUID:inode:generation, so"
            echo "  neither directory can be told apart from any other."
        fi
        return 1
    fi
    case "$step" in
        building|copying|discarding)
            # Before the exchange the root is the old checkout.
            if ! crossing_id_is "$CROSS_ROOT" "$CROSS_ROOT_ID" || [ "$(crossing_head "$CROSS_ROOT")" != "$CROSS_OLD" ]; then
                echo "✗ The crossing record says $CROSS_ROOT is the checkout at $CROSS_OLD, and it is"
                echo "  not. Nothing has been changed; the record ($CROSS_RECORD) is kept."
                return 1
            fi
            echo "→ An earlier update stopped while building the new checkout at $CROSS_NEW"
            echo "  (step: $step). $CROSS_ROOT was not changed by it. Removing $CROSS_NEW..."
            crossing_discard || return 1
            echo "  ✓ Removed."
            echo "" ;;
        exchanging)
            echo "→ An earlier update stopped at the exchange of $CROSS_ROOT and $CROSS_NEW."
            # CROSS_RESULT, not the status, says what happened.
            crossing_after_exchange || true
            case "$CROSS_RESULT" in
                finished) crossing_crossed; return $? ;;
                discarded) echo "  The exchange had not happened; $CROSS_NEW was removed and"
                           echo "  $CROSS_ROOT is the checkout it was." ;;
                *) return 1 ;;
            esac
            echo "" ;;
        renaming)
            echo "→ An earlier update stopped after the exchange of $CROSS_ROOT and $CROSS_NEW."
            crossing_finish || return 1
            crossing_crossed
            return $? ;;
        crossed)
            crossing_crossed
            return $? ;;
        discarded)
            # .new is gone and the flag cleared; the service the crossing
            # stopped may still be down.
            if ! crossing_absent "$CROSS_NEW" || ! crossing_id_is "$CROSS_ROOT" "$CROSS_ROOT_ID" \
                    || [ "$(crossing_head "$CROSS_ROOT")" != "$CROSS_OLD" ]; then
                echo "✗ The crossing record says $CROSS_NEW was removed and $CROSS_ROOT is the"
                echo "  checkout at $CROSS_OLD, and it is not so. Nothing has been changed; the"
                echo "  record ($CROSS_RECORD) is kept."
                return 1
            fi
            echo "→ An earlier update discarded its new checkout but could not start the"
            echo "  service again; trying again..."
            CROSS_WAS_ACTIVE=0
            [ "$CROSS_SERVICE" != stopped ] || CROSS_WAS_ACTIVE=1
            if ! crossing_restart_if_stopped; then
                echo "✗ The service could not be started again: systemctl status dtk;"
                echo "  journalctl -u dtk -n 50. The record ($CROSS_RECORD) is kept."
                return 1
            fi
            crossing_record_remove || return 1
            echo "  ✓ The service is running again, and the record is removed."
            echo "" ;;
        *)
            echo "✗ $CROSS_RECORD names a step this script does not know ('$step')."
            echo "  Nothing has been changed; the record is kept."
            return 1 ;;
    esac
    return 0
}

# crossing_settle: crossing_settle_record, then, when the record is gone,
# crossing_clear_attempt, so that a crossing started later in the run begins
# from crossing_begin_attempt alone.
crossing_settle() {
    local rc=0
    crossing_settle_record || rc=$?
    if crossing_absent "$CROSS_RECORD"; then
        crossing_clear_attempt
    fi
    return "$rc"
}

# crossing_begin_attempt <root> <rootid> <old> <target>: gives a fresh
# crossing its initial values, just before its first record (building) is
# written, so that nothing from an attempt settled earlier in the run is
# carried into it. Every variable that describes one attempt is set here:
# CROSS_STAGE (building), CROSS_ROOT, CROSS_ROOT_ID, CROSS_NEW (<root>.new),
# CROSS_NEW_ID (empty until the mkdir), CROSS_PRE_DIR (<root>.pre-merge),
# CROSS_OLD, CROSS_TARGET, CROSS_FLAG (empty: the start guard not set),
# CROSS_SERVICE (empty: untouched), CROSS_SERVICE_STOPPED (0),
# CROSS_WAS_ACTIVE (0) and CROSS_RESULT (empty). crossing_clear_attempt
# empties the same list.
crossing_begin_attempt() {
    CROSS_STAGE=building
    CROSS_ROOT="$1"
    CROSS_ROOT_ID="$2"
    CROSS_NEW="$1.new"
    CROSS_NEW_ID=""
    CROSS_PRE_DIR="$1.pre-merge"
    CROSS_OLD="$3"
    CROSS_TARGET="$4"
    CROSS_FLAG=""
    CROSS_SERVICE=""
    CROSS_SERVICE_STOPPED=0
    CROSS_WAS_ACTIVE=0
    CROSS_RESULT=""
}

# crossing_clear_attempt: empties every variable crossing_begin_attempt sets
# (CROSS_STAGE, CROSS_ROOT, CROSS_ROOT_ID, CROSS_NEW, CROSS_NEW_ID,
# CROSS_PRE_DIR, CROSS_OLD, CROSS_TARGET, CROSS_FLAG, CROSS_SERVICE,
# CROSS_SERVICE_STOPPED, CROSS_WAS_ACTIVE, CROSS_RESULT), once a settle has
# removed the record those values were read from.
crossing_clear_attempt() {
    CROSS_STAGE=""
    CROSS_ROOT=""
    CROSS_ROOT_ID=""
    CROSS_NEW=""
    CROSS_NEW_ID=""
    CROSS_PRE_DIR=""
    CROSS_OLD=""
    CROSS_TARGET=""
    CROSS_FLAG=""
    CROSS_SERVICE=""
    CROSS_SERVICE_STOPPED=0
    CROSS_WAS_ACTIVE=0
    CROSS_RESULT=""
}

# crossing_list_others <root>: every untracked and ignored path git lists in
# the checkout at <root> and in each submodule of CROSS_PATHS (a directory with nothing
# tracked in it is listed once, as the directory), relative to the root,
# NUL-separated.
# Every git command's status is checked on its own (no pipeline hides one):
# a listing that fails refuses the crossing rather than reading as empty.
crossing_list_others() {
    local root="$1" sub part rc=0
    run_as_repo_owner git -C "$root" ls-files -z --others --directory || return 1
    part="$(mktemp)" || return 1
    for sub in "${CROSS_PATHS[@]}"; do
        if ! run_as_repo_owner git -C "$root/$sub" ls-files -z --others --directory > "$part"; then
            rc=1
            break
        fi
        if ! sub="$sub" python3 -c 'import os, sys; p = os.fsencode(os.environ["sub"]) + b"/"; sys.stdout.buffer.write(b"".join(p + e + b"\0" for e in sys.stdin.buffer.read().split(b"\0") if e))' < "$part"; then
            rc=1
            break
        fi
    done
    rm -f "$part"
    return "$rc"
}

# The closed list (see the comment over the crossing) and the caches it
# leaves out, as Python for crossing_others_check and crossing_copy_others.
CROSS_PY_CARRIED='
CARRIED = (b".env", b"backend/.pixi")
def is_cache(rel):
    parts = rel.split(b"/")
    return b"__pycache__" in parts or parts[-1].endswith(b".pyc")
def carried(rel):
    return any(rel == c or rel.startswith(c + b"/") for c in CARRIED)
'

# crossing_retired_wiki <root>: 0 when <root>/wiki is, by its identity, the
# checkout of the retired wiki submodule; else 1, with the reason on stdout.
# The identity, all of it:
#   - wiki is a real folder (lstat: not a symlink);
#   - wiki/.git is a regular file whose content is exactly
#     `gitdir: ../.git/modules/wiki`, with or without a final newline;
#   - <root>/.git, <root>/.git/modules and <root>/.git/modules/wiki are real
#     folders;
#   - HEAD's .gitmodules, read from the superproject's objects, names no
#     submodule wiki and none at the path wiki: the submodule is retired.
# It runs no git command in the wiki's repository, reads nothing inside
# wiki/ but the gitfile, and writes nothing.
#
# Identity is enough because nothing is deleted. The folder is not carried
# and not examined: it stays in the previous checkout, which is moved whole
# to <root>.pre-merge, and the folder and the repository it names (both
# inside that checkout, by relative paths) go together, as they are, with
# any change, untracked or ignored file in them. A discard removes only
# <root>.new, and <root>.pre-merge is the way back, so a rollback returns
# wiki/ unchanged. Whether the folder holds anything its repository lacks
# matters only when <root>.pre-merge is deleted, so that check belongs to
# the release that deletes it. Like every crossing check, this one does not
# defend against a writer that replaces a path between the check and the
# exchange (the threat model over the crossing): the update holds its lock,
# and the last listing runs with the service stopped.
crossing_retired_wiki() {
    local root="$1" out rc
    if ! out="$(python3 -c 'import os, stat, sys
root = sys.argv[1]
def mode(rel):
    try:
        return os.lstat(os.path.join(root, rel)).st_mode
    except FileNotFoundError:
        return None
m = mode("wiki")
if m is None or not stat.S_ISDIR(m):
    sys.exit("wiki/ is not a folder (it is a symlink or another kind of file)")
m = mode("wiki/.git")
if m is None or not stat.S_ISREG(m):
    sys.exit("wiki/.git is not a regular file (it is a symlink, a folder, or missing)")
with open(os.path.join(root, "wiki", ".git"), "rb") as f:
    body = f.read(64)
if body not in (b"gitdir: ../.git/modules/wiki", b"gitdir: ../.git/modules/wiki\n"):
    sys.exit("wiki/.git does not say exactly gitdir: ../.git/modules/wiki")
for rel in (".git", ".git/modules", ".git/modules/wiki"):
    m = mode(rel)
    if m is None or not stat.S_ISDIR(m):
        sys.exit("%s is not a folder (it is a symlink, or missing)" % rel)' "$root" 2>&1)"; then
        echo "$out"
        return 1
    fi
    if ! out="$(run_as_repo_owner LC_ALL=C git -C "$root" ls-tree HEAD -- .gitmodules 2>&1)"; then
        echo "git could not read HEAD's tree: $out"
        return 1
    fi
    if [ -n "$out" ]; then
        rc=0
        out="$(run_as_repo_owner LC_ALL=C git -C "$root" config --blob HEAD:.gitmodules --get-regexp '^submodule\.' 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
            echo "git could not read HEAD's .gitmodules: $out"
            return 1
        fi
        if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | python3 -c 'import sys
for line in sys.stdin.read().splitlines():
    key, _, value = line.partition(" ")
    name, _, var = key[len("submodule."):].rpartition(".")
    if name == "wiki" or (var == "path" and value == "wiki"):
        sys.exit(1)'; then
            echo "HEAD's .gitmodules still lists wiki, so the submodule is not retired"
            return 1
        fi
    fi
    return 0
}

# crossing_others_check <root>: read a NUL-separated list of the checkout's
# untracked and ignored paths on stdin and print every one, or every path
# under one that is a directory, that is neither carried nor a cache nor
# the retired wiki's checkout; 1 when there is one. Read-only.
#
# The untracked and ignored paths the crossing accepts are, completely:
#   .env, backend/.pixi   carried: copied into the new checkout (the
#                         closed list over the crossing);
#   Python's caches       left out: Python writes them again;
#   wiki                  the retired wiki submodule's checkout, only as the
#                         entry `wiki` at the root (the whole folder
#                         untracked) and only when crossing_retired_wiki
#                         recognises it by its identity. It is not carried
#                         and not examined: it stays, as it is, in the
#                         previous checkout, which is moved whole to
#                         <root>.pre-merge and is not deleted (see
#                         crossing_retired_wiki for why that is enough).
# Anything else refuses, named; a wiki/ crossing_retired_wiki does not
# accept is listed as any other path, with its reason.
crossing_others_check() {
    local wiki_ok=0 wiki_why=""
    if [ -e "$1/wiki" ] || [ -L "$1/wiki" ]; then
        wiki_why="$(crossing_retired_wiki "$1" </dev/null)" && wiki_ok=1
    fi
    CROSS_WIKI_OK="$wiki_ok" CROSS_WIKI_WHY="$wiki_why" python3 -c "$CROSS_PY_CARRIED"'
import os, stat, sys
root = os.fsencode(sys.argv[1])
wiki_ok = os.environ["CROSS_WIKI_OK"] == "1"
wiki_why = os.fsencode(os.environ["CROSS_WIKI_WHY"])
outside = []
wiki_refused = False
def walk(rel):
    if carried(rel) or is_cache(rel):
        return
    p = os.path.join(root, rel)
    st = os.lstat(p)
    if stat.S_ISDIR(st.st_mode):
        names = sorted(os.listdir(p))
        if not names:
            outside.append(rel + b"/")
        for c in names:
            walk(os.path.join(rel, c))
    else:
        outside.append(rel)
for e in sys.stdin.buffer.read().split(b"\0"):
    if not e:
        continue
    e = e.rstrip(b"/")
    if e == b"wiki":
        if wiki_ok:
            continue
        wiki_refused = True
    walk(e)
for o in outside:
    sys.stdout.buffer.write(o + b"\n")
if wiki_refused:
    sys.stdout.buffer.write(b"wiki/ is not the retired wiki\x27s checkout: " + wiki_why + b"\n")
sys.exit(1 if outside or wiki_refused else 0)
' "$1"
}

# crossing_copy_others <src> <dst>: copy into <dst> the carried paths (and
# everything under them but caches) among those a NUL-separated list on
# stdin names, relative to <src>. No file is shared between the checkouts: a regular file is copied
# (content and times, as shutil.copy2 does), a symlink is recreated with the
# same target and not followed, a fifo is recreated, a directory, empty or
# not, is created. Everything is created under umask 077, so no file is ever
# readable by others before its mode is set; then each gets its source's
# owner and then its mode (after the chown, which may clear setuid bits). A
# socket is a running program's, not data, and is left out (listed). Run as
# root, so a file the checkout's owner cannot read is copied all the same.
# Everything is checked before anything is written, and checked again
# before each write: every path written must resolve inside <dst>, so each
# of its ancestors under <dst> that exists must be a real directory (not a
# symlink), and the path itself must not exist. Anything else is a
# collision: the colliding paths are printed, nothing is written, and it
# exits 3. A directory <dst> already has as a real directory is entered,
# not replaced.
crossing_copy_others() {
    python3 -c "$CROSS_PY_CARRIED"'
import os, shutil, stat, sys
os.umask(0o077)
src, dst = os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2])
entries = [e.rstrip(b"/") for e in sys.stdin.buffer.read().split(b"\0") if e]
entries = [e for e in entries if carried(e) and not is_cache(e)]
plan, collisions, skipped = [], [], []
def blocked(rel):
    """The first ancestor of rel under dst that exists and is not a real directory."""
    parts = rel.split(b"/")
    for i in range(1, len(parts)):
        a = os.path.join(dst, *parts[:i])
        if not os.path.lexists(a):
            return None
        if os.path.islink(a) or not os.path.isdir(a):
            return b"/".join(parts[:i])
    return None
def walk(rel):
    if is_cache(rel):
        return
    b = blocked(rel)
    if b is not None:
        collisions.append(b)
        return
    s, d = os.path.join(src, rel), os.path.join(dst, rel)
    st = os.lstat(s)
    if stat.S_ISDIR(st.st_mode):
        if not os.path.lexists(d):
            plan.append(("dir", rel, st))
        elif os.path.islink(d) or not os.path.isdir(d):
            collisions.append(rel)
            return
        for c in sorted(os.listdir(s)):
            walk(os.path.join(rel, c))
    elif os.path.lexists(d):
        collisions.append(rel)
    elif stat.S_ISSOCK(st.st_mode):
        skipped.append(rel)
    elif stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or stat.S_ISFIFO(st.st_mode):
        plan.append(("node", rel, st))
    else:
        collisions.append(rel)
for e in entries:
    walk(e)
if collisions:
    for c in sorted(set(collisions)):
        sys.stdout.buffer.write(c + b"\n")
    sys.exit(3)
made = []
def check(rel):
    b = blocked(rel)
    d = os.path.join(dst, rel)
    if b is not None or os.path.lexists(d):
        sys.stdout.buffer.write((b or rel) + b"\n")
        sys.exit(3)
def parents(rel):
    parent = os.path.dirname(rel)
    if parent and not os.path.lexists(os.path.join(dst, parent)):
        parents(parent)
        check(parent)
        os.mkdir(os.path.join(dst, parent), 0o700)
        made.append((parent, os.lstat(os.path.join(src, parent))))
for kind, rel, st in plan:
    parents(rel)
    check(rel)
    s, d = os.path.join(src, rel), os.path.join(dst, rel)
    if kind == "dir":
        os.mkdir(d, 0o700)
        made.append((rel, st))
    elif stat.S_ISLNK(st.st_mode):
        os.symlink(os.readlink(s), d)
        os.chown(d, st.st_uid, st.st_gid, follow_symlinks=False)
    else:
        if stat.S_ISFIFO(st.st_mode):
            os.mkfifo(d, 0o600)
        else:
            shutil.copy2(s, d, follow_symlinks=False)
        os.chown(d, st.st_uid, st.st_gid, follow_symlinks=False)
        os.chmod(d, stat.S_IMODE(st.st_mode))
for rel, st in reversed(made):
    d = os.path.join(dst, rel)
    os.chown(d, st.st_uid, st.st_gid, follow_symlinks=False)
    os.chmod(d, stat.S_IMODE(st.st_mode))
for s in skipped:
    sys.stderr.buffer.write(b"skipped (a socket): " + s + b"\n")
' "$1" "$2"
}

# crossing_config_check <old .git/config>: the old repository's own
# configuration may hold only keys this crossing knows how to carry, by a
# closed list. The clone sets for itself: core.repositoryformatversion,
# core.filemode, core.bare, core.logallrefupdates, and the ones git sets by
# probing the filesystem (core.ignorecase, core.precomposeunicode,
# core.symlinks), which the clone probes the same way. Carried:
# remote.origin.url and remote.origin.fetch, branch.<name>.remote and
# branch.<name>.merge. Dropped: submodule.* (the submodules the new tree no
# longer has). Any other key could depend on the old layout or on a file the
# clone does not have (include.*, url.*, core.worktree, core.sshCommand
# naming a file in .git, ...): its names are printed, and 1.
crossing_config_check() {
    run_as_repo_owner python3 -c '
import re, subprocess, sys
out = subprocess.run(["git", "config", "--file", sys.argv[1], "--null", "--list"], check=True, capture_output=True).stdout
allowed = re.compile(r"^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|symlinks)"
                     r"|remote\.origin\.(url|fetch)|branch\..+\.(remote|merge)|submodule\..+)$")
bad = sorted({e.split(b"\n", 1)[0].decode("utf-8", "replace") for e in out.split(b"\0") if e} - {""})
bad = [k for k in bad if not allowed.match(k.lower()) and not allowed.match(k)]
for k in bad:
    print(k)
sys.exit(1 if bad else 0)
' "$1"
}

# crossing_carry_config <old .git/config> <new .git/config>: carry the keys
# crossing_config_check lists as carried, each with all its values as
# configured (git config --get-all: the raw URL, never `remote get-url`,
# which applies url.*.insteadOf).
crossing_carry_config() {
    run_as_repo_owner python3 -c '
import re, subprocess, sys
old, new = sys.argv[1], sys.argv[2]
out = subprocess.run(["git", "config", "--file", old, "--null", "--name-only", "--list"], check=True, capture_output=True).stdout
carried = re.compile(r"^(remote\.origin\.(url|fetch)|branch\..+\.(remote|merge))$", re.I)
keys = []
for k in out.split(b"\0"):
    if k and carried.match(k.decode("utf-8", "replace")) and k not in keys:
        keys.append(k)
for k in keys:
    vals = subprocess.run(["git", "config", "--file", old, "--null", "--get-all", k], check=True, capture_output=True).stdout
    subprocess.run(["git", "config", "--file", new, "--unset-all", k], capture_output=True)
    for v in vals.split(b"\0")[:-1]:
        subprocess.run(["git", "config", "--file", new, "--add", k, v], check=True)
' "$1" "$2"
}

# crossing_exchange <a> <b>: exchange two directories in one rename(2), so
# that at every instant each path names a complete directory: Linux
# renameat2(RENAME_EXCHANGE) through libc (or the raw system call where libc
# has no wrapper); renamex_np(RENAME_SWAP) on macOS, for the test suite. Its
# exit status is not evidence either way: crossing_after_exchange reads the
# directories. (Test only: KILL_AT=cross-exchange-helper kills it with
# SIGKILL just after a successful exchange.)
crossing_exchange() {
    KILL_AT="$KILL_AT" python3 -c '
import ctypes, os, signal, sys
a, b = os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
if sys.platform.startswith("linux"):
    AT_FDCWD, RENAME_EXCHANGE = -100, 2
    if hasattr(libc, "renameat2"):
        f = libc.renameat2
        f.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        r = f(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
    else:
        nr = {"aarch64": 276, "x86_64": 316, "armv7l": 382, "armv6l": 382}.get(os.uname().machine)
        if nr is None:
            sys.exit("renameat2: no system call number for " + os.uname().machine)
        f = libc.syscall
        f.argtypes = [ctypes.c_long, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        r = f(nr, AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
elif sys.platform == "darwin":
    f = libc.renamex_np
    f.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    r = f(a, b, 2)
else:
    sys.exit("no atomic exchange of directories on " + sys.platform)
if r != 0:
    sys.exit("exchange failed: " + os.strerror(ctypes.get_errno()))
if os.environ.get("KILL_AT") == "cross-exchange-helper":
    os.kill(os.getpid(), signal.SIGKILL)
' "$1" "$2"
}

# crossing_cross: build the new checkout for CROSS_PATHS at the upstream
# commit beside the old one, copy the carried files (.env, backend/.pixi)
# into it, set the start guard, exchange the two and finish. Before the exchange a failure
# discards <root>.new (a step of the record) and returns 1 with <root> as it
# was; a stop leaves the record for the next run. After the exchange the
# identities and HEADs decide (crossing_after_exchange).
crossing_cross() {
    local need avail sub rc list out gf w ref fstype gd wt want name modules wiki
    local root root_id new pre old target
    # <root> is used by its physical path, and must itself be a directory:
    # a symlink there would be exchanged as a symlink.
    if [ -L "$PROJECT_ROOT" ] || [ ! -d "$PROJECT_ROOT" ]; then
        echo "✗ $PROJECT_ROOT is a symlink (or not a directory). The crossing"
        echo "  exchanges the checkout directory itself, so it stops here."
        echo "  Nothing has been changed. Run this from the checkout's real path:"
        echo "      $(crossing_physical "$PROJECT_ROOT")"
        return 1
    fi
    # The checks below read this attempt's paths and commits from locals;
    # crossing_begin_attempt gives them to the CROSS_* variables just before
    # the record is written.
    root="$(crossing_physical "$PROJECT_ROOT")"
    # An empty identity here is refused with the UUID check below.
    root_id="$(crossing_id "$root" || true)"
    new="$root.new"
    pre="$root.pre-merge"
    old="$(crossing_head "$root")"
    target="$(run_as_repo_owner git -C "$root" rev-parse --verify "$PULL_UPSTREAM^{commit}")" || return 1

    # Preconditions, read-only.
    if ! out="$(python3 -c "$CROSS_PY_CHECK"'
d = sys.argv[1]
if os.path.lexists(d):
    dir_ok(d, False)
if os.path.lexists(sys.argv[2]):
    sys.exit("%s exists" % sys.argv[2])' "$UNRESOLVED_FLAG_DIR" "$CROSS_RECORD" 2>&1)"; then
        echo "✗ The crossing keeps its record in $UNRESOLVED_FLAG_DIR, and: $out."
        echo "  Nothing has been changed."
        return 1
    fi
    if ! crossing_absent "$new"; then
        echo "✗ $new exists, and there is no record of this script having made it."
        echo "  The new checkout is built there, so the crossing stops here. Nothing has"
        echo "  been changed, and $new is left as it is. Look at it, move it away,"
        echo "  then run this again."
        return 1
    fi
    if ! crossing_absent "$pre"; then
        echo "✗ $pre exists. The previous checkout is kept there after the"
        echo "  crossing, so the crossing stops here. Nothing has been changed. Move it"
        echo "  away, then run this again."
        return 1
    fi
    # The new checkout must not depend on anything inside the old one, which
    # moves to <root>.pre-merge: objects borrowed through alternates, a
    # submodule's repository named by an absolute path into <root>, or a
    # configuration key outside the closed list.
    if [ -e "$root/.git/objects/info/alternates" ]; then
        echo "✗ $root/.git/objects/info/alternates exists: this repository borrows"
        echo "  objects from another, which the new checkout would depend on. Nothing"
        echo "  has been changed. To copy the objects in and drop it:"
        echo "      sudo -u $REPO_USER git -C $root repack -a -d"
        echo "      sudo -u $REPO_USER rm $root/.git/objects/info/alternates"
        return 1
    fi
    # The identities in the record are the filesystem's UUID and inode
    # numbers (crossing_id); ext4, the units' filesystem, keeps both across a
    # reboot, and a filesystem without a UUID cannot be recognised after one.
    fstype="$(findmnt -n -o FSTYPE -T "$(dirname "$root")" 2>/dev/null || true)"
    if [ "$fstype" != ext4 ]; then
        echo "✗ $(dirname "$root") is on ${fstype:-a filesystem findmnt could not name}, not ext4. The crossing"
        echo "  records the checkouts' filesystem and inode numbers, which it relies on"
        echo "  ext4 to keep across a reboot, so it stops. Nothing has been changed."
        return 1
    fi
    if [ -z "$(findmnt -n -o UUID -T "$root" 2>/dev/null || true)" ] || [ -z "$root_id" ]; then
        echo "✗ The filesystem holding $root has no UUID, or the inode generation"
        echo "  of $root cannot be read: by these the crossing recognises its"
        echo "  directories after a reboot, so it stops. Nothing has been changed."
        return 1
    fi
    for sub in "${CROSS_PATHS[@]}"; do
        # The submodule's repository must be the one under the old checkout's
        # .git (<root>/.git/modules/<name>, the name from .gitmodules), so that
        # it moves with the old checkout to <root>.pre-merge; and its
        # core.worktree, if set, must name <root>/<path> from there, so that
        # it names the previous checkout's folder afterwards.
        # The name: exactly one .gitmodules entry claims the path, and its name
        # is a relative path whose components are none of empty, . or ..
        modules="$(run_as_repo_owner git config --file "$root/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)"
        if ! name="$(printf '%s\n' "$modules" | python3 -c 'import sys
want = sys.argv[1]
names = []
for line in sys.stdin.read().splitlines():
    key, _, path = line.partition(" ")
    if path == want and key.startswith("submodule.") and key.endswith(".path"):
        names.append(key[len("submodule."):-len(".path")])
if len(names) != 1:
    sys.exit("%d entries in .gitmodules claim the path %s" % (len(names), want))
n = names[0]
if "\0" in n or n.startswith("/") or any(c in ("", ".", "..") for c in n.split("/")):
    sys.exit("the submodule name %r is not a plain relative path" % n)
print(n)' "$sub" 2>&1)"; then
            echo "✗ $root/.gitmodules: $name. Nothing has been changed."
            return 1
        fi
        gd="$(run_as_repo_owner git -C "$root/$sub" rev-parse --absolute-git-dir 2>/dev/null || true)"
        # Every step from <root>/.git to .git/modules/<name> a real directory:
        # a symlink there would resolve both sides of the comparison below to
        # a repository that stays put.
        if [ -n "$name" ] && ! python3 -c 'import os, stat, sys
p = sys.argv[1]
for part in ["", ".git", "modules"] + sys.argv[2].split("/"):
    p = os.path.join(p, part) if part else p
    try:
        st = os.lstat(p)
    except OSError:
        sys.exit(1)
    if not stat.S_ISDIR(st.st_mode):
        sys.exit(1)' "$root" "$name"; then
            echo "✗ $root/.git/modules/$name is not a directory inside $root/.git (a"
            echo "  symlink, or missing): the repository of $sub would not move with the"
            echo "  previous checkout. Nothing has been changed."
            return 1
        fi
        # Independently of the name: the gitfile's target, resolved, lies
        # under <root>/.git/modules and is exactly <root>/.git/modules/<name>.
        if ! python3 -c 'import os, sys
root, sub, name = sys.argv[1:4]
with open(os.path.join(root, sub, ".git")) as f:
    line = f.read().strip()
if not line.startswith("gitdir: "):
    sys.exit(1)
t = os.path.realpath(os.path.join(root, sub, line[len("gitdir: "):]))
m = os.path.realpath(os.path.join(root, ".git", "modules"))
sys.exit(0 if os.path.commonpath([t, m]) == m and t == os.path.realpath(os.path.join(m, name)) else 1)' "$root" "$sub" "$name" 2>/dev/null; then
            echo "✗ $root/$sub/.git names a repository that is not"
            echo "  $root/.git/modules/$name: it would not move with the previous"
            echo "  checkout. Nothing has been changed."
            return 1
        fi
        if [ -z "$name" ] || [ -z "$gd" ] \
                || [ "$(crossing_physical "$gd")" != "$(crossing_physical "$root/.git/modules/$name")" ]; then
            echo "✗ $root/$sub/.git names the repository ${gd:-(none)}, not"
            echo "  $root/.git/modules/${name:-<the name .gitmodules gives $sub>}: it would not move with"
            echo "  the previous checkout. Nothing has been changed."
            return 1
        fi
        # The relative path must be git's own (the way up from the repository
        # to the folder, ../../../<path> for a top-level submodule): another
        # spelling that names the same folder now, through the root's name,
        # would name the new checkout's folder once the old one is renamed.
        wt="$(run_as_repo_owner git config --file "$gd/config" --get core.worktree 2>/dev/null || true)"
        if [ -n "$wt" ]; then
            want="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
                "$(crossing_physical "$root/$sub")" "$(crossing_physical "$gd")")"
            if [ "$wt" != "$want" ]; then
                echo "✗ $gd/config sets core.worktree to '$wt', not git's own"
                echo "  relative path '$want' to $root/$sub: after the crossing it would"
                echo "  not name the previous checkout's $sub. Nothing has been changed. To"
                echo "  set it to git's own:"
                echo "      sudo -u $REPO_USER git config --file $gd/config core.worktree $want"
                return 1
            fi
        fi
        gf="$(cat "$root/$sub/.git" 2>/dev/null || true)"
        case "$gf" in
            "gitdir: /"*)
                echo "✗ $root/$sub/.git names its repository by an absolute path"
                echo "  (${gf#gitdir: }), which after the crossing would name the new"
                echo "  checkout's .git, not the previous checkout's. Nothing has been"
                echo "  changed. To make it relative:"
                echo "      sudo -u $REPO_USER git -C $root submodule absorbgitdirs"
                return 1 ;;
        esac
    done
    if ! out="$(crossing_config_check "$root/.git/config" 2>&1)"; then
        echo "✗ $root/.git/config sets keys the crossing does not carry over:"
        printf '%s\n' "$out" | sed 's/^/      /'
        echo "  The new checkout is made with origin, its fetch settings and the"
        echo "  branches' upstreams only, and a key like these may depend on the old"
        echo "  layout or on a file in the old .git. Nothing has been changed. Move"
        echo "  them to the repository owner's global configuration, or remove them:"
        echo "      sudo -u $REPO_USER git -C $root config --unset-all <key>"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "✗ python3 is needed to exchange the two checkouts and was not found."
        echo "  Nothing has been changed."
        return 1
    fi
    if ! python3 -c 'import os, sys; sys.exit(os.stat(sys.argv[1]).st_dev != os.stat(os.path.dirname(sys.argv[1])).st_dev)' "$root"; then
        echo "✗ $root is a mount point (or on another filesystem than the"
        echo "  directory it is in), so it cannot be exchanged for a directory beside"
        echo "  it. Nothing has been changed."
        return 1
    fi
    # The new checkout's tracked files, about the size of the old ones, plus
    # copies of the carried files: together at most the old working tree
    # outside .git. A tenth more, and 256 MiB.
    w=$(( $(du -sk "$root" | cut -f1) - $(du -sk "$root/.git" | cut -f1) ))
    need=$(( w + w / 10 + 262144 ))
    avail="$(df -Pk "$(dirname "$root")" | awk 'NR == 2 { print $4 }')"
    if [ -z "$avail" ] || [ "$avail" -lt "$need" ]; then
        echo "✗ Building the new checkout beside the old one needs about $(( need / 1024 )) MiB"
        echo "  free on the filesystem of $(dirname "$root"); ${avail:+$(( avail / 1024 )) MiB is free}."
        echo "  Nothing has been changed."
        return 1
    fi

    # The closed list (see the comment over the crossing): every other
    # untracked or ignored path refuses, before anything is written.
    list="$(mktemp)" || return 1
    if ! crossing_list_others "$root" > "$list"; then
        rm -f "$list"
        echo "✗ git could not list the checkout's untracked and ignored files (it says why"
        echo "  above), so what the crossing would carry is not known. Nothing has been"
        echo "  changed."
        return 1
    fi
    out="$(crossing_others_check "$root" < "$list" 2>&1)"; rc=$?
    # Whether the listing holds the root entry wiki, which the check, passing,
    # has accepted as the retired wiki's checkout.
    wiki=0
    python3 -c 'import sys; sys.exit(0 if any(e.rstrip(b"/") == b"wiki" for e in open(sys.argv[1], "rb").read().split(b"\0")) else 1)' "$list" && wiki=1
    rm -f "$list"
    if [ "$rc" -ne 0 ]; then
        echo "✗ These untracked or ignored paths are in the checkout, and the crossing"
        echo "  carries only .env and backend/.pixi (and leaves Python's caches out):"
        printf '%s\n' "$out" | sed 's/^/      /'
        echo "  Data belongs outside the checkout (/var/lib/dtk by default). Nothing has"
        echo "  been changed. Move these out of $root, or remove them, then run"
        echo "  this again."
        return 1
    fi
    if [ "$wiki" -eq 1 ]; then
        echo "→ The folder wiki/, an old copy of the retired documentation, stays with the previous version at $pre and is not carried to the new one."
    fi

    echo "→ Building the new checkout at $new, from the objects already fetched..."
    crossing_begin_attempt "$root" "$root_id" "$old" "$target"
    crossing_record building || { CROSS_STAGE=""; echo "✗ Could not write $CROSS_RECORD. Nothing has been changed."; return 1; }
    kill_point cross-recorded
    if ! run_as_repo_owner mkdir -- "$CROSS_NEW"; then
        # Not made here, so not removed here.
        crossing_record_remove || true
        CROSS_STAGE=""
        echo "✗ Could not create $CROSS_NEW. Nothing has been changed."
        return 1
    fi
    if ! CROSS_NEW_ID="$(crossing_id "$CROSS_NEW")"; then
        # Just made by this mkdir and still empty: rmdir removes nothing else.
        CROSS_NEW_ID=""
        echo "✗ The identity (filesystem, inode and generation) of"
        echo "      $CROSS_NEW"
        echo "  could not be read, so the crossing stops. Nothing has been changed."
        run_as_repo_owner rmdir -- "$CROSS_NEW" 2>/dev/null || echo "  ⚠ Could not remove the empty $CROSS_NEW; remove it by hand."
        crossing_record_remove || true
        CROSS_STAGE=""
        return 1
    fi
    rc=0
    crossing_record building || rc=1
    [ "$rc" -ne 0 ] || run_as_repo_owner python3 -c 'import os, stat, sys; os.chmod(sys.argv[2], stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$CROSS_ROOT" "$CROSS_NEW" || rc=1
    [ "$rc" -ne 0 ] || run_as_repo_owner git clone -q --local --no-checkout -- "$CROSS_ROOT" "$CROSS_NEW/.captua-clone" || rc=1
    [ "$rc" -ne 0 ] || run_as_repo_owner mv -- "$CROSS_NEW/.captua-clone/.git" "$CROSS_NEW/.git" || rc=1
    [ "$rc" -ne 0 ] || run_as_repo_owner rmdir -- "$CROSS_NEW/.captua-clone" || rc=1
    # The old checkout's remote-tracking branches, in place of the ones the
    # clone made from its local branches; then origin and the branches'
    # upstreams as the old checkout configures them.
    if [ "$rc" -eq 0 ]; then
        for ref in $(run_as_repo_owner git -C "$CROSS_NEW" for-each-ref --format='%(refname)' refs/remotes/origin); do
            run_as_repo_owner git -C "$CROSS_NEW" update-ref -d "$ref" || rc=1
        done
    fi
    [ "$rc" -ne 0 ] || run_as_repo_owner git -C "$CROSS_NEW" fetch -q --no-tags "$CROSS_ROOT" '+refs/remotes/origin/*:refs/remotes/origin/*' || rc=1
    [ "$rc" -ne 0 ] || crossing_carry_config "$CROSS_ROOT/.git/config" "$CROSS_NEW/.git/config" || rc=1
    [ "$rc" -ne 0 ] || run_as_repo_owner git -C "$CROSS_NEW" checkout -q --force -B "$PULL_BRANCH" "$CROSS_TARGET" || rc=1
    if [ "$rc" -eq 0 ]; then
        out="$(run_as_repo_owner git -C "$CROSS_NEW" status --porcelain 2>&1)" || rc=1
        [ -z "$out" ] || rc=1
        [ "$(crossing_head "$CROSS_NEW")" = "$CROSS_TARGET" ] || rc=1
        [ "$(run_as_repo_owner git -C "$CROSS_NEW" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" = "$PULL_UPSTREAM" ] || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "✗ The new checkout could not be built and verified at $CROSS_NEW (git says"
        echo "  why above). Removing it; $CROSS_ROOT has not been changed."
        crossing_discard || true
        CROSS_STAGE=""
        return 1
    fi
    kill_point cross-built

    echo "→ Copying .env and backend/.pixi into it..."
    crossing_record copying || rc=1
    list="$(mktemp)" || rc=1
    if [ "$rc" -eq 0 ] && ! crossing_list_others "$CROSS_ROOT" > "$list"; then
        echo "✗ git could not list the checkout's untracked and ignored files again (it"
        echo "  says why above)."
        rc=1
    fi
    # The same closed list, again: a path that appeared since the first scan
    # refuses the crossing too.
    if [ "$rc" -eq 0 ] && ! out="$(crossing_others_check "$CROSS_ROOT" < "$list" 2>&1)"; then
        echo "✗ These untracked or ignored paths appeared in the checkout while the new"
        echo "  one was being built, and the crossing carries only .env and backend/.pixi:"
        printf '%s\n' "$out" | sed 's/^/      /'
        echo "  Data belongs outside the checkout (/var/lib/dtk by default). Removing"
        echo "  $CROSS_NEW; $CROSS_ROOT has not been changed."
        rm -f "$list"
        crossing_discard || true
        CROSS_STAGE=""
        return 1
    fi
    if [ "$rc" -eq 0 ]; then
        out="$(crossing_copy_others "$CROSS_ROOT" "$CROSS_NEW" < "$list" 2>&1)" || rc=$?
    fi
    rm -f "$list"
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 3 ]; then
            echo "✗ These paths of the files the crossing carries are taken in the new"
            echo "  code, by a tracked file or a symlink, so they cannot be carried over:"
            printf '%s\n' "$out" | sed 's/^/      /'
            echo "  Move the files aside by hand; this script will not delete or overwrite a"
            echo "  file it did not put there."
        else
            echo "✗ .env and backend/.pixi could not be copied into $CROSS_NEW:"
            printf '%s\n' "$out" | sed 's/^/      /'
        fi
        echo "  Removing $CROSS_NEW; $CROSS_ROOT has not been changed."
        crossing_discard || true
        CROSS_STAGE=""
        return 1
    fi
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /'
    kill_point cross-copied

    # The service is stopped here, immediately before the exchange step, so
    # that the running backend cannot import code from the new tree once it
    # is at the root: its module paths name <root>/backend. The copy does not
    # depend on this stop (it carries only files nothing writes). Each
    # command's status is checked here, since this runs inside `if !`, where
    # set -e does not act. A stop that fails means no exchange: the new
    # checkout is discarded, and the service started again if it was running
    # and the stop left it down. After the exchange it stays down: the flag
    # set next keeps it from starting until the install.
    CROSS_WAS_ACTIVE=0
    systemctl is-active --quiet dtk 2>/dev/null && CROSS_WAS_ACTIVE=1
    # The record says the crossing stopped a running service before it does,
    # so that a discard, in this run or the next, starts it again.
    if [ "$CROSS_WAS_ACTIVE" -eq 1 ]; then
        CROSS_SERVICE=stopped
        if ! crossing_record copying; then
            echo "✗ Could not write $CROSS_RECORD. Removing $CROSS_NEW; $CROSS_ROOT has not been"
            echo "  changed."
            CROSS_SERVICE=""
            crossing_discard || true
            CROSS_STAGE=""
            return 1
        fi
    fi
    echo "→ Stopping the service, so that it cannot load the new code once it is in place..."
    rc=0
    systemctl stop dtk || rc=1
    if [ "$rc" -eq 0 ] && ! wait_backend_stopped; then
        rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "✗ The service did not stop (systemctl status dtk; pgrep -af uvicorn), so the"
        echo "  crossing stops before the exchange. Removing $CROSS_NEW; $CROSS_ROOT has"
        echo "  not been changed."
        crossing_discard || true
        crossing_restart_if_stopped
        CROSS_STAGE=""
        return 1
    fi
    CROSS_SERVICE_STOPPED=1
    kill_point cross-stopped

    # The closed list a third time, with the service stopped: anything the
    # backend wrote into the checkout while the files were copied is here
    # now.
    list="$(mktemp)" || list=""
    rc=0
    if [ -z "$list" ] || ! crossing_list_others "$CROSS_ROOT" > "$list"; then
        echo "✗ git could not list the checkout's untracked and ignored files a third"
        echo "  time (it says why above)."
        rc=1
    elif ! out="$(crossing_others_check "$CROSS_ROOT" < "$list" 2>&1)"; then
        echo "✗ These untracked or ignored paths appeared in the checkout while .env"
        echo "  and backend/.pixi were copied, and the crossing carries only those:"
        printf '%s\n' "$out" | sed 's/^/      /'
        echo "  Data belongs outside the checkout (/var/lib/dtk by default)."
        rc=1
    fi
    [ -z "$list" ] || rm -f "$list"
    if [ "$rc" -ne 0 ]; then
        echo "  Removing $CROSS_NEW; $CROSS_ROOT has not been changed."
        crossing_discard || true
        CROSS_STAGE=""
        return 1
    fi

    # Before the exchange: the record says exchanging and that the crossing
    # sets the flag; then the flag, so that the exchanged checkout is not
    # started before its install; then the new checkout and the flag, on disk.
    # From here a stop is settled by the EXIT trap from the record.
    CROSS_STAGE=exchanging
    CROSS_FLAG=crossing
    if ! crossing_sync || ! crossing_record exchanging || ! set_unresolved_flag || ! crossing_sync; then
        echo "✗ The start guard could not be set before the exchange. Removing $CROSS_NEW;"
        echo "  $CROSS_ROOT has not been changed."
        crossing_discard || true
        crossing_restart_if_stopped
        CROSS_STAGE=""
        return 1
    fi
    kill_point cross-synced
    echo "→ Exchanging $CROSS_ROOT and $CROSS_NEW..."
    out="$(crossing_exchange "$CROSS_ROOT" "$CROSS_NEW" 2>&1)" || echo "  The exchange reported: ${out:-a failure (exit status $?)}. Reading the directories to see whether it happened."
    kill_point cross-exchanged
    crossing_after_exchange || true
    case "$CROSS_RESULT" in
        finished) CROSS_STAGE=""; return 0 ;;
        discarded)
            echo "✗ The exchange did not happen ($out). $CROSS_NEW was removed and"
            echo "  $CROSS_ROOT is the checkout it was."
            crossing_restart_if_stopped
            CROSS_STAGE=""
            return 1 ;;
        *) return 1 ;;
    esac
}

# crossing_restart_if_stopped: after a crossing that did not exchange, start
# the service again when it was running before the crossing stopped it and
# is down now, with the root the previous checkout (its identity and HEAD)
# and no record at the exchange or after it. 0 when there is nothing to do
# or the service is active afterwards; 1 when it was not started (the start
# failed, it is not active after it, or the root is not the previous
# checkout).
crossing_restart_if_stopped() {
    [ "$CROSS_WAS_ACTIVE" -eq 1 ] || return 0
    systemctl is-active --quiet dtk 2>/dev/null && return 0
    case "$(sed -n 's/^step //p' "$CROSS_RECORD" 2>/dev/null | head -n 1)" in
        exchanging|renaming|crossed) return 1 ;;
    esac
    crossing_id_is "$CROSS_ROOT" "$CROSS_ROOT_ID" && [ "$(crossing_head "$CROSS_ROOT")" = "$CROSS_OLD" ] || return 1
    echo "→ Starting the service again, on the previous version..."
    # As before every start of dtk: the update page gives port 80 back.
    end_update_page
    systemctl start dtk 2>/dev/null || return 1
    systemctl is-active --quiet dtk 2>/dev/null
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
            && ! printf '%s\n' "$sub_status" | grep -qv '^ ' \
            && gitlinks_match_head "$PROJECT_ROOT" checked-out; then
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
    # Against HEAD's tree, not the index: the checkout above resets the index,
    # but this is what "on its pins" has to mean.
    if ! gitlinks_match_head "$PROJECT_ROOT" checked-out; then
        note_not_restored "code: on $RESTORE_SHA, but a submodule's index entry or checkout is not the commit $RESTORE_SHA records"
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
    # Nothing may write between here and the end of the load: a backend found
    # now is refused, with nothing dropped.
    if ! backend_fully_stopped; then
        echo "  ✗ A backend is running; the database was NOT dropped."
        RESTORE_DB_NOT_DROPPED_WHY="a backend was running"
        return 1
    fi
    # The record goes down before the irreversible step, so that a run killed
    # in the middle of it (a signal, a power cut) still leaves one.
    write_unresolved_marker restore-failed || {
        echo "  ✗ Could not write $UNRESOLVED_FILE with its start flag and drop-in;"
        echo "    the database was NOT dropped."
        RESTORE_DB_NOT_DROPPED_WHY="the start guard (flag or drop-in) could not be put in place"
        return 1
    }
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
    # Verified loaded, with the code already back (restore_code ran first):
    # code and database agree again.
    clear_unresolved_marker
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

# The drop-in that keeps dtk from starting while the flag exists. Written
# idempotently, root's, with a daemon-reload only when it changed.
ensure_unresolved_dropin() {
    local want
    want="$(printf '%s\n' \
        "# Written by scripts/update.sh. While $UNRESOLVED_FLAG exists an update" \
        "# was left unresolved (see $UNRESOLVED_FILE) and dtk must not start." \
        "[Unit]" \
        "ConditionPathExists=!$UNRESOLVED_FLAG")"
    if [ "$(cat "$UNRESOLVED_DROPIN" 2>/dev/null)" != "$want" ]; then
        mkdir -p "$(dirname "$UNRESOLVED_DROPIN")" \
            && printf '%s\n' "$want" > "$UNRESOLVED_DROPIN.tmp" \
            && mv -f "$UNRESOLVED_DROPIN.tmp" "$UNRESOLVED_DROPIN" || return 1
    fi
    # Always: a drop-in already on disk but never loaded does nothing.
    systemctl daemon-reload
}

clear_unresolved_marker() {
    rm -f "$UNRESOLVED_FILE" "$UNRESOLVED_FLAG" 2>/dev/null || true
}

# The update page (scripts/update-page), served on port 80 by
# dtk-system-helper while update.sh has the stack down. This script owns
# it; nothing else starts it. mark_update_page writes the marker the helper
# requires (root's, in /run) immediately before the deliberate stop of dtk,
# so a crash of the backend before then, and systemd's restart of it, show
# nothing. show_update_page asks for the page once the stack is down.
# end_update_page stops it and removes the marker, immediately before every
# start of dtk, so port 80 is free for nginx. show_update_page_if_unresolved
# runs on exit: with the unresolved flag left, the page stays up (or comes
# up) saying the update failed; otherwise a page this run wanted is stopped.
#
# Each call tolerates a helper without the verbs, or none, and never changes
# how the script ends. Since the update.sh that runs an update is the copy
# from before its pull, the page first appears on the update after the one
# that installs this code: from then on this script, the helper and start.sh
# all know the page, and so does any version a failed update restores.
mark_update_page() {
    ( umask 022; : > "$UPDATE_PAGE_MARKER" ) 2>/dev/null || true
}
show_update_page() {
    if [ -x "$SYSTEM_HELPER" ]; then
        "$SYSTEM_HELPER" update-page-start >/dev/null 2>&1 || true
    fi
    return 0
}
end_update_page() {
    if [ -x "$SYSTEM_HELPER" ]; then
        "$SYSTEM_HELPER" update-page-stop >/dev/null 2>&1 || true
    fi
    rm -f "$UPDATE_PAGE_MARKER" 2>/dev/null || true
}
show_update_page_if_unresolved() {
    if [ -e "$UNRESOLVED_FLAG" ]; then
        rm -f "$UPDATE_PAGE_MARKER" 2>/dev/null || true
        show_update_page
    elif [ -e "$UPDATE_PAGE_MARKER" ]; then
        end_update_page
    fi
    return 0
}

# write_unresolved_marker [started-failed|restore-failed|restore-refused|migrated-not-restored]
# Record the unresolved state (see UNRESOLVED_FILE): root's alone, 0600 from
# the start, written to a temporary name and renamed.
# The record, the flag and the drop-in, in that order of importance: the
# record is what update.sh refuses on, the flag what keeps dtk from starting.
# Returns non-zero unless all three are in place, so a caller about to
# migrate or DROP refuses to without the start guard. The record is written
# even when the flag or the drop-in fails: it is what update.sh refuses on.
# set_unresolved_flag: the start guard alone, the flag and the drop-in that
# makes it a start condition of dtk.service (write_unresolved_marker, and a
# crossing before its exchange). 1 unless both are in place.
set_unresolved_flag() {
    local guard_ok=1
    if ! ( mkdir -p "$UNRESOLVED_FLAG_DIR" && chmod 0700 "$UNRESOLVED_FLAG_DIR" \
            && ( umask 077; : > "$UNRESOLVED_FLAG" ) ) 2>/dev/null; then
        echo "  ⚠ Could not create $UNRESOLVED_FLAG: dtk is NOT kept from starting."
        guard_ok=0
    fi
    if ! ensure_unresolved_dropin 2>/dev/null; then
        echo "  ⚠ Could not install $UNRESOLVED_DROPIN: dtk is NOT kept from starting."
        guard_ok=0
    fi
    [ "$guard_ok" -eq 1 ]
}

write_unresolved_marker() {
    local kind="${1:-started-failed}" head guard_ok=1
    head="$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    set_unresolved_flag || guard_ok=0
    if ( umask 077
         {
             echo "kind: $kind"
             echo "code-commit: $head"
             if [ "$kind" = restore-failed ] || [ "$kind" = restore-refused ]; then
                 echo "dump-to-restore: $RESTORE_DUMP"
                 [ -z "$RESTORE_DB_NOT_DROPPED_WHY" ] || echo "refused-because: $RESTORE_DB_NOT_DROPPED_WHY"
             else
                 echo "failed-commit: $CURRENT_SHA"
                 # The commit a failure restores to and pre-update-SHA names,
                 # so the rollback accepts the record.
                 echo "restore-target: $RESTORE_SHA"
                 echo "migrated-revision: ${MIGRATED_REVISION:-(unknown)}"
             fi
             echo "dump: $RESTORE_DUMP"
             echo "rollback-command: $ROLLBACK_CMD"
             echo "recorded-at: $(date +%Y-%m-%dT%H:%M:%S%z)"
         } > "$UNRESOLVED_FILE.tmp" ) 2>/dev/null \
         && mv -f "$UNRESOLVED_FILE.tmp" "$UNRESOLVED_FILE" 2>/dev/null; then
        # An explicit status: this runs inside the EXIT trap, where bash 5 gives a
        # `return` with no argument the status from before the trap (the failed
        # update's), not the status of the line above it.
        [ "$guard_ok" -eq 1 ] && return 0
        return 1
    fi
    rm -f "$UNRESOLVED_FILE.tmp" 2>/dev/null || true
    return 1
}

# The code was restored to the previous version, and with it that version's
# scripts/update.sh. One older than the record does not know it, so it would
# not refuse: say so, loudly, where the record is written.
warn_if_restored_update_ignores_record() {
    grep -q 'unresolved-deployment' "$PROJECT_ROOT/scripts/update.sh" 2>/dev/null && return 0
    echo ""
    echo "  ⚠⚠⚠ DO NOT RUN scripts/update.sh ON THIS UNIT UNTIL THE ROLLBACK HAS SUCCEEDED."
    echo "      The code is back on $(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo 'the previous version'),"
    echo "      whose update.sh predates the unresolved-deployment record: it will NOT"
    echo "      refuse, and would update over the broken database. The only way"
    echo "      forward is the rollback command above."
    echo ""
}

# The new version was started in step 8 and the update then failed. From its
# start it could take writes, and nothing on the unit can prove it did not: a
# handler commits before it responds, uvicorn logs the request only on the
# response, and stop.sh kills the backend 2s after asking it to stop. So the
# database is never restored automatically from here, and the code is not
# moved back either, because the old code cannot run over the migrated
# database. The caller stops the new version, fully, and leaves the unit
# stopped; this reports that state and writes the record.
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
        return 0
    fi
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  UPDATE FAILED — restoring the previous version"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    [ "$MIGRATION_STARTED" -eq 1 ] && keep_rollback_copy
    # Make sure nothing is up before anything moves under it. The unit is
    # stopped already; this also takes down any container still running.
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
            if write_unresolved_marker migrated-not-restored; then
                echo "    Until then update.sh refuses to run; the record is"
                echo "    $UNRESOLVED_FILE."
            else
                echo "  ⚠ Could not write $UNRESOLVED_FILE. Do NOT run update.sh again"
                echo "    before the rollback."
            fi
            # The superproject may already be back on the previous commit with
            # a submodule failing to follow: then its update.sh is what is on
            # disk now.
            if [ "$(run_as_repo_owner git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" != "$CURRENT_SHA" ]; then
                warn_if_restored_update_ignores_record
            fi
        else
            echo "    The database was not changed by this update. To move the code"
            echo "    back by hand, then start the unit:"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT checkout -B <branch> ${RESTORE_SHA:-<previous commit>}"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule update --init --recursive"
            echo "      sudo systemctl start dtk"
        fi
        echo ""
        return 0
    fi
    if ! restore_frontend_image; then
        # The previous version will start with whatever the tag holds now, not
        # with the image last-deployed-frontend names for it; that record must
        # not then claim to describe what is serving.
        rm -f "$LAST_DEPLOYED_FRONTEND_FILE" 2>/dev/null || true
        note_not_restored "frontend record: $LAST_DEPLOYED_FRONTEND_FILE removed, because the image that will serve is not the one it names"
    fi
    restore_pixi || true
    if [ "$MIGRATION_STARTED" -eq 1 ]; then
        if restore_database; then
            note_restored "database: restored from this run's backup $RESTORE_DUMP (taken with the backend stopped, before the migration)"
        else
            db_ok=0
            $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
            if [ -n "$RESTORE_DB_NOT_DROPPED_WHY" ]; then
                note_not_restored "database: NOT restored, because $RESTORE_DB_NOT_DROPPED_WHY; nothing was dropped, and the database is as the migration left it"
            else
                note_not_restored "database: the restore from $RESTORE_DUMP FAILED; the database may be partly migrated or partly restored"
            fi
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
        if write_unresolved_marker "$( [ -n "$RESTORE_DB_NOT_DROPPED_WHY" ] && echo restore-refused || echo restore-failed )"; then
            echo "  Until that succeeds, update.sh refuses to run; the record is"
            echo "  $UNRESOLVED_FILE, and the rollback removes it."
        else
            echo "  ⚠ Could not write $UNRESOLVED_FILE. Do NOT run update.sh again"
            echo "    before the rollback."
        fi
        warn_if_restored_update_ignores_record
        echo ""
        return 0
    fi

    if [ -e "$UNRESOLVED_FLAG" ]; then
        print_restore_summary
        echo ""
        echo "  ✗ The previous version was NOT started: $UNRESOLVED_FLAG exists,"
        echo "    and while it does systemd does not start dtk. ${UNRESOLVED_KIND:+(record: $UNRESOLVED_KIND)}"
        echo "    Check $UNRESOLVED_FILE before removing it."
        echo ""
        return 0
    fi
    echo "→ Starting the previous version..."
    end_update_page
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

# The restore's output goes to a log file first and is copied to the
# original output when it ends. A closed output (a `| tee` killed by the same
# hangup) then cannot interrupt it, and a write that failed cannot leave text
# in bash's output buffer to be flushed into the next file the trap writes,
# such as the record: both were seen when the output closed mid-restore.
TRAP_LOG=""
start_trap_log() {
    local log
    log="$BACKUP_DIR/update-failure-$(date +%Y%m%d-%H%M%S).log"
    exec 3>&1
    if [ -d "$BACKUP_DIR" ] && ( umask 077; : >> "$log" ) 2>/dev/null && exec >>"$log" 2>&1; then
        TRAP_LOG="$log"
        printf '%s\n' "→ The update failed; restoring. The output is kept in $log" >&3 2>/dev/null
        printf '%s\n' "  and shown here when the restore has finished." >&3 2>/dev/null
        # The newest few, as with the dumps.
        # shellcheck disable=SC2012
        ls -1t "$BACKUP_DIR"/update-failure-*.log 2>/dev/null | tail -n +$((KEEP_DUMPS + 1)) | while read -r old; do
            rm -f "$old"
        done
    fi
}
end_trap() {
    if [ -n "$TRAP_LOG" ]; then
        cat "$TRAP_LOG" >&3 2>/dev/null
    fi
    exit "$1"
}

on_exit() {
    local rc=$?
    trap '' HUP INT TERM PIPE
    if [ "$UPDATE_OK" -eq 1 ]; then
        return 0
    fi
    # Every step below handles its own failures; one failing must not abort
    # the rest of the restore.
    set +e
    # A refusal before anything changed has nothing to restore, and is not
    # announced as a restore.
    if [ "$SERVICE_STOPPED" -eq 1 ] || [ "$RESTORE_ARMED" -eq 1 ] || [ "$STACK_TOUCHED" -eq 1 ]; then
        start_trap_log
    fi
    # A crossing this run had begun (step 0b). From the exchange on, the
    # record and the HEADs settle it here. Before that the old checkout is
    # unchanged, and <root>.new is left for the next run's start to remove,
    # since a child of this run (the clone, the copy) may still be writing
    # into it.
    if [ "$CROSS_STAGE" = exchanging ]; then
        echo ""
        crossing_settle || true
    elif [ "$CROSS_STAGE" = building ]; then
        echo ""
        echo "  The new checkout being built at $CROSS_NEW is left as it is; the next"
        echo "  run of this script removes it. $CROSS_ROOT was not changed by it."
    fi
    # While a crossing record is at the exchange or after it, the root may be
    # the new checkout: nothing is restored, no restore_code, no start; the
    # flag keeps the service down until the install.
    case "$(sed -n 's/^step //p' "$CROSS_RECORD" 2>/dev/null | head -n 1)" in
        exchanging|renaming|crossed)
            echo ""
            echo "  The crossing record ($CROSS_RECORD) is kept: nothing is restored,"
            echo "  and the service stays down. The next run of update.sh goes on from it."
            end_trap "$rc" ;;
    esac
    # A crossing that stopped the service and did not exchange starts it again.
    if [ "$CROSS_SERVICE_STOPPED" -eq 1 ]; then
        crossing_restart_if_stopped
    fi
    if [ "$SERVICE_STOPPED" -eq 1 ]; then
        restore_after_stop
        show_update_page_if_unresolved
        end_trap "$rc"
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
    end_trap "$rc"
}
# The kiosk's Chromium runs in the tty1 login session, which restarting dtk
# does not reach, and keeps the address start-kiosk.sh gave it at launch.
# Ending cage makes getty log in again and relaunch it from the start-kiosk.sh
# now on disk: from 0.1.0 that opens http://localhost through nginx, since
# the frontend container on :3000 has no /api. Only DTK_USER's cage: on a
# unit as shipped that is pi, the user the tty1 autologin runs the kiosk as
# (install-kiosk-service.sh). A unit with no kiosk has no cage to end.
relaunch_kiosk() {  # relaunch_kiosk <which address, for the message>
    if pkill -u "$DTK_USER" -x cage 2>/dev/null; then
        echo "→ Relaunched the kiosk on $1."
    fi
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
# forward is the decision to run this version. The kiosk is relaunched, as
# after an update.
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
    # The pins are $want's own gitlinks, not the index's: a gitlink staged to
    # another commit, with the submodule on it, passes the check above.
    if ! gitlinks_match_head "$PROJECT_ROOT" checked-out; then
        echo "✗ A submodule's staged pointer or checked-out commit is not the one $want"
        echo "  records. To see which:"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT diff --cached HEAD --submodule"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule status --recursive"
        echo "  To put them back on $want's pins (a staged pointer is discarded; the"
        echo "  commit it named stays in the submodule):"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT reset -q -- <submodule path>"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule update --init --recursive"
        return 1
    fi
    if ! backend_fully_stopped; then
        echo "✗ dtk or a backend process is running. Stop it first: sudo systemctl stop dtk"
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
    clear_unresolved_marker
    if [ -e "$UNRESOLVED_FLAG" ]; then
        echo "✗ $UNRESOLVED_FLAG could not be removed; dtk cannot start while it exists."
        return 1
    fi
    echo "  ✓ Recorded $want as the deployed version; $UNRESOLVED_FILE removed."
    if [ "$RESOLVE_NO_START" -eq 1 ]; then
        # No container serves this version's frontend yet, so there is no
        # image to record against it.
        rm -f "$LAST_DEPLOYED_FRONTEND_FILE" 2>/dev/null || true
        echo "  --no-start: the unit is left stopped. Deploy the fixed version with an"
        echo "  ordinary update now:"
        echo "      sudo $SCRIPT_DIR/update.sh"
        end_update_page
        return 0
    fi
    echo "→ Starting the service..."
    end_update_page
    systemctl start dtk 2>/dev/null || true
    echo "  Waiting up to ${HEALTH_TIMEOUT}s for the backend to answer /health..."
    local healthy=0 img
    wait_for_health "$HEALTH_TIMEOUT" && healthy=1
    # Healthy or not: the kiosk waits for nginx itself, and the one running
    # still has the address of the version before the failed update.
    relaunch_kiosk "this version's address"
    # As the success path does: the image serving now, recorded against this
    # commit, so a later rollback to it can put that image back. No record
    # rather than a wrong one when it cannot be read.
    img="$(frontend_image_id || true)"
    if [ -n "$img" ] && { echo "sha: $want"; echo "image: $img"; } > "$LAST_DEPLOYED_FRONTEND_FILE" 2>/dev/null; then
        echo "  Frontend image recorded for $want: $img"
    else
        rm -f "$LAST_DEPLOYED_FRONTEND_FILE" 2>/dev/null || true
        echo "  ⚠ The running frontend image could not be read; no frontend record kept."
    fi
    if [ "$healthy" -eq 1 ]; then
        echo "  ✓ The appliance is online on $want: the backend answers /health."
        return 0
    fi
    echo "  ✗ The service did not answer /health within ${HEALTH_TIMEOUT}s. The code"
    echo "    and the database agree and are recorded as deployed, so update.sh"
    echo "    can be run again once the cause is found: journalctl -u dtk -n 50"
    return 1
}
# A crossing that an earlier run left part-way (a stop, SIGKILL, a power
# cut) is finished or undone before anything else, since everything below
# reads the checkout.
CROSS_SETTLED=0
crossing_settle || CROSS_SETTLED=$?
case "$CROSS_SETTLED" in
    0) ;;
    3) exit 3 ;;
    *) exit 1 ;;
esac

if [ "$RESOLVE_FORWARD" -eq 1 ]; then
    if resolve_forward; then exit 0; else exit 1; fi
fi

trap on_exit EXIT
# A signal must end the run as a failure, never as a success: the EXIT trap
# then restores. on_exit itself ignores them, so a SIGHUP in the middle of a
# restore (a closed SSH session) cannot cut it short.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# A closed output (a `| tee` killed by the same hangup) must not kill the run
# by SIGPIPE: a write then fails instead, set -e ends the run, and on_exit
# restores, logging to a file.
trap '' PIPE

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

# A file that cannot be read is not a file that is not there.
# PREV_RECORD_STATE carries which it was, so that the messages here and in
# step 2 can say which.
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
elif [ -n "$PRE_HEAD" ] && [ "$DO_PULL" -eq 1 ]; then
    # On the pull path HEAD is still what was checked out before this run. On
    # --no-pull it is already the new code, so it is never a restore target:
    # with no usable record there is none, and a failure leaves the checkout.
    RESTORE_SHA="$PRE_HEAD"
    RESTORE_SHA_SOURCE="the commit checked out before this update; there was no usable record of the last deployed version"
fi

# Without a version to return to, a failure after the stop could be put back
# by nothing, and the unit would be left in a state no script can resolve.
# Refused here, before anything has changed.
if [ -z "$RESTORE_SHA" ]; then
    echo "✗ There is no record of which version this unit is running, so a failed"
    echo "  update could not be undone. Nothing has been changed."
    case "$PREV_RECORD_STATE" in
        present) echo "  $LAST_DEPLOYED_SHA_FILE names '$PREV_DEPLOYED_SHA', which is not a commit in this checkout." ;;
        *) echo "  $LAST_DEPLOYED_SHA_FILE is $PREV_RECORD_STATE." ;;
    esac
    if [ "$DO_PULL" -eq 0 ]; then
        echo "  With --no-pull the checkout is already the new code, so it cannot stand"
        echo "  in for that record. Write the commit this unit runs (the one checked"
        echo "  out before the new code was put in place) into the record, then run"
        echo "  this again:"
        echo "      echo <commit> | sudo tee $LAST_DEPLOYED_SHA_FILE"
    fi
    exit 1
fi

# --no-pull installs whatever is checked out, which this script did not put
# there: the pull path fast-forwards to the remote and sets local changes
# aside (0b), but here nothing vouches for the checkout. So it is checked as
# it is, before anything changes, and refused if it is not exactly a commit
# that descends from the deployed one:
#   • every submodule's staged pointer and checked-out commit are the
#     gitlinks HEAD records (gitlinks_match_head), so the commit installed is
#     the commit that will be recorded as deployed;
#   • no tracked file is modified or staged, in the superproject or in any
#     submodule (tracked_files_modified, recursive), for the same reason;
#   • last-deployed-SHA is HEAD or an ancestor of it. Going back to an older
#     version is a rollback: rollback-update.sh restores the database the
#     older code expects, which an update cannot. Nothing here consults the
#     remote: --no-pull is for units without a network.
# An unresolved record (a failed update, kept or resolved by --resolve-forward)
# is refused earlier, before this point; a commit kept as a failed-update/
# branch can be checked out and installed again, since it descends from the
# deployed one.
if [ "$DO_PULL" -eq 0 ]; then
    NOPULL_RC=0
    gitlinks_match_head "$PROJECT_ROOT" checked-out || NOPULL_RC=$?
    if [ "$NOPULL_RC" -ne 0 ]; then
        echo "✗ --no-pull: a submodule is not on the commit HEAD records ($PRE_HEAD),"
        echo "  or its staged pointer differs from it (or this could not be read)."
        echo "  Installing it would deploy code that is not the commit recorded as"
        echo "  deployed. Nothing has been changed. To see which:"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT diff --cached HEAD --submodule"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule status --recursive"
        echo "  To put every submodule on HEAD's pins (a staged pointer is dropped; the"
        echo "  commit it named stays in the submodule):"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT reset -q -- <submodule path>"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule update --init --recursive"
        echo "  then run this again."
        exit 1
    fi
    NOPULL_RC=0
    NOPULL_FLAGGED="$(flagged_index_entries)" || NOPULL_RC=$?
    if [ "$NOPULL_RC" -ne 0 ] || [ -n "$NOPULL_FLAGGED" ]; then
        echo "✗ --no-pull: tracked files are marked assume-unchanged or skip-worktree"
        echo "  (or the index could not be read), so git does not report changes to"
        echo "  them, and installing the checkout could deploy modified code as the"
        echo "  commit recorded as deployed. Nothing has been changed."
        if [ -n "$NOPULL_FLAGGED" ]; then
            echo "  The files (a lowercase tag is assume-unchanged, S is skip-worktree; a"
            echo "  path with a directory in front of it may be in a submodule):"
            printf '%s\n' "$NOPULL_FLAGGED" | sed 's/^/      /'
        fi
        echo "  Clear the flag in the repository that owns each file (the superproject,"
        echo "  or the submodule the path begins with, giving the path inside it), look"
        echo "  at what git then reports, and run this again:"
        echo "      sudo -u $REPO_USER git -C <repository> update-index --no-assume-unchanged --no-skip-worktree <file>"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT status --short"
        exit 1
    fi
    NOPULL_RC=0
    tracked_files_modified || NOPULL_RC=$?
    if [ "$NOPULL_RC" -ne 0 ]; then
        echo "✗ --no-pull: the checkout has modified tracked files (changed or staged),"
        echo "  in the superproject or a submodule, or this could not be read."
        echo "  Installing them would deploy code that is not the commit recorded as"
        echo "  deployed. Nothing has been changed. To see them:"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT status --short"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule foreach --recursive git status --short"
        echo "  Copy aside anything worth keeping, commit it, or discard it, then run"
        echo "  this again. To discard every local change to tracked files:"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT reset --hard HEAD"
        echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule foreach --recursive git reset --hard HEAD"
        exit 1
    fi
    # RESTORE_SHA is the deployed commit here: --no-pull takes no other target.
    NOPULL_RC=0
    run_as_repo_owner git -C "$PROJECT_ROOT" merge-base --is-ancestor "$RESTORE_SHA" "$PRE_HEAD" 2>/dev/null || NOPULL_RC=$?
    if [ "$NOPULL_RC" -ne 0 ]; then
        if [ "$NOPULL_RC" -eq 1 ]; then
            echo "✗ --no-pull: the code checked out ($PRE_HEAD) does not descend from the version"
            echo "  this unit last deployed ($RESTORE_SHA)."
        else
            echo "✗ --no-pull: could not check whether the code checked out ($PRE_HEAD)"
            echo "  descends from the version this unit last deployed ($RESTORE_SHA)."
        fi
        echo "  It would be an older or an unrelated version, installed over a database"
        echo "  migrated for $RESTORE_SHA. Nothing has been changed."
        echo "  Going back to an earlier version is rollback-update.sh's job: it returns"
        echo "  the code and restores the database that version expects:"
        echo "      sudo $SCRIPT_DIR/rollback-update.sh"
        echo "  To install a newer version instead, check out a commit that contains"
        echo "  $RESTORE_SHA and run this again."
        exit 1
    fi
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
#     The script pulls, not the operator. On a unit that has been fixed by
#     hand in the field, a plain `git pull` aborts — "Your local changes to
#     the following files would be overwritten by merge" — then tells the
#     operator to "commit or stash", which is not an instruction an archive
#     can act on. Pulling here handles the dirty-tree case once, in the open,
#     and the same way whether a person or NEH-186's admin-triggered update
#     started this.
#
#     Local modifications are COPIED ASIDE, never discarded unseen: every
#     modified tracked file, in the superproject and in each submodule, is
#     saved under /var/lib/dtk/local-mods-<timestamp>/ with a patch per level
#     that reproduces the whole set. Untracked and ignored files are left
#     where they are. On an appliance an unknown file may be the only copy of
#     something, so this script never deletes or overwrites one — a pull
#     that an untracked or ignored file would block is reported, not forced.
#
#     Runs before anything is built or stopped, so any failure here leaves
#     the unit serving the current version (the EXIT trap's "nothing
#     changed" branch).
# ---------------------------------------------------------------------------
if [ "$DO_PULL" -eq 1 ]; then
    echo "→ Fetching the new code..."

    # A detached HEAD has no branch to pull into. A rollback-update.sh older
    # than NEH-273 leaves a rolled-back unit detached.
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

    # Submodules that the upstream commit holds as folders: a gitlink at HEAD
    # (mode 160000) whose path is a tree (040000) upstream. A fast-forward
    # cannot make that change in place: every file such a submodule tracks is
    # untracked from the superproject's side. Such an update is a crossing,
    # built beside this checkout and exchanged for it (crossing_cross, and the
    # rule over the crossing functions). Every check it depends on is made
    # here, before anything changes.
    CROSSING=""
    CROSS_PATHS=()
    CROSS_HEAD_TREE="$(run_as_repo_owner git -C "$PROJECT_ROOT" ls-tree -r HEAD)"
    while IFS= read -r line; do
        [ "${line%% *}" = 160000 ] || continue
        path="${line#*$'\t'}"
        up_entry="$(run_as_repo_owner git -C "$PROJECT_ROOT" ls-tree "$PULL_UPSTREAM" -- "$path")"
        [ "${up_entry%% *}" = 040000 ] || continue
        CROSSING="${CROSSING:+$CROSSING }$path"
        CROSS_PATHS+=("$path")
    done <<< "$CROSS_HEAD_TREE"

    if [ -n "$CROSSING" ]; then
        echo "  The new code will hold $CROSSING as folders instead of submodules."
        CROSS_RC=0
        gitlinks_match_head "$PROJECT_ROOT" checked-out || CROSS_RC=$?
        if [ "$CROSS_RC" -ne 0 ]; then
            echo ""
            echo "✗ A submodule is not on the commit HEAD records (or its staged pointer"
            echo "  differs from it, or it is not checked out, or this could not be read),"
            echo "  and its files can become this repository's own only from that commit."
            echo "  Nothing has been changed. To see which:"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule status --recursive"
            echo "  To put every submodule on HEAD's pins (a staged pointer is dropped; the"
            echo "  commit it named stays in the submodule):"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT reset -q -- <submodule path>"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule update --init --recursive"
            echo "  then run this again."
            exit 1
        fi
        # git does not report a change to such a file, so the save below
        # cannot keep it, and the new checkout is built without it.
        CROSS_RC=0
        CROSS_FLAGGED="$(flagged_index_entries)" || CROSS_RC=$?
        CROSS_FLAGGED_HERE="$(printf '%s\n' "$CROSS_FLAGGED" | awk -v paths="$CROSSING" '
            BEGIN { n = split(paths, p, " ") }
            { for (i = 1; i <= n; i++) if (index(substr($0, 3), p[i] "/") == 1) { print; next } }')"
        if [ "$CROSS_RC" -ne 0 ] || [ -n "$CROSS_FLAGGED_HERE" ]; then
            echo ""
            echo "✗ Files in $CROSSING are marked assume-unchanged or skip-worktree (or"
            echo "  the index could not be read), so git does not report changes to"
            echo "  them, and a change to one would be left behind unsaved."
            echo "  Nothing has been changed."
            if [ -n "$CROSS_FLAGGED_HERE" ]; then
                echo "  The files (a lowercase tag is assume-unchanged, S is skip-worktree):"
                printf '%s\n' "$CROSS_FLAGGED_HERE" | sed 's/^/      /'
            fi
            echo "  Clear the flag in the submodule (giving the path inside it), look at"
            echo "  what git then reports, and run this again:"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT/<submodule> update-index --no-assume-unchanged --no-skip-worktree <file>"
            echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT/<submodule> status --short"
            exit 1
        fi
        for path in "${CROSS_PATHS[@]}"; do
            # The gitfile must be a file naming a repository outside the
            # submodule's folder; a .git directory there is the repository
            # itself, and its untracked files would be carried into the new
            # checkout.
            gitdir="$(run_as_repo_owner git -C "$PROJECT_ROOT/$path" rev-parse --absolute-git-dir 2>/dev/null || true)"
            subdir="$(cd "$PROJECT_ROOT/$path" 2>/dev/null && pwd -P || true)"
            if [ -L "$PROJECT_ROOT/$path/.git" ] || [ ! -f "$PROJECT_ROOT/$path/.git" ] \
                    || [ -z "$gitdir" ] || [ -z "$subdir" ] || [ "${gitdir#"$subdir"/}" != "$gitdir" ]; then
                echo ""
                echo "✗ $path keeps its repository inside its own folder ($path/.git is not"
                echo "  a gitfile naming one elsewhere), which this script does not carry"
                echo "  over to the new checkout. Nothing has been changed. To move the"
                echo "  repository into .git/modules:"
                echo "      sudo -u $REPO_USER git -C $PROJECT_ROOT submodule absorbgitdirs"
                echo "  then run this again."
                exit 1
            fi
            # A submodule inside it is not part of the new tree.
            nested="$(run_as_repo_owner git -C "$PROJECT_ROOT/$path" ls-files --stage)"
            if printf '%s\n' "$nested" | grep -q '^160000 '; then
                echo ""
                echo "✗ $path holds submodules of its own, which this script cannot turn"
                echo "  into folders. Nothing has been changed."
                exit 1
            fi
        done
        # The new checkout is cloned without submodules, so every gitlink at
        # HEAD has to become a folder.
        if [ "$(printf '%s\n' "$CROSS_HEAD_TREE" | grep -c '^160000 ')" -ne "${#CROSS_PATHS[@]}" ]; then
            echo ""
            echo "✗ The new code holds $CROSSING as folders but keeps other submodules,"
            echo "  which this script cannot carry over. Nothing has been changed."
            exit 1
        fi
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
        # Set BEFORE the first reset, not after the last. Otherwise a
        # superproject reset that succeeds followed by a submodule reset that
        # fails (a stale index.lock will do it) leaves the flag at zero, and
        # the trap prints "nothing changed" after modifications were
        # discarded, which NEH-215 exists to prevent.
        # A crossing builds the new checkout from the target commit, without
        # them, and leaves this checkout, kept as <root>.pre-merge, with them.
        if [ -n "$CROSSING" ]; then
            echo "  ✓ Saved. The new checkout is built without them; this checkout keeps"
            echo "    them. To see what was set aside:"
            echo "      ls -R $MODS_DIR"
        else
            TREE_TOUCHED=1
            run_as_repo_owner git -C "$PROJECT_ROOT" reset --hard HEAD >/dev/null
            run_as_repo_owner git -C "$PROJECT_ROOT" submodule foreach --quiet --recursive 'git reset --hard HEAD' >/dev/null
            echo "  ✓ Saved and reset. To see what was set aside:"
            echo "      ls -R $MODS_DIR"
        fi
    fi

    echo ""
    if [ -n "$CROSSING" ]; then
        if ! crossing_cross; then
            exit 1
        fi
        # The crossing ends this run. The checkout is now the new code; the
        # steps below (the dependency check, the build, the migration, the
        # record of what is deployed) are this script's, written for the
        # submodule layout, and the new code's update.sh does them for its own
        # layout. The service was stopped before the exchange; the
        # unresolved-deployment flag keeps it from starting the new checkout,
        # and the crossing record stays at crossed, until that run installs
        # it and clears both.
        echo ""
        echo "✓ $CROSS_ROOT now holds the new code ($CROSS_TARGET), with"
        echo "  $CROSSING as folders. The previous checkout is kept at $CROSS_PRE_DIR."
        echo "  The new version is not installed yet: nothing was rebuilt or migrated."
        echo "  The service is stopped, and the flag $UNRESOLVED_FLAG"
        echo "  keeps it from starting again before the install. The next run of"
        echo "  update.sh installs the new version and clears the flag; run it now:"
        echo "      sudo $SCRIPT_DIR/update.sh"
        UPDATE_OK=1
        exit 3
    fi
    # From here the checkout may stop matching what is running: a failure
    # anywhere below puts it back (0a, and the EXIT trap).
    RESTORE_ARMED=1
    # --no-overwrite-ignore: git's default replaces an ignored file at a path
    # the new commit tracks, with no copy anywhere. On an appliance an ignored
    # file (a database, an environment file, build output) may be the only
    # copy of something, so the fast-forward refuses instead and git names it.
    if ! run_as_repo_owner git -C "$PROJECT_ROOT" merge --ff-only --no-overwrite-ignore "$PULL_UPSTREAM"; then
        echo ""
        echo "✗ Fast-forward to $PULL_UPSTREAM failed. The usual cause left at this"
        echo "  point is an untracked or ignored file on the unit that the update"
        echo "  would overwrite — git names it above. Move it aside by hand; this"
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
# inputs, pre-update-SHA (step 5) and the dump that is kept (step 7), are
# written by the same run, after this snapshot, so the NEWEST dump and the
# recorded SHA correspond; older retained dumps do not (rollback-update.sh
# warns when an older dump is selected).
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
# identified by its own file name, which steps 5 and 7 store in
# pre-update-ref together with the dump name.
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
#    not in a service context. With stderr discarded that failure is
#    invisible, and the script would report "no previous-deploy record
#    found" with the record present and correct, and never reach the offline
#    determination (NEH-271). The same reasoning governs CURRENT_SHA above
#    and rollback-update.sh's checkout.
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
    # missing record: no usable record, a recorded commit that is missing or
    # cannot be checked, and an ordinary redeploy of the commit already
    # checked out. Each gets its own message, so that an operator is never
    # told the record is missing when it is present and correct.
    #
    # The conservative NEEDS_INTERNET=1 stays in all three. For a redeploy of
    # the same commit nothing can have changed, so it is stricter than it
    # needs to be.
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
                   echo "Aborted by operator. The code and the service are as they were;"
                   echo "the backup directory's permissions and a pre-update state record"
                   echo "may have been written."
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
#     already has a good rclone takes neither path here — provision-rclone.sh's
#     step 2 finds the
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
# 4d. Unit name, first half: what renaming digitool to captua needs, installed
#     while the unit still serves (avahi-utils from apt, the digitool.local
#     alias service, its NetworkManager hook, and the dtk.service drop-in that
#     finishes an interrupted rename). Renames nothing; the switch is in 6b.
#     apt is tried under --no-pull too: the 0.1.0 install runs --no-pull on
#     units that are online. Only --offline skips it, and a unit without
#     avahi-utils then keeps its name. Advisory for the reason 4c is.
# ---------------------------------------------------------------------------
if [ "$OFFLINE" -eq 1 ]; then
    "$SCRIPT_DIR/provision-hostname.sh" --prepare --advisory --offline
else
    "$SCRIPT_DIR/provision-hostname.sh" --prepare --advisory
fi

# ---------------------------------------------------------------------------
# 4e. Wi-Fi permissions: the polkit rule that lets pi, the user the backend
#     runs as, scan, join and forget Wi-Fi networks through NetworkManager.
#     setup.sh runs once, at first provisioning, so an appliance already in
#     the field receives the rule from update.sh. Without the rule, joining a
#     network from Captua's settings is refused on such a unit.
#     update.sh keeps running its old copy after it pulls (NEH-337), so a unit
#     updated from a version without this section receives the rule on the
#     next update, or from one run of
#     `sudo scripts/install-network-permissions.sh`. New units receive it
#     from setup.sh.
#     Idempotent, needs no network, and restarts nothing. Not advisory: the
#     script exits non-zero on a bad argument, when mktemp or the write of the
#     temporary file fails, when the write into /etc fails, and when a
#     directory sits at the rule's path. A missing rules directory is a
#     warning with exit 0.
# ---------------------------------------------------------------------------
echo "→ Configuring Wi-Fi permissions..."
"$SCRIPT_DIR/install-network-permissions.sh"
echo ""

# ---------------------------------------------------------------------------
# 4f. Privileged helper: /usr/local/bin/dtk-system-helper and its sudoers
#     entry. setup.sh installs them once, at first provisioning, so a unit
#     already in the field receives a helper with new verbs from update.sh.
#     Without it such a unit keeps the helper it was installed with: pairing
#     with Fisqua needs the restart-backend verb and is refused there.
#     update.sh keeps running its old copy after it pulls (NEH-337), so a unit
#     updated from a version without this section receives the helper on the
#     next update, or from one run of `sudo scripts/install-system-helper.sh`.
#     Runs while the old backend still serves. The helper only gains verbs
#     between versions, so the old backend works with the new helper, and a
#     restored update keeps it.
#     Idempotent, needs no network, and restarts nothing. Not advisory: the
#     script exits non-zero when the helper source is missing, when a copy
#     into place fails, and when visudo rejects the sudoers file, which is
#     then not installed.
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/install-system-helper.sh"
echo ""

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
# Probe container state WITHOUT mutating anything. An unconditional
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
# IMPORTANT: step 0b has already pulled the new code (or --no-pull found it
# in place), so HEAD ($CURRENT_SHA) is the NEW version. The rollback target
# is the commit that was RUNNING before this update — RESTORE_SHA, from
# last-deployed-SHA or the pre-pull HEAD (step 0a) — never the new HEAD.
if [ -n "$RESTORE_SHA" ]; then
    # The same commit a failure here restores to (0a), so that the rollback
    # the failure output names returns the code to it too.
    echo "$RESTORE_SHA" > "$SHA_FILE"
    echo "  Rollback target recorded: $RESTORE_SHA"
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
mark_update_page
systemctl stop dtk 2>/dev/null || true
# systemd runs ExecStop (stop.sh) only for an ACTIVE unit. If dtk was already
# failed or inactive, the containers can still be up under their
# restart: unless-stopped policy — so tear down explicitly here.
# --remove-orphans also clears containers whose service no longer exists in
# the compose files; without it a stale container keeps an endpoint on the
# project network and wedges every later network operation (NEH-214).
$COMPOSE down --remove-orphans
assert_stack_gone
# assert_stack_gone sees only Docker. The backend runs natively, and one that
# survived the stop could reconnect once the db is back and write after the
# backup below, and a restore would then discard those writes. So the stop has
# to be confirmed (unit inactive or failed, no main PID, no uvicorn) before
# any backup or migration; otherwise abort here, with the database untouched.
if ! wait_backend_stopped; then
    echo "✗ The backend did not stop: dtk is still active, or a"
    echo "  'uvicorn app.main:app' process survives (systemctl status dtk; pgrep -af uvicorn)."
    echo "  Aborting before the backup and the migration; the database is untouched."
    exit 1   # EXIT trap: no migration ran, so it restores code and image and starts the previous version
fi
# The stack is down: the update page answers on port 80 until the start.
show_update_page
echo ""
fail_point stopped

# ---------------------------------------------------------------------------
# 6b. Unit name, second half: rename digitool to captua, keeping
#     digitool.local as an alias (scripts/provision-hostname.sh). Here, with
#     the stack stopped, because it rewrites .env (HOST_IP, CORS_ORIGINS),
#     which only a start reads. Only a unit named digitool with
#     HOST_IP=digitool.local is renamed; it checks that both names resolve
#     and undoes itself if they do not.
#
#     Never fatal: a unit that keeps the name digitool works, and the guard
#     below keeps an unexpected exit status from reaching the EXIT trap. A
#     failure later in this update restores the previous code but not the
#     name, and the previous code works under it: its frontend calls
#     http://${HOST_IP}/api, captua.local now, and CORS_ORIGINS lists both
#     names.
# ---------------------------------------------------------------------------
if ! "$SCRIPT_DIR/provision-hostname.sh" --switch --advisory; then
    echo "⚠ The rename to captua did not finish; the unit keeps its current name."
fi
echo ""

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
# Checked again: nothing may have started a backend since the backup.
if ! wait_backend_stopped; then
    echo "✗ A backend is running again; aborting before the migration. The"
    echo "  database is untouched."
    exit 1
fi
# Set before the call: a migration that fails part-way can leave the database
# changed, and the restore then loads this run's dump. The record goes down
# first, for a run killed during the migration: until this update either
# succeeds or restores the database, code and database may not agree.
if ! write_unresolved_marker migrated-not-restored; then
    # Nothing has been migrated: whatever of the record and the flag went
    # down would only keep the previous version from starting again.
    clear_unresolved_marker
    echo "✗ Could not write $UNRESOLVED_FILE with its start flag and drop-in;"
    echo "  not migrating without them."
    exit 1
fi
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
# The migration finished and the database is at the new version's head, with
# the new code checked out: the two agree, so the start flag goes. Before it
# does, the record is rewritten to what a run cut off from here on leaves:
# the new version started (or about to), possibly serving, possibly holding
# new data. It stays until the new version is healthy.
if ! write_unresolved_marker started-failed; then
    echo "✗ Could not rewrite $UNRESOLVED_FILE; not starting the new version."
    exit 1   # EXIT trap: the migration ran, so it restores code and database
fi
rm -f "$UNRESOLVED_FLAG" 2>/dev/null || true
echo "→ Starting service..."
NEW_STARTED_AT="$(date +%s)"
end_update_page
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
    # Immediately after: from here the deploy record names what is running.
    clear_unresolved_marker
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
# The record written before the migration: code and database now agree, on
# the version recorded as deployed (cleared above, with the deploy record;
# again here for a commit that could not be resolved).
clear_unresolved_marker
UPDATE_OK=1
SERVICE_STOPPED=0

relaunch_kiosk "the new version's address"

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
echo "  Frontend: http://localhost (nginx), or http://$(hostname 2>/dev/null || echo captua).local from the network"
echo "  Backend:  http://localhost:8000/health"
echo "  Logs:     journalctl -u dtk -f"
echo ""
