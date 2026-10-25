#!/bin/bash
# Roll back a Digitization Toolkit update: restore the pre-update database
# snapshot and return the code to the commit it was on before the update.
#
# This is the companion to scripts/update.sh. update.sh writes, before it
# migrates:
#   • a gzipped SQL dump  →  /var/lib/dtk/backups/pre-update-YYYYmmdd-HHMMSS.sql.gz
#   • the pre-update commit  →  /var/lib/dtk/backups/pre-update-SHA
#
# Who runs this: the project's own operators, over SSH or at the unit. It is
# not written for venue staff, and its messages assume someone who can read
# `git status` and act on it.
#
# What it starts from: the state update.sh leaves behind on its pull path -- a
# clean tree, every submodule initialised and on its pin -- which step 1b
# checks rather than assumes, because a unit updated with --no-pull, or edited
# since, may not be in it. A tree outside that state is refused with the
# appliance still running. States 1b cannot see are unsupported rather than
# handled: an ignored file inside a submodule at a path the target tracks (the
# inner checkout `submodule update` runs overwrites it, and this script has no
# way to tell it not to); an index bit set by hand beyond the ones 1b lists;
# an interruption between two writes under /var/lib/dtk. In those the script
# stops and says where things stand. It does not promise to put anything back.
#
# What this script does, loudly:
#   1. Checks what can be checked without doing anything: who git runs as,
#      that the checkout is readable as that user, that the pre-update commit
#      is present, and that the checkout is in a state the move can start
#      from -- no local changes, every submodule initialised and on its pin.
#      Any of those failing stops it here, with the appliance still running
#      and the database untouched. A copy of this script is kept under
#      /var/lib/dtk, because step 3 replaces the one in the checkout.
#   2. Stops the appliance.
#   3. Checks out the pre-update superproject commit and syncs submodules to
#      the pins that commit records (no --remote — pins are respected), then
#      verifies all four repositories are where the target says. BEFORE the
#      database, so a failure here leaves the database as it was. The code is
#      not put back on failure: the unit is left stopped, with the state named
#      and one command that finishes the move, and the next run recognises an
#      interrupted move by the marker this one leaves.
#   4. Restores the newest (or a named) database dump into PostgreSQL,
#      REPLACING the current database contents. The irreversible step, and the
#      last one that can fail — by which point the code is already right, so a
#      failure here is retryable from the same backup.
#   4b. Puts back the frontend image recorded for the restored version, when
#      update.sh's record names it unambiguously and it is still on the unit.
#   5. Restarts the service and reports what happened, component by component:
#      the database and the code are restored; the pixi environment is NOT
#      rebuilt (that needs the registries), so the summary says whether it and
#      the frontend image correspond to the restored version, using the
#      pre-update-state-* record update.sh writes (NEH-218). A successful
#      rollback also removes update.sh's unresolved-deployment record.
#
# Usage:
#   sudo ./scripts/rollback-update.sh                       # newest dump
#   sudo ./scripts/rollback-update.sh <dump-file.sql.gz>    # a specific dump
#   sudo ./scripts/rollback-update.sh --yes                 # skip confirmation
#   sudo /var/lib/dtk/rollback-update.sh --project-root=/home/pi/dtk ...
#                                     # the kept copy, after the checkout moved
#
# WARNING: restoring a dump DISCARDS any data written since that dump was taken.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BASH_SOURCE may be relative to a directory this script cds out of.
THIS_SCRIPT="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Everything this script keeps outside the checkout lives here -- outside,
# because step 3 replaces the checkout, scripts/ included, and anything a
# second run needs has to survive that.
STATE_DIR="/var/lib/dtk"
BACKUP_DIR="$STATE_DIR/backups"
SHA_FILE="$BACKUP_DIR/pre-update-SHA"
REF_FILE="$BACKUP_DIR/pre-update-ref"
# What the unit believes is deployed. update.sh writes it on success; this
# script has to correct it when it takes the code back, or the unit reports a
# version it is no longer running (NEH-272).
LAST_DEPLOYED_SHA_FILE="$BACKUP_DIR/last-deployed-SHA"
# update.sh's record of an unresolved deployment, and the flag a systemd
# drop-in turns into a start condition for dtk (update.sh, UNRESOLVED_FILE).
# A rollback that restores both code and the database the record names
# removes them; nothing else here does.
UNRESOLVED_FILE="$BACKUP_DIR/unresolved-deployment"
UNRESOLVED_FLAG="/etc/dtk/unresolved-deployment"
# Written just before the code moves and removed once the move is verified. On
# a later run its presence means a move to the commit it names was
# interrupted, so a tree that is part-way there is the expected state and not
# a refusal (see 1b).
ROLLBACK_MARKER="$STATE_DIR/rollback-in-progress"
# A copy of this script, taken before the move. Afterwards the one in
# scripts/ is the target's -- older, or on some targets absent -- so every
# "run this again" below names the copy.
ROLLBACK_SCRIPT_COPY="$STATE_DIR/rollback-update.sh"

USAGE="Usage: sudo ./scripts/rollback-update.sh [--yes] [--project-root=PATH] [<dump-file.sql.gz>]"
ASSUME_YES=0
DUMP_ARG=""
PROJECT_ROOT_ARG=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --project-root=*) PROJECT_ROOT_ARG="${arg#*=}" ;;
        -h|--help)
            echo "$USAGE"
            exit 0 ;;
        -*)
            echo "✗ Unknown option: $arg"
            echo "$USAGE"
            exit 2 ;;
        *)
            if [ -n "$DUMP_ARG" ]; then
                echo "✗ Too many arguments: got both '$DUMP_ARG' and '$arg'."
                echo "  Name at most one dump file."
                echo "$USAGE"
                exit 2
            fi
            DUMP_ARG="$arg" ;;
    esac
done

# The checkout this script acts on: the parent of scripts/ when run from the
# checkout, as it normally is. The copy under $STATE_DIR is not in a checkout
# and is told where it is instead.
if [ -n "$PROJECT_ROOT_ARG" ]; then
    if ! PROJECT_ROOT="$(cd "$PROJECT_ROOT_ARG" 2>/dev/null && pwd)"; then
        echo "✗ --project-root: no such directory: $PROJECT_ROOT_ARG"
        exit 2
    fi
else
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
fi

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

# Load DB credentials the same way update.sh / docker compose do.
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_ROOT/.env"
    set +a
fi
DATABASE_USER="${DATABASE_USER:-user}"
DATABASE_NAME="${DATABASE_NAME:-digitization_toolkit}"

# Resolve real user. The fallback is the CHECKOUT'S OWNER, not whoami: with no
# SUDO_USER -- a systemd unit, NEH-186's admin-triggered path, anything that is
# not an interactive sudo -- whoami is root, and root-run git on a user-owned
# checkout fails dubious-ownership. Every git call in this script runs as this
# user, so getting it wrong fails all of them: the preflight in 1b then refuses
# a rollback the unit was able to perform, which is at least a refusal rather
# than a half-done rollback. update.sh already asks the filesystem who owns the
# checkout; this script was never given the same treatment.
if [ -n "$SUDO_USER" ]; then
    DTK_USER="$SUDO_USER"
else
    DTK_USER="$(stat -c %U "$PROJECT_ROOT" 2>/dev/null || whoami)"
fi
DTK_USER_HOME=$(eval echo "~$DTK_USER")

COMPOSE="docker compose -f $PROJECT_ROOT/docker-compose.yml -f $PROJECT_ROOT/docker-compose.pi.yml"

