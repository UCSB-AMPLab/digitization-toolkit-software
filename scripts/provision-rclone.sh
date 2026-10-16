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
# setup.sh calls it. **update.sh does not yet**, and must: the one line goes
# beside its step 4b, which calls provision-chdk-usb.sh for exactly this
# reason. Everything here is written to be safe on that path — idempotent, no
# service restart, and no network access when the installed rclone is already
# new enough.
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
#      supplied. No key material means no remote: DTK_OFFSITE_REMOTE stays
#      unset, the backend's offsite path stays the deliberate no-op it is by
#      default, and this script says what an operator has to supply. It never
#      invents, guesses or defaults a credential. A half-configured remote
#      that fails every thirty minutes is worse than a disabled one.
#
# Offline-safe: if an rclone new enough is already installed, the network is
# not touched at all. Provisioning and updates both happen on units that may
# have no connectivity, which is why update.sh carries its own
# internet-honesty check.
#
# Does not start, stop or restart the dtk service: callers manage that on
# their own schedule and this script must not add a restart neither of them
# is already doing.
#
# Called by scripts/setup.sh; can also be run standalone:
#   sudo ./scripts/provision-rclone.sh
#
# --advisory changes ONE thing: the exit status when rclone cannot be
# provisioned. The diagnosis printed is identical, and nothing is skipped
# quietly — the only difference is whether the calling script dies with this
# one.
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
# Key material, when there is any, comes from the environment:
#   sudo DTK_B2_KEY_ID=... DTK_B2_APP_KEY=... DTK_OFFSITE_BUCKET=... \
#       ./scripts/provision-rclone.sh
# or, to keep the secret off the command line and out of root's shell
# history, from a file named by DTK_OFFSITE_KEY_FILE holding
# KEY_ID= / APP_KEY= / BUCKET= lines. That file is read, never executed, and
# never modified or removed by this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

ADVISORY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --advisory) ADVISORY=1 ;;
        # Unknown arguments are a bug at the call site, not a field
        # condition, so they are refused rather than guessed at. Silently
        # ignoring a mistyped --advisory would mean a caller that believes it
        # is advisory and is not, which is the whole failure this flag exists
        # to control.
        *)
            echo "✗ provision-rclone.sh: unknown argument '$1'."
            echo "  Usage: provision-rclone.sh [--advisory]"
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

# Installed under /usr/local/bin, which precedes /usr/bin on the default PATH
# and on dtk.service's explicit PATH, so this binary shadows an apt-installed
# one rather than fighting dpkg over /usr/bin/rclone. DTK_RCLONE_BIN is the
# same name the backend reads (app/core/config.py), so there is one name for
# "which rclone", whether it is being installed or being used.
RCLONE_BIN_PATH="${DTK_RCLONE_BIN:-/usr/local/bin/rclone}"

# Per-unit, outside the repository, on the same state directory as the
# secrets-provenance marker generate-secrets.sh writes. Outside the repo
# means it cannot be committed by accident; /var/lib/dtk is already owned by
# DTK_USER after setup.sh's step 2.
RCLONE_CONFIG_PATH="${DTK_RCLONE_CONFIG:-/var/lib/dtk/rclone.conf}"

# The remote's name inside that config file. The backend composes
# DTK_OFFSITE_REMOTE as "<remote>:<bucket>".
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

# Replace one key in .env atomically, preserving mode and ownership, the way
# generate-secrets.sh does for SECRET_KEY and DATABASE_PASSWORD: write a
# sibling temp file, then rename over the original, so a power cut leaves
# either the old file or the new one and never half of either.
env_set() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
    # cp -p carries .env's mode and owner onto the temp file; the redirection
    # below truncates its contents without changing either.
    cp -p "$ENV_FILE" "$tmp"
    { grep -vE "^[[:space:]]*${key}=" "$ENV_FILE" || true; } > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
}

env_get() {
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- \
        | sed 's/[[:space:]]*#.*$//' | tr -d '\r' | xargs || true
}

