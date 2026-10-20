#!/bin/bash
# Roll back a Digitization Toolkit update: restore the pre-update database
# snapshot and return the code to the commit it was on before the update.
#
# This is the companion to scripts/update.sh. update.sh writes, before it
# migrates:
#   • a gzipped SQL dump  →  /var/lib/dtk/backups/pre-update-YYYYmmdd-HHMMSS.sql.gz
#   • the pre-update commit  →  /var/lib/dtk/backups/pre-update-SHA
#
# What this script does, loudly, for possibly non-technical venue staff:
#   1. Checks the few things that can be checked without doing anything: who
#      git runs as, that the checkout is readable as that user, and that the
#      pre-update commit is present. Any of those failing stops it here, with
#      the appliance still running and the database untouched.
#   2. Stops the appliance.
#   3. Checks out the pre-update superproject commit and syncs submodules to
#      the pins that commit records (no --remote — pins are respected). This
#      comes BEFORE the database, because it is the half that can be undone:
#      if any of it fails, the code goes back, the appliance restarts, and
#      nothing was rolled back.
#   4. Restores the newest (or a named) database dump into PostgreSQL,
#      REPLACING the current database contents. The irreversible step, and the
#      last one that can fail — by which point the code is already right, so a
#      failure here is retryable from the same backup.
#   5. Restarts the service and reports what happened, component by component:
#      the database and the code are restored; the pixi environment and the
#      frontend image are NOT rebuilt (that needs the registries), so the
#      summary says whether each still corresponds to the restored version,
#      using the pre-update-state-* record update.sh writes (NEH-218).
#
# Usage:
#   sudo ./scripts/rollback-update.sh                       # newest dump
#   sudo ./scripts/rollback-update.sh <dump-file.sql.gz>    # a specific dump
#   sudo ./scripts/rollback-update.sh --yes                 # skip confirmation
#
# WARNING: restoring a dump DISCARDS any data written since that dump was taken.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BACKUP_DIR="/var/lib/dtk/backups"
SHA_FILE="$BACKUP_DIR/pre-update-SHA"
REF_FILE="$BACKUP_DIR/pre-update-ref"
# What the unit believes is deployed. update.sh writes it on success; this
# script has to correct it when it takes the code back, or the unit reports a
# version it is no longer running (NEH-272).
LAST_DEPLOYED_SHA_FILE="$BACKUP_DIR/last-deployed-SHA"

ASSUME_YES=0
DUMP_ARG=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help)
            echo "Usage: sudo ./scripts/rollback-update.sh [--yes] [<dump-file.sql.gz>]"
            exit 0 ;;
        -*)
            echo "✗ Unknown option: $arg"
            echo "Usage: sudo ./scripts/rollback-update.sh [--yes] [<dump-file.sql.gz>]"
            exit 2 ;;
        *)
            if [ -n "$DUMP_ARG" ]; then
                echo "✗ Too many arguments: got both '$DUMP_ARG' and '$arg'."
                echo "  Name at most one dump file."
                echo "Usage: sudo ./scripts/rollback-update.sh [--yes] [<dump-file.sql.gz>]"
                exit 2
            fi
            DUMP_ARG="$arg" ;;
    esac
done

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
# 1b. The four questions the code rollback depends on that can be answered
#     without doing anything: who git runs as, whether git can read the
#     checkout as that user, whether the recorded commit is present, and what
#     the target's own update.sh does.
#
#     Deliberately only those four. An earlier version of this block also tried
#     to predict whether the checkout would succeed -- a read-tree dry run, an
#     enumeration of the target's submodule pins, a ref pinning the target. Two
#     adversarial rounds kept finding inputs where the prediction and the act
#     diverged: a staged gitlink the dry run preserves and the check never sees,
#     a stale lock on refs/heads/<branch> that read-tree does not need and
#     `checkout -B` does, a stale index lock inside a submodule, a commit that
#     is present locally but not ref-reachable so `submodule update` fetches it
#     anyway. Predicting what git will do across four repositories is not
#     something a shell script finishes doing.
#
#     So the order changed instead, and the prediction went away with it. The
#     code moves BEFORE the database is restored, because a code move can be
#     undone and a restore cannot. Step 3 tries the thing and puts it back if it
#     fails; step 4 does the irreversible work once the code is already where it
#     belongs. Verified offline, with both remotes removed: moving the
#     superproject and its submodule to the target and back again restores the
#     commits, the branch and a clean worktree exactly.
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
    # in step 4 the same way, so it is named here instead of surfacing later
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
    if ! sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" \
            git -C "$PROJECT_ROOT" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null; then
        echo "✗ Recorded commit $TARGET_SHA is not present in $PROJECT_ROOT."
        echo "  The backup was taken at that commit, so restoring it under the"
        echo "  code now checked out would leave the two disagreeing and the"
        echo "  backend refusing to start."
        echo "  Fetch it and run this script again:"
        echo "      sudo -u $DTK_USER git -C $PROJECT_ROOT fetch --all"
        echo "  Aborting with nothing changed — the database is untouched."
        exit 1
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
    # to `unknown`, which prints the conservative recovery in step 4.
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
    # the direction to be wrong in, so the `yes` branch in step 4 carries
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
echo ""