# Is the checkout clean? 0 when the index matches HEAD and the working tree
# matches the index -- tracked files in the superproject, and in a submodule
# its checked-out commit against the gitlink -- 1 when either differs, and
# anything else when a read failed, which every caller treats as "not clean"
# rather than as clean. Two diffs, not one: `git diff HEAD` reads the working
# tree against HEAD and never consults the index, so a gitlink staged with
# nothing checked out behind it -- the input that defeated an earlier version
# of this script -- is invisible to it and visible to `--cached`.
# --ignore-submodules=untracked leaves an untracked file inside a submodule
# alone, as update.sh does, and still reports a modified tracked one.
tree_clean() {
    local rc=0
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" \
        git -C "$PROJECT_ROOT" diff --cached --quiet HEAD --ignore-submodules=untracked 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" \
        git -C "$PROJECT_ROOT" diff --quiet --ignore-submodules=untracked 2>/dev/null || rc=$?
    return "$rc"
}

# Is the backend fully stopped? The unit inactive or failed with no main PID,
# and no uvicorn left (stop.sh, the unit's ExecStop, finds the backend by
# "uvicorn app.main:app"). Same check as update.sh.
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

cd "$PROJECT_ROOT"

echo "=========================================="
echo " Digitization Toolkit — ROLL BACK an update"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Work out which dump to restore.
# ---------------------------------------------------------------------------
if [ -n "$DUMP_ARG" ]; then
    if [ -f "$DUMP_ARG" ]; then
        DUMP_FILE="$DUMP_ARG"
    elif [ -f "$BACKUP_DIR/$DUMP_ARG" ]; then
        DUMP_FILE="$BACKUP_DIR/$DUMP_ARG"
    else
        echo "✗ Named backup not found: $DUMP_ARG"
        echo "  Available backups in $BACKUP_DIR:"
        ls -1t "$BACKUP_DIR"/pre-update-*.sql.gz 2>/dev/null || echo "    (none)"
        exit 1
    fi
else
    # Filenames are our own fixed timestamped pattern; ls -t sorting is safe.
    # shellcheck disable=SC2012
    DUMP_FILE="$(ls -1t "$BACKUP_DIR"/pre-update-*.sql.gz 2>/dev/null | head -n 1 || true)"
    if [ -z "$DUMP_FILE" ]; then
        echo "✗ No backups found in $BACKUP_DIR."
        echo "  Nothing to roll back to. Aborting (nothing changed)."
        exit 1
    fi
fi

# Sanity: the dump must be non-trivial (an empty pg_dump gzips to ~20 bytes).
DUMP_BYTES="$(wc -c < "$DUMP_FILE" | tr -d ' ')"
if [ "${DUMP_BYTES:-0}" -lt 100 ]; then
    echo "✗ Backup looks empty (${DUMP_BYTES} bytes): $DUMP_FILE"
    echo "  Refusing to restore from a broken backup. Aborting (nothing changed)."
    exit 1
fi

# The command a second run is told to use. This form is right when the
# checkout has not been replaced (no commit recorded, so no code move); 1b
# replaces it with the kept copy once there is one.
RESUME_CMD="$(printf '%q' "$PROJECT_ROOT/scripts/rollback-update.sh")"
if [ "$ASSUME_YES" -eq 1 ]; then
    RESUME_CMD="$RESUME_CMD --yes"
fi
RESUME_CMD="$RESUME_CMD $(printf '%q' "$DUMP_FILE")"

# The recorded commit has four states, not two. An absent record is a
# legitimate older backup: the code rollback is skipped and the operator is told
# so before she confirms. A record that is present but unreadable, or present
# and empty, is a BROKEN record, and reading it as absent is what let the
# database be replaced with no code rollback attempted at all -- the old
# database under newer code that this script exists to undo. update.sh
# classifies its own records the same four ways (NEH-218).
#
# Whitespace is stripped rather than trusted: a stray newline or space in the
# record makes every git lookup below fail on a sha that looks correct in the
# message.
TARGET_SHA=""
if [ ! -e "$SHA_FILE" ]; then
    TARGET_RECORD_STATE=absent
elif ! TARGET_SHA="$(tr -d '[:space:]' < "$SHA_FILE" 2>/dev/null)"; then
    TARGET_RECORD_STATE=unreadable
elif [ -z "$TARGET_SHA" ]; then
    TARGET_RECORD_STATE=empty
else
    TARGET_RECORD_STATE=present
fi

# The recorded code-rollback commit is written by the MOST RECENT update,
# next to the newest dump. Selecting an older retained dump breaks that
# correspondence — say so before the operator confirms.
NEWEST_DUMP="$(ls -1t "$BACKUP_DIR"/pre-update-*.sql.gz 2>/dev/null | head -n 1 || true)"
if [ -n "$TARGET_SHA" ] && [ -n "$DUMP_ARG" ] && [ "$DUMP_FILE" != "$NEWEST_DUMP" ]; then
    echo "⚠  The recorded code-rollback commit ($TARGET_SHA) was written by the"
    echo "   most recent update, but you selected an OLDER dump. The restored"
    echo "   database may not correspond to that code version."
    echo ""
fi

