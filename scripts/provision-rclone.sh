#!/bin/bash
# xtrace off before anything else runs. This script holds B2 application keys
# in variables and writes them through heredocs, and an xtrace inherited from
# `bash -x`, from SHELLOPTS=xtrace in the environment, or from a caller that
# sourced it, would print every one of those lines, keys included, to stderr
# and into whatever log captures it.
set +x
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
#      writes its six keys to offsite.env, the backend reads that file in
#      addition to .env, and offsite.env wins on a conflict.
#
# Network use: none at all when a new-enough rclone is already installed AND
# no new credential is being written. Writing a credential adds one listing
# call against the bucket, which is skipped when the unit is offline. A read
# key supplied to the run adds one listing of the tenant prefix through it,
# under the same conditions; a run with no key material makes neither. Both
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
# --config-path names the rclone config file this run is to inspect, and on a
# fresh unit to write. Neither caller passes it. An operator needs it for the
# bucket-only recovery on a unit whose credential is not at the default path,
# because this script will not infer which file a recorded remote is served
# from — see the note on CONFIG_PATH_ESTABLISHED.
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
#
# ── THE 0.1.0 SETTINGS ──────────────────────────────────────────────────────
#
# Three more keys go into offsite.env beside the first three, each validated
# by the rule the backend applies to it, so that a value the backend would
# refuse is refused here, at provisioning, with the reason:
#
#   DTK_OFFSITE_TENANT          --tenant NAME. The prefix every object of this
#                               unit is keyed under. The rule is TENANT_PATTERN
#                               in backend app/core/image_upload.py. Replacing
#                               a recorded tenant also needs --change-tenant.
#   DTK_OFFSITE_DUMP_RECIPIENT  --dump-recipient age1... The age X25519 PUBLIC
#                               key the catalogue dump is encrypted to
#                               (backend app/core/catalogue_backup.py,
#                               dump_recipient). The private half never comes
#                               near the unit, and this script refuses one.
#   DTK_OFFSITE_READ_REMOTE     <name>:<bucket>, the remote an admin restore of
#                               freed files reads through. Written when a READ
#                               key is supplied, as a second section in the
#                               same rclone config, from the key file named by
#                               DTK_OFFSITE_KEY_FILE (READ_KEY_ID, READ_APP_KEY)
#                               and never from the environment.
#
# The tenant and the recipient are ARGUMENTS for the reason --prefix is: the
# callers pass none, update.sh exports every .env key before calling this
# script, and a value this script records should not be steerable from .env.
# A run given neither keeps what offsite.env already records, so setup.sh and
# update.sh carry them forward unchanged.

set -Eeuo pipefail

# readlink -f, so a script reached through a symlink still finds the checkout
# it belongs to rather than the symlink's parent.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ADVISORY=0
# Relocates every path this script writes under one directory. It is an
# ARGUMENT and not an environment variable on purpose: update.sh exports every
# .env key before calling this script, so an environment-variable override
# could be steered by a line in .env, which is exactly how the install
# destination once came to be the bare word `rclone`. argv cannot be reached
# that way. Used by the dry runs, and usable by hand against a staging tree.
PREFIX=""
# The rclone config file this run is to inspect, named explicitly by whoever
# invokes the script. An ARGUMENT for the same reason --prefix is: update.sh
# exports every .env key before calling this script, so an environment
# variable could be steered by a line in .env — and this value decides which
# file gets inspected and, on a fresh unit, written.
#
# It exists because inferring the file was wrong. See the note on
# CONFIG_PATH_ESTABLISHED: a complete [b2unit] section at the default path is
# not evidence that it is the credential behind a remote recorded with no path
# beside it.
CONFIG_PATH_ARG=""
# The 0.1.0 settings named on the command line. Empty means "not given", and a
# value not given keeps what offsite.env records. Validated below, once the
# ERR trap and provision_failed exist, so that a refusal honours --advisory.
TENANT_ARG=""
RECIPIENT_ARG=""
# Replacing a tenant that offsite.env already records needs this flag as well
# as --tenant: the prefix decides where every new object goes, and a mistyped
# one on a unit that has been uploading splits its objects across two prefixes.
CHANGE_TENANT=0
usage() {
    echo "  Usage: provision-rclone.sh [--advisory] [--prefix DIR]"
    echo "                             [--config-path FILE]"
    echo "                             [--tenant NAME [--change-tenant]]"
    echo "                             [--dump-recipient AGE1_PUBLIC_KEY]"
    echo "  Key material, for the write key and the optional read key, comes"
    echo "  from the file named by DTK_OFFSITE_KEY_FILE; run with no key"
    echo "  material to see its format."
}
# An age private key, in either case. Checked wherever a value might be
# echoed, so that the one secret this script is most likely to be handed by
# mistake is never printed back to a terminal or a log.
#
# Two matchers, for two decisions. looks_like_age_secret is loose — the words
# alone — and decides only whether a value may be PRINTED: a refusal withholds
# anything that merely resembles a key. holds_age_secret_key decides whether a
# value is REFUSED: AGE-SECRET-KEY-1 followed by at least 8 bech32 characters,
# in either case. Not the full 58, so that a key truncated in the paste (44
# characters, say) is still refused rather than recorded and printed; and not
# the words alone, so that a tenant, bucket or path such as
# age-secret-key-test is not turned away.
looks_like_age_secret() { [[ "$1" =~ [Aa][Gg][Ee]-[Ss][Ee][Cc][Rr][Ee][Tt]-[Kk][Ee][Yy]- ]]; }
holds_age_secret_key() {
    [[ "$1" =~ [Aa][Gg][Ee]-[Ss][Ee][Cc][Rr][Ee][Tt]-[Kk][Ee][Yy]-1[qpzry9x8gf2tvdw0s3jn54khce6mua7lQPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L]{8,} ]]
}
while [ $# -gt 0 ]; do
    case "$1" in
        --advisory) ADVISORY=1 ;;
        --change-tenant) CHANGE_TENANT=1 ;;
        --tenant)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "✗ provision-rclone.sh: --tenant needs a tenant prefix."
                exit 1
            fi
            TENANT_ARG="$2"
            shift
            ;;
        --dump-recipient)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "✗ provision-rclone.sh: --dump-recipient needs an age public key (age1...)."
                exit 1
            fi
            RECIPIENT_ARG="$2"
            shift
            ;;
        --prefix)
            if [ $# -lt 2 ]; then
                echo "✗ provision-rclone.sh: --prefix needs a directory."
                exit 1
            fi
            PREFIX="$2"
            shift
            ;;
        --config-path)
            if [ $# -lt 2 ]; then
                echo "✗ provision-rclone.sh: --config-path needs a file path."
                exit 1
            fi
            CONFIG_PATH_ARG="$2"
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
            if looks_like_age_secret "$1"; then
                echo "✗ provision-rclone.sh: unknown argument (not printed: it is"
                echo "  shaped like an age private key, AGE-SECRET-KEY-...)."
            else
                echo "✗ provision-rclone.sh: unknown argument '$1'."
            fi
            usage
            exit 1
            ;;
    esac
    shift
done
# A caller bug, like a missing argument value: the flag means nothing alone.
if [ "$CHANGE_TENANT" -eq 1 ] && [ -z "$TENANT_ARG" ]; then
    echo "✗ provision-rclone.sh: --change-tenant needs --tenant NAME beside it."
    usage
    exit 1
fi

# Resolve the real (non-root) user the same way setup.sh, update.sh and
# provision-chdk-usb.sh do, so this script behaves identically whichever one
# calls it, or run by hand. The rclone config file is owned by this user
# because the backend reads it as this user.
if [ -n "${SUDO_USER:-}" ]; then
    DTK_USER="$SUDO_USER"
else
    # No SUDO_USER means a service unit or a plain root shell, where whoami
    # is root: the file this script writes would then be unreadable by the
    # user the backend runs as. The checkout's owner is that user. Reproduced
    # on the bench unit 2026-10-20: update.sh under systemd-run wrote
    # offsite.env as root 0600 and the backend could not start.
    DTK_USER="$(stat -c %U "$PROJECT_ROOT" 2>/dev/null || whoami)"
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
# wrote a credential there, offsite.env already named it, or --config-path
# named it on the command line. When none of those holds, DTK_RCLONE_CONFIG is
# left OUT of offsite.env rather than written, so a path this run never
# established is not overridden — see write_offsite_env.
#
# THERE USED TO BE A FOURTH, AND IT WAS A REAL MISBEHAVIOUR. A run that found a
# complete section for the remote it was about to record, at whatever path it
# happened to be inspecting, treated that as establishing the path. The
# evidence for it is the section NAME, which is not evidence at all:
#
#   .env selects a working /opt/archive/live.conf; offsite.env records
#   DTK_OFFSITE_REMOTE=b2unit:archive and omits DTK_RCLONE_CONFIG; the default
#   /var/lib/dtk/rclone.conf holds a complete [b2unit] for a different
#   institution's bucket, left behind by an earlier provisioning attempt.
#
# The run inspected the default path, found a complete [b2unit], concluded
# that this was the credential behind the recorded remote, and wrote
# DTK_RCLONE_CONFIG=/var/lib/dtk/rclone.conf — promoting the stale credential
# over the working one, and reporting success.
#
# So a routine update now PRESERVES an omitted path: it rewrites offsite.env
# without DTK_RCLONE_CONFIG, and whatever .env sets stays in force. The
# bucket-only recovery, which does need the path recorded beside the selector
# it writes, REQUIRES the path to be named with --config-path rather than
# inferring it from a section name.
CONFIG_PATH_ESTABLISHED=0

# The settings file this script owns. Fixed, because the backend names the
# same path beside the project .env; the only thing that moves it is --prefix,
# for a dry run.
OFFSITE_ENV_PATH="${PREFIX}/var/lib/dtk/offsite.env"

# The remote name this script WRITES into the rclone config. The remote it
# INSPECTS is whichever one offsite.env actually names, which is not always
# this one.
RCLONE_REMOTE_NAME="b2unit"
# The section the READ key is written under, in the same config file: the
# backend runs every rclone call with the one DTK_RCLONE_CONFIG
# (_rclone_argv in backend app/core/catalogue_backup.py), restore included.
# A name of its own, so that the read key can never be what the write remote
# authenticates with, nor the reverse.
RCLONE_READ_REMOTE_NAME="b2read"

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
# A kill lands as a nonzero status, and the callers separate a status that
# came from the bound from one rclone itself returned — see
# config_remote_state.
#
# With neither timeout(1) nor gtimeout(1) on the box there is no bound to be
# had, and the previous version ran the command anyway with a warning. §2 now
# refuses before any bounded call instead, so this function is never reached
# unbounded; it returns 125 rather than running the command, as a backstop for
# a future caller added above that gate. 125 is timeout(1)'s own "the bound
# could not be applied" status, and it is not 1, so config_remote_state reads
# it as an inspection that did not run rather than as an answer about the
# file.
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
    if [ -z "$TIMEOUT_BIN" ]; then
        return 125
    fi
    # -k: rclone may have a child of its own still running, so follow TERM
    # with KILL rather than waiting on a process that ignored it.
    "$TIMEOUT_BIN" -k 5 "$secs" "$@"
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
valid_bucket()   { ! holds_age_secret_key "$1" && [[ "$1" =~ ^[A-Za-z0-9.-]{6,63}$ ]]; }
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
valid_b2_token() { ! holds_age_secret_key "$1" && [[ "$1" =~ ^[A-Za-z0-9_+/=-]+$ ]]; }
# Kept beside the pattern on purpose. These were 400 lines apart, and a
# mutation test caught the consequence: with the pattern reverted and the
# wording left alone, the script enforced one class while naming another. Only
# one of those two edits fails loudly, so they live together.
B2_TOKEN_CLASS="letters, digits, and _ + / = - only"
# An absolute path with no character that could change the meaning of a file
# this script writes.
valid_abs_path() { ! holds_age_secret_key "$1" && [[ "$1" =~ ^/[A-Za-z0-9._/+-]+$ ]]; }
ABS_PATH_RULE="an absolute path, characters A-Z a-z 0-9 . _ / + -"
# The class every value written into offsite.env must match.
OFFSITE_VALUE_CLASS='^[A-Za-z0-9._:/+-]*$'

# DTK_OFFSITE_TENANT, by the backend's own rule: TENANT_PATTERN,
# ^[a-z0-9]+(-[a-z0-9]+)*$, applied by configured_tenant() in backend
# app/core/image_upload.py. One path segment, so a mistyped prefix never
# becomes an object key.
#
# The letters are spelled out rather than written a-z: in a regex bracket a
# range follows the locale's collation, and under some locales [a-z] admits
# uppercase letters, which the backend's pattern does not.
#
# The backend strips surrounding whitespace and slashes before matching; this
# script refuses them instead, so offsite.env holds the one form the backend
# uses rather than a form it has to normalise.
#
# The tenant is also the unit's slug in Fisqua, <tenant>.fisqua.org, so it is
# held to Fisqua's slug rule as well, which is stricter than TENANT_PATTERN:
# 1 to 63 characters (a DNS label; the backend caps it at the same
# TENANT_MAX_LENGTH, 63), starting with a letter, and none of Fisqua's
# reserved slugs (platform, www, api, admin, app; a slug that only contains
# one is not reserved). Not ending with a hyphen, and single hyphens only,
# follow from the pattern.
#
# One more value is refused here explicitly: an age private key in lower case
# (age-secret-key-1...) is lowercase letters and digits joined by hyphens,
# and would otherwise become this unit's prefix in offsite.env and in every
# object key. Every validator in this script refuses an age private key for
# the same reason (holds_age_secret_key).
TENANT_MAX_LENGTH=63
TENANT_RESERVED="platform www api admin app"
valid_tenant() {
    local word
    holds_age_secret_key "$1" && return 1
    [ "${#1}" -le "$TENANT_MAX_LENGTH" ] || return 1
    for word in $TENANT_RESERVED; do
        [ "$1" != "$word" ] || return 1
    done
    [[ "$1" =~ ^[abcdefghijklmnopqrstuvwxyz][abcdefghijklmnopqrstuvwxyz0123456789]*(-[abcdefghijklmnopqrstuvwxyz0123456789]+)*$ ]]
}
TENANT_RULE="1 to 63 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen; not platform, www, api, admin or app; e.g. ahr, sbmal, captua-test"

# DTK_OFFSITE_DUMP_RECIPIENT, by the rule the backend applies: dump_recipient()
# in backend app/core/catalogue_backup.py passes the stripped value to
# pyrage.x25519.Recipient.from_str (pyrage 1.4.0, pinned in backend
# pixi.toml). That parser was asked directly, on 2026-10-24, what it accepts:
#
#   accepted   bech32 (not bech32m), human-readable part "age", a payload of
#              exactly 32 bytes, so 62 characters in all; all lowercase, or
#              all uppercase; the unused padding bits of the last data
#              character are not checked.
#   refused    mixed case, a bad checksum, a bech32m checksum, any other
#              length, any other prefix, surrounding whitespace, and an age
#              private key (AGE-SECRET-KEY-1...).
#
# This is that rule, in bash, with no dependency: the checksum is BIP-173's
# polymod over the expanded prefix "age" (3 3 3 0 1 7 5) and the 58 data and
# checksum characters, which must come to 1.
BECH32_CHARSET="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_CHK=1
bech32_step() {   # bech32_step <5-bit value>: one polymod round on BECH32_CHK
    local top=$(( BECH32_CHK >> 25 ))
    BECH32_CHK=$(( ((BECH32_CHK & 0x1ffffff) << 5) ^ $1 ))
    if (( top & 1 ));  then BECH32_CHK=$(( BECH32_CHK ^ 0x3b6a57b2 )); fi
    if (( top & 2 ));  then BECH32_CHK=$(( BECH32_CHK ^ 0x26508e6d )); fi
    if (( top & 4 ));  then BECH32_CHK=$(( BECH32_CHK ^ 0x1ea119fa )); fi
    if (( top & 8 ));  then BECH32_CHK=$(( BECH32_CHK ^ 0x3d4233dd )); fi
    if (( top & 16 )); then BECH32_CHK=$(( BECH32_CHK ^ 0x2a1462b3 )); fi
    return 0
}
valid_age_recipient() {
    local v="$1" lower rest c idx
    [ "${#v}" -eq 62 ] || return 1
    if [[ "$v" =~ [ABCDEFGHIJKLMNOPQRSTUVWXYZ] ]] && [[ "$v" =~ [abcdefghijklmnopqrstuvwxyz] ]]; then
        return 1
    fi
    lower="$(printf '%s' "$v" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
    [[ "$lower" =~ ^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$ ]] || return 1
    BECH32_CHK=1
    for idx in 3 3 3 0 1 7 5; do
        bech32_step "$idx"
    done
    rest="${lower:4}"
    while [ -n "$rest" ]; do
        c="${rest:0:1}"
        rest="${rest:1}"
        idx="${BECH32_CHARSET%%"$c"*}"
        bech32_step "${#idx}"
    done
    [ "$BECH32_CHK" -eq 1 ]
}
RECIPIENT_RULE="an age X25519 public key: age1 and 58 more bech32 characters (62 in all), one case throughout, with a valid checksum"

# The refusal for a recipient, which is not reject_value: when what was given
# is a private key, the value must not be printed.
reject_recipient() {   # reject_recipient <where it came from> <the value>
    if looks_like_age_secret "$2"; then
        echo "✗ rclone: refusing the catalogue dump recipient from $1: it is an"
        echo "  age PRIVATE key (AGE-SECRET-KEY-...), not the public recipient."
        echo "  The value is not printed, and it was not written to offsite.env."
        echo "  The unit holds only the public half (age1...), never the private"
        echo "  key. Pass the line age-keygen prints as 'Public key: age1...', or"
        echo "  the output of 'age-keygen -y' on the private key file. A value"
        echo "  typed on a command line is kept in the shell's history and is"
        echo "  visible to other users in the process table while the command"
        echo "  runs."
        return 0
    fi
    reject_value "catalogue dump recipient from $1" "$2" "$RECIPIENT_RULE"
}

# A remote specification, <remote>:<bucket>, as this script writes one: the
# name in the class config_remote_state will inspect, and a bucket. The
# backend does not parse DTK_OFFSITE_READ_REMOTE beyond requiring it to be
# non-empty (offsite_free.py on backend/free-local-space); it appends the
# object key to it, so it must name the remote and bucket the uploads went to.
valid_remote_spec() {
    local name="${1%%:*}" bucket="${1#*:}"
    holds_age_secret_key "$1" && return 1
    case "$1" in *:*) ;; *) return 1 ;; esac
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] && valid_bucket "$bucket"
}
REMOTE_SPEC_RULE="<remote>:<bucket>, the remote name in letters, digits, _ . - and a bucket of $B2_BUCKET_RULE"

