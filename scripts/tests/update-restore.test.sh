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
#   dtk-system-helper  (the update page's verbs) records each call; systemctl
#              also logs "page-marker present" after any call made while
#              update.sh's or rollback-update.sh's update-page marker exists.
#   install    GNU-style install -D, which macOS lacks.
#   pgrep      finds no backend process, unless a case says one is stuck.
#
# Each case states the failure it injects, through the fakes or through
# update.sh's test-only DTK_UPDATE_FAIL_AT.
#
# Version: 0.3.0

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
# FAKE_ON_CLONE: shell run as a git clone starts. FAKE_FAIL_LSFILES=<name>:
# git ls-files --others in the folder of that name fails.
if [ "$cmd" = git ] && [ "${1:-}" = clone ] && [ -n "${FAKE_ON_CLONE:-}" ]; then
    sh -c "$FAKE_ON_CLONE"
fi
if [ "$cmd" = git ] && [ -n "${FAKE_FAIL_LSFILES:-}" ] && [ "${1:-}" = -C ] \
        && [ "${2##*/}" = "$FAKE_FAIL_LSFILES" ] && [ "${3:-}" = ls-files ] \
        && case " $* " in *" --others "*) true ;; *) false ;; esac; then
    echo "fatal: index file corrupt" >&2
    exit 128
fi
exec env "${vars[@]}" "$cmd" "$@"
EOF

# pkill: records the call; no kiosk is running (exit 1), unless FAKE_KIOSK.
printf '#!/bin/sh\necho "pkill $*" >> "$CASE_DIR/log"\n[ -n "${FAKE_KIOSK:-}" ]\n' > "$FAKEBIN/pkill"
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
[ ! -e "$DTK_TEST_STATE/dtk-update-page.wanted" ] || echo "page-marker present" >> "$CASE_DIR/log"
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
        echo "stop at step $(sed -n 's/^step //p' "$DTK_TEST_STATE/etc-dtk/crossing" 2>/dev/null)" >> "$CASE_DIR/log"
        # FAKE_STOP_FAIL: the stop fails and leaves the unit running.
        # FAKE_ON_STOP: shell run as the stop happens.
        [ -z "${FAKE_STOP_FAIL:-}" ] || exit 1
        [ -z "${FAKE_ON_STOP:-}" ] || sh -c "$FAKE_ON_STOP"
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
        # FAKE_START_FAIL: the start fails, the unit stays down.
        [ -z "${FAKE_START_FAIL:-}" ] || exit 1
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
        if [ -n "${FAKE_STAGE_BACKEND_PIN_ON_INSTALL:-}" ] && [ ! -f "$CASE_DIR/staged" ]; then
            git -C "$PROJECT_ROOT/backend" checkout -q "$FAKE_STAGE_BACKEND_PIN_ON_INSTALL" >/dev/null 2>&1
            git -C "$PROJECT_ROOT" update-index --cacheinfo "160000,$FAKE_STAGE_BACKEND_PIN_ON_INSTALL,backend"
            touch "$CASE_DIR/staged"
        fi
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
                pg_isready) [ -z "${FAKE_DB_UNREACHABLE:-}" ] || exit 2; exit 0 ;;
                pg_dump)
                    n=$(( $(cat "$CASE_DIR/dumps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE_DIR/dumps"
                    if [ -n "${FAKE_DUMP_FAIL_AT:-}" ] && [ "$n" = "$FAKE_DUMP_FAIL_AT" ]; then
                        echo "pg_dump: error" >&2; exit 1
                    fi
                    echo "-- dump $n of the database at schema A"
                    cat "$CASE_DIR/db_rows" 2>/dev/null
                    # The tables the stem guard reads, in pg_dump's order. Rows
                    # may name @STATE@ for the case's state directory.
                    rows() { [ -z "$1" ] || printf '%b\n' "$1" | sed "s#@STATE@#$DTK_TEST_STATE#g"; }
                    printf 'COPY public.collections (id, name, description, filename_stem, created_at) FROM stdin;\n'
                    rows "${FAKE_DUMP_COLLECTIONS:-}"
                    printf '\\.\n'
                    if [ -z "${FAKE_DUMP_NO_IMAGES:-}" ]; then
                        if [ -n "${FAKE_DUMP_OLD_IMAGES_SCHEMA:-}" ]; then
                            printf 'COPY public.record_images (id, record_id, filename, file_path, format) FROM stdin;\n'
                        else
                            printf 'COPY public.record_images (id, record_id, filename, file_path, format, is_current, master_freed_at, master_freed_bytes) FROM stdin;\n'
                        fi
                        rows "${FAKE_DUMP_RECORD_IMAGES:-}"
                        printf '\\.\n'
                    fi
                    printf 'COPY public.records (id, title, collection_id, capture_mode) FROM stdin;\n'
                    rows "${FAKE_DUMP_RECORDS:-}"
                    printf '\\.\n'
                    seq 1 300 ;;
                psql)
                    case "$*" in *alembic_version*) echo "${FAKE_DB_REV:-rev-B}"; exit 0 ;; esac
                    case "$*" in
                        *"FROM pg_database WHERE datname"*)
                            [ -z "${FAKE_DB_UNREACHABLE:-}" ] || { echo "psql: could not connect" >&2; exit 2; }
                            [ -n "${FAKE_DB_ABSENT:-}" ] || echo 1
                            exit 0 ;;
                        *"information_schema.columns"*)
                            [ -z "${FAKE_DB_UNREACHABLE:-}" ] || { echo "psql: could not connect" >&2; exit 2; }
                            [ -n "${FAKE_NO_STEM_COLUMN:-}" ] || echo 1
                            exit 0 ;;
                        *to_regclass*)
                            [ -z "${FAKE_DB_UNREACHABLE:-}" ] || { echo "psql: could not connect" >&2; exit 2; }
                            [ -z "${FAKE_DB_ABSENT:-}" ] || { echo "psql: database does not exist" >&2; exit 2; }
                            [ -n "${FAKE_NO_COLLECTIONS_TABLE:-}" ] || echo "collections"
                            exit 0 ;;
                        *"filename_stem IS NOT NULL"*)
                            [ -z "${FAKE_DB_UNREACHABLE:-}" ] || { echo "psql: could not connect" >&2; exit 2; }
                            [ -z "${FAKE_NO_STEM_COLUMN:-}" ] || { echo "psql: column \"filename_stem\" does not exist" >&2; exit 1; }
                            [ -z "${FAKE_DB_ABSENT:-}" ] || { echo "psql: database does not exist" >&2; exit 2; }
                            [ -z "${FAKE_STEMMED:-}" ] || printf '%b\n' "$FAKE_STEMMED"
                            exit 0 ;;
                    esac
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
# tree-snapshot <dir>: every path under <dir> but <dir>/.git, with its type,
# mode and content digest (or link target), then the index of the checkout
# and of each submodule as `git ls-files -s` lists it. Two snapshots are
# equal when nothing in the working trees or the indexes has changed.
cat > "$FAKEBIN/tree-snapshot" <<'EOF2'
#!/usr/bin/env python3
import hashlib, os, stat, subprocess, sys
root = sys.argv[1]
lines = []
for dp, dns, fns in os.walk(root):
    rel = os.path.relpath(dp, root)
    if rel == ".":
        dns[:] = [d for d in dns if d != ".git"]
    for name in dns + fns:
        p = os.path.join(dp, name)
        r = os.path.normpath(os.path.join(rel, name))
        st = os.lstat(p)
        mode = oct(stat.S_IMODE(st.st_mode))
        if stat.S_ISLNK(st.st_mode):
            lines.append("L %s -> %s" % (r, os.readlink(p)))
        elif stat.S_ISDIR(st.st_mode):
            lines.append("D %s %s" % (mode, r))
        elif not stat.S_ISREG(st.st_mode):
            lines.append("N %s %s %s" % (oct(stat.S_IFMT(st.st_mode)), mode, r))
        else:
            try:
                with open(p, "rb") as f:
                    h = hashlib.sha256(f.read()).hexdigest()
            except PermissionError:
                h = "unreadable"
            lines.append("F %s %d %s %s" % (mode, st.st_size, h, r))
for line in sorted(lines):
    print(line)
for sub in ("", "backend", "frontend"):
    d = os.path.join(root, sub)
    if os.path.exists(os.path.join(d, ".git")):
        print("index of", sub or ".")
        sys.stdout.write(subprocess.run(["git", "-C", d, "ls-files", "-s"], capture_output=True, text=True).stdout)
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
# findmnt: for -o UUID the UUID FAKE_FSUUID names (test-uuid when unset);
# for -o TARGET the mount point, / unless the path is at or under
# FAKE_MOUNTPOINT; otherwise the filesystem type FAKE_FSTYPE names (ext4
# when unset).
cat > "$FAKEBIN/findmnt" <<'EOF2'
#!/bin/sh
eval "path=\${$#}"
case " $* " in
    *" UUID "*) echo "${FAKE_FSUUID:-test-uuid}" ;;
    *" TARGET "*)
        # FAKE_MOUNTPOINT: a filesystem mounted at that path.
        case "$path" in
            "${FAKE_MOUNTPOINT:-//none}"|"${FAKE_MOUNTPOINT:-//none}"/*) echo "$FAKE_MOUNTPOINT" ;;
            *) echo / ;;
        esac ;;
    *) echo "${FAKE_FSTYPE:-ext4}" ;;
esac
EOF2
chmod +x "$FAKEBIN"/*
export FAKEBIN OLD_IMG NEW_IMG

# ── Fixture: superproject with submodules, deployed A, remote at B ──────────
UP="$WORK/up"
mkdir -p "$UP"
for sub in backend frontend; do
    git init -q "$UP/$sub"
done
# Each submodule ignores its own build output, as the real ones do.
printf '.pixi/\n' > "$UP/backend/.gitignore"
printf 'node_modules/\n' > "$UP/frontend/.gitignore"
echo "lock-A" > "$UP/backend/pixi.lock"; g -C "$UP/backend" add -A; g -C "$UP/backend" commit -m A
echo "fe-A" > "$UP/frontend/app";        g -C "$UP/frontend" add -A; g -C "$UP/frontend" commit -m A

STATE_DIR_T="$WORK/STATE"   # stand-in for /var/lib/dtk, per case (see run_case)
git init -q "$UP/super"
mkdir -p "$UP/super/scripts"
# /var/lib/dtk, /etc/dtk and /etc/systemd/system all point into the case's
# state directory.
TESTPATHS='s#/var/lib/dtk#$DTK_TEST_STATE#g; s#/etc/dtk#$DTK_TEST_STATE/etc-dtk#g; s#/etc/systemd/system#$DTK_TEST_STATE/systemd#g; s#/run/dtk-update.lock#$DTK_TEST_STATE/dtk-update.lock#g; s#/run/dtk-update-page.wanted#$DTK_TEST_STATE/dtk-update-page.wanted#g'
# The update page's helper: a fake that records each call.
TESTPATHS="$TESTPATHS; s#/usr/local/bin/dtk-system-helper#$FAKEBIN/dtk-system-helper#g"
# Inode generations from FAKE_GENERATIONS ("<path>=<n>;..."; 1 otherwise):
# macOS has no FS_IOC_GETVERSION.
TESTPATHS="$TESTPATHS; s#^CROSS_GEN_READER=\"ioctl\"#CROSS_GEN_READER=\"fake\"#"
printf '#!/bin/sh\necho "helper $*" >> "$CASE_DIR/log"\nexit 0\n' > "$FAKEBIN/dtk-system-helper"
chmod +x "$FAKEBIN/dtk-system-helper"
sed "$TESTPATHS" "$SCRIPTS/update.sh" > "$UP/super/scripts/update.sh"
sed "$TESTPATHS" "$SCRIPTS/rollback-update.sh" > "$UP/super/scripts/rollback-update.sh"
cp "$SCRIPTS/captua-env.sh" "$UP/super/scripts/captua-env.sh"
printf '#!/bin/sh\nexit 0\n' > "$UP/super/scripts/provision-chdk-usb.sh"
printf '#!/bin/sh\nexit 0\n' > "$UP/super/scripts/provision-rclone.sh"
printf '#!/bin/sh\nexit 0\n' > "$UP/super/scripts/install-network-permissions.sh"
printf '#!/bin/sh\nexit 0\n' > "$UP/super/scripts/install-system-helper.sh"
# Records its calls. The switch writes what the real one writes inside the
# unit's reach: HOST_IP in the checkout's .env (when there is one) and the
# record in /etc/dtk, both places a restore or rollback works in, so a
# restore that put either back would show.
# FAKE_SWITCH_FAIL: the switch exits 1, as it would not under --advisory.
cat > "$UP/super/scripts/provision-hostname.sh" <<'EOF'
#!/bin/sh
echo "provision-hostname $*" >> "$CASE_DIR/log"
case " $* " in
    *" --switch "*)
        [ -z "${FAKE_SWITCH_FAIL:-}" ] || exit 1
        if [ -f "$PROJECT_ROOT/.env" ]; then
            sed 's/^HOST_IP=.*/HOST_IP=captua.local/' "$PROJECT_ROOT/.env" > "$PROJECT_ROOT/.env.new" \
                && mv "$PROJECT_ROOT/.env.new" "$PROJECT_ROOT/.env"
        fi
        mkdir -p "$DTK_TEST_STATE/etc-dtk"
        printf 'state=done\nfrom=digitool\nto=captua\n' > "$DTK_TEST_STATE/etc-dtk/hostname-switch" ;;