# ---------------------------------------------------------------------------
# 1b. What the code rollback depends on that can be answered without doing
#     anything: who git runs as, whether git can read the checkout as that
#     user, whether the recorded commit is present, whether the checkout is in
#     a state the move can start from, and what the target's own update.sh
#     does.
#
#     None of these predicts whether the checkout will succeed. An earlier
#     version tried -- a read-tree dry run, an enumeration of the target's
#     pins, a ref pinning the target -- and two adversarial rounds kept finding
#     inputs where the prediction and the act diverged. The version after that
#     moved the code first and undid the move on failure, and a third round
#     found the undo restoring less than the snapshot it worked from: no index,
#     no working files, no off-pin submodule heads, no guarantee the objects
#     it needed were still reachable offline.
#
#     What is asked instead is the one thing the repository can answer now and
#     that makes both problems go away: is the tree clean and on its pins? From
#     that state the move is a checkout and a submodule sync that either
#     complete, or stop with the target still local, the dump still on disk and
#     a copy of this script outside the tree to finish with. Nothing is put
#     back, because backward was never the direction the operator asked for.
# ---------------------------------------------------------------------------
TARGET_UPDATE_PULLS=unknown
case "$TARGET_RECORD_STATE" in
    unreadable)
        echo "✗ $SHA_FILE exists but could not be read."
        echo "  It names the commit the code would be returned to. Restoring the"
        echo "  database without it would leave the old data under the newer code."
        echo "  Check its permissions, or name a dump whose record is readable."
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1 ;;
    empty)
        echo "✗ $SHA_FILE exists but is empty."
        echo "  The last update did not finish writing it, so there is no commit to"
        echo "  return the code to, and restoring the database alone would leave"
        echo "  the old data under the newer code."
        echo "  The commit you want is probably in: sudo -u $DTK_USER git -C $PROJECT_ROOT reflog"
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1 ;;
esac
if [ -n "$TARGET_SHA" ]; then
    # Who git runs as. An identity sudo will not accept fails every git call
    # in step 3 the same way, so it is named here instead of surfacing later
    # as a commit that appears to be missing.
    if ! sudo -u "$DTK_USER" true 2>/dev/null; then
        echo "✗ Cannot run commands as '$DTK_USER', the owner of $PROJECT_ROOT."
        echo "  Every git step of the rollback runs as that user, so the code"
        echo "  cannot be returned to $TARGET_SHA."
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1
    fi

    # Whether the checkout is readable AS that user, asked separately from the
    # commit lookup because the two have different remedies: git declines a
    # repository it considers dubiously owned with an error, not with a
    # missing object.
    if ! sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" \
            git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "✗ git cannot read the checkout at $PROJECT_ROOT as '$DTK_USER'."
        echo "  This says why:"
        echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT status"
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1
    fi

    # Whether the recorded commit is here to be checked out. On a unit that
    # never fetched it -- an SD card written from an image, a checkout replaced
    # by hand -- there is nothing to return the code to, and restoring the dump
    # would leave the database older than the code running over it.
    # Resolved to the full id, not only checked for presence: update.sh writes
    # the full `rev-parse HEAD`, but a record edited by hand may hold an
    # abbreviation, and the post-move check compares HEAD against this value
    # byte for byte -- an abbreviation would pass here and then fail that
    # check on every run, including every resume.
    if ! TARGET_FULL="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" \
            git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$TARGET_SHA^{commit}" 2>/dev/null)" \
            || [ -z "$TARGET_FULL" ]; then
        echo "✗ Recorded commit $TARGET_SHA is not present in $PROJECT_ROOT."
        echo "  The backup was taken at that commit, so restoring it under the"
        echo "  code now checked out would leave the two disagreeing and the"
        echo "  backend refusing to start."
        echo "  Fetch it and run this script again:"
        echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT fetch --all"
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1
    fi
    TARGET_SHA="$TARGET_FULL"

    # Both paths this script writes under $STATE_DIR have to be files or
    # absent. A directory at either would make the copy below land inside it
    # with a clean exit, and the marker read below return nothing.
    for path in "$ROLLBACK_SCRIPT_COPY" "$ROLLBACK_MARKER"; do
        if [ -d "$path" ] || [ -d "$path.tmp" ]; then
            echo "✗ A directory is in the way at $path (or its .tmp)."
            echo "  This script needs that path for a file. Move the directory aside and"
            echo "  run this again."
            echo "  Aborting with nothing changed — the database is untouched."
            exit 1
        fi
    done

    # A copy of this script outside the checkout. Step 3 replaces scripts/
    # with the target's, and a target can predate this script altogether
    # (f50aa4f has no scripts/rollback-update.sh) or carry an older one that
    # would be the thing "run this again" ran. Not re-copied when this IS the
    # copy -- and only when the copy is a regular file: a symlink at that
    # path pointing into the checkout would satisfy -ef and then vanish with
    # the checkout, so it is replaced like anything else. Written to a
    # temporary name and renamed, which replaces a symlink rather than
    # writing through it. A failed copy is a refusal, with the appliance
    # still running: without it, every "run this again" below would name a
    # file the checkout may have removed.
    if [ "$THIS_SCRIPT" -ef "$ROLLBACK_SCRIPT_COPY" ] && [ -f "$ROLLBACK_SCRIPT_COPY" ] && [ ! -L "$ROLLBACK_SCRIPT_COPY" ]; then
        :
    elif cp "$THIS_SCRIPT" "$ROLLBACK_SCRIPT_COPY.tmp" 2>/dev/null \
            && chmod 755 "$ROLLBACK_SCRIPT_COPY.tmp" 2>/dev/null \
            && mv -f "$ROLLBACK_SCRIPT_COPY.tmp" "$ROLLBACK_SCRIPT_COPY" 2>/dev/null; then
        :
    else
        rm -f "$ROLLBACK_SCRIPT_COPY.tmp" 2>/dev/null || true
        echo "✗ Could not copy this script to $ROLLBACK_SCRIPT_COPY."
        echo "  The rollback replaces scripts/ along with the rest of the checkout, so"
        echo "  a copy outside it is the only thing a second run can be sure to find."
        echo "  Check that $STATE_DIR is writable, then run this again."
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1
    fi
    # Quoted word by word, so a dump path with a space survives being pasted.
    RESUME_CMD="$(printf '%q' "$ROLLBACK_SCRIPT_COPY") --project-root=$(printf '%q' "$PROJECT_ROOT")"
    if [ "$ASSUME_YES" -eq 1 ]; then
        RESUME_CMD="$RESUME_CMD --yes"
    fi
    RESUME_CMD="$RESUME_CMD $(printf '%q' "$DUMP_FILE")"

    # Whether a previous run was interrupted part-way through moving the code
    # to this same commit. If so, a tree between the two versions is what an
    # interrupted checkout leaves -- git writes the index and the working tree
    # before it updates the branch, so a stale lock on the branch fails the
    # checkout with the files already moved (verified) -- and the state check
    # below would refuse exactly the state this run exists to finish. A marker
    # naming a DIFFERENT commit is a different situation, and not one this
    # script resolves on its own.
    RESUMING=0
    if [ -e "$ROLLBACK_MARKER" ]; then
        MARKER_TARGET="$(sed -n 's/^target: //p' "$ROLLBACK_MARKER" 2>/dev/null | head -n 1)"
        if [ -n "$MARKER_TARGET" ] && [ "$MARKER_TARGET" = "$TARGET_SHA" ]; then
            RESUMING=1
            echo "⚠  A previous rollback to $TARGET_SHA was interrupted while moving the"
            echo "   code. This run finishes that move; the checkout is expected to be"
            echo "   part-way there."
            echo ""
        else
            echo "✗ $ROLLBACK_MARKER records an interrupted rollback to"
            echo "  '${MARKER_TARGET:-an unreadable commit}', but this run would move the code"
            echo "  to $TARGET_SHA. Finish that one first, with the dump it was restoring;"
            echo "  or, once the checkout is clean, remove the marker:"
            echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT status"
            echo "      sudo rm $ROLLBACK_MARKER"
            echo "  Aborting with nothing changed — the database is untouched."
            exit 1
        fi
    fi

    # Whether the tree is in a state the move can start from: no tracked file
    # modified in the superproject or in a submodule, nothing staged, every
    # submodule initialised and at the commit the index pins. Refused rather
    # than preserved or worked around, because the only things this script
    # does to the checkout are `checkout` and `submodule update`, and what
    # those do to local state depends on what the state is. On its pull path
    # update.sh copies modified files aside under
    # $STATE_DIR/local-mods-<timestamp>/ and resets, so a unit arriving from
    # an update usually passes; one updated with --no-pull, or carrying a
    # staged edit whose file matches HEAD (which that inventory does not see),
    # may not, and is told what to clear.
    #
    # Three outcomes from tree_clean, not two: 0 is clean, 1 is dirty and
    # anything else is a read that failed, which is a refusal and not a pass.
    if [ "$RESUMING" -ne 1 ]; then
        TREE_STATUS=0
        tree_clean || TREE_STATUS=$?
        case "$TREE_STATUS" in
            0) ;;
            1)
                echo "✗ The checkout at $PROJECT_ROOT has local changes, and moving the code"
                echo "  would mean deciding what happens to them, which this script does not"
                echo "  do. To see them:"
                echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT status"
                echo "  Commit them, or copy them aside and discard them, then run this again."
                if sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null | grep -q '^+'; then
                    echo "  A submodule is not on the commit the superproject pins, which is what"
                    echo "  an update whose code restore stopped part-way leaves. That is not"
                    echo "  someone's work: put the submodules on their pins and run this again:"
                    echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT submodule update --init --recursive"
                fi
                echo "  (An update that pulled will have saved its own under"
                echo "   $STATE_DIR/local-mods-<timestamp>/ before resetting; check there"
                echo "   before discarding anything.)"
                echo "  Aborting with nothing changed — the database is untouched."
                exit 1 ;;
            *)
                echo "✗ Could not read the state of the checkout at $PROJECT_ROOT (git diff"
                echo "  exited $TREE_STATUS). This says why:"
                echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT status"
                echo "  Aborting with nothing changed — the database is untouched."
                exit 1 ;;
        esac
        # An entry marked assume-unchanged or skip-worktree is invisible to
        # both diffs by design, and a checkout keeps such an entry when the
        # two commits agree on that path -- so a file modified under either
        # bit would survive the move with the restore run over it. Refused,
        # in the superproject and in every submodule; the bits are set only
        # by hand, and clearing them is one command.
        # Two reads, each with its own exit status, and no pipe inside the
        # foreach: a `| sed` there would have reported sed's status and turned
        # a failed listing into an empty one. `submodule foreach` stops on the
        # first non-zero command and exits non-zero itself. The tag is any
        # lowercase letter (assume-unchanged, whatever the base tag) or S.
        if ! FLAGGED_SUPER="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" ls-files -v 2>/dev/null)"; then
            echo "✗ Could not list the index at $PROJECT_ROOT."
            echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT ls-files -v"
            echo "  Aborting with nothing changed — the database is untouched."
            exit 1
        fi
        if ! FLAGGED_SUBS="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule foreach --quiet --recursive 'git ls-files -v' 2>/dev/null)"; then
            echo "✗ Could not list the index of every submodule under $PROJECT_ROOT."
            echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT submodule foreach git ls-files -v"
            echo "  Aborting with nothing changed — the database is untouched."
            exit 1
        fi
        FLAGGED="$(printf '%s\n%s\n' "$FLAGGED_SUPER" "$FLAGGED_SUBS")"
        FLAG_STATUS=0
        printf '%s\n' "$FLAGGED" | grep -q '^[a-zS] ' || FLAG_STATUS=$?
        case "$FLAG_STATUS" in
            0)
                echo "✗ These index entries are marked assume-unchanged (lowercase tag) or"
                echo "  skip-worktree (S), so git does not report changes to them and the move"
                echo "  could carry a modified file across unseen:"
                printf '%s\n' "$FLAGGED" | grep '^[a-zS] ' | sed 's/^/      /'
                echo "  A path with no directory prefix belongs to the superproject; a path"
                echo "  from a submodule is relative to that submodule. Clear the bit in the"
                echo "  repository that owns the file, then run this again:"
                echo "      sudo -u $DTK_USER git -C <that repository> update-index --no-assume-unchanged --no-skip-worktree <file>"
                echo "  Aborting with nothing changed — the database is untouched."
                exit 1 ;;
            1) ;;
            *)
                echo "✗ Could not check the index entries at $PROJECT_ROOT (grep exited $FLAG_STATUS)."
                echo "  Aborting with nothing changed — the database is untouched."
                exit 1 ;;
        esac
        # An uninitialised submodule is not something diff reports -- there is
        # no checkout to compare -- and `submodule update` can be configured
        # to skip one, after which the post-move check in step 3 would find it
        # still uninitialised and stop with the appliance down. Asked here, with
        # the appliance up. The read is kept apart from the grep so a failed
        # read is a refusal and not an empty list.
        if ! SUB_STATUS="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null)"; then
            echo "✗ Could not read the submodule state of $PROJECT_ROOT. This says why:"
            echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT submodule status --recursive"
            echo "  Aborting with nothing changed — the database is untouched."
            exit 1
        fi
        UNINIT_STATUS=1
        if [ -n "$SUB_STATUS" ]; then
            UNINIT_STATUS=0
            printf '%s\n' "$SUB_STATUS" | grep -q '^-' || UNINIT_STATUS=$?
        fi
        if [ "$UNINIT_STATUS" -ne 0 ] && [ "$UNINIT_STATUS" -ne 1 ]; then
            echo "✗ Could not check the submodule state (grep exited $UNINIT_STATUS)."
            echo "  Aborting with nothing changed — the database is untouched."
            exit 1
        fi
        if [ "$UNINIT_STATUS" -eq 0 ]; then
            echo "✗ A submodule is not initialised:"
            printf '%s\n' "$SUB_STATUS" | grep '^-' | sed 's/^/      /'
            echo "  The move would leave it that way and then stop, with the appliance"
            echo "  down, because it is not at the commit the target pins. Initialise it:"
            echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT submodule update --init --recursive"
            echo "  Aborting with nothing changed — the database is untouched."
            exit 1
        fi
    fi

    # scripts/ lives in this repository, so a rollback replaces this script
    # and update.sh along with the application code. The copy on disk
    # afterwards is the target's own, and if the target predates the
    # self-pulling step (NEH-270) that copy does not fetch: it redeploys the
    # commit already checked out and prints "Update complete". An operator
    # reads that as an update. This script is the newer one at the moment it
    # runs, so it is the only thing in a position to say otherwise.
    #
    # Classified structurally rather than by text. The marker is the
    # target's own argument handling -- a `--no-pull)` case arm or a
    # DO_PULL assignment -- which exists only in an implementation that
    # pulls. Searching for "git pull" would match the operator instructions
    # in the header comment of versions that never pull at all.
    #
    # Every step is guarded. The answer is wanted under `set -e`, and failing
    # to reach it is not a reason to refuse the rollback. `git show` exits 128
    # when scripts/update.sh does not exist at that commit, which is a real
    # input on this repository, and a lookup that cannot answer falls through
    # to `unknown`, which prints the conservative recovery in step 3.
    # Three outcomes, not two. A grep that cannot run exits 2, and folding
    # that into "no" would state as a fact that the target does not fetch
    # on the strength of a failed test. 0 is yes, 1 is no, anything else is
    # unknown -- and unknown prints the same recovery as no, so the only
    # thing the distinction costs is a false claim.
    #
    # The markers allow for `export DO_PULL=1` and for a case arm with
    # alternatives (`--offline|--no-pull)`), both of which a line-anchored
    # pattern missed. They are still spelling rather than structure: a
    # `DO_PULL=1` inside a heredoc comment would read as pulling. That is
    # the direction to be wrong in, so the `yes` branch in step 3 carries
    # the recovery too.
    if TARGET_UPDATE_SH="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" show "$TARGET_SHA:scripts/update.sh" 2>/dev/null)"; then
        TARGET_GREP_STATUS=0
        printf '%s\n' "$TARGET_UPDATE_SH" \
            | grep -qE '(^|[[:space:];&|(])DO_PULL=|--no-pull[^)]*\)' \
            || TARGET_GREP_STATUS=$?
        case "$TARGET_GREP_STATUS" in
            0) TARGET_UPDATE_PULLS=yes ;;
            1) TARGET_UPDATE_PULLS=no ;;
            *) TARGET_UPDATE_PULLS=unknown ;;
        esac
    fi
