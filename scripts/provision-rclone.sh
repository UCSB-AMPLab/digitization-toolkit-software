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
# same reason. The difference between those two calls is explained under
# --advisory below.
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
#      material means no remote, and the script says so after reading the
#      actual state rather than assuming it. It never invents, guesses or
#      defaults a credential, and it never replaces an existing one.
#
#      It does NOT read or write the project .env for settings, in either
#      direction. That file has another writer — generate-secrets.sh rotates
#      the database password through it — and two writers to one file cannot
#      be made safe from inside one of them: a provisioner holding an older
#      snapshot could restore a stale password while every key name still
#      matched, which no amount of validation in here would catch. The
#      backend reads offsite.env in addition to .env, and offsite.env wins.
#      The one exception is a single read-only check that reports stale
#      DTK_OFFSITE_* lines an earlier version of this script left in .env.
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
# diagnosis printed is identical, and nothing is skipped quietly — the only
# difference is whether the calling script dies with this one.
#
#   setup.sh calls it plainly. At provisioning the hard exit is correct: a
#   unit that cannot end up with a working rclone should not be handed to an
#   archive as provisioned, which is the stance install-kiosk-service.sh
#   takes when triggerhappy cannot be installed.
#
#   update.sh must call it with --advisory. There the cost inverts. A field
#   unit that is merely offline, updating to a release whose dependency
#   manifests did not move, would otherwise abort an otherwise fine update
#   over a feature that is disabled on that unit until it has a key. The
#   NEH-214/215/216/218 cluster exists because failed updates on remote units
#   are expensive; an appliance in an archive losing its update because a
#   backup binary could not be fetched is a worse outcome than that backup
#   staying unprovisioned for another week. The operator still sees the whole
#   message, and the next run with a connection provisions it.
#
#   The contract is enforced by a trap on ERR, not by routing the failure
#   paths this script happens to know about. Under `set -euo pipefail` an
#   unguarded command that fails never reaches a handler at all: counting the
#   explicit exits says nothing about the implicit ones, and an unzip that
#   returns 50 would otherwise abort an update that --advisory was added
#   specifically to protect.
#
# Key material, when there is any, is supplied in a FILE, not on the command
# line — see the instructions this script prints when none is present, and
# the reasoning beside DTK_OFFSITE_KEY_FILE below. Exported environment
# variables are still accepted for a caller that has set them up properly in
# its own shell.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# Referenced for ONE read-only check, reported below: whether an earlier
# version of this script left DTK_OFFSITE_* lines in it. Nothing here writes,
# renames or filters this file. See the offsite.env section for why.
PROJECT_ENV_FILE="$PROJECT_ROOT/.env"

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
#
# The default is used unless offsite.env — written by this script and by
# nothing else — already names a different path, which is read further down.
RCLONE_CONFIG_DEFAULT="${PREFIX}/var/lib/dtk/rclone.conf"
RCLONE_CONFIG_PATH="$RCLONE_CONFIG_DEFAULT"

# The settings file this script owns. Fixed, because the backend's
# app/core/config.py names the same path in its env_file tuple; the only thing
# that moves it is --prefix, for a dry run.
OFFSITE_ENV_PATH="${PREFIX}/var/lib/dtk/offsite.env"

# The remote name this script WRITES into the rclone config. The remote it
# CHECKS is whichever one the selected settings actually name, which is not
# always this one — see the state diagnosis in step 2.
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

# ── Validation of every value this script writes anywhere ───────────────────
#
# DO NOT REMOVE THESE AS NOW-DECORATIVE. The shell-sourcing threat they were
# first written for IS gone: this script no longer writes .env, so nothing it
# produces is ever sourced by root in update.sh or rollback-update.sh. What
# remains is still real, and it is the reason each check keeps its full
# character class:
#
#   • /var/lib/dtk/offsite.env is parsed by python-dotenv in the backend.
#   • The rclone config is an INI file, where a newline or a '[' in a value
#     adds or redirects a remote — see valid_b2_token.
#   • A value that is merely wrong, rather than hostile, is caught here at
#     provisioning time instead of becoming a backup that fails every thirty
#     minutes looking like a credentials problem.
#
# Where these came from, since the original reason no longer applies and the
# checks are easier to justify than to re-derive. They were written when this
# script wrote the project .env, which scripts/update.sh:45-51 and
# scripts/rollback-update.sh:61-67 both source AS ROOT:
#   set -a; . "$PROJECT_ROOT/.env"; set +a
# A key file line reading BUCKET=$(whatever) became
# DTK_OFFSITE_REMOTE=b2unit:$(whatever) and executed there. key_file_value
# below parses the operator's file rather than sourcing it, and without these
# checks that precaution was defeated one function later by the write into
# .env. Dropping .env as a destination removed that path; it did not remove
# the ones listed above.
#
# Validation, not quoting, for the files that remain. A value still passes
# through python-dotenv and through rclone's INI parser, whose rules are not
# the same as each other's, so a quoting scheme that satisfies one can break
# the other. Rejecting the value on the way in is the fix, and it also catches
# an operator's typo at provisioning time instead of turning it into a backup
# that fails every half hour.

