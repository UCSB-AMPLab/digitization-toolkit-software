#!/bin/bash
# Update Digitization Toolkit to the latest committed code.
#
# This script guards IRREPLACEABLE archival data. It is designed to be safe to
# run on a live Pi at a remote venue, possibly by non-technical staff:
#
#   • All network / compile work (frontend build, pixi install) happens BEFORE
#     the running service is stopped, so a failure there leaves the old, working
#     stack untouched and still serving.
#   • Before any migration a timestamped pg_dump is taken and verified non-empty;
#     the pre-update superproject commit is recorded so a botched update can be
#     rolled back with scripts/rollback-update.sh.
#   • If anything fails after the service is stopped, an EXIT trap restarts the
#     previous stack and tells the operator the unit is back on the old version.
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
#   --yes       Skip the "this update needs internet" confirmation prompt
#               (for scripted / unattended use).
#   --no-pull   Do not fetch; update to whatever is already checked out.
#               For offline updates, and for testing a specific commit.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ASSUME_YES=0
DO_PULL=1
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-pull) DO_PULL=0 ;;
        *) echo "Unknown argument: $arg"; echo "Usage: sudo ./scripts/update.sh [--yes] [--no-pull]"; exit 2 ;;
    esac
done

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
# Frontend image that was serving when LAST_DEPLOYED_SHA_FILE's commit was
# successfully deployed ("sha:" and "image:" lines; written only on success).
LAST_DEPLOYED_FRONTEND_FILE="$BACKUP_DIR/last-deployed-frontend"
LAST_DEPLOYED_SHA_FILE="$BACKUP_DIR/last-deployed-SHA"
KEEP_DUMPS=5

cd "$PROJECT_ROOT"

echo "=========================================="
echo " Digitization Toolkit — Update"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 0. Safety net: if we fail AFTER stopping the service, bring the old stack
#    back up so the venue is never left with a dead appliance. Armed just
#    before we stop the service (see step 6); until then failures are harmless
#    because the running stack was never touched.
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

restore_service() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  UPDATE FAILED — bringing the appliance back up"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    echo "  Something went wrong during the update. Restarting the unit"
    echo "  so it is not left dead..."
    echo ""
    # Make sure nothing is half-up before we restart cleanly. --remove-orphans:
    # containers from services dropped between releases must go too, or they
    # keep an endpoint on the project network and wedge the restart (NEH-214).
    $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    systemctl start dtk 2>/dev/null || true
    sleep 5
    if systemctl is-active --quiet dtk; then
        echo "  ✓ The appliance is back online."
    else
        echo "  ✗ The appliance did NOT come back up automatically."
        echo "    Check logs:  journalctl -u dtk -n 50"
    fi
    echo ""
    echo "  IMPORTANT: the failure happened after the service was stopped for"
    echo "  migration, so the database MAY have been partially (or fully)"
    echo "  migrated. A pre-update backup was saved in: $BACKUP_DIR"
    echo "  To return fully to the previous version (database and code), run:"
    echo "    sudo $SCRIPT_DIR/rollback-update.sh"
    echo ""
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
    if [ "$SERVICE_STOPPED" -eq 1 ]; then
        restore_service
    elif [ "$STACK_TOUCHED" -eq 1 ]; then
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
    exit "$rc"
}
trap on_exit EXIT

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
fi

# ---------------------------------------------------------------------------
# 1. Note the commit being installed. Step 0b has already pulled (or --no-pull
#    said the new code is in place), so HEAD is the NEW version; the rollback
#    target is the previously deployed commit, handled in step 5.
# ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
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
file_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    fi
}
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
# Immutable image id of the running frontend container; empty on any error.
frontend_image_id() {
    local cid
    cid="$($COMPOSE ps -q frontend 2>/dev/null | head -n 1)" || return 1
    [ -n "$cid" ] || return 1
    docker container inspect --format '{{.Image}}' "$cid" 2>/dev/null
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
# A file that cannot be read is not a file that is not there, and this block's
# messages used to say the latter for both. PREV_RECORD_STATE carries which it
# was so the diagnosis below can be true.
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
            *) echo ""; echo "Aborted by operator. Nothing changed."; exit 1 ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# 3. Rebuild frontend image (network/compile risk — done BEFORE stopping).
# ---------------------------------------------------------------------------
echo "→ Rebuilding frontend image..."
$COMPOSE build frontend
echo ""

# ---------------------------------------------------------------------------
# 4. Update pixi environment (network risk — done BEFORE stopping).
# ---------------------------------------------------------------------------
echo "→ Updating backend dependencies (pixi)..."
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" install --locked
cd "$PROJECT_ROOT"
echo ""

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
# 5. Pre-migration backup. The old stack is STILL RUNNING and serving, so this
#    dump is a consistent snapshot of live data before we change anything.
#    (pg_dump takes a single transactional snapshot, so it is safe to run while
#    the app is live.) We take and verify the dump BEFORE stopping anything, so
#    a backup failure aborts the update with the appliance untouched.
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
echo "→ Backing up the database to:"
echo "    $DUMP_FILE"
# Pipe pg_dump through gzip. set -o pipefail so a pg_dump failure fails the line
# even though gzip exits 0.
set -o pipefail
$COMPOSE exec -T db pg_dump -U "$DATABASE_USER" -d "$DATABASE_NAME" | gzip > "$DUMP_FILE"
set +o pipefail

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
# 6. Stop the service. From HERE the EXIT trap will restart the stack on any
#    failure. (The db container — whether it was already up under the service
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
        exit 1   # EXIT trap restores the previous stack
    fi
    sleep 2
done

echo "→ Applying migrations..."
cd "$PROJECT_ROOT/backend"
run_as_user "$PIXI_BIN" run db-upgrade
cd "$PROJECT_ROOT"
echo ""

echo "→ Stopping database..."
$COMPOSE down --remove-orphans
assert_stack_gone
echo ""

# ---------------------------------------------------------------------------
# 8. Restart the service on the new version.
# ---------------------------------------------------------------------------
echo "→ Starting service..."
systemctl start dtk
sleep 5
if systemctl is-active --quiet dtk; then
    echo "  Service running ✓"
else
    echo "✗ Service failed to start on the new version."
    exit 1   # EXIT trap restores the previous stack
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
