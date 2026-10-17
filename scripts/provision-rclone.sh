#!/bin/bash
# provision-rclone.sh — pinned rclone binary + per-unit B2 remote for the
# offsite catalogue backup (NEH-249, NEH-227). Idempotent: safe to re-run on
# every provision and every update.
#
# One copy, meant to be called from both scripts/setup.sh (first-time
# provisioning) and scripts/update.sh, for the same reason
# provision-chdk-usb.sh is: update.sh is the supported way an appliance
# already in the field moves forward, and it never runs setup.sh again. An
# appliance upgraded to a release whose backend uploads through rclone, but
# which never got the binary, would fail every backup attempt with something
# that reads like a credentials problem.
#
# setup.sh calls it plainly (its step 6e); update.sh calls it with --advisory
# (its step 4c), beside the provision-chdk-usb.sh call that exists for the
# same reason.
#
# ── WHAT THIS SCRIPT REPORTS, AND WHAT IT DOES NOT ──────────────────────────
#
# It reports WHAT THIS RUN DID. It does not report whether offsite backup
# works.
#
# That narrowing (2026-10-16) is why this file is shorter than it was.
# Predicting whether backup works means computing the effective state of the
# configuration: what python-dotenv will read out of .env and offsite.env
# together, what rclone will read out of its own config, and what the backend
# will therefore do. From in here that means reimplementing two parsers this
# script does not own, in bash, and keeping them in step with both upstreams.
# Five review rounds put blockers in exactly those lines, and each individual
# fix was correct — the arithmetic was the problem, not the fixes.
#
# So: this script says which rclone it accepted, whether it wrote a credential
# section and for which remote, whether the listing probe succeeded, and what
# it recorded in offsite.env. Whether a backup has actually run and been
# verified is a question about this unit's own backup records, and the Captua
# interface is where that is reported. Nothing here predicts it.
#
# Two separate jobs, in this order, because the second is optional and the
# first is not:
#
#   1. Install a pinned rclone and ASSERT its version. apt's rclone on
#      Bookworm is 1.60, which fails B2 authentication for application keys
#      created after mid-2024: the request is refused in a way that looks
#      exactly like a wrong key. That cost a day once already (NEH-227), so
#      this script refuses to finish on a too-old rclone rather than leaving
#      one in place — the same stance install-kiosk-service.sh takes when
#      triggerhappy cannot be installed. A silent fall back to 1.60 is the
#      outcome this whole script exists to prevent.
#
#   2. Write the per-unit rclone remote, IF and ONLY IF key material was
#      supplied, and record the settings in /var/lib/dtk/offsite.env. No key
#      material means no remote. It never invents, guesses or defaults a
#      credential, and it never replaces an existing one.
#
#      It does NOT read or write the project .env, in either direction, for
#      any purpose — not for settings, and no longer even for a read-only
#      report. That file has another writer (generate-secrets.sh rotates the
#      database password through it) and is not written in a grammar this
#      script can track: every attempt to read it produced a wrong statement
#      about the unit, from a read failure that became empty data to an empty
#      quoted value that came back as two literal quote characters.
#      .env.example's own offsite section records the division: this script
#      writes the three keys to offsite.env, the backend reads that file in
#      addition to .env, and offsite.env wins on a conflict.
#
# Network use: none at all when a new-enough rclone is already installed AND
# no new credential is being written. Writing a credential adds one listing
# call against the bucket, which is skipped when the unit is offline. Both
# provisioning and updates happen on units that may have no connectivity,
# which is why update.sh carries its own internet-honesty check.
#
# Does not start, stop or restart the dtk service: callers manage that on
# their own schedule and this script must not add a restart neither of them
# is already doing.
#
# Called by scripts/setup.sh; can also be run standalone:
#   sudo ./scripts/provision-rclone.sh
#
# --advisory changes ONE thing: the exit status when provisioning fails. The
# diagnosis printed is identical and nothing is skipped quietly.
#
#   setup.sh calls it plainly. At provisioning the hard exit is correct: a
#   unit that cannot end up with a working rclone should not be handed to an
#   archive as provisioned.
#
#   update.sh must call it with --advisory. There the cost inverts. A field
#   unit that is merely offline, updating to a release whose dependency
#   manifests did not move, would otherwise abort an otherwise fine update
#   over a feature that is disabled on that unit until it has a key. The
#   NEH-214/215/216/218 cluster exists because failed updates on remote units
#   are expensive; an appliance in an archive losing its update because a
#   backup binary could not be fetched is a worse outcome than that backup
#   staying unprovisioned for another week.
#
#   The contract is enforced by a trap on ERR, not by routing the failure
#   paths this script happens to know about. Under `set -euo pipefail` an
#   unguarded command that fails never reaches a handler at all: counting the
#   explicit exits says nothing about the implicit ones, and an unzip that
#   returns 50 would otherwise abort an update that --advisory was added
#   specifically to protect.
#
# Key material, when there is any, is supplied in a FILE, not on the command
# line — see the instructions this script prints when none is present.
# Exported environment variables are still accepted for a caller that has set
# them up properly in its own shell.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADVISORY=0
# Relocates every path this script writes under one directory. It is an
# ARGUMENT and not an environment variable on purpose: update.sh exports every
# .env key before calling this script, so an environment-variable override
# could be steered by a line in .env, which is exactly how the install
# destination once came to be the bare word `rclone`. argv cannot be reached
# that way. Used by the dry runs, and usable by hand against a staging tree.
PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --advisory) ADVISORY=1 ;;
        --prefix)
            if [ $# -lt 2 ]; then
                echo "✗ provision-rclone.sh: --prefix needs a directory."
                exit 1
            fi
            PREFIX="$2"
            shift
            ;;
        # Unknown arguments are a bug at the call site, not a field
        # condition, so they are refused rather than guessed at. Silently
        # ignoring a mistyped --advisory would mean a caller that believes it
        # is advisory and is not, which is the whole failure this flag exists
        # to control. This one exit is deliberately not advisory-aware: it
        # fires before anything has been inspected, and it means the caller
        # itself is wrong.
        *)
            echo "✗ provision-rclone.sh: unknown argument '$1'."
            echo "  Usage: provision-rclone.sh [--advisory] [--prefix DIR]"
            exit 1
            ;;
    esac
    shift
done

# Resolve the real (non-root) user the same way setup.sh, update.sh and
# provision-chdk-usb.sh do, so this script behaves identically whichever one
# calls it, or run by hand. The rclone config file is owned by this user
# because the backend reads it as this user.
if [ -n "${SUDO_USER:-}" ]; then
    DTK_USER="$SUDO_USER"
else
    DTK_USER="$(whoami)"
fi

# ── Pin ─────────────────────────────────────────────────────────────────────
# Pinned deliberately, like PIXI_VERSION in setup.sh: every unit gets the same
# rclone rather than whatever was latest the day it was provisioned. Bump the
# version and all three checksums together, from
# https://downloads.rclone.org/<version>/SHA256SUMS — which is also what the
# GitHub release's own asset digests report.
#
# v1.75.2, released 2026-10-09. Checksums taken from that release's SHA256SUMS
# on 2026-10-16 and cross-checked against the GitHub release asset digests.
RCLONE_VERSION="v1.75.2"
RCLONE_SHA256_LINUX_ARM64="7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10"
RCLONE_SHA256_LINUX_ARM_V7="757a5b233ad0e8cdc60749a2d451231d81be45c01304a4c04b4514e733275b73"
RCLONE_SHA256_LINUX_AMD64="349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702"

# The floor the backend's B2 path actually needs, which is not the same thing
# as the pin: an operator who has already installed a NEWER rclone keeps it,
# and nothing is downloaded. 1.70 is the floor because the B2 auth failure is
# in the 1.6x series; apt's 1.60 is the version this guards against.
RCLONE_MIN_VERSION="1.70.0"

# ── Two different things, which must not share a variable ───────────────────
#
#   RCLONE_INSTALL_PATH   where a pinned build gets INSTALLED
#   RCLONE_USE_BIN        which executable the backend is told to RUN
#
# They were one variable, read from DTK_RCLONE_BIN, and that was wrong in both
# directions. DTK_RCLONE_BIN is a .env key that update.sh exports before
# calling this script, and .env.example ships it as the bare word `rclone`, so
# it arrived here as an install DESTINATION and the install targeted the
# current working directory. In the other direction, a unit with no
# /usr/local/bin/rclone but a new-enough /usr/bin/rclone had the install
# correctly skipped and then got DTK_RCLONE_BIN=/usr/local/bin/rclone written
# into .env — a path with no file at it, so the backend would shell out to
# nothing.
#
# /usr/local/bin precedes /usr/bin on the default PATH and on dtk.service's
# explicit PATH, so a pinned build installed there shadows an apt one rather
# than fighting dpkg over /usr/bin/rclone.
RCLONE_INSTALL_PATH="${PREFIX}/usr/local/bin/rclone"
RCLONE_USE_BIN=""

# Per-unit, outside the repository, on the same state directory as the
# secrets-provenance marker generate-secrets.sh writes. Outside the repo means
# it cannot be committed by accident; /var/lib/dtk is already owned by
# DTK_USER after setup.sh's step 2.
RCLONE_CONFIG_DEFAULT="${PREFIX}/var/lib/dtk/rclone.conf"
RCLONE_CONFIG_PATH="$RCLONE_CONFIG_DEFAULT"
# Whether THIS RUN can vouch for that path. Three things establish it: the run
# wrote a credential there, offsite.env already named it, or the run verified a
# complete credential at it for the very remote it is about to record. When
# none of those holds, DTK_RCLONE_CONFIG is left OUT of offsite.env rather than
# written, so a path this run never looked at is not overridden — see
# write_offsite_env.
#
# The third case is why this is "can vouch for" and not "wrote": a run that
# records a selector must record the file that selector's credential is in, or
# the selector names a remote the backend cannot find. Omitting the path there
# would break the bucket-only recovery outright, which is the same class of
# harm as the override it is guarding against.
CONFIG_PATH_ESTABLISHED=0

# The settings file this script owns. Fixed, because the backend names the
# same path beside the project .env; the only thing that moves it is --prefix,
# for a dry run.
OFFSITE_ENV_PATH="${PREFIX}/var/lib/dtk/offsite.env"

# The remote name this script WRITES into the rclone config. The remote it
# INSPECTS is whichever one offsite.env actually names, which is not always
# this one.
RCLONE_REMOTE_NAME="b2unit"