esac
exit 0
EOF
chmod +x "$UP/super/scripts/"*.sh
echo "services: {}" > "$UP/super/docker-compose.yml"
echo "services: {}" > "$UP/super/docker-compose.pi.yml"
echo "readme" > "$UP/super/README"
mkdir -p "$UP/super/docs"; echo base > "$UP/super/docs/base"
# What the superproject ignores, as the real .gitignore does: paths inside the
# submodules, which only matter once they are folders, and one of its own.
printf 'backend/data/\nfrontend/node_modules/\n_data/\n' > "$UP/super/.gitignore"
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

# The merged layout, C, on the remote's branch `merged`: B with the backend
# and frontend gitlinks replaced by directories holding the files each
# submodule pins at B, and no .gitmodules. It also adds one file under
# backend/ that the backend submodule does not track.
MK="$WORK/make-merged"
git clone -q "$UP/super" "$MK" 2>/dev/null
g -C "$MK" checkout -q -b merged "$SHA_B"
g -C "$MK" rm -q --cached backend frontend
g -C "$MK" rm -q .gitmodules
for sub in backend frontend; do
    rm -rf "${MK:?}/$sub"; mkdir -p "$MK/$sub"
    git -C "$UP/$sub" archive HEAD | tar -x -C "$MK/$sub"
done
echo "added in the merged layout" > "$MK/backend/merged-only.txt"
echo "C" > "$MK/VERSION"
g -C "$MK" add -A; g -C "$MK" commit -m C
g -C "$MK" push -q origin merged
SHA_C="$(git -C "$MK" rev-parse HEAD)"
if [ "$(git -C "$UP/super" ls-tree "$SHA_C" -- backend | awk '{print $1}')" != 040000 ]; then
    echo "fixture: could not build the merged commit"; exit 1
fi
# Two commits that track a file at a path the superproject ignores: C with
# backend/data/seed.txt (branch merged-tracks-ignored), and B with
# _data/seed.txt (branch tracks-ignored).
g -C "$MK" checkout -q -b merged-tracks-ignored merged
mkdir -p "$MK/backend/data"; echo theirs > "$MK/backend/data/seed.txt"
g -C "$MK" add -f backend/data/seed.txt; g -C "$MK" commit -m "C tracks an ignored path"
g -C "$MK" push -q origin merged-tracks-ignored
g -C "$MK" checkout -q -b tracks-ignored "$SHA_B"
mkdir -p "$MK/_data"; echo theirs > "$MK/_data/seed.txt"
g -C "$MK" add -f _data/seed.txt; g -C "$MK" commit -m "B tracks an ignored path"
g -C "$MK" push -q origin tracks-ignored
# C with backend/.pixi, which the crossing carries, tracked as a symlink to
# a directory outside the checkout (branch merged-pixi-link); and C with .env
# tracked (branch merged-tracks-env).
mkdir -p "$WORK/outside"
g -C "$MK" checkout -q -b merged-pixi-link merged
ln -s "$WORK/outside" "$MK/backend/.pixi"
g -C "$MK" add -f backend/.pixi; g -C "$MK" commit -m "C with backend/.pixi a symlink"
g -C "$MK" push -q origin merged-pixi-link
g -C "$MK" checkout -q -b merged-tracks-env merged
echo "TRACKED=1" > "$MK/.env"
g -C "$MK" add -f .env; g -C "$MK" commit -m "C with .env tracked"
g -C "$MK" push -q origin merged-tracks-env
for b in merged-tracks-ignored tracks-ignored merged-pixi-link merged-tracks-env; do
    git -C "$UP/super" rev-parse -q --verify "$b" >/dev/null || { echo "fixture: no branch $b"; exit 1; }
done

# An alias the global configuration rewrites to the fixture's remote, for a
# unit whose origin is configured through it.
printf '[url "%s/"]\n    insteadOf = upstream-alias:\n' "$UP" >> "$GIT_CONFIG_GLOBAL"

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
    # FAKE_UPSTREAM: the remote branch the unit's dev tracks instead of dev.
    [ -z "${FAKE_UPSTREAM:-}" ] || g -C "$PROJECT_ROOT" branch --set-upstream-to="origin/$FAKE_UPSTREAM" dev
    # FAKE_UNIT_SETUP: shell run in the unit's checkout before the update.
    [ -z "${FAKE_UNIT_SETUP:-}" ] || ( cd "$PROJECT_ROOT" && eval "$FAKE_UNIT_SETUP" )
    [ -z "${FAKE_STAGE_BACKEND_PIN:-}" ] || stage_backend_pin "$FAKE_STAGE_BACKEND_PIN"
    [ -z "${FAKE_DOTENV:-}" ] || printf '%s\n' "$FAKE_DOTENV" > "$PROJECT_ROOT/.env"
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
# line_of <text>: the first log line holding it.
line_of() { grep -n -F -- "$1" "$CASE_DIR/log" | head -n 1 | cut -d: -f1; }
before()  {  # before <a> <b>: a is logged, b is logged, a first
    local a b; a="$(line_of "$1")"; b="$(line_of "$2")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "'$1' before '$2'"; else fail "'$1' (line ${a:-none}) not before '$2' (line ${b:-none})"; fi
}

# page_checks <stopped|failed> [after-stop]: the update page across the run.
# The marker first appears at update.sh's (or the rollback's) stop of dtk;
# the page is asked for after the stack is torn down; every start of dtk
# after that is preceded, immediately, by update-page-stop; at the end the
# page is stopped, or (failed) its last call is update-page-start; and the
# marker is gone. With after-stop the run did not stop an active dtk (its
# stop is a no-op), so only the order after the stop is checked.
page_checks() {
    local stop down first l prev last bad=0
    stop="$(line_of "systemctl stop dtk")"
    if [ "${2:-}" != after-stop ]; then
        eq "$(line_of "page-marker present")" "$(( ${stop:-0} + 1 ))" "the page marker first exists at the stop of dtk"
    fi
    down="$(awk -v s="${stop:-0}" 'NR > s && /compose .*down/ { print NR; exit }' "$CASE_DIR/log")"
    first="$(grep -n -x 'helper update-page-start' "$CASE_DIR/log" | head -n 1 | cut -d: -f1)"
    if [ -n "$stop" ] && [ -n "$down" ] && [ -n "$first" ] && [ "$first" -gt "$down" ]; then
        ok "the page is asked for after the stop and the teardown"
    else
        fail "page start at ${first:-none}, stop at ${stop:-none}, teardown at ${down:-none}"
    fi
    for l in $(grep -n '^systemctl start dtk' "$CASE_DIR/log" | cut -d: -f1); do
        [ "$l" -gt "${stop:-0}" ] || continue
        prev="$(sed -n "$((l - 1))p" "$CASE_DIR/log")"
        [ "$prev" = "helper update-page-stop" ] || { bad=1; fail "start of dtk at line $l follows '$prev', not update-page-stop"; }
    done
    [ "$bad" -eq 1 ] || ok "every start of dtk follows update-page-stop"
    last="$(grep '^helper ' "$CASE_DIR/log" | tail -n 1)"
    case "$1" in
        stopped) eq "$last" "helper update-page-stop" "the page is stopped at the end" ;;
        failed)  eq "$last" "helper update-page-start" "the page is left up, in its failed state" ;;
    esac
    if [ -e "$DTK_TEST_STATE/dtk-update-page.wanted" ]; then fail "the page marker remains"; else ok "no page marker"; fi
}
no_page() {
    unlogged "helper update-page"
    unlogged "page-marker present"
}

echo "update.sh restore paths"

# ── Success path ────────────────────────────────────────────────────────────
FAKE_KIOSK=1 run_case "success" --yes
eq "$RC" 0 "exit status"
logged "pkill -u $(whoami) -x cage"
has "Relaunched the kiosk on the new version's address."
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
page_checks stopped
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
# A failure, or a backend crash and systemd's restart of it, before the
# deliberate stop shows no page.
no_page
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
FAKE_KIOSK=1 run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward
eq "$RC" 0 "exit status"
before "helper update-page-stop" "systemctl start dtk"
eq "$(sed -n "$(( $(line_of "systemctl start dtk") - 1 ))p" "$CASE_DIR/log")" "helper update-page-stop" "the page is stopped right before the start"
has "Recorded $SHA_B as the deployed version"
has "online on $SHA_B"
before "systemctl start dtk" "pkill -u $(whoami) -x cage"
has "Relaunched the kiosk on this version's address."
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
FAKE_KIOSK=1 run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
logged "pkill -u $(whoami) -x cage"
has "Relaunched the kiosk on the restored version's address."
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
page_checks stopped
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
page_checks failed
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
# B's tree as a child of A_OLD, so that A_OLD is an ancestor of what is
# checked out, as --no-pull requires.
g -C "$PROJECT_ROOT" checkout -q -B dev "$SHA_A_OLD"
g -C "$PROJECT_ROOT" checkout "$SHA_B" -- .
g -C "$PROJECT_ROOT" commit -qm "B on top of A_OLD"
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

# ── Signals, and records before irreversible steps ───────────────────────
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

# ── The start flag and drop-in ───────────────────────────────────────────
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