# B2 bucket names, per Backblaze's native API: 6 to 63 characters of letters,
# digits, hyphens and periods. Uppercase and periods are both permitted there,
# which an earlier version of this line refused — it had been written from S3
# convention rather than from B2's rules, so `myBucket`, `bucket.name` and any
# name over 50 characters were rejected at provisioning, in an archive, with a
# message asserting a rule B2 does not have.
#
# What this check is FOR, and it is worth being clear because the class looks
# lax: catching an operator's typo or a character pasted invisibly out of the
# Backblaze console, and keeping the bucket name safe for the two files it
# reaches — /var/lib/dtk/offsite.env, which python-dotenv parses, and the
# rclone config, which is INI.
#
# What it is NOT: a B2 validator. It deliberately does not check period
# placement, adjacent periods, an IPv4-shaped name or the reserved "b2-"
# prefix. B2 enforces those itself, and the listing probe further down
# surfaces the refusal at provisioning time with B2's own message, which is
# more use than a second-hand copy of a rule that can change.
#
# One naming note for whoever reads this next, not a rule for this validator:
# B2's S3-compatible API is stricter than the native one and accepts lowercase
# only, so a bucket that will ever be served over the S3 endpoint should be
# named in lowercase by convention.
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
# What this class prevents is config-file injection. These two values are
# written into the rclone config, which is INI: $(...) is inert there because
# rclone parses it rather than executing it, but a newline, a '[' or a '#'
# would let a key add a second remote, redirect one, or truncate the file.
# That is why a newline must never pass, even though a newline is harmless in
# a shell-quoted string — and it is the half of the original reasoning that
# survived .env being dropped as a destination.
#
# The check also stays rather than being dropped as unknowable because
# Backblaze warn that copying a highlighted key out of their console can carry
# hidden formatting characters with it, and that the symptom is an
# invalid-key error. Those characters do not match this class, so they are
# caught here with a message naming what happened — instead of becoming a
# backup that fails every thirty minutes looking like a credentials problem,
# which is the exact failure NEH-227 already lost a day to.
valid_b2_token() { [[ "$1" =~ ^[A-Za-z0-9_+/=-]+$ ]]; }
# Kept beside the pattern on purpose. These were 400 lines apart, and a
# mutation test caught the consequence: with the pattern reverted and the
# wording left alone, the script enforced one class while naming another. Only
# one of those two edits fails loudly, so they live together.
B2_TOKEN_CLASS="letters, digits, and _ + / = - only"
# An absolute path with no character that could change the meaning of a file
# this script writes.
valid_abs_path() { [[ "$1" =~ ^/[A-Za-z0-9._/+-]+$ ]]; }
# Beside the pattern, for the same reason as the two above.
ABS_PATH_RULE="an absolute path, characters A-Z a-z 0-9 . _ / + -"

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
# This script used to read and write the project .env. It no longer touches it
# for settings, in either direction, and that is a design decision rather than
# a tidy-up.
#
# .env has another writer. scripts/generate-secrets.sh rotates the Postgres
# password and then publishes a matching .env; a provisioner holding an older
# snapshot of that file could rewrite it afterwards and restore the OLD
# password. Every key name still matched, so a key-set check passed and an
# exact-line check passed, and the next application start could not
# authenticate. The validation worked and still erased another process's
# work — two writers to one file cannot be made safe from inside one of them.
# Editing .env also meant parsing syntax this script did not write, which is
# where the quoting, `export`, `${...}` and multiline cases all came from.
#
# So: the offsite settings go in a file with exactly one writer, in a format
# this script defines, rebuilt whole on every run rather than edited in place.
# The backend reads it in ADDITION to .env — app/core/config.py has
# env_file=('../.env', '/var/lib/dtk/offsite.env') on pydantic-settings 2.7.0,
# where the LATER file wins on a conflict and a missing file in the tuple is
# tolerated silently. That means the two halves can land in either order with
# no window in which a unit is broken, and that a stale DTK_OFFSITE_* line
# left in .env by an earlier version of this script is inert.
#
# Because the format is ours, the reader below is strict: exactly KEY=value,
# no quoting, no `export`, no trailing comment. Anything else in a key this
# script cares about is reported, not guessed at — the file should only ever
# have been written by the writer below.