# Never prints a value shaped like an age private key, whatever it was given
# as: a refusal is exactly where a pasted secret would otherwise be echoed.
reject_value() {   # reject_value <what it is> <the value> <the rule>
    echo "✗ rclone: refusing the $1."
    if looks_like_age_secret "$2"; then
        echo "    value: not printed: it is shaped like an age private key"
        echo "           (AGE-SECRET-KEY-...), which belongs nowhere on this unit"
    else
        echo "    value: $2"
    fi
    echo "    must match: $3"
    echo "  This is our check, not B2's: the value is written into files a"
    echo "  parser reads — the rclone config, and the offsite settings the"
    echo "  backend loads. No credential was written and $OFFSITE_ENV_PATH"
    echo "  was not changed."
}

# ── offsite.env: the file this script owns ──────────────────────────────────
#
# One writer, one grammar, rebuilt whole on every run rather than edited in
# place. .env.example's offsite section records the division of labour: this
# script writes DTK_OFFSITE_REMOTE, DTK_RCLONE_BIN and DTK_RCLONE_CONFIG here,
# and since 0.1.0 DTK_OFFSITE_READ_REMOTE, DTK_OFFSITE_TENANT and
# DTK_OFFSITE_DUMP_RECIPIENT; the backend reads this file IN ADDITION to the
# project .env, and this file WINS on a conflict.
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
# one of the six this script writes, no key twice, and the value inside
# OFFSITE_VALUE_CLASS. No quoting, no `export`, no indentation, no trailing
# comment, nothing else. Anything else makes the file MALFORMED: it is not
# read at all, nothing is changed, and the operator is told which line did it.
# A file this script did not write is not a file this script can interpret.
#
# TWO EXACT NOTES ON BLANK LINES, because this comment used to say "no blank
# lines" and that overstated what the reader enforces. The content is read
# through a command substitution, which strips every trailing newline, so
# trailing blank lines at the END of the file are not visible here at all and
# are accepted; an empty file reads as one empty line and is MALFORMED; a
# blank line in the MIDDLE is a line of its own and is MALFORMED. The writer
# emits no blank lines anywhere, so none of that loses anything.
#
# That same command substitution also drops NUL bytes, which is not a
# formatting nicety: `DTK_OFFSITE_REMOTE<NUL>=b2unit:x` would reach the line
# grammar below with the NUL gone and validate, while python-dotenv in the
# backend reads a key name this script never wrote. The file's bytes are
# therefore counted before any of its lines are read.
OFFSITE_STATUS=""      # ok | absent | malformed | unreadable | secret
OFFSITE_CFG=""         # DTK_RCLONE_CONFIG as recorded, when non-empty
OFFSITE_REMOTE=""      # DTK_OFFSITE_REMOTE as recorded, when non-empty
OFFSITE_TENANT_REC=""  # DTK_OFFSITE_TENANT as recorded, when non-empty
OFFSITE_RECIPIENT_REC=""   # DTK_OFFSITE_DUMP_RECIPIENT as recorded
OFFSITE_READ_REMOTE_REC=""  # DTK_OFFSITE_READ_REMOTE as recorded
OFFSITE_BAD_LINE=""    # the offending line when malformed
OFFSITE_BAD_WHY=""     # why that line is not in the grammar
read_offsite_env() {
    local content line key value st seen="" bytes stripped
    OFFSITE_STATUS="absent"
    OFFSITE_CFG=""; OFFSITE_REMOTE=""
    OFFSITE_TENANT_REC=""; OFFSITE_RECIPIENT_REC=""; OFFSITE_READ_REMOTE_REC=""
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
    # The NUL check, before any line is looked at: $content cannot hold a NUL,
    # so the file's own byte count is compared against its byte count with
    # NULs removed. `grep -z`/`grep -U` would be shorter and are not portable
    # between GNU and BSD grep, and `wc -c` and `tr -d` are both already
    # required by this script's surroundings. wc pads its output, hence the
    # digit filter.
    if ! bytes="$(wc -c < "$OFFSITE_ENV_PATH" 2>/dev/null)"; then
        OFFSITE_STATUS="unreadable"
        return 0
    fi
    if ! stripped="$(LC_ALL=C tr -d '\000' < "$OFFSITE_ENV_PATH" 2>/dev/null | wc -c)"; then
        OFFSITE_STATUS="unreadable"
        return 0
    fi
    bytes="${bytes//[^0-9]/}"
    stripped="${stripped//[^0-9]/}"
    if [ -z "$bytes" ] || [ -z "$stripped" ]; then
        OFFSITE_STATUS="unreadable"
        return 0
    fi
    if [ "$bytes" -ne "$stripped" ]; then
        OFFSITE_STATUS="malformed"
        # Not the line itself: it holds a NUL, and this goes to a terminal.
        OFFSITE_BAD_LINE="(not printed: the line holds a NUL byte)"
        OFFSITE_BAD_WHY="the file contains a NUL byte, which this script never writes, and which the backend's parser and this one would read differently"
        return 0
    fi
    # Before any line is parsed or printed: a file holding an age private
    # key is refused whole, so that no message below can echo it. A malformed
    # line that only resembles one is withheld from the malformed message
    # instead (offsite_malformed).
    if holds_age_secret_key "$content"; then
        OFFSITE_STATUS="secret"
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            "#"*) continue ;;
        esac
        if ! [[ "$line" =~ ^(DTK_RCLONE_BIN|DTK_RCLONE_CONFIG|DTK_OFFSITE_REMOTE|DTK_OFFSITE_READ_REMOTE|DTK_OFFSITE_TENANT|DTK_OFFSITE_DUMP_RECIPIENT)=[A-Za-z0-9._:/+-]*$ ]]; then
            OFFSITE_STATUS="malformed"
            OFFSITE_BAD_LINE="$line"
            if [ -z "$line" ]; then
                OFFSITE_BAD_WHY="an empty line, or an empty file"
            else
                OFFSITE_BAD_WHY="not a plain KEY=value in one of the six keys this script writes"
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
            DTK_OFFSITE_READ_REMOTE)    OFFSITE_READ_REMOTE_REC="$value" ;;
            DTK_OFFSITE_TENANT)         OFFSITE_TENANT_REC="$value" ;;
            DTK_OFFSITE_DUMP_RECIPIENT) OFFSITE_RECIPIENT_REC="$value" ;;
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
    if looks_like_age_secret "$OFFSITE_BAD_LINE"; then
        echo "        (not printed: the line resembles an age private key)"
    else
        echo "        $OFFSITE_BAD_LINE"
    fi
    echo "    ($OFFSITE_BAD_WHY.)"
    echo "    That file is written whole by this script and by nothing else,"
    echo "    so it has been edited by hand or by something else. It is"
    echo "    checked whole rather than key by key because the backend's own"
    echo "    parser reads syntax this script does not write, and the two"
    echo "    disagreeing about what the unit is configured to do is worse"
    echo "    than refusing to guess."
    echo "    Delete it and re-run to have it rebuilt, or reduce every line to"
    echo "    a '#' comment or a plain KEY=value in DTK_RCLONE_BIN,"
    echo "    DTK_RCLONE_CONFIG, DTK_OFFSITE_REMOTE, DTK_OFFSITE_READ_REMOTE,"
    echo "    DTK_OFFSITE_TENANT or DTK_OFFSITE_DUMP_RECIPIENT."
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
#
#   <read-remote>, <tenant>, <recipient>: the same rule, for the same reason.
#   Each is written when this run was given it or found it recorded here, and
#   is otherwise left out, so whatever .env sets for it stays in force.
write_offsite_env() {   # <bin> <config-path> <remote> <read-remote> <tenant> <recipient>, each but bin may be empty
    local bin="$1" cfg="$2" remote="$3" read_remote="$4" tenant="$5" recipient="$6"
    local tmp v want key st
    # Every value is validated by its caller; this is the backstop, so no code
    # path can write something unexpected into a file python-dotenv parses.
    for v in "$bin" "$cfg" "$remote" "$read_remote" "$tenant" "$recipient"; do
        if holds_age_secret_key "$v"; then
            echo "✗ rclone: refusing to write $OFFSITE_ENV_PATH — one of the"
            echo "  values is shaped like an age private key (not printed)."
            echo "  Nothing was written."
            return 1
        fi
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
    if [ -n "$read_remote" ]; then
        wants+=("DTK_OFFSITE_READ_REMOTE=$read_remote")
    else
        omitted+=("DTK_OFFSITE_READ_REMOTE")
    fi
    if [ -n "$tenant" ]; then
        wants+=("DTK_OFFSITE_TENANT=$tenant")
    else
        omitted+=("DTK_OFFSITE_TENANT")
    fi
    if [ -n "$recipient" ]; then
        wants+=("DTK_OFFSITE_DUMP_RECIPIENT=$recipient")
    else
        omitted+=("DTK_OFFSITE_DUMP_RECIPIENT")
    fi
    if ! {
        echo "# Digitization Toolkit — offsite catalogue backup (NEH-249, NEH-227)."
        echo "# Written whole by scripts/provision-rclone.sh at provisioning and on"
        echo "# every update. DO NOT EDIT: the next run replaces this file, and a"
        echo "# line that is not a '#' comment or a plain KEY=value in one of the"
        echo "# six keys it writes makes the whole file unreadable to that script."
        echo "#"
        echo "# The backend reads this in addition to the project .env, and a key"
        echo "# present here wins over the same key in .env. A key that is ABSENT"
        echo "# here overrides nothing: DTK_OFFSITE_REMOTE is written only when a"
        echo "# remote was actually recorded, DTK_RCLONE_CONFIG only when the run"
        echo "# that wrote this file established the config path itself, and the"
        echo "# read remote, tenant and dump recipient only when given or recorded."
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
    # rather than a pass. (None of these values is a secret: two paths, two
    # remote names with their bucket, a prefix and an age PUBLIC key. The B2
    # application keys go only to the rclone config file and never through
    # here, and an age private key is refused before it reaches this.)
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
#   unreadable   rclone was asked for the file's config and exited 1
#                refusing it — an unparseable line, or a config encrypted
#                with a password this script will not supply.
#   undetermined the inspection did not finish, so NO claim is made about the
#                file or the remote: the bound expired, the invocation could
#                not run, python3 is absent, or what came back could not be
#                parsed. Not the same answer as a field being missing, nor as
#                rclone refusing the file, and handled separately for that
#                reason.
#
# A password command that never returns is `undetermined`, not `unreadable`:
# what happened there is that the 30-second bound expired, and a clock running
# out is not rclone's answer about the file.
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
    # rclone exited 0 and this is not the JSON object it emits, so the
    # inspection did not complete. It is NOT rclone refusing the file:
    # rclone said nothing about the file here, and an "unreadable" here
    # would be a claim about it on no evidence.
    print("undetermined")
    sys.exit(0)
if not isinstance(data, dict):
    print("undetermined")
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
    # TWO DIFFERENT ANSWERS, and they used to be one.
    #
    # Status 1 is rclone having been asked and having refused the file: `config
    # dump` exits 1 on a config it cannot load, which is what `unreadable`
    # names.
    #
    # Any other nonzero status is the INSPECTION not finishing, and says
    # nothing about the file. timeout(1) exits 124 when the deadline expires,
    # 125 when the bound itself could not be applied, 126 when the command is
    # not executable and 127 when it is not found, and the -k follow-up KILL
    # lands as 137. A deadline expiring on a config whose password command
    # never returns was reported as "rclone cannot load it" — a verdict on the
    # file, from a clock running out.
    #
    # Exit 1 for a config it refuses is what rclone 1.70.2 was verified to do
    # on an unparseable line. If some other refusal of its own returns a
    # different status, this reads it as undetermined, which is the safe
    # direction: no claim is made, the run stops through provision_failed, and
    # nothing is authorised to write over the file.
    if [ "$st" -eq 1 ]; then
        echo "unreadable"; return 0
    fi
    if [ "$st" -ne 0 ]; then
        echo "undetermined"; return 0
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
    # `unreadable` is deliberately not in this list: it is established by
    # rclone's own exit status above, never by the classifier, which only ever
    # sees output rclone exited 0 to produce.
    case "$state" in
        complete|incomplete|foreign|undetermined) echo "$state" ;;
        *) echo "undetermined" ;;
    esac
}