# ── --no-pull with no usable deploy record: no restore target ────────────
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
run_no_pull() {  # run_no_pull [more update.sh args...]
    OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 \
        bash "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes "$@" 2>&1 </dev/null)"
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
    hasnt "The update failed; restoring"
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

# ── rollback-update.sh refusals ────────────────────────────────────────
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

# ── Partial code restore: superproject back, a submodule not ─────────────
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

# ── --resolve-forward checks ──────────────────────────────────────────
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
page_checks failed
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
page_checks stopped
no_marker
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "a start flag remains"; else ok "no start flag"; fi
active

# ── After step 8 starts B: the record says so, flag or not ───────────────
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

# ── A flag without a record ──────────────────────────────────────────────
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

# ── The pull path with no deploy record: the rollback target is recorded ─
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

# ── A refused restore has its own kind ───────────────────────────────────
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

# ── --resolve-forward --no-start ─────────────────────────────────────────
FAKE_HEALTHY_VERSIONS="A" run_case "resolve forward without starting" --yes
CASE="resolve forward without starting: resolve"
FAKE_KIOSK=1 run_again "$PROJECT_ROOT/scripts/update.sh" --resolve-forward --no-start
eq "$RC" 0 "exit status"
no_marker
inactive
unlogged "systemctl start"
unlogged "pkill"
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
FAKE_STAGE_BACKEND_PIN_ON_INSTALL="$BACKEND_B" DTK_UPDATE_FAIL_AT=pixi run_case "staged gitlink at the restore" --no-pull --yes
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

# ── A rollback from an external dump on a unit with no backups directory ───
# setup_bare_unit <dir-name>: a unit at A, running, whose state directory has
# no backups/ at all (never updated by a script that creates it).
setup_bare_unit() {
    CASE_DIR="$WORK/cases/$1"; mkdir -p "$CASE_DIR/sys" "$CASE_DIR/docker"; export CASE_DIR
    PROJECT_ROOT="$CASE_DIR/dtk"; export PROJECT_ROOT; cp -R "$TEMPLATE" "$PROJECT_ROOT"
    export DTK_TEST_STATE="$CASE_DIR/state"; mkdir -p "$DTK_TEST_STATE"
    touch "$CASE_DIR/sys/active" "$CASE_DIR/docker/db_running" "$CASE_DIR/docker/known_$OLD_IMG"
    echo "$OLD_IMG" > "$CASE_DIR/docker/tag_dtk-frontend_latest"; echo "$OLD_IMG" > "$CASE_DIR/docker/frontend_container"
    echo A > "$CASE_DIR/sys/started"; echo schema-A > "$CASE_DIR/db_state"
    { echo "-- an external dump of the database at schema A"; seq 1 300; } | gzip > "$CASE_DIR/external.sql.gz"
    : > "$CASE_DIR/log"
}
setup_bare_unit external-dump-no-backups
CASE="external dump, no backups directory"
run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$CASE_DIR/external.sql.gz"
eq "$RC" 0 "exit status"
db_is restored
if grep -q "an external dump" "$CASE_DIR/restored.sql" 2>/dev/null; then ok "the external dump was loaded"; else fail "the external dump was not loaded"; fi
if [ -d "$DTK_TEST_STATE/backups" ]; then ok "backups directory created"; else fail "no backups directory"; fi
eq "$(stat -c %a "$DTK_TEST_STATE/backups" 2>/dev/null || stat -f %Lp "$DTK_TEST_STATE/backups")" 700 "backups directory is mode 700, as update.sh makes it"
no_marker
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "a start flag remains"; else ok "no start flag"; fi
active

setup_bare_unit external-dump-backups-blocked
: > "$DTK_TEST_STATE/backups"        # a file where the directory must go
CASE="external dump, backups directory cannot be created"
run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$CASE_DIR/external.sql.gz"
eq "$RC" 1 "exit status"
has "is not a directory"
unlogged "systemctl stop"
unlogged "psql DROP"
db_is schema-A
active
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "a start flag was created"; else ok "no start flag"; fi

# ── --no-pull checks the checkout before anything changes ──────────────────
# nothing_changed: the refusal came before 0a's tag, the build, the stop, any
# record, and the unit still runs A on schema A.
nothing_changed() {
    hasnt "The update failed; restoring"
    unlogged "docker tag"
    unlogged "build frontend"
    unlogged "systemctl stop"
    unlogged "pixi install"
    db_is "${DB_BEFORE:-schema-A}"
    no_marker
    active
}
FAKE_STAGE_BACKEND_PIN="$BACKEND_B" run_case "--no-pull with a staged gitlink" --no-pull --yes
eq "$RC" 1 "exit status"
has "✗ --no-pull: a submodule is not on the commit HEAD records"
has "diff --cached HEAD --submodule"
nothing_changed

run_case "--no-pull with a submodule checked out off its pin" --no-pull --yes   # builds the case
g -C "$PROJECT_ROOT/backend" checkout -q "$BACKEND_B"
DB_BEFORE="$(cat "$CASE_DIR/db_state")"
CASE="--no-pull with a submodule checked out off its pin: run"
run_again "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes
eq "$RC" 1 "exit status"
has "✗ --no-pull: a submodule is not on the commit HEAD records"
nothing_changed

for where in superproject submodule staged; do
    run_case "--no-pull with a modified tracked file ($where)" --no-pull --yes   # builds the case
    case "$where" in
        superproject) echo "hand edit" >> "$PROJECT_ROOT/README" ;;
        submodule)    echo "hand edit" >> "$PROJECT_ROOT/backend/pixi.lock" ;;
        staged)       echo "hand edit" >> "$PROJECT_ROOT/README"; g -C "$PROJECT_ROOT" add README
                      git -C "$PROJECT_ROOT" show HEAD:README > "$PROJECT_ROOT/README" ;;
    esac
    DB_BEFORE="$(cat "$CASE_DIR/db_state")"
    CASE="--no-pull with a modified tracked file ($where): run"
    run_again "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes
    eq "$RC" 1 "exit status"
    has "✗ --no-pull: the checkout has modified tracked files"
    has "submodule foreach --recursive git status --short"
    nothing_changed
done

# Index flags that hide a tracked file's edits from git: each kind, in the
# superproject and in a submodule, with the file edited behind the flag.
for flag in assume-unchanged skip-worktree; do
    for where in superproject submodule; do
        run_case "--no-pull with $flag ($where)" --no-pull --yes   # builds the case
        case "$where" in
            superproject) repo="$PROJECT_ROOT"; file=README; shown=README ;;
            submodule)    repo="$PROJECT_ROOT/backend"; file=pixi.lock; shown=backend/pixi.lock ;;
        esac
        g -C "$repo" update-index "--$flag" "$file"
        echo "edit behind the flag" >> "$repo/$file"
        DB_BEFORE="$(cat "$CASE_DIR/db_state")"
        CASE="--no-pull with $flag ($where): run"
        run_again "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes
        eq "$RC" 1 "exit status"
        has "✗ --no-pull: tracked files are marked assume-unchanged or skip-worktree"
        case "$flag" in
            assume-unchanged) has "      h $shown" ;;
            skip-worktree)    has "      S $shown" ;;
        esac
        has "update-index --no-assume-unchanged --no-skip-worktree <file>"
        nothing_changed
    done
done

run_case "--no-pull downgrade" --no-pull --yes   # builds the case: unit at A
echo "$SHA_B" > "$DTK_TEST_STATE/backups/last-deployed-SHA"
DB_BEFORE="$(cat "$CASE_DIR/db_state")"
CASE="--no-pull downgrade: run"
run_again "$PROJECT_ROOT/scripts/update.sh" --no-pull --yes
eq "$RC" 1 "exit status"
has "✗ --no-pull: the code checked out ($SHA_A) does not descend from the version"
has "this unit last deployed ($SHA_B)"
has "rollback-update.sh"
nothing_changed

DB_BEFORE=""
run_case "--no-pull redeploy of the same commit" --no-pull --yes
eq "$RC" 0 "exit status"
has "Update complete!"
hasnt "✗ --no-pull"

setup_no_pull_case "no-pull-forward" "$SHA_A"
CASE="--no-pull forward from the deployed commit"
run_no_pull
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
hasnt "✗ --no-pull"

# On the pull path a local modification is set aside, not refused.
run_case "pull path with a modified tracked file" --yes   # builds the case
echo "hand edit" >> "$PROJECT_ROOT/README"
CASE="pull path with a modified tracked file: run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 0 "exit status"
has "locally modified files"
hasnt "✗ --no-pull"

# ── rollback-update.sh: volumes the restored dump would cut off from files ─
STEMS_FILE_REL="backups/rollback-stems-at-risk"
# stem_case <name>: a successful update (its dump is the one the rollback
# restores), with volume 7 "Libro 7" stemmed libro-7 in the current database
# and its directory under the projects root. FAKE_DUMP_* in the caller's
# environment shape the dump.
stem_case() {
    run_case "$1" --yes
    mkdir -p "$DTK_TEST_STATE/projects/libro-7/captures"
    DB_BEFORE="$(cat "$CASE_DIR/db_state")"
}
STEMMED_7='7\tLibro 7\tlibro-7'
stems_untouched() {
    unlogged "systemctl stop"
    unlogged "psql DROP"
    db_is "$DB_BEFORE"
    no_marker
    if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "a start flag exists"; else ok "no start flag"; fi
    active
}
list_has() { if grep -qxF -e "$(printf '%b' "$1")" "$DTK_TEST_STATE/$STEMS_FILE_REL" 2>/dev/null; then ok "the list file has: $1"; else fail "the list file lacks: $1"; fi; }
# Volume 7 in the dump with its stem, one record, and images as given.
DUMP_7='7\tLibro 7\t\\N\tlibro-7\t2026-10-01 00:00:00'
RECORDS_7='70\tFolio 1\t7\tsingle'
OLD_PATH='@STATE@/projects/rionegro/libro-7/images/main/libro-7-img_0001.jpg'
NEW_PATH='@STATE@/projects/libro-7/captures/libro-7-img_0001.jpg'

# The first 0.1.0 install at an archive: the volume had its stem already,
# the backup was taken before the layout pass moved its files into
# <stem>/captures/ and rewrote the paths. Same stem, paths gone.
FAKE_DUMP_COLLECTIONS="$DUMP_7" FAKE_DUMP_RECORDS="$RECORDS_7" \
FAKE_DUMP_RECORD_IMAGES="700\t70\tlibro-7-img_0001.jpg\t$OLD_PATH\tjpg\tt\t\\N\t\\N" \
    stem_case "backup from before the layout move, same stem"
mkdir -p "$DTK_TEST_STATE/projects/libro-7/captures"; : > "$DTK_TEST_STATE/projects/libro-7/captures/libro-7-img_0001.jpg"
CASE="backup from before the layout move, same stem: the rollback"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "✗ Restoring this backup may cut volumes off from their files:"
has "id 7  \"Libro 7\"  stem libro-7: 1 of 1 images not on disk, e.g. $DTK_TEST_STATE/projects/rionegro/libro-7/images/main/libro-7-img_0001.jpg"
has "--accept-lost-stems"
hasnt "some of them may be safe"
stems_untouched
eq "$(stat -c %a "$DTK_TEST_STATE/$STEMS_FILE_REL" 2>/dev/null || stat -f %Lp "$DTK_TEST_STATE/$STEMS_FILE_REL")" 600 "the list file is mode 600"
list_has "id\tname\tfilename_stem\timages_missing\timages_total\texample"
list_has "7\tLibro 7\tlibro-7\t1\t1\t$DTK_TEST_STATE/projects/rionegro/libro-7/images/main/libro-7-img_0001.jpg"
if grep -qx "# accepted: no" "$DTK_TEST_STATE/$STEMS_FILE_REL"; then ok "the list file says not accepted"; else fail "the list file does not say not accepted"; fi
if grep -qx "# dump: $(dump_name)" "$DTK_TEST_STATE/$STEMS_FILE_REL"; then ok "the list file names the dump"; else fail "the list file does not name the dump"; fi
if grep -qx "# dump-check: per image" "$DTK_TEST_STATE/$STEMS_FILE_REL"; then ok "the list file says per image"; else fail "the list file does not say per image"; fi

CASE="backup from before the layout move, same stem: accepted"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes --accept-lost-stems "$(dump_name)"
eq "$RC" 0 "exit status"
has "--accept-lost-stems: rolling back anyway"
db_is restored
if grep -qx "# accepted: yes (--accept-lost-stems)" "$DTK_TEST_STATE/$STEMS_FILE_REL"; then ok "the list file says accepted"; else fail "the list file does not say accepted"; fi
active