fi

# A record of an unresolved deployment is resolved only by restoring the code
# to the commit it names as the target and the database from the dump it
# names. Anything else would leave it standing over a unit that then runs,
# so it is refused here, with nothing changed.
if [ -e "$UNRESOLVED_FILE" ]; then
    REC_KIND="$(sed -n 's/^kind: //p' "$UNRESOLVED_FILE" 2>/dev/null | head -n 1)"
    if [ "$REC_KIND" = restore-failed ]; then
        REC_TARGET="$(sed -n 's/^code-commit: //p' "$UNRESOLVED_FILE" 2>/dev/null | head -n 1)"
        REC_DUMP="$(sed -n 's/^dump-to-restore: //p' "$UNRESOLVED_FILE" 2>/dev/null | head -n 1)"
    else
        REC_TARGET="$(sed -n 's/^restore-target: //p' "$UNRESOLVED_FILE" 2>/dev/null | head -n 1)"
        REC_DUMP="$(sed -n 's/^dump: //p' "$UNRESOLVED_FILE" 2>/dev/null | head -n 1)"
    fi
    REC_TARGET_FULL="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" rev-parse --verify --quiet "${REC_TARGET:-none}^{commit}" 2>/dev/null || true)"
    if [ -z "$TARGET_SHA" ] || [ -z "$REC_TARGET_FULL" ] || [ "$TARGET_SHA" != "$REC_TARGET_FULL" ]; then
        echo "✗ $UNRESOLVED_FILE records an unresolved update whose code has to"
        echo "  return to ${REC_TARGET:-(not recorded)}, but this rollback would return it to"
        echo "  ${TARGET_SHA:-nothing (no commit is recorded in $SHA_FILE)}."
        echo "  Restoring the database without the matching code would leave the two"
        echo "  disagreeing. Aborting with nothing changed — the database is untouched."
        exit 1
    fi
    if [ -z "$REC_DUMP" ] || ! [ "$DUMP_FILE" -ef "$REC_DUMP" ]; then
        echo "✗ $UNRESOLVED_FILE names the backup to restore:"
        echo "      ${REC_DUMP:-(not recorded)}"
        echo "  and this run would restore $DUMP_FILE. Run this again with that one."
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1
    fi