RCLONE_BASE_URL="https://downloads.rclone.org/${RCLONE_VERSION}"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Dotted numeric comparison, missing components read as 0. Avoids sort -V,
# which is not uniformly available, and avoids string comparison, under which
# "1.6" sorts after "1.10".
version_at_least() {
    local have="$1" want="$2" i h w
    local -a hp=() wp=()
    IFS=. read -r -a hp <<< "$have"
    IFS=. read -r -a wp <<< "$want"
    for i in 0 1 2; do
        h="${hp[i]:-0}"; w="${wp[i]:-0}"
        h="${h//[^0-9]/}"; w="${w//[^0-9]/}"
        if [ "${h:-0}" -gt "${w:-0}" ]; then return 0; fi
        if [ "${h:-0}" -lt "${w:-0}" ]; then return 1; fi
    done
    return 0
}

# "rclone v1.75.2" -> "1.75.2". Empty when the binary is missing, fails to
# run, or prints something unrecognisable — all of which read as "not new
# enough" below rather than as "fine". The version output is captured before
# being parsed, not piped through head: under `set -o pipefail` a producer
# killed by head's early exit would abort this whole script, turning a broken
# rclone into a failed provisioning run with no explanation.
rclone_version_of() {
    local bin="$1" out=""
    [ -x "$bin" ] || return 0
    out="$("$bin" version 2>/dev/null || true)"
    printf '%s\n' "$out" | sed -n '1s/^rclone v\([0-9][0-9.]*\).*/\1/p'
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

# dpkg's answer is the authoritative one on Debian; uname is the fallback for
# anything else this ever runs on. An architecture with no recorded checksum
# returns empty, and the caller refuses rather than installing unverified.
detect_rclone_target() {
    local a=""
    if command -v dpkg >/dev/null 2>&1; then
        a="$(dpkg --print-architecture 2>/dev/null || true)"
    fi
    [ -n "$a" ] || a="$(uname -m)"
    case "$a" in
        arm64|aarch64)      echo "linux-arm64" ;;
        armhf|armv7l|armv7) echo "linux-arm-v7" ;;
        amd64|x86_64)       echo "linux-amd64" ;;
        *)                  echo "" ;;
    esac
}

sha256_for_target() {
    case "$1" in
        linux-arm64)  echo "$RCLONE_SHA256_LINUX_ARM64" ;;
        linux-arm-v7) echo "$RCLONE_SHA256_LINUX_ARM_V7" ;;
        linux-amd64)  echo "$RCLONE_SHA256_LINUX_AMD64" ;;
        *)            echo "" ;;
    esac
}

# Only grep status 0 is a verified presence and only status 1 a verified
# absence. Status 2 is the check itself failing, and it must stand in for
# neither: a grep error reading as a verified absence is what let a file be
# promoted without its verification having run.
grep_status() {   # grep_status <grep args...> -> prints grep's exit status
    local st
    if grep "$@" >/dev/null 2>&1; then st=0; else st=$?; fi
    printf '%s\n' "$st"
}

# ── A wall-clock bound on every rclone invocation that reads a config ───────
#
# rclone's own --timeout is an IDLE timeout, not a maximum runtime, and
# --ask-password=false does not bound the invocation either: rclone runs a
# configured password command FIRST and waits for it without a deadline, so a
# unit whose config names a password command that never returns stalls here
# rather than being refused. An update that never finishes is worse than one
# that reports a problem, and this script is called synchronously from
# update.sh before its pre-migration backup.
#
# A kill lands as a nonzero status, which every caller already treats as
# "could not read it" rather than as an answer about the file. When timeout(1)
# is absent the command still runs, and §2 says so rather than implying a
# bound it does not have.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v gtimeout)"
fi
RCLONE_READ_TIMEOUT=30    # reading one small config file
RCLONE_PROBE_TIMEOUT=60   # one listing call against B2 over the unit's link
bounded() {   # bounded <seconds> <command> [args...]
    local secs="$1"
    shift
    if [ -n "$TIMEOUT_BIN" ]; then
        # -k: rclone may have a child of its own still running, so follow TERM
        # with KILL rather than waiting on a process that ignored it.
        "$TIMEOUT_BIN" -k 5 "$secs" "$@"
    else
        "$@"
    fi
}

# ── Validation of every value this script writes anywhere ───────────────────
#
# DO NOT REMOVE THESE AS NOW-DECORATIVE. This script no longer writes .env, so
# nothing it produces is sourced by root in update.sh or rollback-update.sh.
# What remains is still real:
#
#   • /var/lib/dtk/offsite.env is parsed by python-dotenv in the backend.
#   • The rclone config is an INI file, where a newline or a '[' in a value
#     adds or redirects a remote — see valid_b2_token.
#   • A value that is merely wrong, rather than hostile, is caught here at
#     provisioning time instead of becoming a backup that fails every thirty
#     minutes looking like a credentials problem.
#
# Validation, not quoting. A value passes through python-dotenv and through
# rclone's INI parser, whose rules are not the same as each other's, so a
# quoting scheme that satisfies one can break the other. Rejecting the value
# on the way in is the fix.

# B2 bucket names, per Backblaze's native API: 6 to 63 characters of letters,
# digits, hyphens and periods. Uppercase and periods are both permitted there,
# which an earlier version of this line refused — it had been written from S3
# convention rather than from B2's rules, so `myBucket`, `bucket.name` and any
# name over 50 characters were rejected at provisioning, in an archive, with a
# message asserting a rule B2 does not have.
#
# What this check is FOR, since the class looks lax: catching an operator's
# typo or a character pasted invisibly out of the Backblaze console, and
# keeping the name safe for the two files it reaches. What it is NOT: a B2
# validator. It deliberately does not check period placement, adjacent
# periods, an IPv4-shaped name or the reserved "b2-" prefix. B2 enforces those
# itself, and the listing probe surfaces the refusal with B2's own message,
# which is more use than a second-hand copy of a rule that can change.
#
# One naming note, not a rule for this validator: B2's S3-compatible API is
# stricter than the native one and accepts lowercase only, so a bucket that
# will ever be served over the S3 endpoint should be named in lowercase.
valid_bucket()   { [[ "$1" =~ ^[A-Za-z0-9.-]{6,63}$ ]]; }
# Beside the pattern, for the same reason B2_TOKEN_CLASS is: these were in two
# places, and only the pattern fails loudly when the two drift apart.
B2_BUCKET_RULE="6-63 characters of letters, digits, hyphens and periods"
# B2 key ids and application keys: opaque secrets whose alphabet Backblaze
# does not specify, so the class is as wide as it can be while still excluding
# every character that could change the meaning of a file these values are
# written into. It was narrower — letters and digits only — and that would
# have refused a credential Backblaze's own documentation shows as an example
# (N2Zug0evLcHDlh_L0Z0AJhiGGdY, which has an underscore in it), at
# provisioning, in an archive.
#
# What the class prevents is config-file injection. These values are written
# into the rclone config, which is INI: $(...) is inert there because rclone
# parses it rather than executing it, but a newline, a '[' or a '#' would let
# a key add a second remote, redirect one, or truncate the file.
#
# It also stays rather than being dropped as unknowable because Backblaze warn
# that copying a highlighted key out of their console can carry hidden
# formatting characters, and that the symptom is an invalid-key error. Those
# characters do not match this class, so they are caught here with a message
# naming what happened — instead of becoming a backup that fails every thirty
# minutes looking like a credentials problem, which is the exact failure
# NEH-227 already lost a day to.
valid_b2_token() { [[ "$1" =~ ^[A-Za-z0-9_+/=-]+$ ]]; }
# Kept beside the pattern on purpose. These were 400 lines apart, and a
# mutation test caught the consequence: with the pattern reverted and the
# wording left alone, the script enforced one class while naming another. Only
# one of those two edits fails loudly, so they live together.
B2_TOKEN_CLASS="letters, digits, and _ + / = - only"
# An absolute path with no character that could change the meaning of a file
# this script writes.
valid_abs_path() { [[ "$1" =~ ^/[A-Za-z0-9._/+-]+$ ]]; }
ABS_PATH_RULE="an absolute path, characters A-Z a-z 0-9 . _ / + -"
# The class every value written into offsite.env must match.
OFFSITE_VALUE_CLASS='^[A-Za-z0-9._:/+-]*$'

reject_value() {   # reject_value <what it is> <the value> <the rule>
    echo "✗ rclone: refusing the $1."
    echo "    value: $2"
    echo "    must match: $3"
    echo "  This is our check, not B2's: the value is written into files a"
    echo "  parser reads — the rclone config, and the offsite settings the"
    echo "  backend loads. Nothing was written and nothing was changed."
}

# ── offsite.env: the file this script owns ──────────────────────────────────
#
# One writer, one grammar, rebuilt whole on every run rather than edited in
# place. .env.example's offsite section records the division of labour: this
# script writes DTK_OFFSITE_REMOTE, DTK_RCLONE_BIN and DTK_RCLONE_CONFIG here,
# the backend reads this file IN ADDITION to the project .env, and this file
# WINS on a conflict.
#
# Because this script is the only writer, the whole file is checkable against
# the grammar the writer emits — and it is checked WHOLE, before any value is
# taken out of it. That is the point. Reading key by key meant deciding, per
# key, whether a line was close enough, and python-dotenv kept disagreeing
# with those decisions: a quoted key name, a later bare declaration, and
# assignment-shaped text inside another variable's multiline quoted value all
# read one way here and another way in the backend. The two disagreed about
# what the unit was configured to do, and this reader was the one deciding
# whether to write.
#
# So every line must be either a '#' comment or exactly KEY=value, with KEY
# one of the three this script writes, no key twice, and the value inside
# OFFSITE_VALUE_CLASS. No quoting, no `export`, no indentation, no trailing
# comment, no blank lines, nothing else. Anything else makes the file
# MALFORMED: it is not read at all, nothing is changed, and the operator is
# told which line did it. A file this script did not write is not a file this
# script can interpret.
OFFSITE_STATUS=""      # ok | absent | malformed | unreadable
OFFSITE_CFG=""         # DTK_RCLONE_CONFIG as recorded, when non-empty
OFFSITE_REMOTE=""      # DTK_OFFSITE_REMOTE as recorded, when non-empty
OFFSITE_BAD_LINE=""    # the offending line when malformed
OFFSITE_BAD_WHY=""     # why that line is not in the grammar
read_offsite_env() {
    local content line key value st seen=""
    OFFSITE_STATUS="absent"
    OFFSITE_CFG=""; OFFSITE_REMOTE=""
    OFFSITE_BAD_LINE=""; OFFSITE_BAD_WHY=""
    [ -e "$OFFSITE_ENV_PATH" ] || return 0
    # `unreadable` is its own answer and not absence, and absence is what
    # authorises writing a credential: a failed read must never reach that
    # path. So cat's status is taken explicitly rather than swallowed by
    # `|| true`, and `if cmd; then` rather than `set +e`, because a condition
    # context is what suppresses the ERR trap while still yielding the status.
    if content="$(cat "$OFFSITE_ENV_PATH" 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    if [ "$st" -ne 0 ]; then
        OFFSITE_STATUS="unreadable"
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            "#"*) continue ;;
        esac
        if ! [[ "$line" =~ ^(DTK_RCLONE_BIN|DTK_RCLONE_CONFIG|DTK_OFFSITE_REMOTE)=[A-Za-z0-9._:/+-]*$ ]]; then
            OFFSITE_STATUS="malformed"
            OFFSITE_BAD_LINE="$line"
            if [ -z "$line" ]; then
                OFFSITE_BAD_WHY="an empty line, or an empty file"
            else
                OFFSITE_BAD_WHY="not a plain KEY=value in one of the three keys this script writes"
            fi
            return 0
        fi
        key="${line%%=*}"
        value="${line#*=}"
        case " $seen " in
            *" $key "*)
                OFFSITE_STATUS="malformed"
                OFFSITE_BAD_LINE="$line"
                OFFSITE_BAD_WHY="a second declaration of $key"
                return 0
                ;;
        esac
        seen="$seen $key"
        case "$key" in
            DTK_RCLONE_CONFIG)  OFFSITE_CFG="$value" ;;
            DTK_OFFSITE_REMOTE) OFFSITE_REMOTE="$value" ;;
        esac
    done <<< "$content"
    OFFSITE_STATUS="ok"
}