FAKE_DUMP_COLLECTIONS="$DUMP_7" FAKE_DUMP_RECORDS="$RECORDS_7" \
FAKE_DUMP_RECORD_IMAGES="700\t70\tlibro-7-img_0001.jpg\t$OLD_PATH\tjpg\tt\t\\N\t\\N" \
    stem_case "accepted, killed after the DROP"
CASE="accepted, killed after the DROP: the rollback"
FAKE_STEMMED="$STEMMED_7" FAKE_KILL_ON_DROP=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes --accept-lost-stems "$(dump_name)"
marker_has "kind: restore-failed"
marker_has "lost-stems-accepted: $DTK_TEST_STATE/$STEMS_FILE_REL"

# Every image the backup records is where it says: nothing at risk.
FAKE_DUMP_COLLECTIONS="$DUMP_7" FAKE_DUMP_RECORDS="$RECORDS_7" \
FAKE_DUMP_RECORD_IMAGES="700\t70\tlibro-7-img_0001.jpg\t$NEW_PATH\tjpg\tt\t\\N\t\\N" \
    stem_case "backup whose paths all exist"
: > "$DTK_TEST_STATE/projects/libro-7/captures/libro-7-img_0001.jpg"
CASE="backup whose paths all exist: the rollback"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
hasnt "may cut volumes off"
db_is restored

# Mixed: volume 7 intact, volume 8 not; a freed master missing on disk is
# stored offsite and does not count; an image with no volume is reported.
FAKE_DUMP_COLLECTIONS="$DUMP_7\n8\tLibro 8\t\\N\tlibro-8\t2026-10-01 00:00:00" \
FAKE_DUMP_RECORDS="$RECORDS_7\n80\tFolio 1\t8\tsingle\n81\tFolio 2\t8\tsingle\n90\tLoose\t\\N\tsingle" \
FAKE_DUMP_RECORD_IMAGES="700\t70\ta.jpg\t$NEW_PATH\tjpg\tt\t\\N\t\\N\n701\t70\tb.jpg\t@STATE@/projects/libro-7/captures/freed.jpg\tjpg\tt\t2026-10-02 00:00:00\t12345\n800\t80\tc.jpg\t@STATE@/projects/libro-8/captures/c.jpg\tjpg\tt\t\\N\t\\N\n801\t81\td.jpg\t@STATE@/projects/old/libro-8/d.jpg\tjpg\tt\t\\N\t\\N\n802\t81\te.jpg\t@STATE@/projects/old/libro-8/e.jpg\tjpg\tf\t\\N\t\\N\n900\t90\tf.jpg\t@STATE@/projects/loose/f.jpg\tjpg\tt\t\\N\t\\N" \
    stem_case "mixed volumes"
: > "$DTK_TEST_STATE/projects/libro-7/captures/libro-7-img_0001.jpg"
mkdir -p "$DTK_TEST_STATE/projects/libro-8/captures"; : > "$DTK_TEST_STATE/projects/libro-8/captures/c.jpg"
CASE="mixed volumes: the rollback"
FAKE_STEMMED="$STEMMED_7\n8\tLibro 8\tlibro-8" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "id 8  \"Libro 8\"  stem libro-8: 2 of 3 images not on disk, e.g. $DTK_TEST_STATE/projects/old/libro-8/d.jpg"
has "no volume: 1 of 1 images not on disk, e.g. $DTK_TEST_STATE/projects/loose/f.jpg"
hasnt "id 7  \"Libro 7\""
list_has "8\tLibro 8\tlibro-8\t2\t3\t$DTK_TEST_STATE/projects/old/libro-8/d.jpg"
list_has "-\t(no volume)\t-\t1\t1\t$DTK_TEST_STATE/projects/loose/f.jpg"
stems_untouched

# A dump from an older schema, without master_freed_at: its paths are still
# checked.
FAKE_DUMP_OLD_IMAGES_SCHEMA=1 FAKE_DUMP_COLLECTIONS="$DUMP_7" FAKE_DUMP_RECORDS="$RECORDS_7" \
FAKE_DUMP_RECORD_IMAGES="700\t70\tlibro-7-img_0001.jpg\t$OLD_PATH\tjpg" \
    stem_case "older image schema in the dump"
CASE="older image schema in the dump: the rollback"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "stem libro-7: 1 of 1 images not on disk"
stems_untouched

# The second signal: a volume with a stem directory that the backup lacks.
stem_case "volume the backup does not have"
CASE="volume the backup does not have: the rollback"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "id 7  \"Libro 7\"  stem libro-7: not in the backup; its files are in $DTK_TEST_STATE/projects/libro-7"
list_has "7\tLibro 7\tlibro-7\tnot-in-backup\t-\t$DTK_TEST_STATE/projects/libro-7"
stems_untouched

stem_case "volume the backup does not have, directory absent"
rm -rf "$DTK_TEST_STATE/projects/libro-7"
CASE="volume the backup does not have, directory absent: the rollback"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
hasnt "may cut volumes off"
db_is restored

stem_case "volume the backup does not have, under the storage override"
rm -rf "$DTK_TEST_STATE/projects/libro-7"
mkdir -p "$CASE_DIR/drive/libro-7"
printf '{\n  "projects_root": "%s"\n}\n' "$CASE_DIR/drive" > "$DTK_TEST_STATE/storage-override.json"
CASE="volume the backup does not have, under the storage override: the rollback"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "its files are in $CASE_DIR/drive/libro-7"
stems_untouched

# Relative roots resolve as the backend resolves them, against its working
# directory, <project>/backend (start.sh cds there), not the project root.
# A copy of the directory under the project root is not what the backend
# uses, and is placed there to show it is not the one found.
for rel in projects-root data-dir override; do
    stem_case "volume the backup does not have, relative $rel"
    rm -rf "$DTK_TEST_STATE/projects/libro-7"
    case "$rel" in
        projects-root) printf 'PROJECTS_ROOT=rel/projects\n' > "$PROJECT_ROOT/.env"; found="$PROJECT_ROOT/backend/rel/projects/libro-7" ;;
        data-dir)      printf 'DTK_DATA_DIR=rel/data\n' > "$PROJECT_ROOT/.env"; found="$PROJECT_ROOT/backend/rel/data/projects/libro-7" ;;
        override)      printf '{\n  "projects_root": "rel/drive"\n}\n' > "$DTK_TEST_STATE/storage-override.json"; found="$PROJECT_ROOT/backend/rel/drive/libro-7" ;;
    esac
    mkdir -p "$found"
    # The script names it from its own normalised project root.
    found="$(cd "$PROJECT_ROOT" && pwd)${found#"$PROJECT_ROOT"}"
    case "$rel" in
        projects-root) mkdir -p "$PROJECT_ROOT/rel/projects/libro-7" ;;
        data-dir)      mkdir -p "$PROJECT_ROOT/rel/data/projects/libro-7" ;;
        override)      mkdir -p "$PROJECT_ROOT/rel/drive/libro-7" ;;
    esac
    CASE="volume the backup does not have, relative $rel: the rollback"
    FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
    eq "$RC" 1 "exit status"
    has "id 7  \"Libro 7\"  stem libro-7: not in the backup; its files are in $found"
    stems_untouched
done

# The fallback: the dump's images cannot be read.
FAKE_DUMP_NO_IMAGES=1 FAKE_DUMP_COLLECTIONS="$DUMP_7" stem_case "dump without readable images"
CASE="dump without readable images: the rollback"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "some of them may be safe"
has "id 7  \"Libro 7\"  stem libro-7: its files are in $DTK_TEST_STATE/projects/libro-7"
if grep -qx "# dump-check: not possible; every volume with a stem directory is listed" "$DTK_TEST_STATE/$STEMS_FILE_REL"; then ok "the list file says the dump could not be checked"; else fail "the list file does not say so"; fi
list_has "7\tLibro 7\tlibro-7\tunknown\t-\t$DTK_TEST_STATE/projects/libro-7"
stems_untouched

# A current database from before the stem migration, no filename_stem.
FAKE_DUMP_COLLECTIONS="$DUMP_7" FAKE_DUMP_RECORDS="$RECORDS_7" \
FAKE_DUMP_RECORD_IMAGES="700\t70\tlibro-7-img_0001.jpg\t$NEW_PATH\tjpg\tt\t\\N\t\\N" \
    stem_case "current database without filename_stem, paths present"
: > "$DTK_TEST_STATE/projects/libro-7/captures/libro-7-img_0001.jpg"
CASE="current database without filename_stem, paths present: the rollback"
FAKE_NO_STEM_COLUMN=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
hasnt "Could not check the current database"
has "The current database predates file name stems"
db_is restored

FAKE_DUMP_COLLECTIONS="$DUMP_7" FAKE_DUMP_RECORDS="$RECORDS_7" \
FAKE_DUMP_RECORD_IMAGES="700\t70\tlibro-7-img_0001.jpg\t$OLD_PATH\tjpg\tt\t\\N\t\\N" \
    stem_case "current database without filename_stem, paths missing"
CASE="current database without filename_stem, paths missing: the rollback"
FAKE_NO_STEM_COLUMN=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
hasnt "Could not check the current database"
has "stem libro-7: 1 of 1 images not on disk"
stems_untouched
CASE="current database without filename_stem, paths missing: accepted"
FAKE_NO_STEM_COLUMN=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes --accept-lost-stems "$(dump_name)"
eq "$RC" 0 "exit status"
db_is restored

stem_case "database unreachable"
CASE="database unreachable: the rollback"
FAKE_DB_UNREACHABLE=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
has "✗ Could not check the current database for volumes with a stem directory"
has "A check that cannot answer is not a clean result"
stems_untouched

stem_case "no collections table in the current database"
CASE="no collections table in the current database: the rollback"
FAKE_STEMMED="$STEMMED_7" FAKE_NO_COLLECTIONS_TABLE=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
has "no volumes table, so no volume can lose its files"
db_is restored

stem_case "db container not running"
rm -f "$CASE_DIR/docker/db_running" "$CASE_DIR/sys/active"
CASE="db container not running: refused"
FAKE_STEMMED="$STEMMED_7" run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 1 "exit status"
logged "up -d --no-recreate db"
if [ -f "$CASE_DIR/docker/db_running" ]; then fail "the db container was left running"; else ok "the db container is stopped again"; fi
CASE="db container not running: nothing at risk"
run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
logged "up -d --no-recreate db"

# ── The stem guard and a database an interrupted restore removed ────────────
stem_case "database removed by an interrupted restore"
CASE="database removed by an interrupted restore: the rollback killed at its DROP"
FAKE_KILL_ON_DROP=1 run_again "$PROJECT_ROOT/scripts/rollback-update.sh" --yes "$(dump_name)"
marker_has "kind: restore-failed"
CASE="database removed by an interrupted restore: the retry"
FAKE_STEMMED="$STEMMED_7" FAKE_DB_ABSENT=1 run_again "$DTK_TEST_STATE/rollback-update.sh" --project-root="$PROJECT_ROOT" --yes "$(dump_name)"
eq "$RC" 0 "exit status"
has "does not exist: an interrupted restore removed it."
has "It holds no volume, so none can lose its files."
hasnt "Could not check the current database"
db_is restored
no_marker
active