# ---------------------------------------------------------------------------
# 3. Return the code to the pre-update commit (pins respected — no --remote).
#
#    Before the database, and that order is the whole design. A code move can
#    be undone; a restore cannot. So this step tries the thing rather than
#    predicting it, and every way it can fail -- a lock in any of the four
#    repositories, a staged gitlink, a submodule commit git decides to fetch
#    and cannot reach offline -- ends in abort_before_restore: put the code
#    back, start the appliance, say nothing was rolled back. The database is
#    never opened on that path, so the unit is the unit it was.
# ---------------------------------------------------------------------------
CODE_ROLLED_BACK=0
ROLLBACK_BACKUP_CREATED=""

# Where to return to if the move fails, read from the repository rather than
# assumed. The submodule commits are recorded too, because `submodule update`
# moves those and a unit whose submodule sat off its pin should not be quietly
# corrected by a rollback that failed.
PREV_BRANCH="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
PREV_SUPER="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
# Kept separate from the sed, because a pipeline reports the sed's status and
# an unreadable submodule state would otherwise look like "no submodules" --
# which the undo would then read as a successful comparison against nothing.
PREV_SUBMODULES=""
PREV_SUBMODULES_KNOWN=0
if PREV_SUBMODULES_RAW="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null)"; then
    PREV_SUBMODULES="$(printf '%s\n' "$PREV_SUBMODULES_RAW" | sed 's/^[+-U]//')"
    PREV_SUBMODULES_KNOWN=1
fi

# Is the unit on the commits it was on when this script started? Asked of the
# repository, never inferred from a command's exit status: a post-checkout hook
# that fails runs after git has already moved the refs, so a failed checkout
# does not mean the checkout did not happen.
code_is_where_it_started() {
    [ -n "$PREV_SUPER" ] || return 1
    [ "$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null)" = "$PREV_SUPER" ] || return 1
    if [ "$PREV_SUBMODULES_KNOWN" = 1 ]; then
        NOW_SUBMODULES_RAW="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule status --recursive 2>/dev/null)" || return 1
        [ "$(printf '%s\n' "$NOW_SUBMODULES_RAW" | sed 's/^[+-U]//')" = "$PREV_SUBMODULES" ] \
            || return 1
    fi
    return 0
}

# Put the code back exactly where it was. 0 if it is, 1 if it is not and
# somebody has to look. Verified offline, with both remotes removed: moving the
# superproject and its submodule to the target and back restores the commits,
# the branch and a clean worktree.
undo_code_move() {
    [ -n "$PREV_SUPER" ] || return 1
    # Nothing to undo if nothing moved, and checked first because the commonest
    # reason the move failed -- a lock git could not take -- is also a reason
    # the undo's own checkout would fail. Reporting "could not be put back" for
    # a unit that never left would be both wrong and frightening.
    code_is_where_it_started && return 0
    if [ -n "$PREV_BRANCH" ]; then
        sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" checkout -B "$PREV_BRANCH" "$PREV_SUPER" >/dev/null 2>&1 || return 1
    else
        sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" checkout "$PREV_SUPER" >/dev/null 2>&1 || return 1
    fi
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule update --init --recursive >/dev/null 2>&1 || return 1
    # The same predicate, so "put back" means the same thing as "never moved".
    # It compares submodules only when the starting state was readable: an
    # empty string standing for "could not read it" would have matched anything.
    code_is_where_it_started
}

abort_before_restore() {
    echo ""
    echo "✗ The code could not be returned to $TARGET_SHA: $1"
    echo ""
    echo "  Nothing has been restored. The database was never opened and the"
    echo "  backup is intact at:"
    echo "      $DUMP_FILE"
    echo ""
    if code_is_where_it_started; then
        echo "  The code never moved: the unit is still on $PREV_SUPER."
        CODE_RECOVERED=1
    else
        echo "→ Putting the code back..."
        if undo_code_move; then
            echo "  ✓ The code is back on $PREV_SUPER."
            CODE_RECOVERED=1
        else
            CODE_RECOVERED=0
        fi
    fi
    if [ "$CODE_RECOVERED" = 1 ]; then
        if [ -n "$ROLLBACK_BACKUP_CREATED" ]; then
            echo "    (The branch '$ROLLBACK_BACKUP_CREATED' this run created names the"
            echo "     same commit and can be deleted.)"
        fi
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
        echo "  Nothing was rolled back. Clear what is named above and run this"
        echo "  script again."
        exit 1
    fi
    echo "  ✗ The code could NOT be put back, so the unit is between versions."
    echo "    The database is still the one it was using, so the safest thing is"
    echo "    to return the code by hand and start the service:"
    echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT status"
    # A unit that was already detached stays detached. Defaulting to `-B dev`
    # here would move someone's branch to the target as part of a recovery,
    # which the rollback itself is careful not to do.
    if [ -n "$PREV_BRANCH" ]; then
        echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT checkout -B $PREV_BRANCH $PREV_SUPER"
    else
        echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT checkout $PREV_SUPER"
    fi
    echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT submodule update --init --recursive"
    echo "        sudo systemctl start dtk"
    if [ -n "$ROLLBACK_BACKUP_CREATED" ]; then
        echo "    The version this run started from is also kept as branch"
        echo "    '$ROLLBACK_BACKUP_CREATED'."
    fi
    echo "    The appliance has NOT been started, because what it would run is"
    echo "    not known."
    exit 1
}