# The diagnosis for OFFSITE_STATUS=unreadable. The outcome is not a state of
# the unit — it is this script being unable to find out.
offsite_read_failed() {
    echo "✗ rclone: could not read $OFFSITE_ENV_PATH."
    echo "  The file is there and this script cannot read it, which is not the"
    echo "  same answer as there being no settings — and no settings is what"
    echo "  authorises writing a credential. Nothing was read, nothing was"
    echo "  written and nothing was changed."
    echo "  Check the file's mode and owner, and that the filesystem under"
    echo "  $(dirname "$OFFSITE_ENV_PATH") is healthy and mounted read-write:"
    echo "    sudo ls -l $OFFSITE_ENV_PATH"
    provision_failed
}

offsite_malformed() {
    echo "  ⚠ $OFFSITE_ENV_PATH is not in the format this script writes, so it"
    echo "    was NOT read and nothing was changed."
    echo "        $OFFSITE_BAD_LINE"
    echo "    ($OFFSITE_BAD_WHY.)"
    echo "    That file is written whole by this script and by nothing else,"
    echo "    so it has been edited by hand or by something else. It is"
    echo "    checked whole rather than key by key because the backend's own"
    echo "    parser reads syntax this script does not write, and the two"
    echo "    disagreeing about what the unit is configured to do is worse"
    echo "    than refusing to guess."
    echo "    Delete it and re-run to have it rebuilt, or reduce every line to"
    echo "    a '#' comment or a plain KEY=value in DTK_RCLONE_BIN,"
    echo "    DTK_RCLONE_CONFIG or DTK_OFFSITE_REMOTE."
}

# Write offsite.env whole, atomically: a temp file in the same directory, all
# settings, verified, then renamed over the target. No line editing, no filter
# over existing content, no key reconciliation — all of which existed only
# because this was editing a file it did not own.
#
# 0600 and the service user: the remote name is not a secret, but this file
# sits in the same directory as the credential and the secrets-provenance
# marker, and nothing here needs to be world-readable.
#
# Returns non-zero having changed nothing on any problem; the caller goes
# through provision_failed.
#
# AN EMPTY ARGUMENT MEANS THE KEY IS OMITTED, not written empty, and that
# distinction is the whole of it. offsite.env is later than .env in the
# backend's env_file tuple, so a key present here wins over the same key in
# .env — and present-but-empty wins with nothing.
#
#   <remote>: this file used to carry DTK_OFFSITE_REMOTE unconditionally,
#   including empty, so the first run of this version on a unit an earlier
#   version had configured through .env wrote an empty value over a working
#   remote. The backend reads absent and empty alike, so omitting it is both
#   equivalent and safe.
#
#   <config-path>: the same hazard, live for longer. A working unit whose
#   .env said DTK_RCLONE_CONFIG=/opt/archive/rclone.conf, with its remote
#   preserved from offsite.env, had that path overridden with
#   /var/lib/dtk/rclone.conf — a file that need not exist. Working backup
#   became failing backup, and the run reported success. So the path is
#   recorded only when THIS RUN established it: it wrote a credential there,
#   or it read that same path out of offsite.env.
write_offsite_env() {   # write_offsite_env <bin> <config-path-or-empty> <remote-or-empty>
    local bin="$1" cfg="$2" remote="$3" tmp v want key st
    # Every value is validated by its caller; this is the backstop, so no code
    # path can write something unexpected into a file python-dotenv parses.
    for v in "$bin" "$cfg" "$remote"; do
        if ! [[ "$v" =~ $OFFSITE_VALUE_CLASS ]]; then
            echo "✗ rclone: refusing to write $OFFSITE_ENV_PATH — one of the"
            echo "  values contains characters this format does not allow."
            echo "  Nothing was written."
            return 1
        fi
    done
    if ! mkdir -p "$(dirname "$OFFSITE_ENV_PATH")"; then
        echo "✗ rclone: could not create $(dirname "$OFFSITE_ENV_PATH"). Nothing was written."
        return 1
    fi
    if ! tmp="$(mktemp "${OFFSITE_ENV_PATH}.XXXXXX")"; then
        echo "✗ rclone: could not create a temporary file beside $OFFSITE_ENV_PATH."
        echo "  Nothing was written."
        return 1
    fi
    if ! chmod 0600 "$tmp"; then
        rm -f "$tmp"
        echo "✗ rclone: could not set mode 0600 on the new $OFFSITE_ENV_PATH."
        echo "  Nothing was written."
        return 1
    fi
    local -a wants=("DTK_RCLONE_BIN=$bin") omitted=()
    if [ -n "$cfg" ]; then
        wants+=("DTK_RCLONE_CONFIG=$cfg")
    else
        omitted+=("DTK_RCLONE_CONFIG")
    fi
    if [ -n "$remote" ]; then
        wants+=("DTK_OFFSITE_REMOTE=$remote")
    else
        omitted+=("DTK_OFFSITE_REMOTE")
    fi
    if ! {
        echo "# Digitization Toolkit — offsite catalogue backup (NEH-249, NEH-227)."
        echo "# Written whole by scripts/provision-rclone.sh at provisioning and on"
        echo "# every update. DO NOT EDIT: the next run replaces this file, and a"
        echo "# line that is not a '#' comment or a plain KEY=value in one of the"
        echo "# three keys below makes the whole file unreadable to that script."
        echo "#"
        echo "# The backend reads this in addition to the project .env, and a key"
        echo "# present here wins over the same key in .env. A key that is ABSENT"
        echo "# here overrides nothing: DTK_OFFSITE_REMOTE is written only when a"
        echo "# remote was actually recorded, and DTK_RCLONE_CONFIG only when the"
        echo "# run that wrote this file established the config path itself."
        printf '%s\n' "${wants[@]}"
    } > "$tmp"; then
        rm -f "$tmp"
        echo "✗ rclone: could not write the new $OFFSITE_ENV_PATH. The existing"
        echo "  file, if any, was left exactly as it was."
        return 1
    fi
    # Verify before promoting. The rename is atomic, so what it promotes has
    # to be right — and a write that ran out of space mid-file returns
    # success often enough that the status alone is not evidence. Each line is
    # matched whole and literally, and a check that could not RUN is a refusal
    # rather than a pass. (None of these values is a secret: two paths and the
    # remote name with its bucket. The B2 application key goes only to the
    # rclone config file and never through here.)
    for want in "${wants[@]}"; do
        st="$(grep_status -qxF "$want" "$tmp")"
        if [ "$st" -ne 0 ]; then
            rm -f "$tmp"
            echo "✗ rclone: the new $OFFSITE_ENV_PATH was not promoted. The check for"
            echo "      $want"
            if [ "$st" -eq 1 ]; then
                echo "  found that line absent."
            else
                echo "  could not be run (grep status $st), and a check that did not run"
                echo "  is not a check that passed."
            fi
            echo "  The existing file, if any, was left exactly as it was."
            return 1
        fi
    done
    # The other half of the same promise: an omitted key must be ABSENT rather
    # than present-and-empty, because a present key overrides .env and an
    # absent one does not.
    for key in ${omitted[@]+"${omitted[@]}"}; do
        st="$(grep_status -q "^$key=" "$tmp")"
        if [ "$st" -ne 1 ]; then
            rm -f "$tmp"
            echo "✗ rclone: the new $OFFSITE_ENV_PATH was not promoted. It must leave"
            echo "  $key out, and that could not be confirmed"
            if [ "$st" -eq 0 ]; then
                echo "  because the key is declared in it."
            else
                echo "  because the check could not be run (grep status $st)."
            fi
            echo "  The existing file, if any, was left exactly as it was."
            return 1
        fi
    done
    if ! chown "$DTK_USER:$DTK_USER" "$tmp"; then
        rm -f "$tmp"
        echo "✗ rclone: could not set the owner of the new $OFFSITE_ENV_PATH to"
        echo "  $DTK_USER. Nothing was written."
        return 1
    fi
    if ! mv "$tmp" "$OFFSITE_ENV_PATH"; then
        rm -f "$tmp"
        echo "✗ rclone: could not put the new $OFFSITE_ENV_PATH in place. The"
        echo "  existing file, if any, was left exactly as it was."
        return 1
    fi
}