# ── The db container the guard started is stopped on every abort ──────────
# run_tty <reply|EOF> <command...>: run the command on a pseudo-terminal, as
# an operator at the unit would, and answer its confirmation prompt with
# <reply>, or close the input (EOF) so that the read fails. OUT and RC as
# run_again.
run_tty() {
    local answer="$1"; shift
    : > "$CASE_DIR/log"
    OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" DTK_UPDATE_HEALTH_TIMEOUT=0 python3 -I -c '
import os, pty, sys, select, time
answer = sys.argv[1]; argv = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
out = b""; sent = False; deadline = time.time() + 120
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if not sent and b"Proceed with rollback?" in out:
        os.write(fd, b"\x04" if answer == "EOF" else (answer + "\n").encode())
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(status))
' "$answer" bash "$@" 2>&1)"
    RC=$?
    echo "$OUT" >> "$CASE_DIR/out"
}
guard_db_stopped() {
    logged "up -d --no-recreate db"
    if [ -f "$CASE_DIR/docker/db_running" ]; then fail "the db container the guard started is still running"; else ok "the db container the guard started is stopped"; fi
}
for abort in no-terminal declined read-fails; do
    stem_case "guard-started db, rollback aborted: $abort"
    rm -f "$CASE_DIR/docker/db_running" "$CASE_DIR/sys/active"
    CASE="guard-started db, rollback aborted: $abort"
    case "$abort" in
        no-terminal) run_again "$PROJECT_ROOT/scripts/rollback-update.sh" "$(dump_name)"
                     has "No terminal to confirm on" ;;
        declined)    run_tty n "$PROJECT_ROOT/scripts/rollback-update.sh" "$(dump_name)"
                     has "Aborted by operator" ;;
        read-fails)  run_tty EOF "$PROJECT_ROOT/scripts/rollback-update.sh" "$(dump_name)" ;;
    esac
    eq "$RC" 1 "exit status"
    guard_db_stopped
    unlogged "psql DROP"
done
stem_case "guard-started db, rollback confirmed"
rm -f "$CASE_DIR/docker/db_running" "$CASE_DIR/sys/active"
CASE="guard-started db, rollback confirmed"
run_tty y "$PROJECT_ROOT/scripts/rollback-update.sh" "$(dump_name)"
eq "$RC" 0 "exit status"
db_is restored
active

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

# ── The rename (6b): in the stopped window, and kept by a restore ──────────
FAKE_DOTENV="$(printf 'HOST_IP=digitool.local\nAPP_ENV=production')" \
    DTK_UPDATE_FAIL_AT=dumped run_case "fails after the rename" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
db_is schema-A
started "A A "
active
before "provision-hostname --prepare --advisory" "systemctl stop dtk"
before "systemctl stop dtk" "provision-hostname --switch --advisory"
before "provision-hostname --switch --advisory" "systemctl start dtk"
unlogged "--offline"
eq "$(grep '^HOST_IP=' "$PROJECT_ROOT/.env" 2>/dev/null)" "HOST_IP=captua.local" "the restore leaves .env as the rename wrote it"
eq "$(grep -c . "$PROJECT_ROOT/.env" 2>/dev/null)" 2 "and keeps its other line"
eq "$(sed -n 's/^state=//p' "$DTK_TEST_STATE/etc-dtk/hostname-switch" 2>/dev/null)" done "the restore leaves the record of the rename"
has "back online on the previous version"

FAKE_SWITCH_FAIL=1 run_case "rename fails" --yes
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
db_is migrated
started "A B "
active
has "The rename to captua did not finish"
has "Update complete!"
hasnt "UPDATE FAILED"

setup_no_pull_case "no-pull-online" "$SHA_A"
CASE="--no-pull: the prepare step still tries apt"
run_no_pull
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
started "A B "
logged "provision-hostname --prepare --advisory"
unlogged "--offline"
logged "provision-hostname --switch --advisory"
has "Update complete!"

setup_no_pull_case "no-pull-offline" "$SHA_A"
CASE="--no-pull --offline: prepare without apt"
run_no_pull --offline
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
logged "provision-hostname --prepare --advisory --offline"
logged "provision-hostname --switch --advisory"
has "Update complete!"

setup_no_pull_case "offline-without-no-pull" "$SHA_A"
CASE="--offline without --no-pull: refused"
OUT="$(PATH="$FAKEBIN:$PATH" SUDO_USER="$(whoami)" bash "$PROJECT_ROOT/scripts/update.sh" --offline --yes 2>&1 </dev/null)"; RC=$?
eq "$RC" 2 "exit status"
has "--offline goes with --no-pull only"
eq "$(cat "$CASE_DIR/log")" "" "nothing run"

# ── Crossing to the merged layout: built beside, then exchanged ─────────────
# The unit has what the crossing carries, .env and backend/.pixi (with a
# read-only file, a symlink and a fifo in it), and Python's caches, in the
# backend, in the environment and at the root. CROSS_SNAP then records the
# checkout as the run finds it.
CROSS_EXTRAS='mkdir -p backend/.pixi/envs/lib/__pycache__ backend/app/__pycache__
echo "CAPTUA_UNIT=bench" > .env
echo env > backend/.pixi/envs/marker
ln -s ../pixi.lock backend/.pixi/lock-link
echo secret > backend/.pixi/locked; chmod 400 backend/.pixi/locked
mkfifo backend/.pixi/pipe; chmod 660 backend/.pixi/pipe
echo cache > backend/.pixi/envs/lib/__pycache__/n.cpython-311.pyc
echo cache > backend/app/__pycache__/m.cpython-311.pyc
echo cache > stray.pyc'
CROSS_SNAP='"$FAKEBIN/tree-snapshot" "$PWD" > "$CASE_DIR/before"'
CROSS_FILES="backend/.pixi/envs/marker backend/.pixi/locked .env"
ORIGIN_URL="$(git -C "$TEMPLATE" remote get-url origin)"
FRONTEND_A="$(git -C "$TEMPLATE/frontend" rev-parse HEAD)"
GITFILE_BACKEND="$(cat "$TEMPLATE/backend/.git")"
GITFILE_FRONTEND="$(cat "$TEMPLATE/frontend/.git")"
inode() { ls -di "$1" 2>/dev/null | awk '{ print $1 }'; }
fmode() { python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))' "$1" 2>/dev/null; }
# same_as_before <dir> <what>: <dir>'s snapshot equals the one CROSS_SNAP took.
same_as_before() {
    "$FAKEBIN/tree-snapshot" "$1" > "$CASE_DIR/now" 2>&1
    if [ -s "$CASE_DIR/before" ] && cmp -s "$CASE_DIR/before" "$CASE_DIR/now"; then ok "$2 is unchanged"
    else fail "$2 changed (diff $CASE_DIR/before $CASE_DIR/now)"; fi
}
no_new()      { if [ -e "$PROJECT_ROOT.new" ]; then fail "$PROJECT_ROOT.new exists"; else ok "no .new"; fi; }
no_premerge() { if [ -e "$PROJECT_ROOT.pre-merge" ]; then fail "$PROJECT_ROOT.pre-merge exists"; else ok "no .pre-merge"; fi; }
CROSS_REC_REL="etc-dtk/crossing"
rec_step()  { sed -n 's/^step //p' "$DTK_TEST_STATE/$CROSS_REC_REL" 2>/dev/null; }
no_record() { if [ -e "$DTK_TEST_STATE/$CROSS_REC_REL" ]; then fail "a crossing record exists (step $(rec_step))"; else ok "no crossing record"; fi; }
# crossed_ok: the crossing is complete. The checkout is C on dev tracking
# origin/merged with the old origin URL, the old checkout is at .pre-merge
# (A, unchanged), the record says crossed, the start guard is set, the carried
# files have copies of their own in the new checkout, with their content and
# mode, and the caches are not there.
crossed_ok() {
    local P="$PROJECT_ROOT.pre-merge" f
    head_is "$SHA_C" C
    eq "$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>&1)" dev "on branch dev"
    eq "$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1)" origin/merged "tracking origin/merged"
    eq "$(git -C "$PROJECT_ROOT" remote get-url origin 2>&1)" "$ORIGIN_URL" "origin's URL is the old checkout's"
    eq "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no 2>&1)" "" "no tracked change in the new checkout"
    eq "$(git -C "$PROJECT_ROOT" config --get-regexp '^submodule\.' 2>&1)" "" "no submodule configuration carried over"
    if [ -e "$PROJECT_ROOT/backend/.git" ]; then fail "backend/.git is in the new checkout"; else ok "backend is a folder"; fi
    if [ -e "$PROJECT_ROOT/.captua-crossing" ]; then fail "a marker is in the checkout"; else ok "no marker in the checkout"; fi
    no_new
    eq "$(rec_step)" crossed "the record says crossed"
    eq "$(sed -n 's/^flag //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" crossing "the record says the crossing set the flag"
    if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the start flag is set"; else fail "the start flag is not set"; fi
    eq "$(git --git-dir="$P/.git" rev-parse HEAD 2>&1)" "$SHA_A" "the previous checkout, at .pre-merge, is A"
    same_as_before "$P" "the previous checkout"
    for f in $CROSS_FILES; do
        if [ -f "$PROJECT_ROOT/$f" ] && cmp -s "$PROJECT_ROOT/$f" "$P/$f" 2>/dev/null \
                && [ "$(inode "$PROJECT_ROOT/$f")" != "$(inode "$P/$f")" ] \
                && [ "$(fmode "$PROJECT_ROOT/$f")" = "$(fmode "$P/$f")" ]; then ok "$f is copied, with its content and mode"
        elif [ "$f" = backend/.pixi/locked ]; then
            # Readable by its owner only after chmod back; compare by mode and inode.
            if [ "$(fmode "$PROJECT_ROOT/$f")" = "$(fmode "$P/$f")" ] && [ "$(inode "$PROJECT_ROOT/$f")" != "$(inode "$P/$f")" ]; then ok "$f is copied, with its mode"; else fail "$f is not a copy with its mode"; fi
        else fail "$f is not a copy of its own with the same content and mode"; fi
    done
    eq "$(readlink "$PROJECT_ROOT/backend/.pixi/lock-link" 2>&1)" ../pixi.lock "the symlink is carried over, not followed"
    for f in backend/.pixi/envs/lib/__pycache__ backend/app stray.pyc; do
        if [ -e "$PROJECT_ROOT/$f" ]; then fail "$f is carried"; else ok "$f is left out (a cache)"; fi
    done
    if [ -p "$PROJECT_ROOT/backend/.pixi/pipe" ]; then ok "the fifo is recreated"; else fail "the fifo is missing"; fi
    eq "$(fmode "$PROJECT_ROOT/backend/.pixi/pipe")" 0o660 "the fifo keeps its mode 0660"
}

FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
git remote set-url origin upstream-alias:super
$CROSS_SNAP" run_case "crossing" --yes
eq "$RC" 3 "exit status (crossed, not installed)"
has "hold backend frontend as folders instead of submodules"
has "now holds the new code"
has "installs the new version and clears the flag"
crossed_ok
eq "$(git -C "$PROJECT_ROOT" config --get remote.origin.url 2>&1)" upstream-alias:super "origin's URL is carried as configured, not as rewritten"
# The start guard is set and holds: a start of dtk is skipped.
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the unresolved-deployment flag is set"; else fail "the flag is not set"; fi
has "keeps it from starting again"
# Stopped once, after the copy, immediately before the exchange step.
logged "stop at step copying"
eq "$(grep -c '^systemctl stop dtk' "$CASE_DIR/log")" 1 "one stop"
inactive
started "A "
PATH="$FAKEBIN:$PATH" systemctl start dtk
logged "condition failed: start skipped"
# A later run of this script meets the crossed record: the install is due,
# and nothing changes.
"$FAKEBIN/tree-snapshot" "$PROJECT_ROOT" > "$CASE_DIR/before"
cp "$DTK_TEST_STATE/$CROSS_REC_REL" "$CASE_DIR/record-before"
CASE="crossing: a later run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 3 "exit status (the install is due)"
has "its install"
has "is due"
hasnt "exists without its record"
same_as_before "$PROJECT_ROOT" "the new checkout"
if cmp -s "$CASE_DIR/record-before" "$DTK_TEST_STATE/$CROSS_REC_REL"; then ok "the record is unchanged"; else fail "the record changed"; fi
unlogged "git"
CASE="crossing"
# An environment tool rewrites a file in place in the new checkout: the
# previous checkout's copy does not change.
echo "rewritten" > "$PROJECT_ROOT/backend/.pixi/envs/marker"
eq "$(cat "$PROJECT_ROOT.pre-merge/backend/.pixi/envs/marker" 2>&1)" env "a file rewritten in place in the new checkout leaves the previous one's"
unlogged "build frontend"
unlogged "pixi install"

FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
echo 'hand edit' >> frontend/app
$CROSS_SNAP" run_case "crossing with a modified submodule file" --yes
eq "$RC" 3 "exit status"
has "locally modified files"
crossed_ok
eq "$(cat "$PROJECT_ROOT/frontend/app" 2>&1)" fe-B "the new checkout has C's file"
if grep -q 'hand edit' "$PROJECT_ROOT.pre-merge/frontend/app" 2>/dev/null; then ok "the previous checkout keeps the edit"; else fail "the previous checkout lost the edit"; fi
if grep -q 'hand edit' "$DTK_TEST_STATE"/local-mods-*/frontend/files/app 2>/dev/null; then
    ok "the modified file is saved"; else fail "the modified file is not saved"; fi

# Untracked or ignored paths outside the closed list (a file in a submodule,
# an ignored build folder, a directory with nothing in it, data): refused
# before anything is written, each named; the flag untouched.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
echo note > backend/operator-note.txt
mkdir -p frontend/node_modules/x backend/scratch/empty; echo m > frontend/node_modules/x/index.js
echo mine > backend/merged-only.txt
$CROSS_SNAP" run_case "crossing over files outside the list" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
has "carries only .env and backend/.pixi"
has "      backend/operator-note.txt"
has "      frontend/node_modules/x/index.js"
has "      backend/scratch/empty/"
has "      backend/merged-only.txt"
hasnt "stray.pyc"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_premerge
no_record
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag was set"; else ok "the flag is untouched"; fi
unlogged "systemctl stop"

# A carried path the new tree tracks (.env): the copy refuses, the new
# checkout is discarded, the flag untouched.
FAKE_UPSTREAM=merged-tracks-env FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing over a carried path the new tree tracks" --yes
eq "$RC" 1 "exit status"
has "      .env"
has "cannot be carried over"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag was set"; else ok "the flag is untouched"; fi

FAKE_UPSTREAM=merged-tracks-ignored FAKE_UNIT_SETUP="$CROSS_EXTRAS
mkdir -p backend/data; echo mine > backend/data/seed.txt
$CROSS_SNAP" run_case "crossing over an ignored file" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
has "backend/data/seed.txt"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

FAKE_UPSTREAM=merged-pixi-link FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing where a directory becomes a symlink" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
has "      backend/.pixi"
eq "$(ls -A "$WORK/outside")" "" "nothing is written outside the new checkout"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# A <root>.new with no record is not this procedure's: never touched. Here it
# holds only a directory named as the old marker's temporary file, with data.
FOREIGN_NEW='mkdir -p ../dtk.new/.captua-crossing.tmp; echo foreign > ../dtk.new/.captua-crossing.tmp/keep'
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$FOREIGN_NEW
$CROSS_SNAP" run_case "crossing beside a foreign .new" --yes
eq "$RC" 1 "exit status"
has "there is no record of this script having made it"
eq "$(cat "$PROJECT_ROOT.new/.captua-crossing.tmp/keep" 2>&1)" foreign "the foreign directory is left as it was"
same_as_before "$PROJECT_ROOT" "the checkout"
no_premerge
no_record

FAKE_UNIT_SETUP="$FOREIGN_NEW" run_case "update beside a foreign .new" --yes
eq "$RC" 0 "exit status"
head_is "$SHA_B" B
has "Update complete!"
hasnt "An earlier update"
eq "$(cat "$PROJECT_ROOT.new/.captua-crossing.tmp/keep" 2>&1)" foreign "the foreign directory is left as it was"

# Refused before anything is written: a symlinked checkout root, an absolute
# gitfile, borrowed objects.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP='cd .. && mv dtk dtk-real && ln -s dtk-real dtk' \
    run_case "crossing from a symlinked root" --yes
eq "$RC" 1 "exit status"
has "is a symlink"
has "Nothing has been changed"
if [ -L "$PROJECT_ROOT" ] && [ -d "$CASE_DIR/dtk-real/.git" ]; then ok "the symlink and the checkout are as they were"; else fail "the root was changed"; fi
eq "$(git -C "$CASE_DIR/dtk-real" rev-parse HEAD 2>&1)" "$SHA_A" "the checkout is A"
if [ -e "$PROJECT_ROOT.new" ] || [ -e "$CASE_DIR/dtk-real.new" ]; then fail "a .new was made"; else ok "no .new"; fi
no_record

FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
printf 'gitdir: %s\n' \"\$PWD/.git/modules/backend\" > backend/.git
$CROSS_SNAP" run_case "crossing with an absolute gitfile" --yes
eq "$RC" 1 "exit status"
has "backend/.git names its repository by an absolute path"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
mkdir -p .git/objects/info; echo \"\$PWD/.git/modules/backend/objects\" > .git/objects/info/alternates
$CROSS_SNAP" run_case "crossing with alternates" --yes
eq "$RC" 1 "exit status"
has ".git/objects/info/alternates exists"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# A stop (SIGKILL, which no trap sees) after each step, then a fresh run.
for point in cross-recorded cross-built cross-copied cross-stopped cross-synced cross-exchanged cross-renamed cross-crossed; do
    DTK_UPDATE_KILL_AT="$point" FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing killed at $point" --yes
    eq "$RC" 137 "exit status"
    case "$point" in
        cross-recorded)
            eq "$(rec_step)" building "the record says building"
            no_new ;;
        cross-built)
            eq "$(rec_step)" building "the record says building"
            eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_C" ".new is the clone" ;;
        cross-copied)
            eq "$(rec_step)" copying "the record says copying" ;;
        cross-stopped)
            eq "$(rec_step)" copying "the record says copying"
            inactive ;;
        cross-crossed)
            eq "$(rec_step)" crossed "the record says crossed"
            head_is "$SHA_C" "C (crossed)" ;;
        cross-synced)
            eq "$(rec_step)" exchanging "the record says exchanging"
            eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_C" ".new is the new checkout, not exchanged" ;;
        cross-exchanged)
            eq "$(rec_step)" exchanging "the record says exchanging"
            head_is "$SHA_C" "C (exchanged)"
            eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_A" ".new holds the previous checkout" ;;
        cross-renamed)
            eq "$(rec_step)" renaming "the record says renaming"
            head_is "$SHA_C" "C (exchanged)"
            no_new
            eq "$(git --git-dir="$PROJECT_ROOT.pre-merge/.git" rev-parse HEAD 2>&1)" "$SHA_A" ".pre-merge holds the previous checkout" ;;
    esac
    case "$point" in
        cross-recorded|cross-built|cross-copied|cross-stopped|cross-synced)
            head_is "$SHA_A" A
            same_as_before "$PROJECT_ROOT" "the checkout"
            no_premerge ;;
    esac
    CASE="crossing killed at $point: the next run"
    FAKE_HEALTHY_VERSIONS="A B C" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
    case "$point" in
        cross-recorded|cross-built|cross-copied|cross-stopped)
            has "An earlier update stopped while building the new checkout"
            eq "$RC" 3 "exit status (crossed again)" ;;
        cross-crossed)
            has "is due"
            eq "$RC" 3 "exit status (the install is due)" ;;
        cross-synced)
            has "An earlier update stopped at the exchange"
            has "The exchange had not happened"
            eq "$RC" 3 "exit status (crossed again)" ;;
        *)
            has "The crossing to the merged layout is complete"
            has "is due"
            eq "$RC" 3 "exit status (the install is due)"
            hasnt "An earlier update stopped while building" ;;
    esac
    crossed_ok
done

# A stop after the record and before the mkdir (no .new, no newid), then a
# run killed during the discard that settles it, then a run that settles
# it. A discard of a .new never made never writes discarding: the record
# stays at building, the one step an empty newid is valid at.
DTK_UPDATE_KILL_AT=cross-recorded FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a discard of a .new never made" --yes
eq "$RC" 137 "exit status"
eq "$(rec_step)" building "the record says building"
eq "$(sed -n 's/^newid //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" "" "the record has no newid"
CASE="a discard of a .new never made: killed during the discard"
DTK_UPDATE_KILL_AT=cross-discard-synced run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 137 "exit status"
has "(step: building)"
case "$(rec_step)" in
    building|"") ok "the record is at building or removed" ;;
    *) fail "the record says $(rec_step)" ;;
esac
no_new
head_is "$SHA_A" A
CASE="a discard of a .new never made: the next run"
FAKE_HEALTHY_VERSIONS="A B C" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
hasnt "a crossing record this script cannot use"
eq "$RC" 3 "exit status (crossed)"
crossed_ok

# crossing_begin_attempt and crossing_clear_attempt set the same variables.
CASE="the attempt's variables"
fn_vars() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" { p = 1; next } p && /^}/ { exit } p { sub(/^ +/, ""); sub(/=.*/, ""); print }' "$SCRIPTS/update.sh" | sort; }
BEGIN_VARS="$(fn_vars crossing_begin_attempt | tr '\n' ' ')"
eq "$(fn_vars crossing_clear_attempt | tr '\n' ' ')" "$BEGIN_VARS" "crossing_clear_attempt empties what crossing_begin_attempt sets"
case "$BEGIN_VARS" in
    *CROSS_FLAG*CROSS_SERVICE*) ok "the attempt's variables include CROSS_FLAG and CROSS_SERVICE" ;;
    *) fail "crossing_begin_attempt does not set CROSS_FLAG and CROSS_SERVICE ($BEGIN_VARS)" ;;
esac

# A crossing killed at cross-synced (its record says flag crossing, service
# stopped); the next run settles it and starts a fresh crossing, killed at
# cross-recorded; the run after that settles the fresh one and crosses. The
# fresh attempt's record carries its own initial values, not the settled
# attempt's.
DTK_UPDATE_KILL_AT=cross-synced FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a fresh attempt after a settled one" --yes
eq "$RC" 137 "exit status"
eq "$(rec_step)" exchanging "the record says exchanging"
eq "$(sed -n 's/^flag //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" crossing "the record says flag crossing"
eq "$(sed -n 's/^service //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" stopped "the record says service stopped"
CASE="a fresh attempt after a settled one: settled, then a fresh crossing killed"
DTK_UPDATE_KILL_AT=cross-recorded FAKE_HEALTHY_VERSIONS="A B C" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 137 "exit status"
has "The exchange had not happened"
eq "$(rec_step)" building "the fresh record says building"
eq "$(sed -n 's/^flag //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" none "the fresh record says flag none"
eq "$(sed -n 's/^service //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" untouched "the fresh record says service untouched"
eq "$(sed -n 's/^newid //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" "" "the fresh record has no newid"
no_new
head_is "$SHA_A" A
CASE="a fresh attempt after a settled one: the next run"
FAKE_HEALTHY_VERSIONS="A B C" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
hasnt "a crossing record this script cannot use"
hasnt "names no identity"
eq "$RC" 3 "exit status (crossed)"
crossed_ok

# The exchange helper dies just after a successful exchange, the script
# alive: the directories show the exchange happened, so it is finished and
# nothing is removed.
DTK_UPDATE_KILL_AT=cross-exchange-helper FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing whose exchange helper dies" --yes
eq "$RC" 3 "exit status (crossed)"
has "Reading the directories to see whether it happened"
crossed_ok