# Does the section already at <file> hold the key id the operator supplied?
# Asked only of a section config_remote_state has already classified
# `complete`, from 2b, to tell an interrupted run's own credential from
# someone else's. Prints `match`, `differ` or `unknown`; `unknown` is every
# way the question could not be answered, and is treated as `differ`.
#
# Only the key id (rclone's `account` field) and the section type are
# compared, and neither is printed. The application key is never compared, so
# it is never read here. The dump goes to python on STDIN, as it does in
# config_remote_state, and the supplied id reaches python through its
# ENVIRONMENT rather than its argument list, so neither value is visible in
# the process table. The section does not hold the bucket: rclone's b2 remote
# takes the bucket from the remote specification, so it cannot be compared
# here — see 2b.
CONFIG_ID_COMPARER='
import json, os, sys
want = sys.argv[1]
supplied = os.environ.get("DTK_CMP_KEY_ID", "")
try:
    data = json.load(sys.stdin)
except Exception:
    print("unknown")
    sys.exit(0)
section = data.get(want) if isinstance(data, dict) else None
if not isinstance(section, dict) or not supplied:
    print("unknown")
    sys.exit(0)
account = section.get("account")
if not isinstance(account, str):
    print("unknown")
    sys.exit(0)
print("match" if (section.get("type") == "b2" and account == supplied) else "differ")
'
config_section_key_id_matches() {   # <rclone> <file> <remote> <supplied key id>
    local rc_bin="$1" f="$2" want="$3" supplied="$4" dump st answer
    if ! [[ "$want" =~ ^[A-Za-z0-9_.-]+$ ]] || [ ! -f "$f" ] \
            || [ ! -x "$rc_bin" ] || ! command -v python3 >/dev/null 2>&1; then
        echo "unknown"; return 0
    fi
    if dump="$(bounded "$RCLONE_READ_TIMEOUT" "$rc_bin" --config "$f" \
                   --ask-password=false config dump 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    if [ "$st" -ne 0 ]; then
        echo "unknown"; return 0
    fi
    if answer="$(printf '%s' "$dump" \
                   | DTK_CMP_KEY_ID="$supplied" \
                     python3 -I -c "$CONFIG_ID_COMPARER" "$want" 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    if [ "$st" -ne 0 ]; then
        echo "unknown"; return 0
    fi
    case "$answer" in
        match|differ) echo "$answer" ;;
        *) echo "unknown" ;;
    esac
}

reachable() {
    curl -fsS --head --max-time 15 "$1" >/dev/null 2>&1
}

# host_answers <url>: whether the server answers at all. Any HTTP status is an
# answer, 4xx and 5xx included (api.backblazeb2.com answers a bare HEAD with
# 405); only a connection that cannot be made (refused, a name that does not
# resolve, TLS, a timeout) is not, and curl then reports status 000. The
# listing probes that follow test the credentials themselves. reachable(),
# which fails on a 4xx, stays for the download, where a 404 means the asset
# is not there.
host_answers() {
    local code
    code="$(curl -sS --head --max-time 15 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)" || return 1
    [ -n "$code" ] && [ "$code" != 000 ]
}

probe_listing_once() {
    # Called on both paths that record a remote: the one that just wrote a
    # credential, and the resume in 2b that found the supplied key id already
    # in place. The resume needs it more, not less: the section holds no
    # bucket, so a key id can match while the bucket supplied beside it is
    # mistyped, and this listing is the only thing that would say so.
    #
    # Best-effort, never fatal: one listing call, so that a mistyped key
    # surfaces here instead of half an hour later as something that reads as a
    # credentials problem. It LISTS; it writes nothing, because the only
    # capability worth confirming without side effects is the one a failed
    # listing already explains. Not attempted at all when api.backblazeb2.com
    # does not answer — being unable to ask is not an answer, so it must not be
    # reported as one, and must not fail the run.
    #
    # WHAT A SUCCESS ESTABLISHES, AND NOTHING MORE: that this invocation of
    # this rclone, with this config file, listed that remote and exited 0. It
    # is NOT "the key can list the bucket". The environment can redefine the
    # remote out from under the listing — RCLONE_CONFIG_B2UNIT_TYPE=local makes
    # `rclone lsf b2unit:scripts` list a local directory and exit 0 — which is
    # why §2 refuses to run at all when such a variable is set, and why the
    # line this prints says a listing succeeded rather than what the key can
    # do.
    #
    # WHAT IT LISTS. With a tenant prefix recorded, the prefix: that is the
    # only part of the bucket the backend ever lists (remote_dir() and
    # remote_path() in backend app/core/catalogue_backup.py and
    # image_upload.py both address <remote>/<tenant>/...), and a key scoped to
    # that prefix, as an upload key may be, is refused a listing of the bucket
    # root while every listing the backend makes succeeds. The probe's purpose
    # is unchanged — a wrong key id, application key or bucket still fails it
    # — and it now asks the same question the read probe asks, of the same
    # place. With no tenant, the backend uploads nothing (configured_tenant),
    # and the probe lists the bucket as it always has.
    #
    # Nothing is inferred from the two probes together. Both keys may list,
    # so a failed upload listing beside a successful read listing does not
    # say which key is which.
    local where="$RCLONE_REMOTE_NAME:$B2_BUCKET"
    if [ -n "$TENANT_FINAL" ]; then
        where="$RCLONE_REMOTE_NAME:$B2_BUCKET/$TENANT_FINAL"
    fi
    if host_answers "https://api.backblazeb2.com"; then
        echo "  Listing $where once..."
        # --ask-password=false for the same reason the classification carries
        # it, and `bounded` for the same reason too: the flags below are
        # per-operation and idle timeouts, not a maximum runtime, and this
        # call happens AFTER the credential and offsite.env are both written,
        # which is the worst place in the script to stall.
        if bounded "$RCLONE_PROBE_TIMEOUT" \
                "$RCLONE_USE_BIN" --config "$RCLONE_CONFIG_PATH" \
                --ask-password=false lsf --max-depth 1 \
                --retries 1 --low-level-retries 1 --contimeout 10s --timeout 20s \
                "$where" >/dev/null 2>&1; then
            echo "  a listing of $where succeeded  ✓"
            RUN_PROBE="a listing of $where succeeded"
        else
            echo "  ⚠ the listing of $where did not succeed. The"
            echo "    remote is recorded; check the key id, the application key, the"
            echo "    bucket name, and that the key grants listFiles there. Run"
            echo "    this to see what rclone says:"
            echo "      sudo -u $DTK_USER $RCLONE_USE_BIN --config $RCLONE_CONFIG_PATH \\"
            echo "          lsf --max-depth 1 $where"
            RUN_PROBE="a listing of $where did not succeed"
        fi
    else
        echo "  (api.backblazeb2.com did not answer from here: no connection could be"
        echo "  made, so no listing was attempted)"
        RUN_PROBE="not attempted: api.backblazeb2.com did not answer (no connection)"
    fi
}