# Read one KEY=value line out of an operator-supplied file. Deliberately NOT
# `source`: that file holds a credential an operator wrote by hand, and
# sourcing it would execute whatever else is in it as root. What it yields is
# validated before it goes anywhere.
key_file_value() {
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null \
        | tail -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# ── What state is the rclone config in, for one remote? ─────────────────────
#
# Returns one of:
#   missing      the config file does not exist. The ONLY state that
#                authorises writing a credential.
#   complete     rclone loads the file and that remote's type, account and
#                key all have non-empty values.
#   incomplete   rclone loads the file, the remote is there, but it is not
#                usable.
#   foreign      rclone loads the file and finds no such remote in it.
#   unreadable   rclone cannot load the file at all — an unparseable line, a
#                config encrypted with a password this script will not ask
#                for, a password command that never returns, or anything else
#                that makes rclone refuse it.
#   undetermined the classification could not be RUN, so NO claim is made
#                about the file or the remote. Not the same answer as a field
#                being missing, and handled separately for that reason.
#
# ASK RCLONE, AND ASK IT FOR STRUCTURE. This was an awk pass over the text of
# `config show`, and before that an awk pass imitating goconfig, and both
# disagreed with the real parser. `config dump` emits JSON keyed by remote
# name with exact field names, so there is no shape to imitate: the field is
# looked up by name or it is not there.
#
# Verified against native rclone 1.70.2 on 2026-10-16, including on round 5's
# own decoy fixture, which is what killed the text pass:
#
#     [b2unit]
#     type = b2
#     account = acct
#     key =
#     "key = decoy" = harmless
#
#   `config show` renders that as two lines reading `key =` and
#   `key = decoy = harmless`, and a text matcher sees a non-empty `key`.
#   `config dump` reports  "key": ""  and puts  "key = decoy": "harmless"  in
#   a field of its own. The credential is empty, and the dump says so.
#
# The other disagreements the text pass had to imitate, all of which the dump
# simply reports: last assignment wins, so "key = k" then "key =" leaves the
# key EMPTY; "[ b2unit ]" with spaces inside the brackets is a valid section;
# "type: b2" is a valid assignment, colon and equals both separating; a
# trailing "# comment" after a value is PART OF THE VALUE; one unparseable
# line makes rclone refuse the WHOLE file (exit 1); and a missing file dumps
# "{}" with exit 0 — so existence is decided on the filesystem before rclone
# is asked anything.
#
# False absence is the dangerous direction, because absence is what reaches
# the fresh-credential path and that path writes. Only `missing` authorises a
# write, and `missing` is established by the filesystem, not by a parser.
#
# python3 reads the JSON. It is already this script's zip fallback, so it is
# not a new dependency; if it is absent the answer is `undetermined` and no
# claim is made about the config at all. The dump carries this unit's
# application key, so it goes to python on STDIN and never into an argument
# list. Keep it that way.
CONFIG_DUMP_CLASSIFIER='
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print("unreadable")
    sys.exit(0)
if not isinstance(data, dict):
    print("unreadable")
    sys.exit(0)
section = data.get(want)
if not isinstance(section, dict):
    print("foreign")
    sys.exit(0)
for field in ("type", "account", "key"):
    value = section.get(field)
    if not isinstance(value, str) or not value.strip():
        print("incomplete")
        sys.exit(0)
print("complete")
'
config_remote_state() {   # <rclone> <file> <remote>
    local rc_bin="$1" f="$2" want="$3" dump st state
    # The remote name is printed in the messages below, so a name outside this
    # class is not interpreted at all — it is reported as undetermined, which
    # blocks the overwrite path like every other uncertain answer.
    if ! [[ "$want" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "undetermined"; return 0
    fi
    [ -e "$f" ] || { echo "missing"; return 0; }
    if [ ! -x "$rc_bin" ] || ! command -v python3 >/dev/null 2>&1; then
        echo "undetermined"; return 0
    fi
    # `if cmd; then` and not `set +e`: an ERR trap fires on a failing command
    # whether or not errexit is on, and only a condition context suppresses
    # it. With `set +e` here, a config rclone cannot load tripped the trap
    # inside this command substitution and the caller got the generic
    # "stopped unexpectedly" abort instead of the diagnosis below.
    #
    # --ask-password=false because this runs unattended, from setup.sh and
    # from update.sh: rclone otherwise prompts for the password of an
    # encrypted config, and the prompt went to a suppressed stderr, so the run
    # hung. That flag is not a bound on the invocation — see bounded.
    if dump="$(bounded "$RCLONE_READ_TIMEOUT" "$rc_bin" --config "$f" \
                   --ask-password=false config dump 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    if [ "$st" -ne 0 ]; then
        echo "unreadable"; return 0
    fi
    # $dump holds this unit's B2 application key. It goes to python on stdin
    # and is never echoed.
    if state="$(printf '%s' "$dump" \
                  | python3 -I -c "$CONFIG_DUMP_CLASSIFIER" "$want" 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    # The check itself failing is not a field being missing. Saying
    # `incomplete` here would be a claim about the credential made on no
    # evidence, which is how a usable one came to be reported unusable.
    if [ "$st" -ne 0 ]; then
        echo "undetermined"; return 0
    fi
    case "$state" in
        complete|incomplete|foreign|unreadable) echo "$state" ;;
        *) echo "undetermined" ;;
    esac
}

reachable() {
    curl -fsS --head --max-time 15 "$1" >/dev/null 2>&1
}

# ── What this run did ───────────────────────────────────────────────────────
#
# The closing block, printed on every ordinary exit path. It is an account of
# this run and not a verdict on the unit: see the note at the top of this
# file. Each field is set by the branch that establishes it, so an unset field
# reads as "this run did not do that" rather than as a claim.
RUN_RCLONE="not resolved"
RUN_CRED="no credential was written by this run"
RUN_PROBE="not run"
RUN_SETTINGS="not written by this run"
run_report() {
    echo ""
    echo "  What this run did:"
    echo "    rclone       $RUN_RCLONE"
    echo "    credential   $RUN_CRED"
    echo "    bucket probe $RUN_PROBE"
    echo "    settings     $RUN_SETTINGS"
    echo ""
    echo "  That is an account of this run, not a verdict on the unit. This"
    echo "  script does not report whether offsite backup is working: that is"
    echo "  a question about whether a backup has actually run and been"
    echo "  verified, which is answered from this unit's own backup records in"
    echo "  the Captua interface. Do not infer it from the lines above."
    echo ""
}

# Leave after a failure to provision. Every caller has already printed its own
# diagnosis; this decides only whether the surrounding script dies with us. In
# advisory mode it says plainly that it is not failing the caller, so a reader
# of an update log can tell "this was tolerated" from "nothing went wrong".
#
# It says nothing about the state of offsite backup. It used to say backup
# "stays unprovisioned on this unit", which is a claim about the unit — and
# several of the paths that reach here have inspected no configuration at all
# (a lock that could not be taken, an architecture with no pinned build).
provision_failed() {
    if [ "$ADVISORY" -eq 1 ]; then
        echo ""
        echo "  --advisory: not failing the caller. Everything above still"
        echo "  applies; only this script's exit status has been suppressed, so"
        echo "  the calling script carries on. The next run tries again."
        echo ""
        exit 0
    fi
    exit 1
}

# Record the run's settings. The config path is written only when this run
# established it (see write_offsite_env); otherwise the key is left out and
# whatever .env sets stays in force, which is said out loud because an
# operator reading offsite.env will notice the absence.
offsite_write_or_fail() {   # <remote-or-empty>
    local cfg=""
    if [ "$CONFIG_PATH_ESTABLISHED" -eq 1 ]; then
        cfg="$RCLONE_CONFIG_PATH"
    fi
    if ! write_offsite_env "$RCLONE_USE_BIN" "$cfg" "$1"; then
        provision_failed
    fi
    RUN_SETTINGS="$OFFSITE_ENV_PATH written (mode 0600, owner $DTK_USER): DTK_RCLONE_BIN=$RCLONE_USE_BIN"
    echo "  $OFFSITE_ENV_PATH written  ✓ (mode 0600, owner $DTK_USER)"
    if [ -n "$1" ]; then
        RUN_SETTINGS="$RUN_SETTINGS, DTK_OFFSITE_REMOTE=$1"
        echo "    DTK_OFFSITE_REMOTE=$1"
    else
        RUN_SETTINGS="$RUN_SETTINGS, no DTK_OFFSITE_REMOTE"
        echo "    no DTK_OFFSITE_REMOTE: this run recorded no remote, and it has"
        echo "    not disabled one. A key it does not declare is a key it does"
        echo "    not override, so anything the project .env sets is untouched;"
        echo "    this script does not read that file and does not report on it."
    fi
    if [ -n "$cfg" ]; then
        RUN_SETTINGS="$RUN_SETTINGS, DTK_RCLONE_CONFIG=$cfg"
        echo "    DTK_RCLONE_CONFIG=$cfg"
    else
        RUN_SETTINGS="$RUN_SETTINGS, DTK_RCLONE_CONFIG left out"
        echo "    no DTK_RCLONE_CONFIG: this run did not establish the config"
        echo "    path, so it does not override one. Whatever the project .env"
        echo "    sets stays in force. The config inspected here was"
        echo "    $RCLONE_CONFIG_PATH."
    fi
}

# What the inspected config file is, in the same words everywhere. Three
# branches used to describe the same five states in three wordings, which is
# how the three copies came to disagree with each other and with the state
# they were describing. Sets RUN_CRED to match. `undetermined` is not here: it
# never reaches a branch that prints a diagnosis.
describe_config_state() {   # describe_config_state <indent>
    local i="$1"
    case "$CONFIG_STATE" in
        missing)
            echo "$i$RCLONE_CONFIG_PATH does not exist."
            RUN_CRED="none: $RCLONE_CONFIG_PATH does not exist"
            ;;
        complete)
            echo "$i$RCLONE_CONFIG_PATH holds a complete [$CHECK_NAME] remote:"
            echo "$i  rclone reads its type, account and key as non-empty."
            RUN_CRED="left the complete [$CHECK_NAME] section in $RCLONE_CONFIG_PATH untouched"
            ;;
        incomplete)
            echo "$i$RCLONE_CONFIG_PATH has a [$CHECK_NAME] remote that rclone"
            echo "$i  reads as unusable: type, account and key must all have"
            echo "$i  non-empty values, and at least one does not. A later"
            echo "$i  assignment overrides an earlier one, so a trailing"
            echo "$i  'key =' empties a key set above it."
            RUN_CRED="left the unusable [$CHECK_NAME] section in $RCLONE_CONFIG_PATH untouched"
            ;;
        foreign)
            echo "$i$RCLONE_CONFIG_PATH exists, and rclone finds no [$CHECK_NAME]"
            echo "$i  remote in it."
            RUN_CRED="left $RCLONE_CONFIG_PATH untouched; rclone finds no [$CHECK_NAME] remote in it"
            ;;
        unreadable)
            echo "$i$RCLONE_CONFIG_PATH exists but rclone CANNOT LOAD IT, so no"
            echo "$i  claim is made about what it holds. One unparseable line"
            echo "$i  does that, and so do an encrypted config and a password"
            echo "$i  command that never returns — this script supplies no"
            echo "$i  password and does not wait indefinitely. See:"
            echo "$i    sudo -u $DTK_USER $RCLONE_USE_BIN --config \\"
            echo "$i        $RCLONE_CONFIG_PATH config dump"
            RUN_CRED="left $RCLONE_CONFIG_PATH untouched; rclone cannot load it"
            ;;
    esac
}