fi

echo "This will:"
echo "  • RESTORE the database from:"
echo "      $DUMP_FILE   (${DUMP_BYTES} bytes)"
echo "    ⚠  This DISCARDS anything saved since that backup was taken."
if [ -n "$TARGET_SHA" ]; then
    echo "  • Return the code to commit: $TARGET_SHA"
else
    echo "  • (No pre-update commit recorded — code will be left as-is.)"
fi
echo "  • Restart the appliance."
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo "✗ No terminal to confirm on, and --yes was not given. Aborting."
        exit 1
    fi
    printf "Proceed with rollback? [y/N] "
    read -r reply
    case "$reply" in
        y|Y|yes|YES) echo "" ;;
        *) echo ""; echo "Aborted by operator. Nothing changed."; exit 1 ;;
    esac
fi

# ---------------------------------------------------------------------------
# 2. Stop the appliance.
# ---------------------------------------------------------------------------
echo "→ Stopping the appliance..."
systemctl stop dtk 2>/dev/null || true
$COMPOSE down --remove-orphans >/dev/null 2>&1 || true
# The database is about to be replaced: nothing may still be writing to it.
if ! wait_backend_stopped; then
    echo "✗ The backend did not stop (systemctl status dtk; pgrep -af uvicorn)."
    echo "  Nothing has been restored; the code and the database are as they were."
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Return the code to the pre-update commit (pins respected — no --remote).
#
#    Before the database, so a failure here leaves the database as it was and
#    the backup unopened. What this step does NOT do is put the code back
#    where it was. Two designs that did -- one predicting the move, one undoing
#    it -- each failed review on inputs where git's idea of "back" and the
#    script's disagreed: a staged gitlink, an off-pin submodule, a lock taken
#    after the files had moved, a commit that was local but no longer
#    ref-reachable. 1b accepts only a clean tree on its pins, and from there
#    the move either completes or stops with the target still local, the dump
#    still on disk, a marker saying which move was interrupted and a copy of
#    this script outside the tree to finish it with.
# ---------------------------------------------------------------------------
CODE_ROLLED_BACK=0
ROLLBACK_BACKUP_CREATED=""

# Where the unit was when this run started: the branch, so it is the branch
# that moves rather than a detached HEAD; the commit, so it is kept under a
# name before the branch leaves it. Read from the repository, once, before
# anything changes.
PREV_BRANCH="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
PREV_SUPER="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"

# Did the tree move at all? Asked of the repository -- HEAD, index, working
# tree and submodule heads together -- and never of a command's exit status: a
# checkout that fails on the branch lock has already written the index and
# the files (verified), and a post-checkout hook that fails runs after the refs
# moved. Meaningful only when the run started from a clean tree, which 1b
# required unless it is resuming; on a resume the answer is always "it did".
code_never_moved() {
    [ "$RESUMING" -ne 1 ] || return 1
    [ -n "$PREV_SUPER" ] || return 1
    [ "$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" = "$PREV_SUPER" ] || return 1
    tree_clean || return 1
    return 0
}

# The move failed. Nothing has been restored and nothing is put back: say
# where things stand and how to finish. The appliance is started only when the
# repository says nothing moved; otherwise what it would run is not known, and
# a stopped unit is the one state an operator can be told about accurately.
stop_before_restore() {
    echo ""
    echo "✗ The code could not be moved to $TARGET_SHA: $1"
    echo ""
    echo "  Nothing has been restored. The database was never opened and the"
    echo "  backup is intact at:"
    echo "      $DUMP_FILE"
    if [ -n "$ROLLBACK_BACKUP_CREATED" ]; then
        echo "  The version this unit was running is kept as branch"
        echo "  '$ROLLBACK_BACKUP_CREATED' ($PREV_SUPER)."
    fi
    echo ""
    if code_never_moved; then
        echo "  The code never moved: the unit is still on $PREV_SUPER."
        rm -f "$ROLLBACK_MARKER"
        echo "→ Starting the appliance..."
        systemctl start dtk || true
        sleep 5
        if systemctl is-active --quiet dtk; then
            echo "  ✓ Running the version it was running before this script started."
        else
            echo "  ⚠ The appliance did not come back up, although nothing was"
            echo "    rolled back. Check:  journalctl -u dtk -n 50"
        fi
        echo ""
        echo "  Clear what is named above and run this script again."
        exit 1
    fi
    echo "  The code is part-way between versions, so the appliance has NOT been"
    echo "  started. To see where it is:"
    echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT status"
    echo "  Clear what is named above, then finish the rollback. This command"
    echo "  knows a move to $TARGET_SHA was interrupted and continues it:"
    echo "      sudo $RESUME_CMD"
    echo "  ($ROLLBACK_SCRIPT_COPY is a copy of this script kept outside the"
    echo "   checkout; the checkout's own copy may now be the target's.)"
    exit 1
}