# Read one KEY=value line out of an operator-supplied file. Deliberately NOT
# `source`: that file holds a credential an operator wrote by hand, and
# sourcing it would execute whatever else is in it as root.
key_file_value() {
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null \
        | tail -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

reachable() {
    curl -fsS --head --max-time 15 "$1" >/dev/null 2>&1
}

# Leave after a failure to provision rclone. Every caller has already printed
# its own diagnosis; this decides only whether the surrounding script dies
# with us. In advisory mode it says plainly that it is not failing the caller,
# so a reader of an update log can tell the difference between "this was
# tolerated" and "nothing went wrong".
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

# ── 1. Pinned rclone ────────────────────────────────────────────────────────

echo "→ Checking rclone (need >= $RCLONE_MIN_VERSION for B2 application keys)..."

# Which rclone would be used: our own install path first, then whatever is on
# PATH, so an operator's newer hand-installed rclone is accepted instead of
# being downloaded over.
FOUND_BIN=""
if [ -x "$RCLONE_BIN_PATH" ]; then
    FOUND_BIN="$RCLONE_BIN_PATH"
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
        echo "  rclone >= $RCLONE_MIN_VERSION at $RCLONE_BIN_PATH by hand and re-run."
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
        echo "  re-run, or install rclone >= $RCLONE_MIN_VERSION at $RCLONE_BIN_PATH"
        echo "  by hand (download it on another machine and copy it across)."
        provision_failed
    fi

    TMPDIR_RCLONE="$(mktemp -d)"
    # Nothing below leaves anything behind, on any exit path, including the
    # checksum-mismatch one: a rejected download must not sit on an SD card
    # whose last incident was a full card.
    # shellcheck disable=SC2064  # expand TMPDIR_RCLONE now, not at trap time
    trap "rm -rf '$TMPDIR_RCLONE'" EXIT

    echo "  Downloading $ASSET..."
    if ! curl -fsSL --max-time 600 -o "$TMPDIR_RCLONE/$ASSET" "$URL"; then
        echo "✗ rclone: download of $URL failed."
        echo "  Nothing was installed. Re-run with a working connection, or"
        echo "  install rclone >= $RCLONE_MIN_VERSION at $RCLONE_BIN_PATH by hand."
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

    # Install via a sibling temp name and rename, so the appliance never has a
    # half-written rclone at $RCLONE_BIN_PATH — a torn binary there would fail
    # in a far more confusing way than an absent one.
    mkdir -p "$(dirname "$RCLONE_BIN_PATH")"
    install -m 0755 "$NEW_BIN" "$RCLONE_BIN_PATH.new"
    mv "$RCLONE_BIN_PATH.new" "$RCLONE_BIN_PATH"
    rm -rf "$TMPDIR_RCLONE"
    trap - EXIT

    INSTALLED_VERSION="$(rclone_version_of "$RCLONE_BIN_PATH")"
    # The assertion, not a formality: this is the line that stops the 1.60
    # fall-back. If the installed binary does not report a version at or above
    # the floor, provisioning stops here rather than handing back an appliance
    # that will report every backup failure as an authentication error.
    if [ -z "$INSTALLED_VERSION" ] || ! version_at_least "$INSTALLED_VERSION" "$RCLONE_MIN_VERSION"; then
        echo "✗ rclone: $RCLONE_BIN_PATH reports '${INSTALLED_VERSION:-nothing}' after"
        echo "  installing $RCLONE_VERSION, which is below the required"
        echo "  $RCLONE_MIN_VERSION. Refusing to provision offsite backup on an"
        echo "  rclone that cannot authenticate to B2 — it would look like a"
        echo "  credentials problem on every single run."
        provision_failed
    fi
    echo "  rclone $INSTALLED_VERSION at $RCLONE_BIN_PATH  ✓"
    FOUND_BIN="$RCLONE_BIN_PATH"
    FOUND_VERSION="$INSTALLED_VERSION"
fi

# An apt rclone left on the box is shadowed by /usr/local/bin on PATH, and
# DTK_RCLONE_BIN below is absolute, so the backend cannot pick it up. Say so
# anyway: the next person to run `rclone version` by hand in a login shell
# needs to know which one answered.
OTHER_RCLONE=""
if command -v rclone >/dev/null 2>&1; then
    OTHER_RCLONE="$(command -v rclone)"
fi
if [ -n "$OTHER_RCLONE" ] && [ "$OTHER_RCLONE" != "$RCLONE_BIN_PATH" ]; then
    OTHER_VERSION="$(rclone_version_of "$OTHER_RCLONE")"
    if [ -n "$OTHER_VERSION" ] && ! version_at_least "$OTHER_VERSION" "$RCLONE_MIN_VERSION"; then
        echo "  ⚠ $OTHER_RCLONE is rclone $OTHER_VERSION (too old for B2). It is left"
        echo "    in place; the backend is pointed at $RCLONE_BIN_PATH by absolute path."
    fi
fi
echo ""

# ── 2. Per-unit remote ──────────────────────────────────────────────────────

echo "→ Configuring the offsite remote..."

if [ ! -f "$ENV_FILE" ]; then
    echo "  ⚠ $ENV_FILE does not exist yet, so there is nowhere to record the"
    echo "    remote. Run setup.sh (which creates .env from .env.example) and"
    echo "    then re-run this script."
    echo ""
    exit 0
fi

# Record which rclone the backend must use even when there is no remote yet:
# the binary was provisioned either way, and the value is correct whether or
# not credentials ever arrive.
env_set DTK_RCLONE_BIN "$RCLONE_BIN_PATH"

# Already configured: do not touch the credential, do not re-derive the
# bucket, do not overwrite with anything. Re-assert the mode and owner, which
# is the part that can drift (an SD card cloned and hand-edited, a file copied
# in as root), and make sure .env still points at it.
if [ -f "$RCLONE_CONFIG_PATH" ] \
   && grep -qE "^\[${RCLONE_REMOTE_NAME}\]" "$RCLONE_CONFIG_PATH" 2>/dev/null; then
    chown "$DTK_USER:$DTK_USER" "$RCLONE_CONFIG_PATH"
    chmod 0600 "$RCLONE_CONFIG_PATH"
    env_set DTK_RCLONE_CONFIG "$RCLONE_CONFIG_PATH"
    EXISTING_REMOTE="$(env_get DTK_OFFSITE_REMOTE)"
    echo "  $RCLONE_CONFIG_PATH already has a [$RCLONE_REMOTE_NAME] remote — left untouched."
    echo "  mode 0600, owner $DTK_USER  ✓"
    if [ -n "$EXISTING_REMOTE" ]; then
        echo "  DTK_OFFSITE_REMOTE=$EXISTING_REMOTE"
    elif [ -n "${DTK_OFFSITE_BUCKET:-}" ]; then
        # A remote with no DTK_OFFSITE_REMOTE is a half-provisioned unit: the
        # credential is there and the backend is still doing nothing. Naming
        # the bucket is enough to finish it, and needs no new credential.
        env_set DTK_OFFSITE_REMOTE "$RCLONE_REMOTE_NAME:$DTK_OFFSITE_BUCKET"
        echo "  DTK_OFFSITE_REMOTE=$RCLONE_REMOTE_NAME:$DTK_OFFSITE_BUCKET  ✓ (was unset)"
    else
        echo "  ⚠ DTK_OFFSITE_REMOTE is not set in .env, so offsite backup is still"
        echo "    disabled even though this unit has a remote. Re-run with"
        echo "    DTK_OFFSITE_BUCKET set to this unit's bucket, or set"
        echo "    DTK_OFFSITE_REMOTE=$RCLONE_REMOTE_NAME:<bucket> in .env by hand."
    fi
    sync
    echo ""
    exit 0
fi

# Collect key material. The environment wins; a file named by
# DTK_OFFSITE_KEY_FILE is the alternative for keeping a credential off the
# command line. Nothing is defaulted or derived.
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

if [ -z "$B2_KEY_ID" ] || [ -z "$B2_APP_KEY" ] || [ -z "$B2_BUCKET" ]; then
    # The deliberate no-op. This is the correct state for every unit that has
    # not been issued a key, which today is every unit, and it must not be
    # dressed up as a failure: rclone is installed and ready, and the backend
    # does nothing until a remote exists.
    echo "  No B2 key material supplied, so NO remote was written and"
    echo "  DTK_OFFSITE_REMOTE is left unset. Offsite backup is disabled on this"
    echo "  unit, which is the intended state until it has its own key."
    echo ""
    echo "  To enable it, an operator must supply three things for THIS unit:"
    echo "    DTK_B2_KEY_ID        the scoped B2 application key id"
    echo "    DTK_B2_APP_KEY       its application key"
    echo "    DTK_OFFSITE_BUCKET   the unit's bucket, one per institution"
    echo ""
    echo "  The key must be scoped to that one bucket with writeFiles and"
    echo "  listFiles ONLY — no readFiles, no deleteFiles — so that a stolen"
    echo "  appliance can neither erase nor download the archive. Then:"
    echo "    sudo DTK_B2_KEY_ID=... DTK_B2_APP_KEY=... DTK_OFFSITE_BUCKET=... \\"
    echo "        $SCRIPT_DIR/provision-rclone.sh"
    echo "  or put KEY_ID= / APP_KEY= / BUCKET= lines in a file and point"
    echo "  DTK_OFFSITE_KEY_FILE at it to keep the key off the command line."
    sync
    echo ""
    exit 0
fi

# Written here rather than through `rclone config create` so the application
# key never appears in the process table, where any other user on the box
# could read it out of /proc while this runs. The format below is exactly what
# rclone v1.75.2's own `config create b2unit b2 ...` produces, verified
# against it: for the b2 backend `key` is stored in plain text, which is why
# the file's mode is the only thing protecting it.
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

env_set DTK_RCLONE_CONFIG "$RCLONE_CONFIG_PATH"
env_set DTK_OFFSITE_REMOTE "$RCLONE_REMOTE_NAME:$B2_BUCKET"
sync
echo "  DTK_OFFSITE_REMOTE=$RCLONE_REMOTE_NAME:$B2_BUCKET  ✓"

# Best-effort, never fatal: one listing call against the bucket turns a
# mistyped key into a provisioning-time message instead of a backup that
# fails every half hour afterwards with something that reads as a credentials
# problem. Skipped entirely when the unit is offline — being unable to ask is
# not an answer, so it must not be reported as one, and must not fail the run.
if reachable "https://api.backblazeb2.com"; then
    echo "  Checking the key against $B2_BUCKET..."
    if "$FOUND_BIN" --config "$RCLONE_CONFIG_PATH" lsf --max-depth 1 \
            --retries 1 --low-level-retries 1 --contimeout 10s --timeout 20s \
            "$RCLONE_REMOTE_NAME:$B2_BUCKET" >/dev/null 2>&1; then
        echo "  the key can list $B2_BUCKET  ✓"
    else
        echo "  ⚠ rclone could not list $RCLONE_REMOTE_NAME:$B2_BUCKET. The remote is"
        echo "    written and the backend will use it, but check the key id, the"
        echo "    application key, the bucket name, and that the key grants"
        echo "    listFiles on that bucket. Run this to see the actual error:"
        echo "      sudo -u $DTK_USER $FOUND_BIN --config $RCLONE_CONFIG_PATH \\"
        echo "          lsf --max-depth 1 $RCLONE_REMOTE_NAME:$B2_BUCKET"
    fi
else
    echo "  (offline — the key was not checked against B2)"
fi
echo ""