# Everything that is NOT one of the failures below — an unzip that returns 50,
# an install that cannot write, a chown that fails — lands here, so --advisory
# means what it says for every failure rather than for the enumerated ones.
# `set -E` carries the trap into functions.
#
# It reports the failing command rather than $LINENO: inside an ERR trap
# $LINENO gives the line of the enclosing compound statement, not of the
# command that failed, so it pointed at the `fi` of the install block for a
# failure in the middle of it. $BASH_COMMAND is the command text,
# pre-expansion, and no command in this script carries the application key:
# the key only ever reaches a heredoc and a variable, never an argument list.
# Keep it that way if you add one.
on_unexpected_error() {
    local rc="$1" cmd="$2"
    # Inside a subshell — a command substitution, a pipeline element, a
    # process substitution — --advisory must NOT convert this to success, and
    # this handler must print nothing.
    #
    # `set -E` carries this trap into command substitutions, and a subshell's
    # exit status becomes the substitution's status while its STDOUT becomes
    # the substitution's VALUE. So an advisory `exit 0` here made the subshell
    # succeed and handed the caller this diagnostic text as data: when the
    # handler fired inside $(mktemp -d), TMPDIR_RCLONE was assigned an error
    # message and the script carried on with that string as a directory path.
    # A failure that becomes a value is worse than one that stops the run,
    # because everything after it is reasoning about an error message.
    #
    # Preserving the status is enough: the failing assignment then fails in
    # the parent, where this trap fires again with BASH_SUBSHELL at 0 and
    # converts to success there if --advisory was given.
    if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
        if [ "$rc" -eq 0 ]; then rc=1; fi
        exit "$rc"
    fi
    echo "✗ rclone: provisioning stopped — this command failed with status $rc:"
    echo "    $cmd"
    echo "  That is a failure this script does not diagnose specifically. The"
    echo "  messages above show how far it got; nothing after it ran."
    provision_failed
}
trap 'on_unexpected_error "$?" "$BASH_COMMAND"' ERR

# No .env guard is needed any more, and its absence is the point: the install
# destination and the settings file are derived from constants and from
# --prefix, which is an argument. There is no environment variable for .env to
# set that could move either of them.
if ! valid_abs_path "$RCLONE_INSTALL_PATH"; then
    reject_value "rclone install path" "$RCLONE_INSTALL_PATH" "$ABS_PATH_RULE"
    provision_failed
fi
if ! valid_abs_path "$OFFSITE_ENV_PATH"; then
    reject_value "offsite settings path" "$OFFSITE_ENV_PATH" "$ABS_PATH_RULE"
    provision_failed
fi

# ── One run at a time ───────────────────────────────────────────────────────
#
# setup.sh calls this script and update.sh calls it with --advisory, and
# nothing stops both from running at once — an operator re-running setup.sh in
# one terminal while an update proceeds in another is not exotic. Two
# invocations would each classify the config as `missing`, each decide it was
# authorised to write a credential, and the second would publish over the
# first; the unit would then hold key B while offsite.env recorded the bucket
# from the run that wrote key A.
#
# The lock serialises the whole run rather than the write, because classifying
# the config and acting on that classification have to be one indivisible
# step: a lock held only around the write would still let both runs decide
# `missing` first. The second invocation waits and then sees the finished
# state, which every branch below already handles.
#
# The lock is not the only guard. The credential publish is also atomic and
# non-replacing (see 2b), so a run without a lock cannot clobber a credential
# either — which is what makes a missing flock(1) a warning, not a refusal.
LOCK_PATH="${PREFIX}/var/lib/dtk/provision-rclone.lock"
if ! mkdir -p "$(dirname "$LOCK_PATH")"; then
    echo "✗ rclone: could not create $(dirname "$LOCK_PATH"), so the run lock"
    echo "  cannot be taken. Nothing was changed."
    provision_failed
fi
if command -v flock >/dev/null 2>&1; then
    # fd 9 stays open for the life of the script, so the lock is released by
    # the kernel when this process ends, on every exit path including the
    # ERR trap and a kill. No lock file is ever removed: removing it races
    # with the next run opening it.
    # Guarded rather than left to the ERR trap: an unopenable lock file has a
    # remedy worth naming, and the trap's generic "this command failed" would
    # bury it under bash's own redirection error. A failing redirection on a
    # bare `exec` would otherwise end the shell.
    if ! exec 9>"$LOCK_PATH"; then
        echo "✗ rclone: could not open the run lock $LOCK_PATH, so this run"
        echo "  cannot be serialised against another copy of itself. Nothing"
        echo "  was changed. Check that $(dirname "$LOCK_PATH") is writable by"
        echo "  root and mounted read-write."
        provision_failed
    fi
    # TWO DIFFERENT THINGS, and they used to print the same message.
    #
    # flock(1) exits with the conflict status — 1, unless --conflict-exit-code
    # says otherwise — when the lock is held by someone else or the -w wait
    # ran out. Any OTHER nonzero status is flock failing to operate at all: a
    # bad file descriptor, an unsupported filesystem, an OS error. Both were
    # read as contention, so a status 71 returned instantly produced "another
    # run still holds the lock after 120 seconds" — an owner that might not
    # exist, and 120 seconds that did not elapse.
    #
    # On real contention this run has nothing to add: the holder is another
    # provisioning run and it is doing the work. So it stands down through
    # provision_failed, the convention the rest of the script uses — setup.sh's
    # plain call fails, update.sh's --advisory call carries on.
    #
    # The wait is BOUNDED, and that matters more here than the lock does.
    # update.sh calls this script synchronously at its step 4c, before the
    # pre-migration backup, and passes --advisory so that provisioning can
    # never cost an update. An unbounded `flock 9` on a wedged holder would
    # hang that update for as long as the holder lived.
    if flock -n 9; then FLOCK_ST=0; else FLOCK_ST=$?; fi
    if [ "$FLOCK_ST" -eq 1 ]; then
        echo "  another provision-rclone.sh run holds $LOCK_PATH — waiting up to"
        echo "  120 seconds for it."
        if flock -w 120 9; then FLOCK_ST=0; else FLOCK_ST=$?; fi
        if [ "$FLOCK_ST" -eq 1 ]; then
            echo "✗ rclone: another provision-rclone.sh run still holds"
            echo "  $LOCK_PATH after the 120-second wait."
            echo "  That run is the one provisioning this unit, so this one has"
            echo "  nothing to add and has stood down. Nothing was read and"
            echo "  nothing was changed. If no other run is in fact going, find"
            echo "  what holds the lock and then re-run this script:"
            echo "    sudo fuser -v $LOCK_PATH"
            provision_failed
        fi
        [ "$FLOCK_ST" -eq 0 ] && echo "  lock acquired; continuing."
    fi
    if [ "$FLOCK_ST" -ne 0 ]; then
        echo "✗ rclone: flock could not operate on $LOCK_PATH (status $FLOCK_ST)."
        echo "  That is flock failing, not another run holding the lock: no"
        echo "  owner has been identified and nothing has been waited for."
        echo "  Nothing was read and nothing was changed. Check that"
        echo "  $(dirname "$LOCK_PATH") is on a filesystem that supports"
        echo "  locking and is mounted read-write:"
        echo "    sudo ls -l $LOCK_PATH"
        provision_failed
    fi
else
    echo "  ⚠ flock is not installed, so this run is NOT serialised against"
    echo "    another copy of this script running at the same time. The"
    echo "    credential write below is still atomic and will not replace an"
    echo "    existing credential, so a concurrent run cannot overwrite one;"
    echo "    what it can do is make the two runs report different states."
    echo "    Install util-linux to restore the lock."
fi

# ── 1. Pinned rclone ────────────────────────────────────────────────────────

echo "→ Checking rclone (need >= $RCLONE_MIN_VERSION for B2 application keys)..."

# Which rclone would be used: our own install path first, then whatever is on
# PATH, so an operator's newer hand-installed rclone is accepted instead of
# being downloaded over.
FOUND_BIN=""
if [ -x "$RCLONE_INSTALL_PATH" ]; then
    FOUND_BIN="$RCLONE_INSTALL_PATH"
elif command -v rclone >/dev/null 2>&1; then
    FOUND_BIN="$(command -v rclone)"
fi

FOUND_VERSION=""
if [ -n "$FOUND_BIN" ]; then
    FOUND_VERSION="$(rclone_version_of "$FOUND_BIN")"
fi

NEED_INSTALL=1
if [ -n "$FOUND_VERSION" ] && version_at_least "$FOUND_VERSION" "$RCLONE_MIN_VERSION"; then
    NEED_INSTALL=0
    echo "  rclone $FOUND_VERSION at $FOUND_BIN  ✓ (nothing downloaded)"
elif [ -n "$FOUND_BIN" ]; then
    echo "  rclone at $FOUND_BIN reports '${FOUND_VERSION:-unrecognised}', which is"
    echo "  below $RCLONE_MIN_VERSION — installing the pinned $RCLONE_VERSION alongside it."