if [ -n "$TARGET_SHA" ]; then
    echo "→ Returning code to commit $TARGET_SHA ..."
    # Which branch the unit is on, and the commit it is at, were read above,
    # before anything changed. A plain
    # `git checkout <sha>` detaches HEAD, and the documented update then
    # refuses to run at all ("You are not currently on a branch") — so taking
    # the recovery path blocked the upgrade path until someone knew to check
    # out dev by hand (NEH-273). `checkout -B` moves the branch to the target
    # and stays on it, which keeps the next `git pull --ff-only` working: the
    # target is an ancestor of the remote tip in the case that matters, a
    # rollback to the previously deployed commit.
    #
    # Run git as the repo owner (dubious-ownership under sudo) WITH the
    # owner's HOME, so the appliance's global insteadOf rewrite (NEH-217)
    # applies to the SSH submodule URLs .gitmodules registers.
    if [ -n "$PREV_BRANCH" ]; then
        # Moving the branch discards its old tip, and if that tip is an
        # unpushed field hotfix the branch was the only reference naming
        # it — verified: after `checkout -B`, no ref points at it and only
        # the reflog holds it, until that expires. Leave a real ref behind
        # first, so the commit is recoverable by name.
        if [ "$RESUMING" -ne 1 ] && [ -n "$PREV_SUPER" ] && [ "$PREV_SUPER" != "$TARGET_SHA" ]; then
            ROLLBACK_BACKUP_REF="pre-rollback/$(date +%Y%m%d-%H%M%S)"
            # Recorded as created only once it exists: the failure handler
            # tells the operator the old version is kept there, and that has
            # to be true when it says it.
            if sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" branch "$ROLLBACK_BACKUP_REF" "$PREV_SUPER" 2>/dev/null; then
                echo "  Previous tip kept as branch '$ROLLBACK_BACKUP_REF' ($PREV_SUPER)."
                ROLLBACK_BACKUP_CREATED="$ROLLBACK_BACKUP_REF"
            else
                echo "  ⚠ Could not record the previous tip as a branch. It was"
                echo "    $PREV_SUPER — note it down before the reflog expires"
                echo "    if this unit had commits that were never pushed."
            fi
        fi
    fi
    # From here the tree changes. Record that first, so a run interrupted
    # anywhere below is recognised by the next one (1b reads this), and stop
    # if the record cannot be written: without it an interrupted move would be
    # refused as a dirty tree, with no way through but by hand. Nothing has
    # moved yet, so the stop restarts the appliance.
    # Written to a temporary name and renamed, so an interruption leaves
    # either the old marker or the new one and never a truncated file that
    # every later run would refuse. Not rewritten on a resume: the marker
    # that got us here is the record, and rewriting it is the one way to
    # lose it.
    if [ "$RESUMING" -ne 1 ]; then
        if ! printf 'target: %s\nproject-root: %s\ndump: %s\nstarted: %s\n' \
                "$TARGET_SHA" "$PROJECT_ROOT" "$DUMP_FILE" "$(date +%Y%m%d-%H%M%S)" \
                > "$ROLLBACK_MARKER.tmp" 2>/dev/null \
                || ! mv -f "$ROLLBACK_MARKER.tmp" "$ROLLBACK_MARKER" 2>/dev/null; then
            rm -f "$ROLLBACK_MARKER.tmp" 2>/dev/null || true
            stop_before_restore "could not write $ROLLBACK_MARKER"
        fi
    fi
    if [ -n "$PREV_BRANCH" ]; then
        sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" checkout --no-overwrite-ignore -B "$PREV_BRANCH" "$TARGET_SHA" \
            || stop_before_restore "the checkout to $TARGET_SHA failed"
    else
        # Already detached before we started — there is no branch to
        # preserve, so say so rather than inventing one.
        echo "  ⚠ This repository was already on a detached HEAD, so the"
        echo "    rollback leaves it detached. Before the next update, run:"
        echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT checkout dev"
        sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" checkout --no-overwrite-ignore "$TARGET_SHA" \
            || stop_before_restore "the checkout to $TARGET_SHA failed"
    fi
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule update --init --recursive \
        || stop_before_restore "the submodules could not be synced"

    # Verified, not inferred from the exit statuses above. Three reads, each
    # with one side already known, so a read that fails fails the check rather
    # than producing an empty string that equals another empty string -- which
    # is what the previous comparison did when both of its pipelines reported
    # `sort`'s exit status instead of git's. HEAD at the target; index
    # matching HEAD and working tree matching index, which with HEAD at the
    # target means the index's gitlinks are the target's; and every submodule
    # checked out at its index pin, which `submodule status` marks with a
    # leading space (and with +, - or U when it is ahead, uninitialised or
    # conflicted).
    NOW_HEAD="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if [ "$NOW_HEAD" != "$TARGET_SHA" ]; then
        stop_before_restore "HEAD is at '${NOW_HEAD:-unreadable}' and not at $TARGET_SHA"
    fi
    TREE_STATUS=0
    tree_clean || TREE_STATUS=$?
    if [ "$TREE_STATUS" -ne 0 ]; then
        stop_before_restore "the files do not match $TARGET_SHA after the checkout (git diff exited $TREE_STATUS)"
    fi
    if ! SUB_STATUS="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null)"; then
        stop_before_restore "the submodule state could not be read after the move"
    fi
    OFFPIN_STATUS=1
    if [ -n "$SUB_STATUS" ]; then
        OFFPIN_STATUS=0
        printf '%s\n' "$SUB_STATUS" | grep -qv '^ ' || OFFPIN_STATUS=$?
    fi
    if [ "$OFFPIN_STATUS" -ne 0 ] && [ "$OFFPIN_STATUS" -ne 1 ]; then
        stop_before_restore "the submodule state could not be checked after the move (grep exited $OFFPIN_STATUS)"
    fi
    if [ "$OFFPIN_STATUS" -eq 0 ]; then
        echo "  Submodules not at the commits $TARGET_SHA pins:"
        printf '%s\n' "$SUB_STATUS" | grep -v '^ ' | sed 's/^/      /'
        stop_before_restore "a submodule is not at the commit $TARGET_SHA pins"
    fi
    rm -f "$ROLLBACK_MARKER"

    CODE_ROLLED_BACK=1
    echo "  ✓ Code restored to the pre-update version."
    if [ "$TARGET_UPDATE_PULLS" = yes ]; then
        if [ -n "$PREV_BRANCH" ]; then
            echo "    Branch '$PREV_BRANCH' now points at it, so the next update can run."
            echo "    If that update reports no change, this version's update.sh did not"
            echo "    fetch after all; run these two and deploy again:"
            echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT pull --ff-only"
            echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT submodule update --init --recursive"
        fi
    else
        if [ "$TARGET_UPDATE_PULLS" = no ]; then
            echo "  ⚠ scripts/ was rolled back with everything else, and this version's"
            echo "    update.sh does not fetch. Running it would redeploy the commit"
            echo "    already checked out and report 'Update complete'."
        else
            echo "  ⚠ scripts/ was rolled back with everything else, and this version's"
            echo "    update.sh could not be read, so whether it fetches is unknown."
            echo "    It may redeploy the commit already checked out and report success."
        fi
        echo "    To return to the current version, run these two first:"
        echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT pull --ff-only"
        echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT submodule update --init --recursive"
        echo "    and then deploy with scripts/update.sh."
    fi
    # The code is now the rolled-back version, so the deploy record has
    # to say so. Leaving it naming the commit we rolled AWAY from made
    # the next update log a false "previously-deployed" and made its
    # offline-safety check compare a commit against itself (NEH-272).
    # Only inside this branch: with no commit recorded the code is not
    # rolled back at all, the new code is still deployed, and the existing
    # record is already correct.
    if printf '%s\n' "$TARGET_SHA" > "$LAST_DEPLOYED_SHA_FILE" 2>/dev/null; then
        echo "    Deploy record updated: $TARGET_SHA"
    else
        echo "  ⚠ Could not update $LAST_DEPLOYED_SHA_FILE — it still names the"
        echo "    version that was rolled back. The next update will report the"
        echo "    wrong previous version; the rollback itself was fine."
    fi
    # last-deployed-frontend is deliberately left alone. Its only reader
    # (update.sh's previous_frontend_image) accepts it only when its
    # "sha:" matches the deploy record, so rewriting that record above
    # already makes a now-unrelated image read as nothing. Deleting it
    # would discard a record that becomes correct again the moment that
    # commit is redeployed.
    echo ""
fi
# ---------------------------------------------------------------------------
# 4. Restore the database.
#    The irreversible step, and deliberately the last one that can fail. The
#    code is already where it belongs, so a failure here leaves a retryable
#    state rather than a mismatch nobody can undo: the dump is untouched and
#    re-running this script redoes the (idempotent) code move and tries the
#    restore again.
#
#    Start only the db container, wait for it, drop & recreate the database so
#    the restore lands in a clean state, then load the dump.
# ---------------------------------------------------------------------------
echo "→ Starting the database container..."
$COMPOSE up -d db

echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if $COMPOSE exec -T db pg_isready -U "$DATABASE_USER" -d "$DATABASE_NAME" >/dev/null 2>&1; then
        echo "  Database ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "✗ Database did not become ready after 60s. Aborting."
        echo "  The dump at $DUMP_FILE is intact."
        if [ "$CODE_ROLLED_BACK" -eq 1 ]; then
            echo "  The code is already on $TARGET_SHA, so running this again retries"
            echo "  just the restore:"
        else
            echo "  The code was not changed, so running this again retries the restore:"
        fi
        echo "      sudo $RESUME_CMD"
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
        exit 1
    fi
    sleep 2
done

if ! backend_fully_stopped; then
    echo "✗ A backend is running again; the database was NOT dropped."
    echo "  The dump at $DUMP_FILE is intact. Stop dtk and run this again:"
    echo "      sudo $RESUME_CMD"
    $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    exit 1
fi
echo "→ Restoring the database (dropping and recreating '$DATABASE_NAME')..."
# Terminate other sessions, then drop/recreate via the maintenance 'postgres'
# database so we are not connected to the DB we are dropping.
$COMPOSE exec -T db psql -U "$DATABASE_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DATABASE_NAME' AND pid <> pg_backend_pid();" \
    >/dev/null
$COMPOSE exec -T db psql -U "$DATABASE_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$DATABASE_NAME\";" \
    -c "CREATE DATABASE \"$DATABASE_NAME\" OWNER \"$DATABASE_USER\";" \
    >/dev/null

set -o pipefail
if ! gunzip -c "$DUMP_FILE" | $COMPOSE exec -T db psql -U "$DATABASE_USER" -d "$DATABASE_NAME" -v ON_ERROR_STOP=1 >/dev/null; then
    set +o pipefail
    echo "✗ Restore FAILED while loading the dump."
    echo "  The database may be in a partial state. The dump file itself is"
    echo "  intact at: $DUMP_FILE"
    if [ "$CODE_ROLLED_BACK" -eq 1 ]; then
        echo "  The code IS already on $TARGET_SHA, so running this again retries"
        echo "  the restore from the same backup:"
    else
        echo "  The code was not changed, so running this again retries the restore"
        echo "  from the same backup:"
    fi
    echo "      sudo $RESUME_CMD"
    echo "  Do NOT start the service until this is resolved. Get technical help."
    $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    exit 1
fi
set +o pipefail
echo "  ✓ Database restored from backup."
echo ""

echo "→ Stopping the database container..."
$COMPOSE down --remove-orphans
echo ""