# ── The read remote ─────────────────────────────────────────────────────────
#
# The second section of the same config file, holding the key an admin restore
# of freed files reads through (DTK_OFFSITE_READ_REMOTE). The rules are the
# write remote's, carried over:
#
#   • never replaced: a [b2read] that exists with another key id, or that
#     rclone reads as unusable, is preserved and the run stops;
#   • never the same key as the upload remote, checked against what was
#     supplied AND against what the upload section already holds;
#   • never printed, and never on an argument list: the key reaches the file
#     through a heredoc, and the dumps that hold it go to python on stdin.
#
# ONE DEPARTURE, and it is deliberate. On a unit whose upload credential is
# already installed, adding the read section means writing a file that
# exists, which the write path never does: it publishes with `ln` precisely so
# that it cannot replace anything. Here the file is rebuilt beside itself as
# its current bytes plus the new section, and before that is renamed over it,
# rclone must read the new file as (a) a complete [b2read] with the read key
# id, and (b) every other section exactly as it read them in the old file,
# compared as a digest of the parsed config; and the old file's bytes must not
# have changed since they were copied. The run lock is what keeps a second
# writer out between that last check and the rename.

# A digest of everything rclone reads out of a config EXCEPT one section, so
# that two files can be compared section by section without either one's
# keys appearing anywhere but on python's stdin. Prints "undetermined" when
# the dump is not what rclone emits.
CONFIG_OTHERS_DIGEST='
import hashlib, json, sys
skip = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print("undetermined")
    sys.exit(0)
if not isinstance(data, dict):
    print("undetermined")
    sys.exit(0)
rest = {k: v for k, v in data.items() if k != skip}
print(hashlib.sha256(json.dumps(rest, sort_keys=True).encode()).hexdigest())
'
config_others_digest() {   # <rclone> <file> <section to leave out>
    local rc_bin="$1" f="$2" skip="$3" dump st out
    if [ ! -f "$f" ] || [ ! -x "$rc_bin" ] || ! command -v python3 >/dev/null 2>&1; then
        echo "undetermined"; return 0
    fi
    if dump="$(bounded "$RCLONE_READ_TIMEOUT" "$rc_bin" --config "$f" \
                   --ask-password=false config dump 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    if [ "$st" -ne 0 ]; then
        echo "undetermined"; return 0
    fi
    if out="$(printf '%s' "$dump" | python3 -I -c "$CONFIG_OTHERS_DIGEST" "$skip" 2>/dev/null)"; then
        st=0
    else
        st=$?
    fi
    if [ "$st" -ne 0 ] || ! [[ "$out" =~ ^[0-9a-f]{64}$ ]]; then
        echo "undetermined"; return 0
    fi
    echo "$out"
}

# The read section, in the format the upload section is written in. A heredoc,
# so the application key is never on an argument list. No hard_delete line:
# that setting governs what rclone does when it deletes, and this key cannot.
emit_read_section() {
    cat <<RCLONE_READ_CONF
# Read key for restoring freed files (DTK_OFFSITE_READ_REMOTE): listFiles and
# readFiles only, under this unit's tenant prefix. Never the upload key.
[$RCLONE_READ_REMOTE_NAME]
type = b2
account = $B2_READ_KEY_ID
key = $B2_READ_APP_KEY
RCLONE_READ_CONF
}

READ_CONFIRMED=0   # 1 once [b2read] holds the supplied read key, written or found
READ_BUCKET=""
READ_TMP=""        # the append's temporary file, named by the EXIT trap
LOCK_HELD=0        # 1 once flock(1) holds the run lock

# What a refusal leaves is stated exactly: no [b2read] was written and
# offsite.env was not touched. Anything else this run had already done, such
# as re-asserting the config file's mode and owner, is in the report printed
# with it.
read_refused() {   # read_refused <lines...>: print, report, stop
    local line
    for line in "$@"; do echo "$line"; done
    echo "  The read key supplied was not used. No [$RCLONE_READ_REMOTE_NAME] section was written and $OFFSITE_ENV_PATH was not changed."
    RUN_READ_CRED="not written: refused (see above)"
    run_report
    provision_failed
}

# A recorded read remote, carried forward when no read key is supplied, is
# checked against the upload remote this run records beside it:
#
#   • naming the upload remote itself is refused: the two keys would be one;
#   • on another bucket, it is DROPPED when this run records a new upload
#     remote (fresh, new) — the restore would read a bucket the uploads do not
#     go to — and REFUSED when the upload remote is the one already recorded
#     (kept), where the pair as recorded is inconsistent and this script will
#     not choose between them;
#   • after a fresh write, whose config this run produced whole, a read remote
#     with no complete section in it is dropped as well;
#   • otherwise it is carried forward, with a warning when rclone finds no
#     complete section behind it.
reconcile_recorded_read_remote() {   # <upload remote name> <bucket> <fresh|new|kept>
    local up="$1" bucket="$2" mode="$3" name rbucket state
    [ -n "$READ_REMOTE_FINAL" ] || return 0
    name="${READ_REMOTE_FINAL%%:*}"
    rbucket="${READ_REMOTE_FINAL#*:}"
    if [ "$name" = "$up" ] || [ "$name" = "$RCLONE_REMOTE_NAME" ]; then
        echo "✗ rclone: $OFFSITE_ENV_PATH records DTK_OFFSITE_READ_REMOTE=$READ_REMOTE_FINAL,"
        echo "  which names the upload remote [$name]. The read remote must be a"
        echo "  section of its own, holding a different key. $OFFSITE_ENV_PATH"
        echo "  was not changed. Remove that line, or supply READ_KEY_ID and"
        echo "  READ_APP_KEY in the key file to write [$RCLONE_READ_REMOTE_NAME]."
        RUN_READ_CRED="refused: the recorded read remote names the upload remote"
        run_report
        provision_failed
    fi
    if [ "$rbucket" != "$bucket" ]; then
        if [ "$mode" = "kept" ]; then
            echo "✗ rclone: $OFFSITE_ENV_PATH records DTK_OFFSITE_READ_REMOTE=$READ_REMOTE_FINAL,"
            echo "  on bucket $rbucket, not the upload remote's bucket $bucket. A"
            echo "  restore reads the objects the upload wrote, so the two must share"
            echo "  a bucket. $OFFSITE_ENV_PATH was not changed; correct or remove"
            echo "  that line and re-run."
            RUN_READ_CRED="refused: the recorded read remote is on another bucket"
            run_report
            provision_failed
        fi
        echo "  ⚠ DTK_OFFSITE_READ_REMOTE=$READ_REMOTE_FINAL was recorded on bucket"
        echo "    $rbucket, and this run records the upload remote on $bucket. It"
        echo "    was dropped from $OFFSITE_ENV_PATH. Supply READ_KEY_ID and"
        echo "    READ_APP_KEY to write a read remote for $bucket."
        RUN_READ_CRED="dropped the recorded $READ_REMOTE_FINAL: another bucket than $bucket"
        READ_REMOTE_FINAL=""
        return 0
    fi
    if [ "$mode" = "fresh" ]; then
        state="$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$name")"
        if [ "$state" != "complete" ]; then
            echo "  ⚠ DTK_OFFSITE_READ_REMOTE=$READ_REMOTE_FINAL was recorded, and the"
            echo "    config this run wrote has no complete [$name] section. It was"
            echo "    dropped from $OFFSITE_ENV_PATH. Supply READ_KEY_ID and"
            echo "    READ_APP_KEY to write one."
            RUN_READ_CRED="dropped the recorded $READ_REMOTE_FINAL: no [$name] in the config this run wrote"
            READ_REMOTE_FINAL=""
            return 0
        fi
    fi
    warn_recorded_read_remote
}

# Put the read key beside an upload credential that is already installed and
# complete at RCLONE_CONFIG_PATH. Called only from the paths that go on to
# record <upload remote>:<bucket>, before offsite.env is written, so that a
# read remote is never recorded ahead of the section behind it.
provision_read_remote() {   # <upload remote name> <bucket> <new|kept>
    local up_name="$1" bucket="$2" mode="$3" same state target before after d_old d_new
    if [ "$HAVE_READ_KEY" -ne 1 ]; then
        reconcile_recorded_read_remote "$up_name" "$bucket" "$mode"
        return 0
    fi
    if ! valid_bucket "$bucket"; then
        read_refused "✗ rclone: the upload remote's bucket part '$bucket' is not a bucket" \
                     "  name ($B2_BUCKET_RULE), so no read remote can be derived from it."
    fi
    if [ "$up_name" = "$RCLONE_READ_REMOTE_NAME" ]; then
        read_refused "✗ rclone: the upload remote is named [$up_name], which is the name" \
                     "  this script gives the read remote. One section cannot hold both keys."
    fi
    # The checks below only READ the file. The two that guard a WRITE — an
    # established path and the run lock — come after the state check in mode
    # `new`, so that a [b2read] already holding the supplied key resumes: 2b's
    # resume is a run interrupted after it wrote that config itself.
    #
    # In mode `kept` the established path comes FIRST, before anything is
    # recorded. There the config was not written by this run or its
    # interrupted predecessor, and a complete [b2read] at a path nobody named
    # is the same non-evidence a complete [b2unit] there is (see
    # CONFIG_PATH_ESTABLISHED): recording it would point the restore at a
    # credential this run cannot vouch for.
    if [ "$mode" != "new" ] && [ "$CONFIG_PATH_ESTABLISHED" -ne 1 ]; then
        read_refused "✗ rclone: the read remote would be recorded from $RCLONE_CONFIG_PATH, and" \
                     "  this run has not established that file as the backend's config:" \
                     "  $OFFSITE_ENV_PATH records no DTK_RCLONE_CONFIG and no" \
                     "  --config-path was given. Name the file that holds [$up_name]" \
                     "  with --config-path and re-run."
    fi
    same="$(config_section_key_id_matches "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$up_name" "$B2_READ_KEY_ID")"
    case "$same" in
        differ) ;;
        match)
            read_refused "✗ rclone: the upload remote [$up_name] in $RCLONE_CONFIG_PATH already" \
                         "  holds the key id supplied as the READ key. The two remotes must" \
                         "  hold different keys. Issue a separate read key and re-run."
            ;;
        *)
            read_refused "✗ rclone: could not confirm that the upload remote [$up_name] in" \
                         "  $RCLONE_CONFIG_PATH holds a different key id from the read key" \
                         "  supplied, and the two must differ."
            ;;
    esac
    state="$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$RCLONE_READ_REMOTE_NAME")"
    case "$state" in
        complete)
            if [ "$(config_section_key_id_matches "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" \
                    "$RCLONE_READ_REMOTE_NAME" "$B2_READ_KEY_ID")" = "match" ]; then
                echo "  $RCLONE_CONFIG_PATH already holds a complete [$RCLONE_READ_REMOTE_NAME]"
                echo "  remote with the read key id supplied, so it was not rewritten."
                RUN_READ_CRED="left the complete [$RCLONE_READ_REMOTE_NAME] section in $RCLONE_CONFIG_PATH untouched (same key id as supplied)"
                READ_CONFIRMED=1
                READ_BUCKET="$bucket"
                READ_REMOTE_FINAL="$RCLONE_READ_REMOTE_NAME:$bucket"
                return 0
            fi
            read_refused "✗ rclone: $RCLONE_CONFIG_PATH already holds a complete" \
                         "  [$RCLONE_READ_REMOTE_NAME] remote with a different key id, or one" \
                         "  this run could not compare. It was NOT replaced. To replace" \
                         "  it, remove that section by hand and re-run."
            ;;
        foreign) ;;
        *)
            read_refused "✗ rclone: $RCLONE_CONFIG_PATH holds a [$RCLONE_READ_REMOTE_NAME] section" \
                         "  this run cannot use or will not replace (classified: $state)."
            ;;
    esac

    # From here on the file is rewritten. Appending to a file is writing it,
    # and this run may only write a config it has established as the one the
    # backend reads — the same rule the bucket-only recovery follows, for the
    # same counterexample.
    if [ "$CONFIG_PATH_ESTABLISHED" -ne 1 ]; then
        read_refused "✗ rclone: the read key would be added to $RCLONE_CONFIG_PATH, and this" \
                     "  run has not established that file as the backend's config:" \
                     "  $OFFSITE_ENV_PATH records no DTK_RCLONE_CONFIG and no" \
                     "  --config-path was given. Name the file that holds [$up_name]" \
                     "  with --config-path and re-run."
    fi
    # The rename replaces the file, so unlike the upload write it is not safe
    # against a second run without the lock: the second run's file would be
    # renamed over, or rename over, this one's.
    if [ "$LOCK_HELD" -ne 1 ]; then
        read_refused "✗ rclone: refusing to add the read key to $RCLONE_CONFIG_PATH without" \
                     "  the run lock: flock is not installed, so this run is not" \
                     "  serialised against another copy of itself, and adding a section" \
                     "  replaces the file. Install util-linux and re-run."
    fi

    target="$RCLONE_CONFIG_PATH"
    if [ -L "$target" ]; then
        if ! target="$(readlink -f "$RCLONE_CONFIG_PATH" 2>/dev/null)" || [ ! -f "$target" ]; then
            read_refused "✗ rclone: could not resolve the symlink $RCLONE_CONFIG_PATH to the file" \
                         "  the read key would be added to."
        fi
    fi
    # The resolved target is named in a trap, in mktemp's template and in
    # messages; it is held to the same class as every other path here.
    if ! valid_abs_path "$target"; then
        reject_value "resolved rclone config path" "$target" "$ABS_PATH_RULE"
        read_refused "  (The symlink $RCLONE_CONFIG_PATH resolves to that path.)"
    fi
    if ! before="$(sha256_of "$target")" || [ -z "$before" ]; then
        read_refused "✗ rclone: could not take a checksum of $target before changing it."
    fi
    d_old="$(config_others_digest "$RCLONE_USE_BIN" "$target" "$RCLONE_READ_REMOTE_NAME")"
    if [ "$d_old" = "undetermined" ]; then
        read_refused "✗ rclone: could not read $target as rclone does before changing it."
    fi
    echo "  Adding the [$RCLONE_READ_REMOTE_NAME] remote to $target..."
    if ! READ_TMP="$(mktemp "${target}.XXXXXX")"; then
        READ_TMP=""
        read_refused "✗ rclone: could not create a temporary file beside $target."
    fi
    # Single quotes: the path is read from the variable when the trap fires,
    # never pasted into the trap's text.
    trap 'rm -f -- "$READ_TMP"' EXIT
    if ! chmod 0600 "$READ_TMP" \
            || ! { cat "$target"
                   if [ -n "$(tail -c 1 "$target")" ]; then echo; fi
                   emit_read_section; } > "$READ_TMP" \
            || ! chown "$DTK_USER:$DTK_USER" "$READ_TMP"; then
        rm -f -- "$READ_TMP"; trap - EXIT
        read_refused "✗ rclone: could not write the new $target beside the old one." \
                     "  The existing file was left exactly as it was."
    fi
    d_new="$(config_others_digest "$RCLONE_USE_BIN" "$READ_TMP" "$RCLONE_READ_REMOTE_NAME")"
    state="$(config_remote_state "$RCLONE_USE_BIN" "$READ_TMP" "$RCLONE_READ_REMOTE_NAME")"
    same="$(config_section_key_id_matches "$RCLONE_USE_BIN" "$READ_TMP" "$RCLONE_READ_REMOTE_NAME" "$B2_READ_KEY_ID")"
    if ! after="$(sha256_of "$target")"; then after=""; fi
    if [ "$state" != "complete" ] || [ "$same" != "match" ] \
            || [ "$d_new" = "undetermined" ] || [ "$d_new" != "$d_old" ] \
            || [ "$after" != "$before" ]; then
        rm -f -- "$READ_TMP"; trap - EXIT
        read_refused "✗ rclone: the new $target was not promoted. Before the rename, rclone" \
                     "  had to read it as a complete [$RCLONE_READ_REMOTE_NAME] with the read key" \
                     "  id and every other section unchanged, and the old file had to be" \
                     "  unchanged since it was copied; one of those did not hold" \
                     "  ([$RCLONE_READ_REMOTE_NAME]: $state, key id: $same, other sections:" \
                     "  $( [ "$d_new" = "$d_old" ] && echo unchanged || echo "changed or unread")," \
                     "  old file: $( [ "$after" = "$before" ] && echo unchanged || echo "changed or unread"))." \
                     "  The existing file was left exactly as it was."
    fi
    if ! mv -- "$READ_TMP" "$target"; then
        rm -f -- "$READ_TMP"; trap - EXIT
        read_refused "✗ rclone: could not put the new $target in place. The existing file" \
                     "  was left exactly as it was."
    fi
    trap - EXIT
    echo "  mode 0600, owner $DTK_USER  ✓"
    RUN_READ_CRED="added a [$RCLONE_READ_REMOTE_NAME] section to $target (mode 0600, owner $DTK_USER); the other sections read back unchanged"
    READ_CONFIRMED=1
    READ_BUCKET="$bucket"
    READ_REMOTE_FINAL="$RCLONE_READ_REMOTE_NAME:$bucket"
}