else
    echo "  rclone not installed — installing the pinned $RCLONE_VERSION."
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
    TARGET="$(detect_rclone_target)"
    EXPECTED_SHA="$(sha256_for_target "$TARGET")"
    if [ -z "$TARGET" ] || [ -z "$EXPECTED_SHA" ]; then
        echo "✗ rclone: no pinned build recorded for this architecture ($(uname -m))."
        echo "  This script will not install a binary it cannot verify. Install"
        echo "  rclone >= $RCLONE_MIN_VERSION at $RCLONE_INSTALL_PATH by hand and re-run."
        provision_failed
    fi

    ASSET="rclone-${RCLONE_VERSION}-${TARGET}.zip"
    URL="$RCLONE_BASE_URL/$ASSET"

    # Separated from the download failure below on purpose: "this appliance is
    # offline" and "the download was corrupt" need different things from an
    # operator, and a single generic failure would hide which one happened.
    if ! reachable "$URL"; then
        echo "✗ rclone: $URL is not reachable."
        echo "  This appliance appears to be offline, and the rclone it has is"
        echo "  missing or older than $RCLONE_MIN_VERSION. Offsite backup cannot be"
        echo "  provisioned from here. Connect this unit to the internet and"
        echo "  re-run, or install rclone >= $RCLONE_MIN_VERSION at"
        echo "  $RCLONE_INSTALL_PATH by hand (download it on another machine"
        echo "  and copy it across)."
        provision_failed
    fi

    TMPDIR_RCLONE="$(mktemp -d)"
    # Covers the download directory AND the staged binary, and stays armed
    # until the staged binary has been asserted and promoted. Nothing is left
    # behind on any exit path, including the checksum-mismatch one: a rejected
    # download must not sit on an SD card whose last incident was a full card.
    # shellcheck disable=SC2064  # expand both paths now, not at trap time
    trap "rm -rf '$TMPDIR_RCLONE'; rm -f '$RCLONE_INSTALL_PATH.new'" EXIT

    echo "  Downloading $ASSET..."
    if ! curl -fsSL --max-time 600 -o "$TMPDIR_RCLONE/$ASSET" "$URL"; then
        echo "✗ rclone: download of $URL failed."
        echo "  Nothing was installed. Re-run with a working connection, or"
        echo "  install rclone >= $RCLONE_MIN_VERSION at $RCLONE_INSTALL_PATH by hand."
        provision_failed
    fi

    echo "  Verifying checksum..."
    if ! ACTUAL_SHA="$(sha256_of "$TMPDIR_RCLONE/$ASSET")"; then
        echo "✗ rclone: neither sha256sum nor shasum is available, so the"
        echo "  download cannot be verified. Nothing was installed."
        provision_failed
    fi
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        echo "✗ rclone: CHECKSUM MISMATCH for $ASSET. Nothing was installed."
        echo "    expected $EXPECTED_SHA"
        echo "    got      $ACTUAL_SHA"
        echo "  This is either a corrupted download or a tampered-with one."
        echo "  Do not work around it by installing the file by hand. Re-run; if"
        echo "  it mismatches again, compare the pin in this script against"
        echo "  $RCLONE_BASE_URL/SHA256SUMS before changing anything."
        provision_failed
    fi
    echo "  sha256 $EXPECTED_SHA  ✓"

    if command -v unzip >/dev/null 2>&1; then
        unzip -qq -o "$TMPDIR_RCLONE/$ASSET" -d "$TMPDIR_RCLONE/x"
    elif command -v python3 >/dev/null 2>&1; then
        # -I so the interpreter cannot pick up a module from the archive's own
        # directory; the archive is downloaded content.
        python3 -I -m zipfile -e "$TMPDIR_RCLONE/$ASSET" "$TMPDIR_RCLONE/x"
    else
        echo "✗ rclone: neither unzip nor python3 is available to unpack $ASSET."
        echo "  Nothing was installed. Install unzip and re-run."
        provision_failed
    fi

    # sed, not head: head exits after the first line and would kill find with
    # SIGPIPE, which `set -o pipefail` would turn into an aborted run.
    NEW_BIN="$( { find "$TMPDIR_RCLONE/x" -type f -name rclone || true; } | sed -n '1p' )"
    if [ -z "$NEW_BIN" ]; then
        echo "✗ rclone: $ASSET did not contain an rclone binary. Nothing was installed."
        provision_failed
    fi

    # Stage beside the final path, ASSERT the staged file, and only then
    # promote it. Asserting after the rename — which is what this did — left
    # an unusable binary at the final path whenever the assertion failed,
    # which is the one state the assertion exists to prevent. An absent rclone
    # is a clear failure; a present, unusable one is a day of debugging.
    mkdir -p "$(dirname "$RCLONE_INSTALL_PATH")"
    install -m 0755 "$NEW_BIN" "$RCLONE_INSTALL_PATH.new"
    STAGED_VERSION="$(rclone_version_of "$RCLONE_INSTALL_PATH.new")"
    if [ -z "$STAGED_VERSION" ] || ! version_at_least "$STAGED_VERSION" "$RCLONE_MIN_VERSION"; then
        echo "✗ rclone: the $RCLONE_VERSION build just unpacked reports"
        echo "  '${STAGED_VERSION:-nothing}', which is below the required"
        echo "  $RCLONE_MIN_VERSION. Refusing to promote it to"
        echo "  $RCLONE_INSTALL_PATH — an rclone that cannot authenticate to B2"
        echo "  would report every backup failure as a credentials problem."
        echo "  Nothing was installed; the staged file has been removed."
        provision_failed
    fi
    mv "$RCLONE_INSTALL_PATH.new" "$RCLONE_INSTALL_PATH"
    rm -rf "$TMPDIR_RCLONE"
    trap - EXIT

    echo "  rclone $STAGED_VERSION at $RCLONE_INSTALL_PATH  ✓"
    FOUND_BIN="$RCLONE_INSTALL_PATH"
    FOUND_VERSION="$STAGED_VERSION"
fi

# What the backend will be told to run: whatever was actually accepted above,
# never the install path by assumption. Checked for existence here, because
# this value becomes DTK_RCLONE_BIN and a path with no file at it would turn
# every backup into a silent no-op inside the backend.
RCLONE_USE_BIN="$FOUND_BIN"
if [ -z "$RCLONE_USE_BIN" ] || [ ! -x "$RCLONE_USE_BIN" ]; then
    echo "✗ rclone: finished with no executable rclone to record"
    echo "  (resolved to '${RCLONE_USE_BIN:-nothing}'). Nothing was recorded,"
    echo "  so the backend is not pointed at a path with no file at it."
    provision_failed
fi
if ! valid_abs_path "$RCLONE_USE_BIN"; then
    reject_value "resolved rclone path" "$RCLONE_USE_BIN" "$ABS_PATH_RULE"
    provision_failed
fi
RUN_RCLONE="${FOUND_VERSION:-unrecognised} at $RCLONE_USE_BIN"

# An apt rclone left on the box is shadowed by /usr/local/bin on PATH, and the
# value recorded below is absolute, so the backend cannot pick it up. Say so
# anyway: the next person to run `rclone version` by hand in a login shell
# needs to know which one answered.
OTHER_RCLONE=""
if command -v rclone >/dev/null 2>&1; then
    OTHER_RCLONE="$(command -v rclone)"
fi
if [ -n "$OTHER_RCLONE" ] && [ "$OTHER_RCLONE" != "$RCLONE_USE_BIN" ]; then
    OTHER_VERSION="$(rclone_version_of "$OTHER_RCLONE")"
    if [ -n "$OTHER_VERSION" ] && ! version_at_least "$OTHER_VERSION" "$RCLONE_MIN_VERSION"; then
        echo "  ⚠ $OTHER_RCLONE is rclone $OTHER_VERSION (too old for B2). It is left"
        echo "    in place; the backend is pointed at $RCLONE_USE_BIN by absolute path."
    fi
fi
echo ""

# ── 2. Per-unit remote ──────────────────────────────────────────────────────

echo "→ Configuring the offsite remote..."

if [ -z "$TIMEOUT_BIN" ]; then
    echo "  ⚠ timeout(1) is not installed, so the rclone calls below run"
    echo "    without a wall-clock bound. rclone's own --timeout is an idle"
    echo "    timeout and --ask-password=false does not stop it running a"
    echo "    configured password command first, so a config that names one"
    echo "    that never returns can stall this run. Install coreutils to"
    echo "    restore the bound."
fi

# ── 2.1 What offsite.env records ────────────────────────────────────────────
read_offsite_env
case "$OFFSITE_STATUS" in
    unreadable)
        offsite_read_failed
        ;;
    malformed)
        offsite_malformed
        run_report
        sync
        exit 0
        ;;
esac

# Only this script writes offsite.env, so a path in it is one this script put
# there. Adopting it is also what keeps a legacy unit's credential path from
# being overridden: adopted here, it is written back unchanged, and with
# nothing to adopt the key is left out of the file entirely rather than set to
# this script's default.
if [ -n "$OFFSITE_CFG" ]; then
    if ! valid_abs_path "$OFFSITE_CFG"; then
        reject_value "rclone config path recorded in $OFFSITE_ENV_PATH" \
            "$OFFSITE_CFG" "$ABS_PATH_RULE"
        provision_failed
    fi
    RCLONE_CONFIG_PATH="$OFFSITE_CFG"
    CONFIG_PATH_ESTABLISHED=1
fi
SELECTED_REMOTE="$OFFSITE_REMOTE"

# ── 2.2 Key material ────────────────────────────────────────────────────────
print_key_instructions() {
    echo "  To enable it, an operator needs three values issued for THIS unit:"
    echo "    KEY_ID    the scoped B2 application key id"
    echo "    APP_KEY   its application key"
    echo "    BUCKET    the unit's bucket, one per institution"
    echo ""
    echo "  The key must be scoped to that one bucket with writeFiles and"
    echo "  listFiles ONLY — no readFiles, no deleteFiles — so that a stolen"
    echo "  appliance can neither erase nor download the archive."
    echo ""
    echo "  Put them in a file only root can read, and point this script at it:"
    echo "    sudo install -m 0600 /dev/null /root/dtk-offsite-key"
    echo "    sudo sh -c 'cat > /root/dtk-offsite-key' <<'END'"
    echo "    KEY_ID=..."
    echo "    APP_KEY=..."
    echo "    BUCKET=..."
    echo "    END"
    echo "    sudo DTK_OFFSITE_KEY_FILE=/root/dtk-offsite-key \\"
    echo "        $SCRIPT_DIR/provision-rclone.sh"
    echo ""
    echo "  Do NOT pass the key as 'sudo DTK_B2_APP_KEY=... ./provision-rclone.sh'."
    echo "  An assignment written in front of sudo is part of SUDO's argv, not"
    echo "  the shell's environment, and any local user can read it out of"
    echo "  /proc/<pid>/cmdline for as long as the command runs. Only the path"
    echo "  above goes on the command line; the key itself never does."
}

B2_KEY_ID="${DTK_B2_KEY_ID:-}"
B2_APP_KEY="${DTK_B2_APP_KEY:-}"
B2_BUCKET="${DTK_OFFSITE_BUCKET:-}"

if [ -n "${DTK_OFFSITE_KEY_FILE:-}" ]; then
    if [ -r "$DTK_OFFSITE_KEY_FILE" ]; then
        [ -n "$B2_KEY_ID" ]  || B2_KEY_ID="$(key_file_value "$DTK_OFFSITE_KEY_FILE" KEY_ID)"
        [ -n "$B2_APP_KEY" ] || B2_APP_KEY="$(key_file_value "$DTK_OFFSITE_KEY_FILE" APP_KEY)"
        [ -n "$B2_BUCKET" ]  || B2_BUCKET="$(key_file_value "$DTK_OFFSITE_KEY_FILE" BUCKET)"
        echo "  read key material from $DTK_OFFSITE_KEY_FILE"
    else
        echo "  ⚠ DTK_OFFSITE_KEY_FILE=$DTK_OFFSITE_KEY_FILE is not readable — ignoring it."
    fi