# ---------------------------------------------------------------------------
# 4b. Put back the frontend image recorded for the restored version.
#     update.sh records, in the state file pre-update-ref names, the image that
#     was serving when the previous version was deployed
#     (previously-deployed-frontend-image), and keeps it under a
#     pre-update-<timestamp> tag so the rebuild cannot let it be pruned. The
#     record is used only when it is unambiguous (STATE_RECORD, below) and the
#     image is still on this unit; otherwise the image is left as it is and
#     the summary says it does not correspond.
# ---------------------------------------------------------------------------
file_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    else
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    fi
}
# Image the compose tag points at NOW, which is what the stack starts from.
# Read the RUNNING container's image, exactly as update.sh records it. The
# tag is not the same question: update.sh rebuilds the tag before it stops
# anything, so a tag can point at an image no container is serving. With no
# container running - the service did not come back up - this returns empty
# and the summary says UNKNOWN rather than comparing against a tag.
frontend_image_id() {
    local cid
    cid="$($COMPOSE ps -q frontend 2>/dev/null | head -n 1)" || return 1
    [ -n "$cid" ] || return 1
    docker container inspect --format '{{.Image}}' "$cid" 2>/dev/null
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

# state_field <key> <file>: value of "key: value", empty if absent/unreadable.
state_field() {
    sed -n "s/^$1: //p" "$2" 2>/dev/null | head -n 1
}

# frontend_rebuilt_detail <installed-sha> <target-sha>: why the running
# frontend image is not the one recorded for <target-sha>. <installed-sha> is
# the commit the update recorded as installing (installing-superproject), which
# is the code its frontend build ran on. When an update re-installed the commit
# that was already deployed, the rollback returns to that same commit, and
# "the newer code" would be false.
frontend_rebuilt_detail() {
    if [ -z "$1" ] || [ "$1" = "unknown" ]; then
        echo "the running frontend image is not the one recorded when $2 was deployed"
    elif [ "$1" = "$2" ]; then
        echo "the frontend image was rebuilt from the same commit, $2, after it was deployed"
    else
        echo "the frontend image was rebuilt from the newer code ($1)"
    fi
}

# Which record describes the dump just restored? update.sh writes
# pre-update-ref (state file name + dump name) in the same step as the dump,
# so the record is identified by the attempt, not by the commit: several
# records can share one previously-deployed value (an update that aborts
# before the dump writes a record and advances nothing). Anything short of an
# unambiguous match leaves STATE_RECORD empty and the result UNKNOWN.
STATE_RECORD=""
ENV_NOTE=""
if [ "$CODE_ROLLED_BACK" -ne 1 ]; then
    ENV_NOTE="the code was not rolled back, so it is not known what this component corresponds to"
elif [ -h "$REF_FILE" ] || [ ! -r "$REF_FILE" ]; then
    ENV_NOTE="no pre-update-ref links a state record to this dump"
else
    REF_STATE="$(state_field state "$REF_FILE")"
    REF_DUMP="$(state_field dump "$REF_FILE")"
    CAND="$BACKUP_DIR/$REF_STATE"
    if [ -z "$REF_STATE" ] || [ -z "$REF_DUMP" ]; then
        ENV_NOTE="pre-update-ref is unreadable or incomplete"
    elif [ "$REF_DUMP" != "$(basename "$REF_DUMP")" ] || [ "$DUMP_FILE" != "$BACKUP_DIR/$REF_DUMP" ] \
         || [ -h "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
        # Identity, not basename: a same-named dump from another directory
        # (a USB stick) has other contents.
        # Spelling is not identity: a symlink sitting at exactly the expected
        # name matches the comparison while gunzip reads something else
        # entirely. The restore itself is the operator's call; certifying what
        # the restored data corresponds to is not.
        ENV_NOTE="the dump restored is not the backup $REF_DUMP that pre-update-ref names in $BACKUP_DIR"
    elif [ "$REF_STATE" != "$(basename "$REF_STATE")" ] || [ -h "$CAND" ] || [ ! -f "$CAND" ] || [ ! -r "$CAND" ]; then
        ENV_NOTE="the state record named by pre-update-ref is missing, a symlink, unreadable or already pruned"
    elif [ "$(state_field previously-deployed "$CAND")" != "$TARGET_SHA" ]; then
        ENV_NOTE="the state record does not name $TARGET_SHA as the previous version"
    else
        STATE_RECORD="$CAND"
    fi
fi

if [ -n "$STATE_RECORD" ]; then
    REC_IMG_PRE="$(state_field previously-deployed-frontend-image "$STATE_RECORD")"
    FRONTEND_NAME="$(frontend_image_name || true)"
    FRONTEND_WHY=""
    if [ -z "$REC_IMG_PRE" ]; then
        FRONTEND_WHY="no image was recorded when $TARGET_SHA was deployed"
    elif [ -z "$FRONTEND_NAME" ]; then
        FRONTEND_WHY="Compose did not give the frontend image's name"
    elif ! docker image inspect "$REC_IMG_PRE" >/dev/null 2>&1; then
        FRONTEND_WHY="the recorded image $REC_IMG_PRE is no longer on this unit"
    elif ! docker tag "$REC_IMG_PRE" "$FRONTEND_NAME" >/dev/null 2>&1; then
        FRONTEND_WHY="docker tag $REC_IMG_PRE $FRONTEND_NAME failed"
    fi
    if [ -z "$FRONTEND_WHY" ]; then
        echo "→ Frontend image put back: $FRONTEND_NAME is $REC_IMG_PRE, the image"
        echo "  recorded when $TARGET_SHA was deployed."
    else
        echo "⚠⚠ THE FRONTEND IMAGE WAS NOT PUT BACK: $FRONTEND_WHY."
        echo "   The restored version will run with the frontend image that is tagged"
        echo "   now; the summary below says whether that corresponds."
    fi
    echo ""
fi

# Code and database are both back (with a record, on the commit and from the
# dump it names: checked before anything changed). The record and the flag
# go before the start, which the flag would otherwise block.
RECORD_NOTE=""
if [ "$CODE_ROLLED_BACK" -eq 1 ]; then
    if [ -e "$UNRESOLVED_FILE" ]; then
        if rm -f "$UNRESOLVED_FILE"; then
            RECORD_NOTE="$UNRESOLVED_FILE removed; update.sh will run again"
        else
            RECORD_NOTE="⚠ could not remove $UNRESOLVED_FILE; update.sh still refuses"
        fi
    fi
    rm -f "$UNRESOLVED_FLAG" 2>/dev/null || true
elif [ -e "$UNRESOLVED_FILE" ]; then
    RECORD_NOTE="$UNRESOLVED_FILE kept: the code was not rolled back"
fi
if [ -e "$UNRESOLVED_FILE" ] || [ -e "$UNRESOLVED_FLAG" ]; then
    echo "✗ An unresolved-deployment record or flag remains, so the appliance is"
    echo "  NOT started. ${RECORD_NOTE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Restart the service.
# ---------------------------------------------------------------------------
echo "→ Starting the appliance..."
systemctl start dtk
sleep 5
SERVICE_OK=0
if systemctl is-active --quiet dtk; then
    SERVICE_OK=1
fi

# ---------------------------------------------------------------------------
# What does NOT correspond to the restored version?
#    Steps 3-4 restore the git checkout and the database; 4b retags the
#    frontend image when the record allows. The pixi environment was rebuilt
#    by update.sh for the NEW code and is not rebuilt here (that needs the
#    registries, and rollback is when a remote unit may be offline). Read what
#    update.sh recorded and say, per component, whether it still matches — or
#    that we cannot tell.
# ---------------------------------------------------------------------------
# Pixi environment. The lock digest says what the update installed against,
# not what is installed now: start.sh runs "pixi run start", which can
# reinstall for the restored lock before the summary prints.
PIXI_STATUS="unknown"
PIXI_DETAIL="$ENV_NOTE"
PIXI_FIX="cd $PROJECT_ROOT/backend && pixi install --locked   (needs the conda registry)"
if [ -n "$STATE_RECORD" ]; then
    REC_LOCK="$(state_field installing-pixi-lock-sha256 "$STATE_RECORD")"
    NOW_LOCK="$(file_digest "$PROJECT_ROOT/backend/pixi.lock" || true)"
    if [ -z "$REC_LOCK" ] || [ -z "$NOW_LOCK" ]; then
        PIXI_DETAIL="the lock digest is missing from the record or from the checkout"
    elif [ "$REC_LOCK" = "$NOW_LOCK" ]; then
        PIXI_STATUS="corresponds"
        PIXI_DETAIL="backend/pixi.lock is identical in both versions"
    else
        PIXI_STATUS="lockdiffers"
        PIXI_DETAIL="backend/pixi.lock differs from the one the update installed. The environment may still be the newer one, or may already have been reinstalled for the restored lock when the service started; this script does not check which"
    fi
fi

# Frontend image.
IMG_STATUS="unknown"
IMG_DETAIL="$ENV_NOTE"
IMG_FIX="cd $PROJECT_ROOT && docker compose -f docker-compose.yml -f docker-compose.pi.yml build frontend && sudo systemctl restart dtk   (needs the npm registry)"
if [ -n "$STATE_RECORD" ]; then
    # The image that was serving when $TARGET_SHA was successfully deployed;
    # empty when no such record existed (older unit, or the write failed).
    REC_IMG="$(state_field previously-deployed-frontend-image "$STATE_RECORD")"
    NOW_IMG="$(frontend_image_id || true)"
    if [ -z "$REC_IMG" ]; then
        IMG_DETAIL="no record of which image was serving when $TARGET_SHA was deployed"
    elif [ -z "$NOW_IMG" ]; then
        IMG_DETAIL="the running frontend container's image could not be read"
    elif [ "$REC_IMG" = "$NOW_IMG" ]; then
        IMG_STATUS="corresponds"
        IMG_DETAIL="the running frontend image is the one recorded when $TARGET_SHA was deployed"
    else
        IMG_STATUS="differs"
        IMG_DETAIL="$(frontend_rebuilt_detail "$(state_field installing-superproject "$STATE_RECORD")" "$TARGET_SHA")"
    fi
fi

# Print one component line: <label> <status> <detail> <fix>
report_component() {
    case "$2" in
        corresponds) printf '  %-10s corresponds to the restored version (%s)\n' "$1" "$3" ;;
        differs)
            printf '  %-10s does NOT correspond: %s.\n' "$1" "$3"
            echo "      To fix: $4" ;;
        lockdiffers)
            printf '  %-10s NOT CONFIRMED: %s.\n' "$1" "$3"
            echo "      To make sure: $4" ;;
        *)
            printf '  %-10s UNKNOWN: %s.\n' "$1" "$3"
            echo "      Cannot confirm it matches the restored version. If in doubt: $4" ;;
    esac
}

# ---------------------------------------------------------------------------
# What happened
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " Rollback summary"
echo "=========================================="
echo "  Database:  RESTORED from $DUMP_FILE"
# With a commit recorded, step 3 either moved the code or exited: there is no
# third state to report here.
if [ "$CODE_ROLLED_BACK" -eq 1 ]; then
    echo "  Code:      restored to $TARGET_SHA"
else
    echo "  Code:      NOT changed (no pre-update commit was recorded)"
fi
report_component "Pixi env:" "$PIXI_STATUS" "$PIXI_DETAIL" "$PIXI_FIX"
report_component "Frontend:" "$IMG_STATUS" "$IMG_DETAIL" "$IMG_FIX"
if [ -n "$RECORD_NOTE" ]; then
    echo "  Record:    $RECORD_NOTE"
fi
if [ "$SERVICE_OK" -eq 1 ]; then
    echo "  Service:   running ✓"
    echo ""
    if [ "$CODE_ROLLED_BACK" -ne 1 ]; then
        echo "  The database was restored but the code was not changed, so the"
        echo "  appliance is NOT confirmed to be on the previous version."
    elif [ "$PIXI_STATUS" != "corresponds" ] || [ "$IMG_STATUS" != "corresponds" ]; then
        echo "  The database and code are back on the previous version. The"
        echo "  appliance may still be running parts of the newer version (see"
        echo "  the lines above); it is not confirmed fully rolled back."
    else
        echo "  The database, code, pixi environment and frontend image all"
        echo "  correspond to the previous version."
    fi
else
    echo "  Service:   ✗ did NOT come back up"
    echo ""
    echo "  Check logs:  journalctl -u dtk -n 50"
fi
echo ""