# A stop in the middle of a discard (the record says discarding, part of
# .new is gone), then a fresh run, which resumes it.
DTK_UPDATE_KILL_AT=cross-discarding FAKE_UPSTREAM=merged-tracks-env FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing killed during the discard" --yes
eq "$RC" 137 "exit status"
eq "$(rec_step)" discarding "the record says discarding"
if [ -d "$PROJECT_ROOT.new" ] && [ ! -e "$PROJECT_ROOT.new/.git" ]; then ok ".new is part-removed"; else fail ".new is not part-removed"; fi
g -C "$PROJECT_ROOT" remote set-url origin "$WORK/nonexistent"
CASE="crossing killed during the discard: the next run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status (then the fetch fails)"
has "(step: discarding)"
has "Could not reach the remote"
no_new
no_record
head_is "$SHA_A" A

# Something else at <root>.new when the record names it: a symlink to the
# checkout itself (the record has no identity for .new yet), and a directory
# that is not the one the mkdir made. Both are left alone, and the run
# refuses with the record kept.
DTK_UPDATE_KILL_AT=cross-recorded FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a symlink to the root at .new" --yes
eq "$RC" 137 "exit status"
ln -s dtk "$PROJECT_ROOT.new"
CASE="a symlink to the root at .new: the next run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "is not the directory this script made"
same_as_before "$PROJECT_ROOT" "the live checkout"
head_is "$SHA_A" A
if [ -L "$PROJECT_ROOT.new" ]; then ok "the symlink is left as it is"; else fail "the symlink was removed"; fi
eq "$(rec_step)" building "the record is kept"

DTK_UPDATE_KILL_AT=cross-built FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "another directory at .new" --yes
eq "$RC" 137 "exit status"
mv "$PROJECT_ROOT.new" "$PROJECT_ROOT.new-moved"; mkdir "$PROJECT_ROOT.new"; echo keep > "$PROJECT_ROOT.new/keep"
CASE="another directory at .new: the next run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "is not the directory this script made"
eq "$(cat "$PROJECT_ROOT.new/keep" 2>&1)" keep "the other directory is left as it is"
same_as_before "$PROJECT_ROOT" "the live checkout"
eq "$(rec_step)" building "the record is kept"

# The record's directory must be root's alone: a symlink, or mode 0755, is
# refused before anything is written.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
mkdir -p \"\$CASE_DIR/state\" \"\$CASE_DIR/elsewhere\"; chmod 700 \"\$CASE_DIR/elsewhere\"
ln -s \"\$CASE_DIR/elsewhere\" \"\$CASE_DIR/state/etc-dtk\"
$CROSS_SNAP" run_case "the record's directory is a symlink" --yes
eq "$RC" 1 "exit status"
has "must be a directory (not a symlink)"
eq "$(ls -A "$CASE_DIR/elsewhere")" "" "nothing is written where the symlink points"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new

FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
mkdir -p \"\$CASE_DIR/state/etc-dtk\"; chmod 755 \"\$CASE_DIR/state/etc-dtk\"
$CROSS_SNAP" run_case "the record's directory is 0755" --yes
eq "$RC" 1 "exit status"
has "with mode 0700"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# Configuration outside the closed list is refused, by name.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
git config include.path unit-auth.conf
git config url.https://mirror.invalid/.insteadOf https://
git config core.sshCommand 'ssh -i /home/pi/dtk/.git/unit-key'
$CROSS_SNAP" run_case "crossing with configuration it does not carry" --yes
eq "$RC" 1 "exit status"
has "sets keys the crossing does not carry over"
has "include.path"
has "url.https://mirror.invalid/.insteadof"
has "core.sshcommand"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# The start guard: set at the exchange step (a stop there leaves it set),
# not before (a stop at the copy leaves it unset); when the exchange had not
# happened the next run's discard clears it. No crossing stops the service.
DTK_UPDATE_KILL_AT=cross-copied FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "the flag is not set before the exchange step" --yes
eq "$RC" 137 "exit status"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag is set"; else ok "the flag is not set"; fi
unlogged "systemctl stop"

DTK_UPDATE_KILL_AT=cross-synced FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "the flag is set at the exchange step" --yes
eq "$RC" 137 "exit status"
eq "$(rec_step)" exchanging "the record says exchanging"
eq "$(sed -n 's/^flag //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" crossing "the record says the crossing set the flag"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the flag is set"; else fail "the flag is not set"; fi
if [ -f "$DTK_TEST_STATE/systemd/dtk.service.d/unresolved.conf" ]; then ok "the start condition is installed"; else fail "the start condition is not installed"; fi
logged "stop at step copying"
g -C "$PROJECT_ROOT" remote set-url origin "$WORK/nonexistent"
CASE="the flag is set at the exchange step: the next run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status (then the fetch fails)"
has "The exchange had not happened"
hasnt "exists without its record"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag is still set"; else ok "the flag the crossing set is cleared"; fi
no_record
no_new
head_is "$SHA_A" A

# Identities are the filesystem's UUID and the inode number: the record holds
# them; a next run on the same filesystem (same UUID, whatever its device
# number) finishes the crossing; one on a filesystem with another UUID is not
# recognised, and nothing is moved.
DTK_UPDATE_KILL_AT=cross-exchanged FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "identity is the filesystem UUID and the inode" --yes
eq "$RC" 137 "exit status"
case "$(sed -n 's/^rootid //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" in
    test-uuid:[0-9]*) ok "the record names the root by UUID and inode" ;;
    *) fail "the record's root identity is not UUID:inode" ;;
esac
CASE="identity is the filesystem UUID and the inode: another UUID"
FAKE_FSUUID=other-uuid run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "Nothing"
eq "$(rec_step)" exchanging "the record is kept"
eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_A" ".new still holds the previous checkout"
CASE="identity is the filesystem UUID and the inode: the same UUID"
FAKE_HEALTHY_VERSIONS="A B C" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
has "The crossing to the merged layout is complete"
crossed_ok

# A submodule whose repository is not under the checkout's .git/modules (here
# beside the checkout, with a worktree that names the checkout's folder):
# refused, naming the gitfile.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
cp -R .git/modules/backend ../backend-repo
printf 'gitdir: ../../backend-repo\n' > backend/.git
git config --file ../backend-repo/config core.worktree ../dtk/backend
$CROSS_SNAP" run_case "crossing with a submodule repository outside the checkout" --yes
eq "$RC" 1 "exit status"
has "backend/.git names a repository that is not"
has ".git/modules/backend: it would not move with"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# The service is stopped only immediately before the exchange step (after
# the copy), so that the running backend cannot import the new code; a stop
# that fails means no exchange.
FAKE_UPSTREAM=merged FAKE_STOP_FAIL=1 FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing whose stop fails" --yes
eq "$RC" 1 "exit status"
has "The service did not stop"
logged "systemctl stop dtk"
active
started "A "
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag was set"; else ok "the flag is untouched"; fi

FAKE_UPSTREAM=merged FAKE_PGREP_STUCK=1 FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing whose backend survives the stop" --yes
eq "$RC" 1 "exit status"
has "The service did not stop"
has "Starting the service again, on the previous version"
started "A A "
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# SIGTERM at each step from the stop on. Before the exchange: the new
# checkout discarded, the service started again, the root the previous
# checkout. From the exchange on: the crossing finished to crossed, nothing
# restored, the service left down.
for point in cross-stopped cross-synced cross-exchanged cross-renamed cross-crossed; do
    DTK_UPDATE_KILL_AT="term:$point" FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "SIGTERM at $point" --yes
    eq "$RC" 143 "exit status"
    hasnt "UPDATE FAILED"
    hasnt "Putting back what it"
    case "$point" in
        cross-stopped|cross-synced)
            head_is "$SHA_A" A
            same_as_before "$PROJECT_ROOT" "the checkout"
            started "A A "
            active
            if [ "$point" = cross-stopped ]; then
                # The record at copying and its .new are the next run's to remove.
                eq "$(rec_step)" copying "the record says copying"
            else
                no_new
                no_record
            fi
            if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag is set"; else ok "no flag"; fi ;;
        *)
            head_is "$SHA_C" "C (crossed)"
            eq "$(rec_step)" crossed "the record says crossed"
            has "nothing is restored"
            started "A "
            inactive
            eq "$(git --git-dir="$PROJECT_ROOT.pre-merge/.git" rev-parse HEAD 2>&1)" "$SHA_A" ".pre-merge holds the previous checkout"
            if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then ok "the flag is set"; else fail "no flag"; fi ;;
    esac
done

# A path that appears while the new checkout is being built (here during the
# clone): the second listing refuses it, and the new checkout is discarded
# before the service is stopped.
FAKE_UPSTREAM=merged FAKE_ON_CLONE='echo late > "$PROJECT_ROOT/backend/late-export.txt"' FAKE_UNIT_SETUP="$CROSS_EXTRAS" \
    run_case "a file appears during the crossing" --yes
eq "$RC" 1 "exit status"
has "appeared in the checkout while the new"
has "      backend/late-export.txt"
unlogged "systemctl stop"
active
no_new
no_record
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag was set"; else ok "the flag is untouched"; fi

# git failing to list a submodule's untracked files: refused, not read as
# an empty list.
FAKE_UPSTREAM=merged FAKE_FAIL_LSFILES=backend FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a submodule's listing fails" --yes
eq "$RC" 1 "exit status"
has "git could not list the checkout's untracked and ignored files"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# A stop after the crossing stopped the service and before the exchange:
# the record says so, and the next run's discard starts the service again
# (here a next run whose fetch then fails).
DTK_UPDATE_KILL_AT=cross-stopped FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "killed after the stop, then a next run" --yes
eq "$RC" 137 "exit status"
inactive
eq "$(sed -n 's/^service //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" stopped "the record says the crossing stopped the service"
g -C "$PROJECT_ROOT" remote set-url origin "$WORK/nonexistent"
CASE="killed after the stop, then a next run: the next run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status (then the fetch fails)"
has "Starting the service again, on the previous version"
has "Could not reach the remote"
active
started "A A "
no_record
no_new
head_is "$SHA_A" A

# The service cannot be started again after such a discard: the record is
# kept at discarded (.new gone, flag clear) and the run fails; the next run
# tries again and removes the record once the service runs.
DTK_UPDATE_KILL_AT=cross-stopped FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a restart that fails after a discard" --yes
eq "$RC" 137 "exit status"
g -C "$PROJECT_ROOT" remote set-url origin "$WORK/nonexistent"
CASE="a restart that fails after a discard: the next run"
FAKE_START_FAIL=1 run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "could not be started again"
has "sudo systemctl start dtk"
eq "$(rec_step)" discarded "the record is kept at discarded"
eq "$(sed -n 's/^service //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" stopped "it still says the crossing stopped the service"
no_new
inactive
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag is set"; else ok "no flag"; fi
CASE="a restart that fails after a discard: the run after"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status (then the fetch fails)"
has "could not start the"
has "The service is running again, and the record is removed"
has "Could not reach the remote"
active
no_record
head_is "$SHA_A" A

# A path the backend creates while .env and backend/.pixi are copied (here
# as the service stops): the third check, with the service stopped, refuses
# it; the new checkout is discarded and the service started again.
FAKE_UPSTREAM=merged FAKE_ON_STOP='echo late > "$PROJECT_ROOT/backend/export-during-copy.json"' FAKE_UNIT_SETUP="$CROSS_EXTRAS" \
    run_case "a file appears during the copy" --yes
eq "$RC" 1 "exit status"
has "appeared in the checkout while .env"
has "      backend/export-during-copy.json"
started "A A "
active
no_new
no_record
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag was set"; else ok "the flag is untouched"; fi