# Read one key from offsite.env. Sets globals rather than printing, so it
# needs no subshell:
#   OFFSITE_GET_STATUS  ok | absent | malformed
#   OFFSITE_GET_VALUE   the value when ok (may legitimately be empty)
#   OFFSITE_GET_LINE    the offending line when malformed
OFFSITE_GET_STATUS=""
OFFSITE_GET_VALUE=""
OFFSITE_GET_LINE=""
offsite_get() {
    local key="$1" hit v
    OFFSITE_GET_STATUS="absent"; OFFSITE_GET_VALUE=""; OFFSITE_GET_LINE=""
    [ -f "$OFFSITE_ENV_PATH" ] || return 0
    hit="$( { grep -n "^${key}=" "$OFFSITE_ENV_PATH" 2>/dev/null || true; } | tail -1 )"
    if [ -z "$hit" ]; then
        # Not in the strict form. If the key appears at all, the file is not
        # one this script wrote, and that is worth saying rather than
        # silently reading it as absent.
        hit="$( { grep -nE "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" \
                       "$OFFSITE_ENV_PATH" 2>/dev/null || true; } | tail -1 )"
        if [ -n "$hit" ]; then
            OFFSITE_GET_STATUS="malformed"
            OFFSITE_GET_LINE="${hit#*:}"
        fi
        return 0
    fi
    v="${hit#*:}"
    v="${v#"$key="}"
    # Our writer never emits anything outside this class, so a value outside
    # it means the file was edited by something else.
    if ! [[ "$v" =~ ^[A-Za-z0-9._:/+-]*$ ]]; then
        OFFSITE_GET_STATUS="malformed"
        OFFSITE_GET_LINE="${hit#*:}"
        return 0
    fi
    OFFSITE_GET_STATUS="ok"
    OFFSITE_GET_VALUE="$v"
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
write_offsite_env() {   # write_offsite_env <bin> <config-path> <remote-or-empty>
    local bin="$1" cfg="$2" remote="$3" tmp
    # Every value is validated by its caller; this is the backstop, so no code
    # path can write something unexpected into a file python-dotenv parses.
    local v
    for v in "$bin" "$cfg" "$remote"; do
        if ! [[ "$v" =~ ^[A-Za-z0-9._:/+-]*$ ]]; then
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
    if ! {
        echo "# Digitization Toolkit — offsite catalogue backup (NEH-249, NEH-227)."
        echo "# Written whole by scripts/provision-rclone.sh at provisioning and on"
        echo "# every update. DO NOT EDIT: the next run replaces this file."
        echo "#"
        echo "# The backend reads this in addition to the project .env, and these"
        echo "# values win over anything .env says. An empty DTK_OFFSITE_REMOTE"
        echo "# disables offsite backup entirely."
        echo "DTK_RCLONE_BIN=$bin"
        echo "DTK_RCLONE_CONFIG=$cfg"
        echo "DTK_OFFSITE_REMOTE=$remote"
    } > "$tmp"; then
        rm -f "$tmp"
        echo "✗ rclone: could not write the new $OFFSITE_ENV_PATH. The existing"
        echo "  file, if any, was left exactly as it was."
        return 1
    fi
    # Verify before promoting. The rename is atomic, so what it promotes has
    # to be right — and a write that ran out of space mid-file returns
    # success often enough that the status alone is not evidence. Each line is
    # matched whole and literally. (None of these three values is a secret:
    # the two paths and the remote name with its bucket. The B2 application
    # key goes only to the rclone config file and never through here.)
    local want
    for want in "DTK_RCLONE_BIN=$bin" "DTK_RCLONE_CONFIG=$cfg" "DTK_OFFSITE_REMOTE=$remote"; do
        if ! grep -qxF "$want" "$tmp"; then
            rm -f "$tmp"
            echo "✗ rclone: the new $OFFSITE_ENV_PATH does not contain the exact line"
            echo "      $want"
            echo "  so it was not promoted. The existing file, if any, was left"
            echo "  exactly as it was."
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

# What state is the rclone config in, for the remote actually selected?
# Returns one of:
#   missing      the config file does not exist. The ONLY state that
#                authorises writing a credential.
#   complete     rclone loads the file and that remote's type, account and
#                key all have non-empty effective values.
#   incomplete   rclone loads the file, the remote's section is there, but it
#                is not usable.
#   foreign      rclone loads the file and it has no section for that remote,
#                but the file exists and holds something else.
#   unreadable   rclone cannot load the file at all.
#
# ASK RCLONE. This used to be an awk pass imitating goconfig, and it disagreed
# with the real parser in both directions. Verified against the pinned
# rclone v1.75.2 on 2026-10-16, all six by direct probe:
#
#   • Last assignment wins. "key = k" followed by "key =" leaves the key
#     EMPTY. The awk version remembered that a non-empty value had been seen
#     at some point and certified a credential rclone would not authenticate
#     with — a false `complete`.
#   • "[ b2unit ]" with spaces inside the brackets is a valid section. The awk
#     header match rejected it.
#   • "type: b2" is a valid assignment; colon and equals are both separators.
#     The awk matcher only accepted equals.
#   • A trailing "# comment" after a value is PART OF THE VALUE, not a
#     comment. Stripping it would have been a third disagreement.
#   • One unparseable line makes rclone refuse the WHOLE file, so a config
#     this script would have called complete may not load at all.
#   • A section with no type is invisible to `listremotes`, so that is not a
#     usable existence test.
#
# The last two false-absent cases are the dangerous direction: false absence
# reached the fresh-credential path, and that path overwrites. An uncertain
# read must never authorise an overwrite, which is why only `missing` does.
#
# `config show` is the authority for the field values; it is not an existence
# test, because its output for "no such section" and for "section present but
# empty" is identical. Existence is therefore a deliberately PERMISSIVE
# textual header match, which is safe in a way strictness was not: leaning
# towards "present" can only ever block an overwrite, never authorise one.
config_remote_state() {   # <rclone> <file> <remote>
    local rc_bin="$1" f="$2" want="$3" out st k ok=1
    # A remote name goes into a grep pattern below, so anything outside this
    # class is not interpreted at all — it is reported as uncertain, which
    # blocks the overwrite path like every other uncertain answer.
    if ! [[ "$want" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "unreadable"; return 0
    fi
    [ -e "$f" ] || { echo "missing"; return 0; }
    if [ ! -x "$rc_bin" ]; then
        echo "unreadable"; return 0
    fi
    # $out holds this unit's B2 application key when the credential is
    # complete. It is piped into grep and never echoed. Keep it that way.
    # `if cmd; then` and not `set +e`: an ERR trap fires on a failing command
    # whether or not errexit is on — only a condition context suppresses it.
    # With `set +e` here, a config rclone cannot load tripped the trap inside
    # this command substitution, so the caller got the generic "stopped
    # unexpectedly" abort instead of the unreadable diagnosis below. Caught in
    # the dry run for exactly that case.
    if out="$("$rc_bin" --config "$f" config show "$want" 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    if [ "$st" -ne 0 ]; then
        echo "unreadable"; return 0
    fi
    for k in type account key; do
        if ! printf '%s\n' "$out" | grep -qE "^${k}[[:space:]]*=[[:space:]]*[^[:space:]]"; then
            ok=0
        fi
    done
    if [ "$ok" -eq 1 ]; then
        echo "complete"; return 0
    fi
    if grep -qE "^[[:space:]]*\[[[:space:]]*${want}[[:space:]]*\][[:space:]]*$" "$f" 2>/dev/null; then
        echo "incomplete"; return 0
    fi
    echo "foreign"
}

reachable() {
    curl -fsS --head --max-time 15 "$1" >/dev/null 2>&1
}

# Leave after a failure to provision. Every caller has already printed its own
# diagnosis; this decides only whether the surrounding script dies with us. In
# advisory mode it says plainly that it is not failing the caller, so a reader
# of an update log can tell "this was tolerated" from "nothing went wrong".
provision_failed() {
    if [ "$ADVISORY" -eq 1 ]; then
        echo ""
        echo "  --advisory: not failing the caller. Offsite backup stays"
        echo "  unprovisioned on this unit; everything above still applies and"
        echo "  the next run with a working connection will provision it."
        echo ""
        exit 0
    fi
    exit 1
}

offsite_write_or_fail() {   # <bin> <config-path> <remote-or-empty>
    if ! write_offsite_env "$1" "$2" "$3"; then
        provision_failed
    fi
}

# Everything that is NOT one of the failures below — an unzip that returns 50,
# an install that cannot write, a chown that fails — lands here, so --advisory
# means what it says for every failure rather than for the enumerated ones.
# `set -E` carries the trap into functions.
#
# It reports the failing command rather than $LINENO: inside an ERR trap
# $LINENO gives the line of the enclosing compound statement, not of the
# command that failed, so it pointed at the `fi` of the install block for a
# failure in the middle of it — a wrong line number sends the next person to
# the wrong place. $BASH_COMMAND is the command text, pre-expansion, and no
# command in this script carries the application key: the key only ever
# reaches a heredoc and a variable, never an argument list. Keep it that way
# if you add one.
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
    # message, the script carried on with that string as a directory path, and
    # went on to diagnose a different, later failure. A failure that becomes a
    # value is worse than one that stops the run, because everything after it
    # is reasoning about a string that was an error message.
    #
    # Preserving the status is enough: the failing assignment then fails in
    # the parent, where this trap fires again with BASH_SUBSHELL at 0, reports
    # the whole assignment as the failing command, and converts to success
    # there if --advisory was given. Printing nothing here keeps the
    # substitution's output clean and avoids diagnosing the same failure
    # twice.
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

# Everything below is written to, and read from, offsite.env — this script's
# own file, with no other writer. The project .env is touched exactly once,
# read-only, to report stale keys an earlier version of this script left in
# it.

# ── 2.1 Values an earlier version of this script left in .env ───────────────
# Reported, never removed: removing them would be editing .env again, which is
# the thing this script stopped doing. They are inert, because offsite.env is
# later in the backend's env_file tuple and therefore wins.
#
# Keyed on the VALUE, not on the key name. .env.example documents all eight
# DTK_OFFSITE_*/DTK_RCLONE_* variables and setup.sh copies it verbatim to
# .env, so every unit has those key names and reporting on names alone printed
# this notice on every run of every unit — noise, and noise that would train
# an operator to skip exactly the paragraph that matters. Only a value this
# script would have written counts: an absolute path for either of the two
# paths, or a non-empty remote.
#
# Read-only. One grep, no rewrite, no rename, no filter.
env_file_value() {   # <key> -> prints the raw value, or nothing
    [ -f "$PROJECT_ENV_FILE" ] || return 0
    { sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1[[:space:]]*=//p" \
          "$PROJECT_ENV_FILE" 2>/dev/null | tail -1 \
        | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' ; } || true
}
STALE_NOTES=""
_v="$(env_file_value DTK_OFFSITE_REMOTE)"
[ -z "$_v" ] || STALE_NOTES="$STALE_NOTES
      DTK_OFFSITE_REMOTE=$_v"
_v="$(env_file_value DTK_RCLONE_BIN)"
case "$_v" in /*) STALE_NOTES="$STALE_NOTES
      DTK_RCLONE_BIN=$_v" ;; esac
_v="$(env_file_value DTK_RCLONE_CONFIG)"
case "$_v" in /*) STALE_NOTES="$STALE_NOTES
      DTK_RCLONE_CONFIG=$_v" ;; esac
if [ -n "$STALE_NOTES" ]; then
    echo "  note: $PROJECT_ENV_FILE still carries values an earlier version of"
    echo "  this script wrote into it:$STALE_NOTES"
    echo "    They are inert and were NOT touched. This script no longer"
    echo "    writes .env at all — that file has another writer"
    echo "    (generate-secrets.sh rotates the database password through it),"
    echo "    and two writers to one file cannot be made safe from inside one"
    echo "    of them. The backend reads $OFFSITE_ENV_PATH"
    echo "    in addition to .env and that file wins, so a stale value there"
    echo "    changes nothing. Delete those lines by hand if you want the"
    echo "    file tidy."
fi

# ── 2.2 Where the credential lives ──────────────────────────────────────────
# offsite.env may already name a config path from a previous run. Only this
# script writes that file, so a value in it is one this script put there.
offsite_get DTK_RCLONE_CONFIG
case "$OFFSITE_GET_STATUS" in
    ok)
        if [ -n "$OFFSITE_GET_VALUE" ]; then
            if ! valid_abs_path "$OFFSITE_GET_VALUE"; then
                reject_value "rclone config path recorded in $OFFSITE_ENV_PATH" \
                    "$OFFSITE_GET_VALUE" "$ABS_PATH_RULE"
                provision_failed
            fi
            RCLONE_CONFIG_PATH="$OFFSITE_GET_VALUE"
        fi
        ;;
    malformed)
        echo "  ⚠ $OFFSITE_ENV_PATH is not in the format this script writes."
        echo "    This line declares DTK_RCLONE_CONFIG in a way the reader will"
        echo "    not guess at:"
        echo "        $OFFSITE_GET_LINE"
        echo "    That file is written whole by this script and by nothing"
        echo "    else, so it has been edited by hand or by something else."
        echo "    Nothing was changed. Delete it and re-run to have it"
        echo "    rebuilt, or correct the line to a plain KEY=value."
        sync
        echo ""
        exit 0
        ;;
esac

# ── 2.3 What the settings currently select ──────────────────────────────────
offsite_get DTK_OFFSITE_REMOTE
case "$OFFSITE_GET_STATUS" in
    malformed)
        echo "  ⚠ $OFFSITE_ENV_PATH is not in the format this script writes."
        echo "    This line declares DTK_OFFSITE_REMOTE in a way the reader"
        echo "    will not guess at:"
        echo "        $OFFSITE_GET_LINE"
        echo "    No claim is made here about whether backup is on or off."
        echo "    Nothing was changed. Delete that file and re-run to have it"
        echo "    rebuilt, or correct the line to a plain KEY=value."
        sync
        echo ""
        exit 0
        ;;
esac
SELECTED_REMOTE="$OFFSITE_GET_VALUE"

# ── 2.4 Key material ────────────────────────────────────────────────────────
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

# ── 2.5 Which remote is actually selected, and is THAT one usable ───────────
# The check used to be hardcoded to the remote this script writes, so a
# selected remote of "missing:archive" alongside a complete [b2unit] section
# reported CONFIGURED — it validated the remote it expected instead of the one
# in force. The name is now taken from the selected settings.
#
# A spec is "<remote>:<bucket>". Anything else is not something to interpret.
SELECTED_NAME=""
SELECTED_BUCKET=""
SELECTED_MALFORMED=0
if [ -n "$SELECTED_REMOTE" ]; then
    case "$SELECTED_REMOTE" in
        *:*)
            SELECTED_NAME="${SELECTED_REMOTE%%:*}"
            SELECTED_BUCKET="${SELECTED_REMOTE#*:}"
            if [ -z "$SELECTED_NAME" ] || [ -z "$SELECTED_BUCKET" ]; then
                SELECTED_MALFORMED=1
            fi
            ;;
        *) SELECTED_MALFORMED=1 ;;
    esac
fi

# When key material is being written, the remote that matters is the one about
# to be written, not whatever is recorded now.
CHECK_NAME="$SELECTED_NAME"
if [ "$HAVE_KEY" -eq 1 ]; then
    CHECK_NAME="$RCLONE_REMOTE_NAME"
fi
# With nothing selected and no key material, ask about the remote this script
# writes, so the disabled path still reports the state of the file it would
# write rather than assuming there is nothing there.
if [ -z "$CHECK_NAME" ]; then
    CHECK_NAME="$RCLONE_REMOTE_NAME"
fi
CONFIG_STATE="$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$CHECK_NAME")"

if [ "$SELECTED_MALFORMED" -eq 1 ] && [ "$HAVE_KEY" -eq 0 ]; then
    echo "  ⚠ The recorded DTK_OFFSITE_REMOTE is not a remote specification:"
    echo "        $SELECTED_REMOTE"
    echo "    It must be <remote>:<bucket>, e.g. $RCLONE_REMOTE_NAME:<bucket>."
    echo "    No claim is made about whether backup works, and nothing was"
    echo "    changed. Supply this unit's key material to rewrite it, or"
    echo "    delete $OFFSITE_ENV_PATH and re-run."
    echo ""
    print_key_instructions
    sync
    echo ""
    exit 0
fi

# ── 2a. The selected remote is backed by a complete credential ──────────────
# Never overwritten, never re-derived. Re-assert the mode and owner, which is
# what drifts (a cloned SD card, a file copied in as root), and rewrite
# offsite.env so the recorded paths are current.
if [ "$HAVE_KEY" -eq 0 ] && [ -n "$SELECTED_NAME" ] && [ "$CONFIG_STATE" = "complete" ]; then
    chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
    chmod 0600 "$RCLONE_CONFIG_PATH"
    offsite_write_or_fail "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$SELECTED_REMOTE"
    sync
    echo "  $RCLONE_CONFIG_PATH has a complete [$SELECTED_NAME] remote — left untouched."
    echo "  mode 0600, owner $DTK_USER  ✓"
    echo "  DTK_OFFSITE_REMOTE=$SELECTED_REMOTE"
    echo "  Offsite backup is CONFIGURED on this unit."
    echo ""
    exit 0
fi

# ── 2a-bis. A remote is selected but its credential is not usable ───────────
# Either the config has no section for the selected remote at all, or it has
# one that is missing type, account or key. Preserved, not overwritten, and
# not overwritten even when fresh key material is to hand for a DIFFERENT
# remote name: this script does not delete a credential an operator may have
# half-typed, and it cannot tell a half-typed one from a truncated one.
if [ "$HAVE_KEY" -eq 0 ] && [ -n "$SELECTED_NAME" ]; then
    echo "  ⚠ This unit is HALF-CONFIGURED, and offsite backup is NOT working."
    echo "      DTK_OFFSITE_REMOTE = $SELECTED_REMOTE   (set, so the backend will try)"
    echo "      $RCLONE_CONFIG_PATH"
    case "$CONFIG_STATE" in
        missing)
            echo "        does not exist, so every attempt will fail."
            ;;
        foreign)
            echo "        exists but has no [$SELECTED_NAME] section, so every"
            echo "        attempt will fail. It does hold something else, and"
            echo "        this script will not replace a config file it did"
            echo "        not write."
            ;;
        incomplete)
            echo "        has a [$SELECTED_NAME] section, but rclone reads it as"
            echo "        unusable: type, account and key must all have"
            echo "        non-empty effective values, and at least one does"
            echo "        not. Note that a later assignment overrides an"
            echo "        earlier one, so a trailing 'key =' empties a key set"
            echo "        above it."
            chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
            chmod 0600 "$RCLONE_CONFIG_PATH"
            echo "        mode 0600, owner $DTK_USER re-asserted; the file is"
            echo "        otherwise left exactly as it is."
            ;;
        unreadable)
            echo "        exists but rclone CANNOT LOAD IT, so no claim is"
            echo "        made here about what it contains. One unparseable"
            echo "        line makes rclone refuse the whole file. See:"
            echo "          sudo -u $DTK_USER $RCLONE_USE_BIN --config \\"
            echo "              $RCLONE_CONFIG_PATH config show $SELECTED_NAME"
            ;;
    esac
    echo ""
    echo "    This is not a deliberate no-op. Nothing here will overwrite that"
    echo "    credential, including a re-run with key material: it may be"
    echo "    something an operator was part way through. Resolve it one of"
    echo "    two ways:"
    echo "      • move the credential aside and provision a new one:"
    echo "          sudo mv $RCLONE_CONFIG_PATH $RCLONE_CONFIG_PATH.bad"
    echo "          sudo DTK_OFFSITE_KEY_FILE=<file> $SCRIPT_DIR/provision-rclone.sh"
    echo "      • or, if this unit is not meant to back up offsite, delete"
    echo "        $OFFSITE_ENV_PATH and re-run to record it as disabled."
    echo ""
    print_key_instructions
    sync
    echo ""
    exit 0
fi

# ── 2b. Key material was supplied ───────────────────────────────────────────
if [ "$HAVE_KEY" -eq 1 ]; then
    # ONLY a config file that does not exist authorises writing one. Every
    # other state — complete, incomplete, foreign, unreadable — preserves what
    # is there.
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
        case "$CONFIG_STATE" in
            complete)
                echo "    rclone reads it as a complete [$CHECK_NAME] remote, so this"
                echo "    unit already has a working credential."
                ;;
            incomplete)
                echo "    rclone reads its [$CHECK_NAME] section as unusable, but it"
                echo "    may be something an operator was part way through"
                echo "    typing, so it is preserved rather than replaced."
                ;;
            foreign)
                echo "    It has no [$CHECK_NAME] section, but it does hold something"
                echo "    else. Writing a credential here replaces the whole"
                echo "    file, which would delete whatever that is."
                ;;
            unreadable)
                echo "    rclone CANNOT LOAD IT, so there is no telling what it"
                echo "    contains. An unreadable file is not an empty one, and"
                echo "    it does not authorise an overwrite."
                ;;
        esac
        chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
        chmod 0600 "$RCLONE_CONFIG_PATH"
        echo "    mode 0600, owner $DTK_USER re-asserted."
        echo ""
        echo "    To replace it with the key material you supplied, move it"
        echo "    aside and re-run:"
        echo "      sudo mv $RCLONE_CONFIG_PATH $RCLONE_CONFIG_PATH.bad"
        echo "      sudo DTK_OFFSITE_KEY_FILE=<file> $SCRIPT_DIR/provision-rclone.sh"
        sync
        echo ""
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
    cat > "$RCLONE_CONF_TMP" <<EOF
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
EOF
    chown "$DTK_USER:$DTK_USER" "$RCLONE_CONF_TMP"
    mv "$RCLONE_CONF_TMP" "$RCLONE_CONFIG_PATH"
    trap - EXIT
    echo "  mode 0600, owner $DTK_USER  ✓"

    # Verify what was just written really is a complete credential for the
    # remote about to be selected, before recording that selection. Writing
    # the file and trusting it are two different things.
    if [ "$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$RCLONE_REMOTE_NAME")" != "complete" ]; then
        echo "✗ rclone: the credential just written to $RCLONE_CONFIG_PATH does"
        echo "  not read back as a complete [$RCLONE_REMOTE_NAME] remote."
        echo "  $OFFSITE_ENV_PATH was NOT updated, so the backend is not being"
        echo "  pointed at a credential that cannot be used."
        provision_failed
    fi

    if [ -n "$SELECTED_REMOTE" ] && [ "$SELECTED_REMOTE" != "$RCLONE_REMOTE_NAME:$B2_BUCKET" ]; then
        echo "  note: replacing the recorded remote $SELECTED_REMOTE"
    fi
    offsite_write_or_fail "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" \
        "$RCLONE_REMOTE_NAME:$B2_BUCKET"
    sync
    echo "  $OFFSITE_ENV_PATH written  ✓ (mode 0600, owner $DTK_USER)"
    echo "  DTK_OFFSITE_REMOTE=$RCLONE_REMOTE_NAME:$B2_BUCKET  ✓"
    echo "  Offsite backup is CONFIGURED on this unit."

    # Best-effort, never fatal: one listing call against the bucket turns a
    # mistyped key into a provisioning-time message instead of a backup that
    # fails every half hour afterwards with something that reads as a
    # credentials problem. Skipped entirely when the unit is offline — being
    # unable to ask is not an answer, so it must not be reported as one, and
    # must not fail the run.
    if reachable "https://api.backblazeb2.com"; then
        echo "  Checking the key against $B2_BUCKET..."
        if "$RCLONE_USE_BIN" --config "$RCLONE_CONFIG_PATH" lsf --max-depth 1 \
                --retries 1 --low-level-retries 1 --contimeout 10s --timeout 20s \
                "$RCLONE_REMOTE_NAME:$B2_BUCKET" >/dev/null 2>&1; then
            echo "  the key can list $B2_BUCKET  ✓"
        else
            echo "  ⚠ rclone could not list $RCLONE_REMOTE_NAME:$B2_BUCKET. The remote is"
            echo "    recorded and the backend will use it, but check the key id, the"
            echo "    application key, the bucket name, and that the key grants"
            echo "    listFiles on that bucket. Run this to see the actual error:"
            echo "      sudo -u $DTK_USER $RCLONE_USE_BIN --config $RCLONE_CONFIG_PATH \\"
            echo "          lsf --max-depth 1 $RCLONE_REMOTE_NAME:$B2_BUCKET"
        fi
    else
        echo "  (offline — the key was not checked against B2)"
    fi
    echo ""
    exit 0
fi

# ── 2c. Nothing is selected and no complete key material was supplied ───────

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
    sync
    echo ""
    exit 0
fi

# Nothing is selected and no key material was supplied. offsite.env is still
# written, with an empty remote: it records which rclone the backend should
# run, and an explicit empty remote states "disabled" more clearly than an
# absent file. Nothing already on this unit is changed by it, because reaching
# here means offsite.env named no remote in the first place.
#
# But "nothing selected" is not the same fact as "nothing here", and the state
# of the credential file is reported either way rather than being summarised
# as disabled. A complete credential that nothing selects is an unfinished
# provisioning, not a deliberate no-op.
offsite_write_or_fail "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" ""
sync
echo "  $OFFSITE_ENV_PATH written  ✓ (mode 0600, owner $DTK_USER)"
echo "  DTK_OFFSITE_REMOTE is empty, so the backend will not attempt a backup."
case "$CONFIG_STATE" in
    complete)
        echo "  ⚠ But $RCLONE_CONFIG_PATH DOES hold a complete"
        echo "    [$CHECK_NAME] remote. This unit is not disabled by intent; it is"
        echo "    an unfinished provisioning — the credential is there and"
        echo "    nothing selects it. Finish it by naming this unit's bucket,"
        echo "    which needs no new credential:"
        echo "      sudo DTK_OFFSITE_BUCKET=<bucket> $SCRIPT_DIR/provision-rclone.sh"
        sync
        echo ""
        exit 0
        ;;
    incomplete)
        echo "  note: $RCLONE_CONFIG_PATH has a [$CHECK_NAME] section that rclone"
        echo "    reads as unusable. It was left exactly as it is. Offsite"
        echo "    backup is off either way, but that file is not a working"
        echo "    credential and will not become one by itself."
        ;;
    unreadable)
        echo "  note: $RCLONE_CONFIG_PATH exists and rclone CANNOT LOAD IT, so no"
        echo "    claim is made about what it contains. It was left exactly as"
        echo "    it is. Offsite backup is off either way."
        ;;
    foreign)
        echo "  note: $RCLONE_CONFIG_PATH exists and holds other rclone remotes,"
        echo "    but nothing for [$CHECK_NAME]. It was left exactly as it is."
        ;;
    missing)
        echo "  Offsite backup is DISABLED on this unit, which is the intended"
        echo "  state until it has been issued its own key."
        ;;
esac
echo ""
print_key_instructions
echo ""