# With no read key supplied, a recorded read remote is carried forward. Say so
# when rclone finds no complete section behind it in the file inspected — a
# statement about that file, not about whether a restore would work.
warn_recorded_read_remote() {
    local name state
    [ -n "$READ_REMOTE_FINAL" ] || return 0
    name="${READ_REMOTE_FINAL%%:*}"
    state="$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$name")"
    if [ "$state" != "complete" ]; then
        echo "  ⚠ $OFFSITE_ENV_PATH records DTK_OFFSITE_READ_REMOTE=$READ_REMOTE_FINAL,"
        echo "    and rclone does not read a complete [$name] section in"
        echo "    $RCLONE_CONFIG_PATH (classified: $state). It is carried forward"
        echo "    unchanged. Supply READ_KEY_ID and READ_APP_KEY to write one."
    fi
}

probe_read_listing_once() {
    # The read key is scoped to the tenant prefix, so the listing is of that
    # prefix: a listing of the bucket root is refused to a prefix-scoped key
    # whatever else is right. Best-effort and never fatal, like the upload
    # probe, and with the same limit on what a success establishes.
    [ "$READ_CONFIRMED" -eq 1 ] || return 0
    if [ -z "$TENANT_FINAL" ]; then
        RUN_READ_PROBE="not attempted: no tenant prefix to list under"
        return 0
    fi
    if host_answers "https://api.backblazeb2.com"; then
        echo "  Listing $RCLONE_READ_REMOTE_NAME:$READ_BUCKET/$TENANT_FINAL once..."
        if bounded "$RCLONE_PROBE_TIMEOUT" \
                "$RCLONE_USE_BIN" --config "$RCLONE_CONFIG_PATH" \
                --ask-password=false lsf --max-depth 1 \
                --retries 1 --low-level-retries 1 --contimeout 10s --timeout 20s \
                "$RCLONE_READ_REMOTE_NAME:$READ_BUCKET/$TENANT_FINAL" >/dev/null 2>&1; then
            echo "  a listing of $RCLONE_READ_REMOTE_NAME:$READ_BUCKET/$TENANT_FINAL succeeded  ✓"
            RUN_READ_PROBE="a listing of $RCLONE_READ_REMOTE_NAME:$READ_BUCKET/$TENANT_FINAL succeeded"
        else
            echo "  ⚠ the listing of $RCLONE_READ_REMOTE_NAME:$READ_BUCKET/$TENANT_FINAL did not"
            echo "    succeed. The read remote is recorded; check the read key id, its"
            echo "    application key, and that it grants listFiles and readFiles under"
            echo "    $TENANT_FINAL/ in that bucket."
            RUN_READ_PROBE="a listing of $RCLONE_READ_REMOTE_NAME:$READ_BUCKET/$TENANT_FINAL did not succeed"
        fi
    else
        RUN_READ_PROBE="not attempted: api.backblazeb2.com did not answer (no connection)"
    fi
}

# ── Does the environment redefine the remote under inspection? ──────────────
#
# rclone takes remote definitions from the environment as well as from its
# config file. RCLONE_CONFIG_<REMOTE>_<FIELD> defines or overrides one field of
# one remote, whether or not that remote is in the config file at all, and
# RCLONE_B2_<FIELD> overrides a field for every b2 remote. Verified against
# rclone 1.70.2 on 2026-10-16: with RCLONE_CONFIG_B2UNIT_TYPE=local,
# `rclone lsf b2unit:scripts` lists the local scripts/ directory and exits 0 —
# a successful listing that reached no bucket. RCLONE_B2_KEY= empty works from
# the other side: the config dump reports a complete section and the key rclone
# would actually use is empty.
#
# So with any of those set, neither the classification of the config file nor a
# successful listing says anything about the credential or the bucket. This
# does NOT model rclone's precedence rules — which variable wins over which
# file is exactly the arithmetic this script stopped doing. It detects that an
# override is present and stops claiming.
#
# Names only, never values: RCLONE_B2_KEY holds a key.
rclone_env_overrides() {
    local names n out=""
    names="$(compgen -e 2>/dev/null || true)"
    while IFS= read -r n; do
        case "$n" in
            RCLONE_CONFIG*|RCLONE_B2_*) out="$out $n" ;;
        esac
    done <<< "$names"
    printf '%s\n' "${out# }"
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
RUN_READ_CRED="no read section was written by this run"
RUN_READ_PROBE="not run"
SETTINGS_WRITTEN=0
# What offsite.env will carry for the 0.1.0 keys: set from the command line or
# from what offsite.env records, once that file has been read (2.1b).
TENANT_FINAL=""
RECIPIENT_FINAL=""
READ_REMOTE_FINAL=""
# A --tenant or --dump-recipient that never reached offsite.env is said out
# loud: an operator who typed one will otherwise assume it was recorded.
OPTIONS_NOTE_PRINTED=0
note_options_not_recorded() {
    [ "$OPTIONS_NOTE_PRINTED" -eq 0 ] || return 0
    if [ "$SETTINGS_WRITTEN" -eq 0 ] && { [ -n "$TENANT_ARG" ] || [ -n "$RECIPIENT_ARG" ]; }; then
        OPTIONS_NOTE_PRINTED=1
        echo "  note: $OFFSITE_ENV_PATH was not written by this run, so the"
        echo "        --tenant or --dump-recipient given was NOT recorded."
    fi
}
run_report() {
    echo ""
    echo "  What this run did:"
    echo "    rclone       $RUN_RCLONE"
    echo "    credential   $RUN_CRED"
    echo "    bucket probe $RUN_PROBE"
    echo "    read key     $RUN_READ_CRED"
    echo "    read probe   $RUN_READ_PROBE"
    echo "    settings     $RUN_SETTINGS"
    note_options_not_recorded
    echo ""
    echo "  That is an account of this run, not a verdict on the unit. This"
    echo "  script does not report whether offsite backup is working: that is"
    echo "  a question about whether a backup has actually run and been"
    echo "  verified, which is answered from this unit's own backup records in"
    echo "  the Captua interface. Do not infer it from the lines above."
    echo ""
    echo "  One scope note that applies to every line above: this script reads"
    echo "  and writes $OFFSITE_ENV_PATH only. The project"
    echo "  .env can set the same keys, and nothing here inspects it."
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
    note_options_not_recorded
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
    if ! write_offsite_env "$RCLONE_USE_BIN" "$cfg" "$1" \
            "$READ_REMOTE_FINAL" "$TENANT_FINAL" "$RECIPIENT_FINAL"; then
        provision_failed
    fi
    SETTINGS_WRITTEN=1
    RUN_SETTINGS="$OFFSITE_ENV_PATH written (mode 0600, owner $DTK_USER): DTK_RCLONE_BIN=$RCLONE_USE_BIN"
    echo "  $OFFSITE_ENV_PATH written  ✓ (mode 0600, owner $DTK_USER)"
    if [ -n "$1" ]; then
        RUN_SETTINGS="$RUN_SETTINGS, DTK_OFFSITE_REMOTE=$1"
        echo "    DTK_OFFSITE_REMOTE=$1"
    else
        RUN_SETTINGS="$RUN_SETTINGS, no DTK_OFFSITE_REMOTE"
        echo "    no DTK_OFFSITE_REMOTE: this run recorded no remote, and it has"
        echo "    not disabled one. An omitted key overrides nothing, so whatever"
        echo "    the project .env sets is still in force."
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
    # The 0.1.0 settings: each written, or left out, by the same rule.
    local key val
    for key in DTK_OFFSITE_READ_REMOTE DTK_OFFSITE_TENANT DTK_OFFSITE_DUMP_RECIPIENT; do
        case "$key" in
            DTK_OFFSITE_READ_REMOTE)    val="$READ_REMOTE_FINAL" ;;
            DTK_OFFSITE_TENANT)         val="$TENANT_FINAL" ;;
            DTK_OFFSITE_DUMP_RECIPIENT) val="$RECIPIENT_FINAL" ;;
        esac
        if [ -n "$val" ]; then
            RUN_SETTINGS="$RUN_SETTINGS, $key=$val"
            echo "    $key=$val"
        else
            RUN_SETTINGS="$RUN_SETTINGS, no $key"
            echo "    no $key: not given to this run and not recorded before it."
        fi
    done
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
            echo "$i$RCLONE_CONFIG_PATH exists; rclone was asked to dump its"
            echo "$i  config and exited 1 refusing the file, so no claim is"
            echo "$i  made about what it holds. One unparseable line does"
            echo "$i  that, and so does a config encrypted with a password —"
            echo "$i  this script supplies none. Ask it the same question:"
            echo "$i    sudo -u $DTK_USER $RCLONE_USE_BIN --config \\"
            echo "$i        $RCLONE_CONFIG_PATH config dump"
            RUN_CRED="left $RCLONE_CONFIG_PATH untouched; rclone refused it when asked to dump its config"
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