fi

# Validate before any branch can use it. A value that fails here stops the
# run: it is either an operator's typo, a character pasted invisibly out of
# the Backblaze console, or an attempt to get syntax into a file a parser
# reads, and none of those should be written.
if [ -n "$B2_KEY_ID" ] && ! valid_b2_token "$B2_KEY_ID"; then
    reject_value "B2 key id" "$B2_KEY_ID" "$B2_TOKEN_CLASS"
    provision_failed
fi
if [ -n "$B2_APP_KEY" ] && ! valid_b2_token "$B2_APP_KEY"; then
    # The value is deliberately not echoed back: it is a credential.
    echo "✗ rclone: refusing the B2 application key — it must be"
    echo "  $B2_TOKEN_CLASS. The value is not printed here"
    echo "  because it is a secret."
    echo "  This is our check, not B2's: the key is written into an rclone"
    echo "  config file, where a newline or a '[' would add or redirect a"
    echo "  remote. Nothing was written."
    echo "  If you copied the key out of the Backblaze console, copy it again"
    echo "  as plain text: a highlighted copy can carry hidden formatting"
    echo "  characters, and that is the most likely cause of this message."
    provision_failed
fi
if [ -n "$B2_BUCKET" ] && ! valid_bucket "$B2_BUCKET"; then
    reject_value "B2 bucket name" "$B2_BUCKET" "$B2_BUCKET_RULE"
    provision_failed
fi

HAVE_KEY=0
if [ -n "$B2_KEY_ID" ] && [ -n "$B2_APP_KEY" ] && [ -n "$B2_BUCKET" ]; then
    HAVE_KEY=1
fi

# ── 2.3 Which remote is recorded, and what is in the config file ────────────
# The inspection used to be hardcoded to the remote this script writes, so a
# recorded remote of "missing:archive" alongside a complete [b2unit] section
# was reported as working — it inspected the remote it expected instead of the
# one recorded. The name is now taken from the recorded settings.
#
# A spec is "<remote>:<bucket>". Anything else is not something to interpret.
SELECTED_NAME=""
SELECTED_MALFORMED=0
if [ -n "$SELECTED_REMOTE" ]; then
    case "$SELECTED_REMOTE" in
        *:*)
            SELECTED_NAME="${SELECTED_REMOTE%%:*}"
            if [ -z "$SELECTED_NAME" ] || [ -z "${SELECTED_REMOTE#*:}" ]; then
                SELECTED_MALFORMED=1
                SELECTED_NAME=""
            fi
            ;;
        *) SELECTED_MALFORMED=1 ;;
    esac
fi

# When key material is being written, the remote that matters is the one about
# to be written, not whatever is recorded now. With nothing recorded, ask about
# the remote this script writes, so the unconfigured path still reports the
# state of the file it would write rather than assuming there is nothing there.
CHECK_NAME="$SELECTED_NAME"
if [ "$HAVE_KEY" -eq 1 ] || [ -z "$CHECK_NAME" ]; then
    CHECK_NAME="$RCLONE_REMOTE_NAME"
fi
CONFIG_STATE="$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$CHECK_NAME")"

# ── 2.4 The classification could not be run ─────────────────────────────────
# FIRST, before any branch that prints a diagnosis. `undetermined` means this
# script does not know what is in that file, and every branch below reasons
# from knowing. The HALF-CONFIGURED message used to print its headline — "and
# offsite backup is NOT working" — before reaching the arm that said no claim
# was being made, so a working credential plus a failed check got a false
# failure diagnosis, and then exited 0.
#
# A failed check is not an answer. It stops the run through provision_failed,
# so setup.sh fails and update.sh carries on, and nothing is written either
# way: not knowing must not authorise writing a credential over that file.
if [ "$CONFIG_STATE" = "undetermined" ]; then
    echo "✗ rclone: could not classify $RCLONE_CONFIG_PATH, so this run makes"
    echo "  NO claim about what it holds and changed nothing."
    echo "  The file exists. Reading it means asking rclone for its config as"
    echo "  JSON and reading that JSON with python3, and one of those could not"
    echo "  be run here. Not knowing is not the same as the file being empty,"
    echo "  and it does not authorise writing a credential over it."
    if ! command -v python3 >/dev/null 2>&1; then
        echo "  python3 is not installed on this unit, which is the likely"
        echo "  cause. Install it and re-run."
    else
        echo "  Read the file yourself with:"
        echo "    sudo -u $DTK_USER $RCLONE_USE_BIN --config \\"
        echo "        $RCLONE_CONFIG_PATH config dump"
    fi
    provision_failed
fi

if [ "$SELECTED_MALFORMED" -eq 1 ] && [ "$HAVE_KEY" -eq 0 ]; then
    echo "  ⚠ The recorded DTK_OFFSITE_REMOTE is not a remote specification:"
    echo "        $SELECTED_REMOTE"
    echo "    It must be <remote>:<bucket>, e.g. $RCLONE_REMOTE_NAME:<bucket>."
    echo "    Nothing was changed. Supply this unit's key material to rewrite"
    echo "    it, or delete $OFFSITE_ENV_PATH and re-run."
    echo ""
    print_key_instructions
    run_report
    sync
    exit 0
fi

# ── 2a. The recorded remote is backed by a complete credential ──────────────
# Never overwritten, never re-derived. Re-assert the mode and owner, which is
# what drifts (a cloned SD card, a file copied in as root), and rewrite
# offsite.env so what it records is current.
if [ "$HAVE_KEY" -eq 0 ] && [ -n "$SELECTED_NAME" ] && [ "$CONFIG_STATE" = "complete" ]; then
    chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
    chmod 0600 "$RCLONE_CONFIG_PATH"
    describe_config_state "  "
    echo "  It was left untouched; mode 0600, owner $DTK_USER re-asserted."
    RUN_CRED="$RUN_CRED; mode 0600, owner $DTK_USER re-asserted"
    # The recorded selector and the credential it names were both verified at
    # this path, so recording the path pairs the two rather than overriding a
    # path this run never looked at.
    CONFIG_PATH_ESTABLISHED=1
    offsite_write_or_fail "$SELECTED_REMOTE"
    sync
    run_report
    exit 0
fi

# ── 2a-bis. A remote is recorded but its credential is not usable ───────────
# Either the config has no section for that remote at all, or it has one that
# is missing type, account or key. Preserved, not overwritten, and not
# overwritten even when fresh key material is to hand for a DIFFERENT remote
# name: this script does not delete a credential an operator may have
# half-typed, and it cannot tell a half-typed one from a truncated one.
if [ "$HAVE_KEY" -eq 0 ] && [ -n "$SELECTED_NAME" ]; then
    echo "  ⚠ $OFFSITE_ENV_PATH records DTK_OFFSITE_REMOTE=$SELECTED_REMOTE, and"
    echo "    this run found no usable [$SELECTED_NAME] credential behind it."
    describe_config_state "    "
    if [ "$CONFIG_STATE" = "incomplete" ]; then
        chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
        chmod 0600 "$RCLONE_CONFIG_PATH"
        echo "      mode 0600, owner $DTK_USER re-asserted; the file is"
        echo "      otherwise left exactly as it is."
        RUN_CRED="$RUN_CRED; mode 0600, owner $DTK_USER re-asserted"
    fi
    echo ""
    echo "    This is not a deliberate no-op. Nothing here will overwrite that"
    echo "    credential, including a re-run with key material: it may be"
    echo "    something an operator was part way through. Resolve it one of"
    echo "    two ways:"
    echo "      • move the credential aside and provision a new one:"
    echo "          sudo mv $RCLONE_CONFIG_PATH $RCLONE_CONFIG_PATH.bad"
    echo "          sudo DTK_OFFSITE_KEY_FILE=<file> $SCRIPT_DIR/provision-rclone.sh"
    echo "      • or, if this unit is not meant to back up offsite, clear"
    echo "        DTK_OFFSITE_REMOTE wherever it is set — $OFFSITE_ENV_PATH"
    echo "        here, and the project .env, which this script does not read"
    echo "        and cannot speak for."
    echo ""
    print_key_instructions
    run_report
    sync
    exit 0
fi

# ── 2b. Key material was supplied ───────────────────────────────────────────
if [ "$HAVE_KEY" -eq 1 ]; then
    # ONLY a config file that does not exist authorises writing one. Every
    # other state — complete, incomplete, foreign, unreadable — preserves what
    # is there, and `undetermined` never gets this far.
    #
    # `missing` rather than "no section of ours" because the write below
    # produces the config file WHOLE: on a file that exists and holds another
    # remote, writing it would delete that remote along with everything else
    # in it. And `unreadable` must not authorise an overwrite either, which is
    # the half of this that a parser disagreement once got wrong from the
    # other side: a config rclone reads perfectly was reported absent, and
    # absence reached this path.
    if [ "$CONFIG_STATE" != "missing" ]; then
        echo "  ⚠ $RCLONE_CONFIG_PATH already exists and was NOT replaced."
        echo "    The key material supplied was not used."
        describe_config_state "    "
        chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
        chmod 0600 "$RCLONE_CONFIG_PATH"
        echo "    mode 0600, owner $DTK_USER re-asserted."
        RUN_CRED="not written: $RCLONE_CONFIG_PATH already exists and was preserved; mode 0600, owner $DTK_USER re-asserted"
        echo ""
        echo "    To replace it with the key material you supplied, move it"
        echo "    aside and re-run:"
        echo "      sudo mv $RCLONE_CONFIG_PATH $RCLONE_CONFIG_PATH.bad"
        echo "      sudo DTK_OFFSITE_KEY_FILE=<file> $SCRIPT_DIR/provision-rclone.sh"
        run_report
        sync
        exit 0
    fi

    # Written here rather than through `rclone config create` so the
    # application key never appears in the process table, where any other user
    # on the box could read it out of /proc while this runs. The format is
    # exactly what rclone v1.75.2's own `config create b2unit b2 ...`
    # produces, verified against it: for the b2 backend `key` is stored in
    # plain text, which is why the file's mode is the only thing protecting it.
    echo "  Writing $RCLONE_CONFIG_PATH..."
    mkdir -p "$(dirname "$RCLONE_CONFIG_PATH")"
    RCLONE_CONF_TMP="$(mktemp "${RCLONE_CONFIG_PATH}.XXXXXX")"
    # shellcheck disable=SC2064  # expand the path now, not at trap time
    trap "rm -f '$RCLONE_CONF_TMP'" EXIT
    chmod 0600 "$RCLONE_CONF_TMP"
    cat > "$RCLONE_CONF_TMP" <<RCLONE_CONF