# With the flag set, a crossing record that is a fifo, or a symlink: refused
# at the start, without reading it (no hang).
for kind in fifo symlink; do
    run_case "a $kind at the crossing record" --yes
    mkdir -p "$DTK_TEST_STATE/etc-dtk"; chmod 700 "$DTK_TEST_STATE/etc-dtk"
    : > "$DTK_TEST_STATE/etc-dtk/unresolved-deployment"
    if [ "$kind" = fifo ]; then mkfifo "$DTK_TEST_STATE/etc-dtk/crossing"
    else mkfifo "$CASE_DIR/elsewhere"; ln -s "$CASE_DIR/elsewhere" "$DTK_TEST_STATE/etc-dtk/crossing"; fi
    CASE="a $kind at the crossing record: update.sh refuses"
    # A watchdog: a reader of the fifo is let go after 20 seconds.
    fifo="$DTK_TEST_STATE/etc-dtk/crossing"; [ "$kind" = fifo ] || fifo="$CASE_DIR/elsewhere"
    started_at=$(date +%s)
    perl -e 'sleep 20; alarm 5; open(my $f, ">", $ARGV[0]);' "$fifo" & watchdog=$!
    run_again "$PROJECT_ROOT/scripts/update.sh" --yes
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    if [ $(( $(date +%s) - started_at )) -lt 15 ]; then ok "no wait on the record"; else fail "the run waited on the record"; fi
    eq "$RC" 1 "exit status"
    has "is not a crossing"
    has "record this script can read"
done

# Another directory at the recorded .new with the same inode number (the old
# one removed, the number used again): its inode generation differs, so it
# is not this procedure's, and is left alone.
DTK_UPDATE_KILL_AT=cross-built FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "an inode number used again at .new" --yes
eq "$RC" 137 "exit status"
case "$(sed -n 's/^newid //p' "$DTK_TEST_STATE/$CROSS_REC_REL")" in
    test-uuid:[0-9]*:1) ok "the record names .new by UUID, inode and generation" ;;
    *) fail "the record's .new identity is not UUID:inode:generation" ;;
esac
CASE="an inode number used again at .new: the next run"
FAKE_GENERATIONS="$(cd "$CASE_DIR" && pwd -P)/dtk.new=2" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "is not the directory this script made"
eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_C" ".new is left as it is"
eq "$(rec_step)" building "the record is kept"

# A .gitmodules entry ahead of the real one that names the backend's
# repository by a path out of .git/modules ("../../../backend.git"), with
# that repository beside the checkout: refused.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
cp -R .git/modules/backend ../backend.git
printf 'gitdir: ../../backend.git\n' > backend/.git
git config --file ../backend.git/config core.worktree ../dtk/backend
{ printf '[submodule \"../../../backend.git\"]\n\tpath = backend\n\turl = x\n'; cat .gitmodules; } > gm.tmp && mv gm.tmp .gitmodules
$CROSS_SNAP" run_case "a .gitmodules name that leaves .git/modules" --yes
eq "$RC" 1 "exit status"
has "2 entries in .gitmodules claim the path backend"
no_new
no_record

# The identity of .new cannot be read right after its mkdir: the crossing
# stops there, before the stop of the service, with .new removed and no
# record left (none past building).
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" FAKE_GEN_FAIL="$WORK/cases/the_identity_of_.new_cannot_be_read/dtk.new" \
    run_case "the identity of .new cannot be read" --yes
eq "$RC" 1 "exit status"
has "could not be read, so the crossing stops"
unlogged "systemctl stop"
active
no_new
no_record
same_as_before "$PROJECT_ROOT" "the checkout"
if [ -e "$DTK_TEST_STATE/etc-dtk/unresolved-deployment" ]; then fail "the flag was set"; else ok "no flag"; fi

# Empty identities never compare equal: an identity that cannot be read, or
# an empty recorded one, matches nothing.
CASE="empty identities"
CASE_DIR="$WORK/cases/empty-identities"; mkdir -p "$CASE_DIR/d"
{
    echo 'run_as_repo_owner() { "$@"; }'
    echo 'CROSS_GEN_READER=fake'
    for fn in crossing_id crossing_id_wellformed crossing_id_is; do
        awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" { p = 1 } p { print } p && /^}/ { exit }' "$SCRIPTS/update.sh"
    done
    echo 'crossing_id_is "$1/d" "" && echo "empty matches a readable directory"'
    echo 'crossing_id_is "$1/missing" "" && echo "empty matches a missing directory"'
    echo 'FAKE_GEN_FAIL="$(cd "$1/d" && pwd -P)" crossing_id_is "$1/d" "" && echo "empty matches an unreadable identity"'
    echo 'id="$(crossing_id "$1/d")" && crossing_id_is "$1/d" "$id" && echo "a full identity matches itself"'
    echo 'FAKE_GEN_FAIL="$(cd "$1/d" && pwd -P)" crossing_id "$1/d"; echo "unreadable status: $?"'
} > "$CASE_DIR/ids.sh"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$CASE_DIR/ids.sh" "$CASE_DIR" 2>&1)"
hasnt "empty matches"
has "a full identity matches itself"
has "unreadable status: 1"

# A record past building whose newid is empty: refused, nothing touched.
DTK_UPDATE_KILL_AT=cross-copied FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a record with an empty newid" --yes
eq "$RC" 137 "exit status"
rec="$DTK_TEST_STATE/$CROSS_REC_REL"
body="$(sed 's/^newid .*/newid /' "$rec")"; printf '%s\n' "$body" > "$rec"
CASE="a record with an empty newid: the next run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "a crossing record this script cannot use"
has "Its rootid or newid is empty or not a UUID:inode:generation"
eq "$(rec_step)" copying "the record is kept"
eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_C" ".new is left as it is"

# A copy of the filesystem mounted at the recorded .new (the same UUID and
# inode numbers, another mount): not this procedure's directory, left alone.
DTK_UPDATE_KILL_AT=cross-built FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a filesystem mounted at .new" --yes
eq "$RC" 137 "exit status"
CASE="a filesystem mounted at .new: the next run"
FAKE_MOUNTPOINT="$(cd "$CASE_DIR" && pwd -P)/dtk.new" run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "is not the directory this script made"
eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_C" ".new is left as it is"
eq "$(rec_step)" building "the record is kept"
same_as_before "$PROJECT_ROOT" "the checkout"

# A submodule's .git/modules/<name> that is a symlink to a repository
# elsewhere: refused.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
mv .git/modules/backend ../backend.git
ln -s \"\$(cd .. && pwd -P)/backend.git\" .git/modules/backend
git config --file ../backend.git/config core.worktree ../dtk/backend
$CROSS_SNAP" run_case "crossing with a symlinked module repository" --yes
eq "$RC" 1 "exit status"
has ".git/modules/backend is not a directory inside"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# Not ext4: refused (the type read is the fake findmnt).
FAKE_UPSTREAM=merged FAKE_FSTYPE=btrfs FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "crossing on btrfs" --yes
eq "$RC" 1 "exit status"
has "is on btrfs, not ext4"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

# A submodule's repository naming its working tree by an absolute path, or
# by a relative path other than git's: refused.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
git config --file .git/modules/backend/config core.worktree \"\$PWD/backend\"
$CROSS_SNAP" run_case "crossing with an absolute core.worktree" --yes
eq "$RC" 1 "exit status"
has "sets core.worktree to '"
has "relative path '../../../backend'"
same_as_before "$PROJECT_ROOT" "the checkout"
no_new
no_record

FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
git config --file .git/modules/frontend/config core.worktree ../../../../dtk/frontend
$CROSS_SNAP" run_case "crossing with another relative core.worktree" --yes
eq "$RC" 1 "exit status"
has "relative path '../../../frontend'"
no_new

# A stale renaming record with the root at an unexpected HEAD: the whole
# state is checked first, so nothing is moved.
DTK_UPDATE_KILL_AT=cross-exchanged FAKE_UPSTREAM=merged FAKE_UNIT_SETUP="$CROSS_EXTRAS
$CROSS_SNAP" run_case "a stale renaming record" --yes
eq "$RC" 137 "exit status"
rec="$DTK_TEST_STATE/$CROSS_REC_REL"
body="$(sed 's/^step exchanging$/step renaming/' "$rec")"; printf '%s\n' "$body" > "$rec"
git -C "$PROJECT_ROOT" update-ref refs/heads/dev "$SHA_B"
CASE="a stale renaming record: the next run"
run_again "$PROJECT_ROOT/scripts/update.sh" --yes
eq "$RC" 1 "exit status"
has "Nothing"
has "has been moved"
eq "$(git --git-dir="$PROJECT_ROOT.new/.git" rev-parse HEAD 2>&1)" "$SHA_A" ".new still holds the previous checkout"
no_premerge
eq "$(rec_step)" renaming "the record is kept"

# A healthy unit with local work, as Codex's third round found it destroyed:
# a deleted tracked file in a submodule and a staged edit in the
# superproject. No run has crossed, so there is no crossing state: the start
# changes nothing, and the fetch fails before anything else.
FAKE_UPSTREAM=merged FAKE_BREAK_ORIGIN=1 FAKE_UNIT_SETUP="rm frontend/app
echo 'staged edit' >> README; git add README
$CROSS_SNAP" run_case "local work is not a crossing state" --yes
eq "$RC" 1 "exit status"
has "Could not reach the remote"
hasnt "An earlier update"
same_as_before "$PROJECT_ROOT" "the checkout, its deletion and its staged edit"
eq "$(git -C "$PROJECT_ROOT" diff --cached --name-only 2>&1)" README "the edit is still staged"
if [ -e "$PROJECT_ROOT/frontend/app" ]; then fail "the deleted file is back"; else ok "the deleted file is still deleted"; fi
no_new
no_premerge
no_record

# The same refusal on an update that does not cross: an ignored file at a
# path the new commit tracks.
FAKE_UPSTREAM=tracks-ignored FAKE_UNIT_SETUP='mkdir -p _data; echo mine > _data/seed.txt' \
    run_case "update over an ignored file" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
eq "$(cat "$PROJECT_ROOT/_data/seed.txt" 2>/dev/null)" mine "the ignored file is unchanged"
has "_data/seed.txt"
has "code: still on $SHA_A with submodules on its pins"
hasnt "hold backend"
unlogged "build frontend"

# Refused before anything is built: a submodule off its pin, and a file git
# is told not to report.
FAKE_UPSTREAM=merged FAKE_UNIT_SETUP='git -C backend checkout -q "$BACKEND_B"' \
    run_case "crossing refused: a submodule off its pin" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
eq "$(git -C "$PROJECT_ROOT/backend" rev-parse HEAD 2>/dev/null)" "$BACKEND_B" "backend left where it was"
eq "$(cat "$PROJECT_ROOT/backend/.git" 2>/dev/null)" "$GITFILE_BACKEND" "backend's gitfile untouched"
has "A submodule is not on the commit HEAD records"
has "Nothing has been changed"
no_new
unlogged "build frontend"

FAKE_UPSTREAM=merged FAKE_UNIT_SETUP='git -C frontend update-index --assume-unchanged app; echo edit >> frontend/app' \
    run_case "crossing refused: an assume-unchanged file" --yes
eq "$RC" 1 "exit status"
head_is "$SHA_A" A
if grep -qx edit "$PROJECT_ROOT/frontend/app" 2>/dev/null; then ok "the edit is kept"; else fail "the edit is lost"; fi
has "assume-unchanged or skip-worktree"
has "Nothing has been changed"
no_new
unlogged "build frontend"

# ── The test-only switch refuses an unknown point ───────────────────────────
DTK_UPDATE_FAIL_AT=nowhere run_case "unknown failure point" --yes
eq "$RC" 2 "exit status"
head_is "$SHA_A" A
has "is not a failure point"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