# Before any path is printed: --prefix and --config-path become part of every
# path this script names, so an age private key pasted into either would be
# echoed by every message below, including the refusals. Refused here with a
# message that names no path, and directly rather than through
# provision_failed, which itself prints one.
if holds_age_secret_key "$PREFIX" || holds_age_secret_key "$CONFIG_PATH_ARG"; then
    echo "✗ provision-rclone.sh: --prefix or --config-path is shaped like an age"
    echo "  private key (AGE-SECRET-KEY-...). It is not printed, and nothing was"
    echo "  read or written."
    if [ "$ADVISORY" -eq 1 ]; then
        echo "  --advisory: not failing the caller."
        exit 0
    fi
    exit 1
fi

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
# Checked here, before anything is inspected, because this value is both a
# file this run may write a credential to and a value written into
# offsite.env.
if [ -n "$CONFIG_PATH_ARG" ] && ! valid_abs_path "$CONFIG_PATH_ARG"; then
    reject_value "rclone config path given with --config-path" \
        "$CONFIG_PATH_ARG" "$ABS_PATH_RULE"
    provision_failed
fi
# The 0.1.0 settings named on the command line, refused here, before anything
# is inspected, by the rules the backend applies (see valid_tenant and
# valid_age_recipient). A value the backend would refuse is a backup that never
# runs, and the backend says so only in its own log.
if [ -n "$TENANT_ARG" ] && ! valid_tenant "$TENANT_ARG"; then
    reject_value "tenant prefix given with --tenant" "$TENANT_ARG" "$TENANT_RULE"
    echo "  The backend refuses the same value (configured_tenant in"
    echo "  app/core/image_upload.py), and would then upload nothing."
    provision_failed
fi
if [ -n "$RECIPIENT_ARG" ] && ! valid_age_recipient "$RECIPIENT_ARG"; then
    reject_recipient "--dump-recipient" "$RECIPIENT_ARG"
    if ! looks_like_age_secret "$RECIPIENT_ARG"; then
        echo "  The backend refuses the same value (dump_recipient in"
        echo "  app/core/catalogue_backup.py), and would then upload no"
        echo "  catalogue dump."
    fi
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
# The lock is not the only guard for the UPLOAD credential: its publish is
# also atomic and non-replacing (see 2b), so a run without a lock cannot
# clobber it either — which is what makes a missing flock(1) a warning, not a
# refusal, for every path that writes only that. Adding the read section to a
# config that already exists is different: it renames a rebuilt file over the
# old one, which a second run could race, so that path refuses to run without
# the lock (provision_read_remote, LOCK_HELD).
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
    LOCK_HELD=1
else
    echo "  ⚠ flock is not installed, so this run is NOT serialised against"
    echo "    another copy of this script running at the same time. The"
    echo "    upload credential write below is still atomic and will not"
    echo "    replace an existing credential, so a concurrent run cannot"
    echo "    overwrite one; what it can do is make the two runs report"
    echo "    different states. Adding a read key to a config that already"
    echo "    exists replaces that file, and is refused without the lock."
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
        echo "✗ rclone: a HEAD request for $URL did not succeed,"
        echo "  so nothing was downloaded and nothing was installed."
        echo "  Connect this unit to the internet and"
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
    echo "  (resolved to '${RCLONE_USE_BIN:-nothing}'). Nothing was written to"
    echo "  $OFFSITE_ENV_PATH, so this run has not recorded a path with no"
    echo "  file at it. Whatever was recorded before this run is unchanged."
    provision_failed
fi
if ! valid_abs_path "$RCLONE_USE_BIN"; then
    reject_value "resolved rclone path" "$RCLONE_USE_BIN" "$ABS_PATH_RULE"
    provision_failed
fi
RUN_RCLONE="${FOUND_VERSION:-unrecognised} at $RCLONE_USE_BIN"

# An apt rclone left on the box is shadowed by /usr/local/bin on PATH, and the
# value this run will record, if it gets that far, is absolute. Say so anyway:
# the next person to run `rclone version` by hand in a login shell needs to
# know which one answered.
#
# What it must NOT say is that the backend is pointed at the accepted
# executable. Nothing has been written yet at this point, and several refusals
# below exit before offsite.env is written — an undetermined classification, a
# listing that cannot be bounded, an override in the environment — each of
# which leaves the previously recorded DTK_RCLONE_BIN in force, whatever it
# was.
OTHER_RCLONE=""
if command -v rclone >/dev/null 2>&1; then
    OTHER_RCLONE="$(command -v rclone)"
fi
if [ -n "$OTHER_RCLONE" ] && [ "$OTHER_RCLONE" != "$RCLONE_USE_BIN" ]; then
    OTHER_VERSION="$(rclone_version_of "$OTHER_RCLONE")"
    if [ -n "$OTHER_VERSION" ] && ! version_at_least "$OTHER_VERSION" "$RCLONE_MIN_VERSION"; then
        echo "  ⚠ $OTHER_RCLONE is rclone $OTHER_VERSION (too old for B2). It is left"
        echo "    in place. This run is using $RCLONE_USE_BIN; the settings"
        echo "    line below says whether that got recorded."
    fi
fi
echo ""

# ── 2. Per-unit remote ──────────────────────────────────────────────────────

echo "→ Configuring the offsite remote..."

# Every rclone call from here on reads a config file, and every one of them
# has to be bounded: rclone's own --timeout is an idle timeout, and
# --ask-password=false does not stop it running a configured password command
# first, so a config naming one that never returns stalls the invocation. This
# script is called synchronously from update.sh at its step 4c, before the
# pre-migration backup, so a stall here is an update that never finishes.
#
# The previous version warned and carried on unbounded. Refusing instead costs
# nothing in the field: Raspberry Pi OS ships coreutils, so timeout(1) is
# present on every unit this runs on, and a box without it is not a box to
# start an unbounded rclone on.
if [ -z "$TIMEOUT_BIN" ]; then
    echo "✗ rclone: neither timeout(1) nor gtimeout(1) was found on PATH, so"
    echo "  the rclone calls this section needs cannot be given a wall-clock"
    echo "  bound. rclone's own --timeout is an idle timeout, and"
    echo "  --ask-password=false does not stop it running a configured"
    echo "  password command first, so an unbounded call can stall this run —"
    echo "  and this script is called from update.sh before its pre-migration"
    echo "  backup. No config file was inspected and nothing was changed."
    echo "  Install coreutils and re-run."
    provision_failed
fi

# Before anything is inspected, because an override makes every answer below
# unsafe to state — see rclone_env_overrides.
RCLONE_ENV_OVERRIDES="$(rclone_env_overrides)"
if [ -n "$RCLONE_ENV_OVERRIDES" ]; then
    declare -a OVERRIDE_NAMES=()
    read -r -a OVERRIDE_NAMES <<< "$RCLONE_ENV_OVERRIDES"
    echo "✗ rclone: the environment carries variables that redefine rclone"
    echo "  remotes:"
    for OVERRIDE_NAME in ${OVERRIDE_NAMES[@]+"${OVERRIDE_NAMES[@]}"}; do
        echo "      $OVERRIDE_NAME"
    done
    echo "  (names only; the values are not printed, because RCLONE_B2_KEY"
    echo "  holds a key.)"
    echo "  rclone reads RCLONE_CONFIG_<REMOTE>_<FIELD> and"
    echo "  RCLONE_B2_<FIELD> as remote definitions. With one of those set,"
    echo "  neither the state of a config file nor a listing that succeeds"
    echo "  tells this run anything about the credential or the bucket, so it"
    echo "  makes no claim about either. No config file was inspected and"
    echo "  nothing was changed."
    echo "  Unset them in the shell that calls this script and re-run."
    provision_failed
fi

# ── 2.1 What offsite.env records ────────────────────────────────────────────
read_offsite_env
case "$OFFSITE_STATUS" in
    unreadable)
        offsite_read_failed
        ;;
    secret)
        echo "✗ rclone: $OFFSITE_ENV_PATH holds a line shaped like an age"
        echo "  private key (AGE-SECRET-KEY-...). It is not printed, the file was"
        echo "  not read further, and it was not changed. This script never"
        echo "  writes such a value, so the file was edited by something else."
        echo "  Remove that line, or delete the file and re-run to rebuild it."
        provision_failed
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
# --config-path wins over the recorded value: it was typed for this run, by
# someone looking at this unit, and the recorded value is only ever something
# an earlier run of this script put there. The two being different is worth
# printing rather than resolving silently.
if [ -n "$CONFIG_PATH_ARG" ]; then
    if [ -n "$OFFSITE_CFG" ] && [ "$OFFSITE_CFG" != "$CONFIG_PATH_ARG" ]; then
        echo "  note: --config-path names $CONFIG_PATH_ARG; $OFFSITE_ENV_PATH"
        echo "        records $OFFSITE_CFG. This run inspects and records the"
        echo "        path given on the command line."
    fi
    RCLONE_CONFIG_PATH="$CONFIG_PATH_ARG"
    CONFIG_PATH_ESTABLISHED=1
fi
# A path that exists must be a regular file. valid_abs_path checks the SHAPE of
# the path and nothing about what is at it, and config_remote_state treats any
# existing path as present. A directory therefore classifies as `unreadable`
# (rclone refuses to load it), and with key material supplied that reaches the
# preservation path in 2b, which runs chmod 0600 on it. 0600 on a directory
# removes search permission: `--config-path /var/lib/dtk` would take away the
# access the appliance user needs to its own state directory. The same path is
# chmod'd in 2a, 2a-bis and 2c-ante, so the refusal is made once, here, before
# anything inspects the path and before any chown or chmod can reach it.
#
# `-f` follows symlinks, so a link to a DIRECTORY is refused here like a bare
# directory: the test resolves to the target. A link to a regular file passes,
# and is meant to: an operator who keeps the config on a mounted volume and
# links it into place has arranged exactly that, and chown and chmod follow to
# the target, which is the file they meant. What that leaves is silence about
# which file was changed, so the link is resolved and named below.
if [ -e "$RCLONE_CONFIG_PATH" ] && [ ! -f "$RCLONE_CONFIG_PATH" ]; then
    if [ -d "$RCLONE_CONFIG_PATH" ]; then
        FOUND_KIND="a directory"
    else
        FOUND_KIND="not a regular file (a device, socket or pipe)"
    fi
    echo "✗ rclone: refusing the rclone config path $RCLONE_CONFIG_PATH."
    echo "    found: $FOUND_KIND"
    echo "    must be: a regular file, or a path where nothing exists yet"
    echo "  This run would inspect that path, and may set its mode to 0600 and"
    echo "  its owner to $DTK_USER, which on anything but a regular file would"
    echo "  damage something other than a credential. Nothing was written and"
    echo "  nothing was changed. Name the rclone config FILE with --config-path,"
    echo "  or check where $OFFSITE_ENV_PATH records DTK_RCLONE_CONFIG."
    provision_failed
fi
# A symlink that survived the test above points at a regular file. Say which
# one, before the mode and owner of that file are changed: `ls -l` on the path
# given would show the link's own permissions, not the target's, so an operator
# reading the report has no other way to see what this run touched. `-f`
# resolves the whole chain; without it `readlink` gives one hop, which still
# names something more useful than the path we were handed.
if [ -L "$RCLONE_CONFIG_PATH" ]; then
    LINK_TARGET="$(readlink -f "$RCLONE_CONFIG_PATH" 2>/dev/null \
                   || readlink "$RCLONE_CONFIG_PATH" 2>/dev/null || true)"
    if [ -n "$LINK_TARGET" ]; then
        echo "  note: $RCLONE_CONFIG_PATH is a symlink to $LINK_TARGET."
        echo "        That file is what this run inspects, and whose mode and"
        echo "        owner it may set."
    else
        echo "  note: $RCLONE_CONFIG_PATH is a symlink whose target could not"
        echo "        be resolved for reporting. The run continues; the target"
        echo "        is a regular file, since the check above resolved it."
    fi
fi
SELECTED_REMOTE="$OFFSITE_REMOTE"