if [ -n "$TARGET_SHA" ]; then
    echo "→ Returning code to commit $TARGET_SHA ..."
    # Which branch the unit is on, and the commit it is at, were read above:
    # the undo needs them and so does this, so they are read once. A plain
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
        if [ -n "$PREV_SUPER" ] && [ "$PREV_SUPER" != "$TARGET_SHA" ]; then
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
        sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" checkout -B "$PREV_BRANCH" "$TARGET_SHA" \
            || abort_before_restore "the checkout to $TARGET_SHA failed"
    else
        # Already detached before we started — there is no branch to
        # preserve, so say so rather than inventing one.
        echo "  ⚠ This repository was already on a detached HEAD, so the"
        echo "    rollback leaves it detached. Before the next update, run:"
        echo "        sudo -u $DTK_USER git -C $PROJECT_ROOT checkout dev"
        sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" checkout "$TARGET_SHA" \
            || abort_before_restore "the checkout to $TARGET_SHA failed"
    fi
    sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" git -C "$PROJECT_ROOT" submodule update --init --recursive \
        || abort_before_restore "the submodules could not be synced"

    # Verified, not predicted. `submodule update` works from the INDEX, and git
    # keeps a staged index entry when the old and the new tree agree on that
    # path -- so a staged gitlink can install a different submodule commit from
    # the one $TARGET_SHA names, and no check made beforehand sees it. Comparing
    # afterwards does, and the move is still undoable at this point.
    #
    # Compared at the depth `ls-tree -r` reports, which is the superproject's
    # own gitlinks: none of backend, frontend or wiki carries a .gitmodules, so
    # there is nothing nested for the non-recursive status to miss.
    TARGET_PINS="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" \
        git -C "$PROJECT_ROOT" ls-tree -r "$TARGET_SHA" \
        | sed -n 's/^160000 commit \([0-9a-f]*\)'$'\t''\(.*\)$/\2 \1/p' | sort)"
    ACTUAL_PINS="$(sudo -u "$DTK_USER" env HOME="$DTK_USER_HOME" \
        git -C "$PROJECT_ROOT" submodule status \
        | sed 's/^[+-U]//' | awk '{print $2" "$1}' | sort)"
    if [ "$TARGET_PINS" != "$ACTUAL_PINS" ]; then
        echo "  The submodules are not at the commits $TARGET_SHA names."
        echo "  $TARGET_SHA names:"
        printf '%s\n' "$TARGET_PINS" | sed 's/^/      /'
        echo "  the unit has:"
        printf '%s\n' "$ACTUAL_PINS" | sed 's/^/      /'
        abort_before_restore "the submodules ended up on the wrong commits"
    fi

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
        echo "  The dump at $DUMP_FILE is intact, and the code is already on"
        echo "  $TARGET_SHA, so running this script again retries just the restore."
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
        exit 1
    fi
    sleep 2
done

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
    echo "  The code IS already on $TARGET_SHA, so running this script again"
    echo "  retries the restore from the same backup."
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
#    Steps 3-4 restore the git checkout and the database only. The pixi
#    environment and the frontend image were rebuilt by update.sh for the NEW
#    code and are not rebuilt here (that needs the registries, and rollback is
#    when a remote unit may be offline). Read what update.sh recorded and say,
#    per component, whether it still matches — or that we cannot tell.
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
# state_field <key> <file>: value of "key: value", empty if absent/unreadable.
state_field() {
    sed -n "s/^$1: //p" "$2" 2>/dev/null | head -n 1
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
        IMG_DETAIL="the frontend image was rebuilt from the newer code"
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
if [ "$CODE_ROLLED_BACK" -eq 1 ]; then
    echo "  Code:      restored to $TARGET_SHA"
elif [ -n "$TARGET_SHA" ]; then
    echo "  Code:      NOT changed (commit $TARGET_SHA unavailable) — see warning above"
else
    echo "  Code:      NOT changed (no pre-update commit was recorded)"
fi
report_component "Pixi env:" "$PIXI_STATUS" "$PIXI_DETAIL" "$PIXI_FIX"
report_component "Frontend:" "$IMG_STATUS" "$IMG_DETAIL" "$IMG_FIX"
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