# Digitization Toolkit — per-unit offsite remote (NEH-249, NEH-227).
# Written by scripts/provision-rclone.sh at deployment. NEVER commit this
# file: it holds this unit's B2 application key in plain text, which is how
# rclone stores B2 credentials. Mode 0600, owned by the appliance user.
# The key is scoped to one bucket with writeFiles + listFiles only.
[$RCLONE_REMOTE_NAME]
type = b2
hard_delete = false
account = $B2_KEY_ID
key = $B2_APP_KEY
RCLONE_CONF
    chown "$DTK_USER:$DTK_USER" "$RCLONE_CONF_TMP"
    # `ln` and not `mv`: the publish must be atomic AND non-replacing.
    #
    # `mv` over the final path replaces whatever is there without being
    # asked, which made the whole "only `missing` authorises a write" rule
    # depend on the classification above still being true by the time the
    # write happens. Between those two points another invocation can publish
    # a credential of its own, and the `mv` would have deleted it — the run
    # lock makes that window small rather than absent, and a unit whose
    # flock(1) is missing has no lock at all. `ln` fails with EEXIST instead,
    # which is the answer this path wants: a credential that arrived while we
    # were working is a credential this script does not replace, exactly like
    # one that was there from the start.
    #
    # Both names refer to one inode, so the mode and owner set on the
    # temporary file are the mode and owner of the published file; removing
    # the temporary name afterwards leaves the published one intact. `mv` is
    # still right for offsite.env, which this script alone writes and which
    # it rebuilds whole on every run by design.
    if ! ln "$RCLONE_CONF_TMP" "$RCLONE_CONFIG_PATH" 2>/dev/null; then
        echo "✗ rclone: could not put the new credential at $RCLONE_CONFIG_PATH."
        echo "  The most likely reason is that something created that file"
        echo "  while this run was working — another provision-rclone.sh, most"
        echo "  likely. This script does not replace a credential it did not"
        echo "  write, so nothing was replaced and the key material supplied"
        echo "  was not used. $OFFSITE_ENV_PATH was not updated either."
        echo "  Look at what is there now and re-run:"
        echo "    sudo ls -l $RCLONE_CONFIG_PATH"
        provision_failed
    fi
    rm -f "$RCLONE_CONF_TMP"
    trap - EXIT
    echo "  mode 0600, owner $DTK_USER  ✓"
    RUN_CRED="wrote a [$RCLONE_REMOTE_NAME] section to $RCLONE_CONFIG_PATH (mode 0600, owner $DTK_USER)"
    CONFIG_PATH_ESTABLISHED=1

    # Verify what was just written really reads back as a complete credential
    # before recording it. Writing the file and trusting it are two different
    # things.
    WROTE_STATE="$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$RCLONE_REMOTE_NAME")"
    if [ "$WROTE_STATE" != "complete" ]; then
        echo "✗ rclone: the credential just written to $RCLONE_CONFIG_PATH does"
        echo "  not read back as a complete [$RCLONE_REMOTE_NAME] remote"
        echo "  (classified: $WROTE_STATE)."
        echo "  $OFFSITE_ENV_PATH was NOT updated, so nothing now records a"
        echo "  credential this script could not read back."
        provision_failed
    fi

    if [ -n "$SELECTED_REMOTE" ] && [ "$SELECTED_REMOTE" != "$RCLONE_REMOTE_NAME:$B2_BUCKET" ]; then
        echo "  note: replacing the recorded remote $SELECTED_REMOTE"
    fi
    offsite_write_or_fail "$RCLONE_REMOTE_NAME:$B2_BUCKET"
    sync

    # Best-effort, never fatal: one listing call against the bucket turns a
    # mistyped key into a provisioning-time message instead of a backup that
    # fails every half hour afterwards with something that reads as a
    # credentials problem. It LISTS; it writes nothing, because the only
    # capability worth confirming without side effects is the one a failed
    # listing already explains. Skipped entirely when the unit is offline —
    # being unable to ask is not an answer, so it must not be reported as one,
    # and must not fail the run.
    if reachable "https://api.backblazeb2.com"; then
        echo "  Checking the key against $B2_BUCKET..."
        # --ask-password=false for the same reason the classification carries
        # it, and `bounded` for the same reason too: the flags below are
        # per-operation and idle timeouts, not a maximum runtime, and this
        # call happens AFTER the credential and offsite.env are both written,
        # which is the worst place in the script to stall.
        if bounded "$RCLONE_PROBE_TIMEOUT" \
                "$RCLONE_USE_BIN" --config "$RCLONE_CONFIG_PATH" \
                --ask-password=false lsf --max-depth 1 \
                --retries 1 --low-level-retries 1 --contimeout 10s --timeout 20s \
                "$RCLONE_REMOTE_NAME:$B2_BUCKET" >/dev/null 2>&1; then
            echo "  the key can list $B2_BUCKET  ✓"
            RUN_PROBE="listed $RCLONE_REMOTE_NAME:$B2_BUCKET successfully"
        else
            echo "  ⚠ rclone could not list $RCLONE_REMOTE_NAME:$B2_BUCKET. The remote is"
            echo "    recorded; check the key id, the application key, the bucket name,"
            echo "    and that the key grants listFiles on that bucket. Run this to see"
            echo "    the actual error:"
            echo "      sudo -u $DTK_USER $RCLONE_USE_BIN --config $RCLONE_CONFIG_PATH \\"
            echo "          lsf --max-depth 1 $RCLONE_REMOTE_NAME:$B2_BUCKET"
            RUN_PROBE="FAILED to list $RCLONE_REMOTE_NAME:$B2_BUCKET"
        fi
    else
        echo "  (offline — the key was not checked against B2)"
        RUN_PROBE="skipped: this unit could not reach api.backblazeb2.com"
    fi
    run_report
    exit 0
fi

# ── 2c. No remote is recorded and no complete key material was supplied ─────

# ── 2c-ante. The bucket alone, over a credential that is already complete ───
# This is the recovery the note at the end of this script tells an operator to
# run:
#
#   sudo DTK_OFFSITE_BUCKET=<bucket> provision-rclone.sh
#
# It had nowhere to land. A bucket makes B2_BUCKET non-empty with no key id
# and no application key beside it, so the partial-key branch below caught it
# and reported "INCOMPLETE key material — missing: KEY_ID APP_KEY" — correct
# for an operator half way through typing a new credential, and wrong for this
# one, where the credential is already there and only the selector is missing.
#
# So it runs BEFORE the partial-key branch, and it is narrow: ONLY the bucket
# supplied, nothing recorded, and rclone reading the credential this script
# writes as complete. A key id or an application key alongside the bucket is
# an operator part way through a NEW credential. Nothing here creates or
# replaces a credential.
if [ -n "$B2_BUCKET" ] && [ -z "$B2_KEY_ID" ] && [ -z "$B2_APP_KEY" ] \
        && [ "$CONFIG_STATE" = "complete" ]; then
    chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
    chmod 0600 "$RCLONE_CONFIG_PATH"
    describe_config_state "  "
    echo "  It was left untouched — no credential was created or replaced."
    echo "  mode 0600, owner $DTK_USER  ✓"
    RUN_CRED="$RUN_CRED; mode 0600, owner $DTK_USER re-asserted"
    # Same as 2a: the selector being recorded names a credential verified
    # complete at this path, and a selector recorded without its config path
    # would point at a remote the backend cannot find.
    CONFIG_PATH_ESTABLISHED=1
    offsite_write_or_fail "$CHECK_NAME:$B2_BUCKET"
    sync
    echo ""
    echo "  The bucket was taken on trust: it is recorded as supplied, and"
    echo "  nothing here checked that this unit's key can reach it. If the"
    echo "  next backup fails, check the bucket name first:"
    echo "    sudo -u $DTK_USER $RCLONE_USE_BIN --config $RCLONE_CONFIG_PATH \\"
    echo "        lsf --max-depth 1 $CHECK_NAME:$B2_BUCKET"
    run_report
    exit 0
fi

# Partial key material is an operator half way through, not a disabled unit.
if [ -n "$B2_KEY_ID" ] || [ -n "$B2_APP_KEY" ] || [ -n "$B2_BUCKET" ]; then
    MISSING_PARTS=""
    [ -n "$B2_KEY_ID" ]  || MISSING_PARTS="$MISSING_PARTS KEY_ID"
    [ -n "$B2_APP_KEY" ] || MISSING_PARTS="$MISSING_PARTS APP_KEY"
    [ -n "$B2_BUCKET" ]  || MISSING_PARTS="$MISSING_PARTS BUCKET"
    echo "  ⚠ INCOMPLETE key material — missing:$MISSING_PARTS"
    echo "    No remote was recorded, and nothing already on this unit was"
    echo "    changed. All three values are needed together; a remote written"
    echo "    from two of them would fail every half hour."
    echo ""
    print_key_instructions
    run_report
    sync
    exit 0
fi

# Nothing is recorded and no key material was supplied. offsite.env is still
# written, because it records which rclone the backend runs, and that is a fact
# about this unit whether or not it backs up. What it does NOT do is declare
# DTK_OFFSITE_REMOTE, and it declares DTK_RCLONE_CONFIG only when this run
# established that path.
#
# DTK_OFFSITE_REMOTE used to be declared empty here, on the reasoning that an
# explicit empty value states "disabled" more clearly than an absent key. It
# states it to the wrong audience: offsite.env is later than .env in the
# backend's env_file tuple, so an empty declaration here overrides .env with
# nothing. On the first run of this version on a unit an earlier version had
# configured through .env, that turned a working backup off.
#
# Nothing below claims to have disabled anything, and nothing below says what
# the backend will do: this script does not read .env and cannot speak for
# what it sets. It reports the file it inspected, and stops there.
offsite_write_or_fail ""
sync
describe_config_state "  "
if [ "$CONFIG_STATE" = "complete" ]; then
    echo "    Nothing this script wrote names it. If that credential is meant"
    echo "    to be used, name this unit's bucket, which needs no new"
    echo "    credential:"
    echo "      sudo DTK_OFFSITE_BUCKET=<bucket> $SCRIPT_DIR/provision-rclone.sh"
elif [ "$CONFIG_STATE" = "missing" ]; then
    echo "    This unit has no credential of its own yet, which is the"
    echo "    expected state until it has been issued one."
fi
echo ""
print_key_instructions
run_report