# ── 2.1b The 0.1.0 settings: given, or carried forward ──────────────────────
# A value given on the command line wins, and a change from what is recorded
# is printed rather than made silently. With nothing given, what offsite.env
# records is carried forward, which is how setup.sh and update.sh, which pass
# neither option, keep them. A recorded value is held to the same rule as a
# given one: this script wrote it, so one that fails the rule now means the
# file was changed by something else, and it is not written back.
if [ -n "$OFFSITE_TENANT_REC" ] && ! valid_tenant "$OFFSITE_TENANT_REC"; then
    reject_value "tenant prefix recorded in $OFFSITE_ENV_PATH" \
        "$OFFSITE_TENANT_REC" "$TENANT_RULE"
    provision_failed
fi
if [ -n "$OFFSITE_RECIPIENT_REC" ] && ! valid_age_recipient "$OFFSITE_RECIPIENT_REC"; then
    reject_recipient "$OFFSITE_ENV_PATH" "$OFFSITE_RECIPIENT_REC"
    provision_failed
fi
if [ -n "$OFFSITE_READ_REMOTE_REC" ] && ! valid_remote_spec "$OFFSITE_READ_REMOTE_REC"; then
    reject_value "read remote recorded in $OFFSITE_ENV_PATH" \
        "$OFFSITE_READ_REMOTE_REC" "$REMOTE_SPEC_RULE"
    provision_failed
fi
TENANT_FINAL="${TENANT_ARG:-$OFFSITE_TENANT_REC}"
RECIPIENT_FINAL="${RECIPIENT_ARG:-$OFFSITE_RECIPIENT_REC}"
READ_REMOTE_FINAL="$OFFSITE_READ_REMOTE_REC"
# A different tenant over a recorded one is refused unless --change-tenant
# says it is meant: nothing moves the objects already uploaded, so a change
# leaves the unit's images under two prefixes. A recipient change is not
# guarded the same way: dumps are whole and each one stands alone.
if [ -n "$TENANT_ARG" ] && [ -n "$OFFSITE_TENANT_REC" ] && [ "$TENANT_ARG" != "$OFFSITE_TENANT_REC" ]; then
    if [ "$CHANGE_TENANT" -ne 1 ]; then
        echo "✗ rclone: refusing to replace the recorded tenant $OFFSITE_TENANT_REC"
        echo "  with $TENANT_ARG. Images already uploaded under $OFFSITE_TENANT_REC/"
        echo "  keep their keys there; new ones would go under $TENANT_ARG/."
        echo "  No credential was written and $OFFSITE_ENV_PATH was not changed."
        echo "  If the change is meant, re-run with --change-tenant beside"
        echo "  --tenant $TENANT_ARG."
        provision_failed
    fi
    echo "  note: --tenant $TENANT_ARG replaces the recorded tenant $OFFSITE_TENANT_REC"
    echo "        (--change-tenant). Images already uploaded under"
    echo "        $OFFSITE_TENANT_REC/ keep their keys there; new ones go under"
    echo "        $TENANT_ARG/."
fi
if [ -n "$RECIPIENT_ARG" ] && [ -n "$OFFSITE_RECIPIENT_REC" ] && [ "$RECIPIENT_ARG" != "$OFFSITE_RECIPIENT_REC" ]; then
    echo "  note: --dump-recipient replaces the recorded recipient"
    echo "        $OFFSITE_RECIPIENT_REC."
    echo "        Dumps already uploaded stay encrypted to that one."
fi

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
    echo "  Restoring freed files needs a SECOND key, optional at provisioning:"
    echo "    READ_KEY_ID   a B2 application key id scoped to the same bucket"
    echo "                  and to this unit's tenant prefix, with listFiles"
    echo "                  and readFiles ONLY"
    echo "    READ_APP_KEY  its application key"
    echo "  It is written as the [$RCLONE_READ_REMOTE_NAME] remote beside [$RCLONE_REMOTE_NAME],"
    echo "  and must be a different key from the upload key. It is read from"
    echo "  the key file only, never from the environment."
    echo ""
    echo "  Put them in a file only root can read, and point this script at it:"
    echo "    sudo install -m 0600 /dev/null /root/dtk-offsite-key"
    echo "    sudo sh -c 'cat > /root/dtk-offsite-key' <<'END'"
    echo "    KEY_ID=..."
    echo "    APP_KEY=..."
    echo "    BUCKET=..."
    echo "    READ_KEY_ID=..."
    echo "    READ_APP_KEY=..."
    echo "    END"
    echo "    sudo DTK_OFFSITE_KEY_FILE=/root/dtk-offsite-key \\"
    echo "        $SCRIPT_DIR/provision-rclone.sh \\"
    echo "        --tenant <prefix> --dump-recipient age1..."
    echo ""
    echo "  --tenant is the prefix this unit's objects are keyed under, and"
    echo "  --dump-recipient the age PUBLIC key its catalogue dumps are"
    echo "  encrypted to. Neither is a secret; the private age key stays off"
    echo "  the unit. Both are kept on later runs that do not give them."
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

# ── 2.2b The read key ───────────────────────────────────────────────────────
# From the key file ONLY (READ_KEY_ID, READ_APP_KEY), never from the
# environment, and never under --advisory. The write key still accepts
# DTK_B2_KEY_ID and DTK_B2_APP_KEY, as it always has; the read key is new and
# does not take on that exposure. update.sh exports every .env key before
# calling this script, so anything it could read from the environment could
# be planted by a line in .env — and that includes DTK_OFFSITE_KEY_FILE
# itself: a DTK_OFFSITE_KEY_FILE= line in .env would feed whatever file it
# names into the rclone config on every update. update.sh is the one caller
# that passes --advisory, so under --advisory the read key is never written:
# READ_KEY_ID is read only to compare it with KEY_ID, so that a file giving
# both remotes the same key is refused there exactly as on a plain run, and
# HAVE_READ_KEY stays 0. An operator adds the read key with a plain run.
# The same token class as the write key, for the same reason: both values go
# into the same INI file. The application key is never printed.
#
# No bucket of its own. The backend restores a freed file by appending its
# object key, the same key the upload wrote, to DTK_OFFSITE_READ_REMOTE
# (read_remote_path in offsite_free.py, backend/free-local-space), so the read
# remote must name the bucket the uploads went to, and it is derived from it.
B2_READ_KEY_ID=""
B2_READ_APP_KEY=""
READ_KEY_FOR_COMPARISON_ONLY=0
if [ -n "${DTK_OFFSITE_KEY_FILE:-}" ] && [ -r "$DTK_OFFSITE_KEY_FILE" ]; then
    B2_READ_KEY_ID="$(key_file_value "$DTK_OFFSITE_KEY_FILE" READ_KEY_ID)"
    B2_READ_APP_KEY="$(key_file_value "$DTK_OFFSITE_KEY_FILE" READ_APP_KEY)"
    if [ "$ADVISORY" -eq 1 ] && { [ -n "$B2_READ_KEY_ID" ] || [ -n "$B2_READ_APP_KEY" ]; }; then
        READ_KEY_FOR_COMPARISON_ONLY=1
        # The application key is dropped at once; only the id is kept, for
        # the same-id comparison below.
        B2_READ_APP_KEY=""
        echo "  note: the read key is not written under --advisory, which is how"
        echo "        update.sh calls this script; DTK_OFFSITE_KEY_FILE can come"
        echo "        from .env there. Its id is still compared with the upload"
        echo "        key's. Run this script without --advisory to add it."
    fi
fi
if [ -n "$B2_READ_KEY_ID" ] && ! valid_b2_token "$B2_READ_KEY_ID"; then
    reject_value "B2 read key id" "$B2_READ_KEY_ID" "$B2_TOKEN_CLASS"
    provision_failed
fi
if [ -n "$B2_READ_APP_KEY" ] && ! valid_b2_token "$B2_READ_APP_KEY"; then
    echo "✗ rclone: refusing the B2 read application key — it must be"
    echo "  $B2_TOKEN_CLASS. The value is not printed here"
    echo "  because it is a secret. No credential was written and"
    echo "  $OFFSITE_ENV_PATH was not changed."
    echo "  If you copied the key out of the Backblaze console, copy it again"
    echo "  as plain text: a highlighted copy can carry hidden formatting"
    echo "  characters, and that is the most likely cause of this message."
    provision_failed
fi
# One key for both remotes would give the upload remote read access, or the
# read remote write access, depending on which key it was: the separation the
# two remotes exist for would be gone without anything failing. So the same
# key id for both is refused outright, before anything is written. The key id
# is not printed: it would only repeat what the operator supplied twice.
if [ -n "$B2_KEY_ID" ] && [ -n "$B2_READ_KEY_ID" ] && [ "$B2_KEY_ID" = "$B2_READ_KEY_ID" ]; then
    echo "✗ rclone: the read key id is the same as the upload key id."
    echo "  The upload remote [$RCLONE_REMOTE_NAME] and the read remote"
    echo "  [$RCLONE_READ_REMOTE_NAME] must hold different keys: the upload key"
    echo "  writes and lists only, and the read key lists and reads only."
    echo "  No credential was written and $OFFSITE_ENV_PATH was not changed."
    echo "  Issue a separate read key for this unit and re-run."
    provision_failed
fi
HAVE_READ_KEY=0
if [ "$READ_KEY_FOR_COMPARISON_ONLY" -eq 1 ]; then
    # Compared above; never written. Cleared so that nothing below can use it.
    B2_READ_KEY_ID=""
elif [ -n "$B2_READ_KEY_ID" ] && [ -n "$B2_READ_APP_KEY" ]; then
    HAVE_READ_KEY=1
elif [ -n "$B2_READ_KEY_ID" ] || [ -n "$B2_READ_APP_KEY" ]; then
    # Half a read key is an operator part way through, exactly as half a write
    # key is: said, and not written.
    if [ -n "$B2_READ_KEY_ID" ]; then READ_MISSING="READ_APP_KEY"; else READ_MISSING="READ_KEY_ID"; fi
    echo "  ⚠ INCOMPLETE read key material — missing: $READ_MISSING."
    echo "    No read remote will be written by this run."
    RUN_READ_CRED="not written: incomplete read key material (missing $READ_MISSING)"
fi

# The read key, when supplied, on a path that records no upload remote. A read
# remote is only ever recorded beside the upload remote whose objects it reads.
read_key_unused() {   # read_key_unused <why>
    [ "$HAVE_READ_KEY" -eq 1 ] || return 0
    echo "  ⚠ The read key supplied was NOT used: $1."
    echo "    A read remote is written only beside an upload remote this run"
    echo "    records, since it reads the objects that remote uploaded."
    RUN_READ_CRED="not written: $1"
}

# A recorded read remote that names the upload remote is refused HERE, before
# 2b can publish a credential: refused after the fresh write, it left a config
# in place that the next run would preserve and the operator would have to
# move aside by hand. With a read key supplied the recorded value is replaced,
# so there is nothing to refuse. reconcile_recorded_read_remote keeps the same
# check as a backstop.
if [ "$HAVE_READ_KEY" -eq 0 ] && [ -n "$READ_REMOTE_FINAL" ]; then
    RECORDED_READ_NAME="${READ_REMOTE_FINAL%%:*}"
    if [ "$RECORDED_READ_NAME" = "$RCLONE_REMOTE_NAME" ] \
            || { [ -n "$OFFSITE_REMOTE" ] && [ "$RECORDED_READ_NAME" = "${OFFSITE_REMOTE%%:*}" ]; }; then
        echo "✗ rclone: $OFFSITE_ENV_PATH records DTK_OFFSITE_READ_REMOTE=$READ_REMOTE_FINAL,"
        echo "  which names the upload remote [$RECORDED_READ_NAME]. The read remote must"
        echo "  be a section of its own, holding a different key. No credential was"
        echo "  written and $OFFSITE_ENV_PATH was not changed. Remove that line, or"
        echo "  supply READ_KEY_ID and READ_APP_KEY in the key file to write"
        echo "  [$RCLONE_READ_REMOTE_NAME]."
        RUN_READ_CRED="refused: the recorded read remote names the upload remote"
        run_report
        provision_failed
    fi
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
    echo "  JSON, inside a ${RCLONE_READ_TIMEOUT}-second bound, and reading that JSON with"
    echo "  python3. One of those did not finish: the bound expired, the"
    echo "  invocation could not run, python3 is absent, or what came back"
    echo "  could not be parsed. rclone has NOT refused the file — it was not"
    echo "  heard from. Not knowing is not the same as the file being empty,"
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
    read_key_unused "the recorded upload remote is not a remote specification"
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
    # CONFIG_PATH_ESTABLISHED is deliberately NOT set here. This branch found
    # a complete section named $CHECK_NAME at the path it was inspecting, and
    # a section name is not evidence that this is the file the recorded remote
    # is served from — see the note on CONFIG_PATH_ESTABLISHED for the
    # counterexample this rule promoted the wrong file in. If offsite.env
    # recorded a path, or --config-path named one, it is already established
    # and gets written back; if neither did, the key stays out and whatever
    # .env sets stays in force.
    #
    # A read key supplied now goes in beside the recorded remote, on the same
    # bucket — and only into an established config path; see
    # provision_read_remote.
    provision_read_remote "$SELECTED_NAME" "${SELECTED_REMOTE#*:}" kept
    offsite_write_or_fail "$SELECTED_REMOTE"
    sync
    probe_read_listing_once
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
    echo "        DTK_OFFSITE_REMOTE wherever it is set."
    read_key_unused "the recorded upload remote has no usable credential"
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
    #
    # ONE EXCEPTION, and it is not a replacement: the credential is the one
    # this script wrote on an earlier run that then failed before it could
    # record anything. That run wrote the section, read it back, and then
    # could not write offsite.env (a full card, say). Re-running with the same
    # key file found a complete section, preserved it, and exited 0 with the
    # settings never published; a later run with no key cannot recover it
    # either, because 2a needs a recorded remote and none was recorded.
    #
    # So when the section is complete and its key id and type are the ones
    # supplied, the file is left exactly as it is and the run goes on to
    # publish the settings. Only the key id is compared: the application key
    # is not read, and the section holds no bucket — rclone's b2 remote takes
    # the bucket from the remote specification, not from the config — so the
    # bucket is checked only against a recorded remote, which must be absent
    # or already name this bucket. On the interrupted run this exists for,
    # nothing is recorded, so nothing here verifies the bucket: a matching
    # key id beside a mistyped bucket would resume and record the mistake.
    # The listing probe at the end is what would say so, which is why this
    # path runs it rather than exiting first. A different id, a different
    # recorded remote, or a comparison that could not be made takes the
    # preservation path below unchanged.
    #
    # CONFIG_PATH_ESTABLISHED is NOT set by finding a match — that is the
    # fourth establishing condition the note on that variable removed, and a
    # matching id at an inspected path is no better evidence than a matching
    # section name. If the path was not established some other way,
    # DTK_RCLONE_CONFIG stays out of offsite.env.
    RESUME_INTERRUPTED=0
    if [ "$CONFIG_STATE" = "complete" ] \
            && { [ -z "$SELECTED_REMOTE" ] \
                 || [ "$SELECTED_REMOTE" = "$RCLONE_REMOTE_NAME:$B2_BUCKET" ]; } \
            && [ "$(config_section_key_id_matches "$RCLONE_USE_BIN" \
                    "$RCLONE_CONFIG_PATH" "$RCLONE_REMOTE_NAME" "$B2_KEY_ID")" = "match" ]; then
        RESUME_INTERRUPTED=1
    fi
    if [ "$RESUME_INTERRUPTED" -eq 1 ]; then
        echo "  $RCLONE_CONFIG_PATH already holds a complete [$RCLONE_REMOTE_NAME]"
        echo "  remote with the key id supplied, so it was not rewritten. Its"
        echo "  application key was not compared. Publishing the settings."
        chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
        chmod 0600 "$RCLONE_CONFIG_PATH"
        echo "  mode 0600, owner $DTK_USER re-asserted."
        RUN_CRED="left the complete [$RCLONE_REMOTE_NAME] section in $RCLONE_CONFIG_PATH untouched (same key id as supplied); mode 0600, owner $DTK_USER re-asserted"
        provision_read_remote "$RCLONE_REMOTE_NAME" "$B2_BUCKET" new
        offsite_write_or_fail "$RCLONE_REMOTE_NAME:$B2_BUCKET"
        sync
        probe_listing_once
        probe_read_listing_once
        run_report
        exit 0
    fi
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
        read_key_unused "the upload key supplied was not written"
        # This exits nonzero, so setup.sh stops and update.sh carries on. An
        # operator supplied a credential for this unit and the unit is holding
        # a different one: either the key material is wrong or the file is,
        # and a fresh unit must not be handed over with that unresolved. The
        # branch said exit 0 while it also caught the benign case — a run
        # interrupted between writing the credential and publishing the
        # settings, where the installed credential IS the one supplied. That
        # case now resumes above and never reaches here, so what is left is
        # only a credential this script cannot account for.
        #
        # update.sh calls this script --advisory, where provision_failed
        # prints its note and returns 0: an update to a working appliance is
        # not the moment to stop over an offsite credential, and the next run
        # tries again.
        run_report
        sync
        provision_failed
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
    # The read section, when a read key was supplied, goes into the same new
    # file and is published with it, by the same non-replacing `ln`.
    if [ "$HAVE_READ_KEY" -eq 1 ]; then
        emit_read_section >> "$RCLONE_CONF_TMP"
    fi
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
        echo "  $OFFSITE_ENV_PATH was NOT updated, so this run recorded nothing"
        echo "  pointing at a credential it could not read back. What was"
        echo "  recorded before this run, here or in the project .env, is"
        echo "  unchanged."
        provision_failed
    fi
    if [ "$HAVE_READ_KEY" -eq 1 ]; then
        WROTE_READ_STATE="$(config_remote_state "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" "$RCLONE_READ_REMOTE_NAME")"
        WROTE_READ_ID="$(config_section_key_id_matches "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" \
                            "$RCLONE_READ_REMOTE_NAME" "$B2_READ_KEY_ID")"
        WROTE_UP_ID="$(config_section_key_id_matches "$RCLONE_USE_BIN" "$RCLONE_CONFIG_PATH" \
                            "$RCLONE_REMOTE_NAME" "$B2_READ_KEY_ID")"
        if [ "$WROTE_READ_STATE" != "complete" ] || [ "$WROTE_READ_ID" != "match" ] \
                || [ "$WROTE_UP_ID" != "differ" ]; then
            echo "✗ rclone: the credential just written to $RCLONE_CONFIG_PATH does"
            echo "  not read back as a complete [$RCLONE_READ_REMOTE_NAME] remote holding the"
            echo "  read key id, beside a [$RCLONE_REMOTE_NAME] that does not"
            echo "  (classified: $WROTE_READ_STATE; read key id: $WROTE_READ_ID;"
            echo "  upload section against the read key id: $WROTE_UP_ID)."
            echo "  That file, with both sections as written, is left in place;"
            echo "  $OFFSITE_ENV_PATH was NOT updated, so nothing points at it."
            echo "  Move it aside before re-running: this script will not replace it."
            RUN_READ_CRED="written to $RCLONE_CONFIG_PATH and left there; it did not read back, and offsite.env was not updated"
            run_report
            provision_failed
        fi
        RUN_READ_CRED="wrote a [$RCLONE_READ_REMOTE_NAME] section to $RCLONE_CONFIG_PATH beside [$RCLONE_REMOTE_NAME]"
        READ_CONFIRMED=1
        READ_BUCKET="$B2_BUCKET"
        READ_REMOTE_FINAL="$RCLONE_READ_REMOTE_NAME:$B2_BUCKET"
    else
        reconcile_recorded_read_remote "$RCLONE_REMOTE_NAME" "$B2_BUCKET" fresh
    fi

    if [ -n "$SELECTED_REMOTE" ] && [ "$SELECTED_REMOTE" != "$RCLONE_REMOTE_NAME:$B2_BUCKET" ]; then
        echo "  note: replacing the recorded remote $SELECTED_REMOTE"
    fi
    offsite_write_or_fail "$RCLONE_REMOTE_NAME:$B2_BUCKET"
    sync

    probe_listing_once
    probe_read_listing_once
    run_report
    exit 0
fi

# ── 2c. No remote is recorded and no complete key material was supplied ─────

# ── 2c-ante. The bucket alone, over a credential that is already complete ───
# This is the recovery the note at the end of this script tells an operator to
# run:
#
#   sudo DTK_OFFSITE_BUCKET=<bucket> provision-rclone.sh \
#       --config-path <the file that holds the credential>
#
# It had nowhere to land. A bucket makes B2_BUCKET non-empty with no key id
# and no application key beside it, so the partial-key branch below caught it
# and reported "INCOMPLETE key material — missing: KEY_ID APP_KEY" — correct
# for an operator half way through typing a new credential, and wrong for this
# one, where the credential is already there and only the selector is missing.
#
# So it runs BEFORE the partial-key branch, and it is narrow: ONLY the bucket
# supplied, nothing recorded, rclone reading the credential as complete, and
# the config path ESTABLISHED rather than inferred. A key id or an application
# key alongside the bucket is an operator part way through a NEW credential.
# Nothing here creates or replaces a credential.
#
# The last of those four conditions is the one added when the third
# config-path rule was dropped. This branch writes DTK_OFFSITE_REMOTE, and a
# selector recorded without the path its credential is in names a remote the
# backend may not find — so the path has to be recorded beside it. What it may
# NOT do is infer the path from the fact that a complete section of the right
# NAME happens to be at the path it was inspecting: that is how a stale
# credential at the default path came to be promoted over a working one named
# in .env. The path is therefore required to come from offsite.env or from
# --config-path, and the refusal below says so.
if [ -n "$B2_BUCKET" ] && [ -z "$B2_KEY_ID" ] && [ -z "$B2_APP_KEY" ] \
        && [ "$CONFIG_STATE" = "complete" ] && [ "$CONFIG_PATH_ESTABLISHED" -eq 0 ]; then
    echo "  ⚠ a bucket was supplied with no key material, which is the"
    echo "    bucket-only recovery, and this run has no established config"
    echo "    path to record beside the remote it would write."
    describe_config_state "    "
    echo "    That path is this script's default: $OFFSITE_ENV_PATH records no"
    echo "    DTK_RCLONE_CONFIG and no --config-path was given. A section named"
    echo "    [$CHECK_NAME] is this script's own remote name, which is not evidence"
    echo "    that this is the credential the recorded remote uses. Nothing was"
    echo "    changed. Name the file that holds it and re-run:"
    echo "      sudo DTK_OFFSITE_BUCKET=$B2_BUCKET \\"
    echo "          $SCRIPT_DIR/provision-rclone.sh \\"
    echo "          --config-path $RCLONE_CONFIG_PATH"
    read_key_unused "the bucket-only recovery was refused"
    provision_failed
fi
if [ -n "$B2_BUCKET" ] && [ -z "$B2_KEY_ID" ] && [ -z "$B2_APP_KEY" ] \
        && [ "$CONFIG_STATE" = "complete" ]; then
    chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
    chmod 0600 "$RCLONE_CONFIG_PATH"
    describe_config_state "  "
    echo "  It was left untouched — no credential was created or replaced."
    echo "  mode 0600, owner $DTK_USER  ✓"
    RUN_CRED="$RUN_CRED; mode 0600, owner $DTK_USER re-asserted"
    # CONFIG_PATH_ESTABLISHED is already 1 — the branch above refuses this
    # recovery otherwise — so the path written beside the selector is one
    # offsite.env recorded or --config-path named, never one inferred here.
    provision_read_remote "$CHECK_NAME" "$B2_BUCKET" new
    offsite_write_or_fail "$CHECK_NAME:$B2_BUCKET"
    sync
    probe_read_listing_once
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
    echo "    changed. This script writes a credential only from all three"
    echo "    values together: two of them are an operator part way through"
    echo "    typing, not a credential to write."
    read_key_unused "the upload key material is incomplete"
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
read_key_unused "no upload remote is recorded or being written"
# A read remote reads what the upload remote wrote. With no upload remote
# recorded there is nothing for it to read beside, so it is dropped rather
# than carried forward; one naming the upload remote was refused above.
if [ -n "$READ_REMOTE_FINAL" ]; then
    echo "  ⚠ DTK_OFFSITE_READ_REMOTE=$READ_REMOTE_FINAL was recorded with no upload"
    echo "    remote beside it. It was dropped from $OFFSITE_ENV_PATH."
    RUN_READ_CRED="dropped the recorded $READ_REMOTE_FINAL: no upload remote is recorded"
    READ_REMOTE_FINAL=""
fi
offsite_write_or_fail ""
sync
describe_config_state "  "
if [ "$CONFIG_STATE" = "complete" ]; then
    echo "    Nothing this script wrote names it. If that credential is meant"
    echo "    to be used, name this unit's bucket and the file the credential"
    echo "    is in, which needs no new credential:"
    echo "      sudo DTK_OFFSITE_BUCKET=<bucket> \\"
    echo "          $SCRIPT_DIR/provision-rclone.sh \\"
    echo "          --config-path $RCLONE_CONFIG_PATH"
elif [ "$CONFIG_STATE" = "missing" ]; then
    echo "    No credential file there, which is expected until this unit has"
    echo "    been issued a key. That path is the only one this run looked at."
fi
echo ""
print_key_instructions
run_report
