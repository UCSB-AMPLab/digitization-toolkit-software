#!/bin/bash
# Tests for scripts/provision-rclone.sh: the offsite.env settings and the two
# rclone remotes it writes.
#
#   bash scripts/tests/provision-rclone.test.sh
#
# Each case runs the real script under --prefix against a fresh temporary
# tree, with an empty environment and a PATH of fakes in front of the
# system's:
#
#   rclone   at <prefix>/usr/local/bin/rclone, where the script looks first, so
#            nothing is downloaded. `version` reports the pin; `config dump`
#            parses the INI file into the JSON rclone emits; `lsf` succeeds.
#   curl     always fails, so the unit reads as offline and no listing probe
#            or download is attempted. Nothing here touches the network.
#   timeout  runs the command unbounded (macOS has no timeout(1)).
#   chown    does nothing, so the cases run as an ordinary user.
#
# No real key appears anywhere: the key ids and application keys are made-up
# strings in B2's alphabet, and the age recipients are encodings of fixed byte
# patterns that no one holds a private key for. The "secret key" is a string
# of the right shape that is not a key.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(dirname "$HERE")/provision-rclone.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/provision-rclone-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""

# ── Values ──────────────────────────────────────────────────────────────────
BUCKET="captua-test-bucket"
UP_ID="000fakeupload0000000000001"
UP_KEY="K000FAKEuploadAppKeyNotReal01"
RD_ID="000fakeread000000000000002"
RD_KEY="K000FAKEreadAppKeyNotReal002"
# age X25519 recipients: bech32 of 32 zero bytes, and of 32 bytes of 0x01 in
# upper case. Both accepted by pyrage 1.4.0's Recipient.from_str.
RCPT="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq5cu47z"
RCPT_UPPER="AGE1QYQSZQGPQYQSZQGPQYQSZQGPQYQSZQGPQYQSZQGPQYQSZQGPQYQS3290GQ"
# Refused by the same parser: last character changed, mixed case, a bech32m
# checksum, human-readable part "agx", and a 31-byte payload.
RCPT_BADSUM="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq5cu47q"
RCPT_MIXED="age1QQQQqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq5cu47z"
RCPT_M="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpyvemq"
RCPT_HRP="agx1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7gf884"
RCPT_SHORT="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqar9jk6"
# Shaped like an age private key; not one.
FAKE_SECRET="AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
FAKE_SECRET_LOWER="age-secret-key-1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

# ── Fakes ───────────────────────────────────────────────────────────────────
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/sh
# Offline, unless a case sets FAKE_ONLINE=1 (the server answers 200) or
# FAKE_HTTP_STATUS=<code> (it answers with that status) to reach the listing
# probes, or FAKE_CURL_FAIL=refused|dns for the two ways of not answering.
# Nothing leaves the machine: curl is only ever asked for a HEAD. As real
# curl: -f turns a status of 400 or more into exit 22, -w prints the status
# (000 when there was no answer), and a refused connection exits 7, a name
# that does not resolve 6.
status=""
[ "${FAKE_ONLINE:-}" = 1 ] && status=200
[ -n "${FAKE_HTTP_STATUS:-}" ] && status="$FAKE_HTTP_STATUS"
case "${FAKE_CURL_FAIL:-}" in refused) status="" ; rc=7 ;; dns) status="" ; rc=6 ;; *) rc=7 ;; esac
fail=0; w=0
for a in "$@"; do
    case "$a" in
        -f|-fsS|-fsSL) fail=1 ;;
        -w) w=1 ;;
    esac
done
if [ -z "$status" ]; then
    [ "$w" = 1 ] && printf '000'
    exit "$rc"
fi
[ "$w" = 1 ] && printf '%s' "$status"
if [ "$fail" = 1 ] && [ "$status" -ge 400 ]; then exit 22; fi
exit 0
EOF
cat > "$FAKEBIN/timeout" <<'EOF'
#!/bin/sh
# timeout [-k N] SECS CMD...: run CMD unbounded.
if [ "$1" = "-k" ]; then shift 2; fi
shift
exec "$@"
EOF
cat > "$FAKEBIN/chown" <<'EOF'
#!/bin/sh
# FAKE_CHOWN_FAIL=<text>: fail for any path containing it, to interrupt a run
# at a chosen write.
if [ -n "${FAKE_CHOWN_FAIL:-}" ]; then
    for a in "$@"; do
        case "$a" in *"$FAKE_CHOWN_FAIL"*) exit 1 ;; esac
    done
fi
exit 0
EOF
cat > "$WORK/fake-rclone.py" <<'EOF'
import json, os, sys
args = sys.argv[1:]
if args[:1] == ["version"]:
    print("rclone v1.75.2")
    sys.exit(0)
cfg = None
rest = []
i = 0
while i < len(args):
    if args[i] == "--config":
        cfg = args[i + 1]
        i += 2
        continue
    rest.append(args[i])
    i += 1
log = os.environ.get("FAKE_RCLONE_LOG")
if log:
    with open(log, "a") as fh:
        fh.write(" ".join(a for a in rest if not a.startswith("--")) + "\n")
if rest[-2:] == ["config", "dump"]:
    data = {}
    if cfg and os.path.exists(cfg):
        section = None
        for raw in open(cfg):
            line = raw.strip()
            if not line or line[0] in "#;":
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                data.setdefault(section, {})
                continue
            if "=" not in line or section is None:
                sys.exit(1)
            k, v = line.split("=", 1)
            data[section][k.strip()] = v.strip()
    # FAKE_RCLONE_DRIFT: read any file but the real config's name as if its
    # upload section had changed, to exercise the check that appending the
    # read section leaves every other section as rclone read it.
    if os.environ.get("FAKE_RCLONE_DRIFT") and cfg and not cfg.endswith(".conf") and "b2unit" in data:
        data["b2unit"]["hard_delete"] = "true"
    # FAKE_RCLONE_TOUCH=<file>: when a temporary copy is read, change <file>,
    # as a second writer would between the copy and the rename.
    touch = os.environ.get("FAKE_RCLONE_TOUCH")
    if touch and cfg and not cfg.endswith(".conf"):
        with open(touch, "a") as fh:
            fh.write("# changed by another writer\n")
    print(json.dumps(data))
    sys.exit(0)
if "lsf" in rest:
    # FAKE_LSF_FAIL=<remote>: a listing through that remote fails.
    # FAKE_LSF_PREFIX_ONLY=<prefix>: every key is scoped to that name prefix,
    # as B2 scopes one, so a listing outside <bucket>/<prefix> fails.
    target = rest[-1]
    if os.environ.get("FAKE_LSF_FAIL") and target.startswith(os.environ["FAKE_LSF_FAIL"] + ":"):
        sys.exit(1)
    only = os.environ.get("FAKE_LSF_PREFIX_ONLY")
    if only and target.split(":", 1)[-1].split("/", 1)[1:] != [only]:
        sys.exit(1)
    sys.exit(0)
sys.exit(2)
EOF
chmod +x "$FAKEBIN"/*

# flock(1): the Pi has it; macOS does not. Where it is missing, a fake that
# always takes the lock stands in, so the cases that need the lock run on
# both. NOLOCKBIN is the system's bin directories with flock left out, for the
# case that needs it absent.
FLOCKBIN="$WORK/flockbin"
mkdir -p "$FLOCKBIN"
if ! command -v flock >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "$FLOCKBIN/flock"
    chmod +x "$FLOCKBIN/flock"
fi
NOLOCKBIN="$WORK/nolockbin"
mkdir -p "$NOLOCKBIN"
for d in /usr/bin /bin /usr/sbin /sbin; do
    for f in "$d"/*; do
        n="${f##*/}"
        [ "$n" = flock ] && continue
        [ -e "$NOLOCKBIN/$n" ] || ln -s "$f" "$NOLOCKBIN/$n" 2>/dev/null
    done
done
DEFAULT_PATH="$FAKEBIN:$FLOCKBIN:/usr/bin:/bin:/usr/sbin:/sbin"
RUN_PATH="$DEFAULT_PATH"
RUN_SHELL="/bin/bash"

# ── Harness ─────────────────────────────────────────────────────────────────
ROOT=""
OUT=""
STATUS=0

new_unit() {
    ROOT="$WORK/unit.$RANDOM$RANDOM"
    mkdir -p "$ROOT/usr/local/bin" "$ROOT/var/lib/dtk"
    printf '#!/bin/sh\nexec python3 -I %s "$@"\n' "$WORK/fake-rclone.py" > "$ROOT/usr/local/bin/rclone"
    chmod +x "$ROOT/usr/local/bin/rclone"
}
env_file()  { echo "$ROOT/var/lib/dtk/offsite.env"; }
conf_file() { echo "$ROOT/var/lib/dtk/rclone.conf"; }

# run [VAR=value ...] -- [script args...]
run() {
    local -a envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    # RUN_SHELL is word-split on purpose, so a case can run "/bin/bash -x".
    # shellcheck disable=SC2086
    OUT="$(env -i HOME="$WORK" PATH="$RUN_PATH" \
              FAKE_RCLONE_LOG="$ROOT/rclone.log" ${envs[@]+"${envs[@]}"} \
              $RUN_SHELL "$SCRIPT" --prefix "$ROOT" "$@" 2>&1)"
    STATUS=$?
}

key_file() {   # key_file <name> <lines...>
    local f="$WORK/$1"
    shift
    printf '%s\n' "$@" > "$f"
    echo "$f"
}

case_() { CASE="$1"; }
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL [$CASE] $1"; }

indent() { local l; while IFS= read -r l; do printf '    | %s\n' "$l"; done <<< "$1"; }
expect_status() {
    if [ "$STATUS" -eq "$1" ]; then ok; else bad "exit status $STATUS, wanted $1"; indent "$OUT"; fi
}
expect_out() {
    case "$OUT" in *"$1"*) ok ;; *) bad "output lacks: $1"; indent "$OUT" ;; esac
}
expect_not_out() {
    case "$OUT" in *"$1"*) bad "output contains: $1" ;; *) ok ;; esac
}
expect_line() {   # expect_line <file> <exact line>
    if [ -f "$1" ] && grep -qxF "$2" "$1"; then ok; else bad "$(basename "$1") lacks line: $2"; fi
}
expect_no_key() {   # expect_no_key <file> <KEY>
    if [ -f "$1" ] && grep -q "^$2=" "$1"; then bad "$(basename "$1") declares $2"; else ok; fi
}
expect_absent() {
    if [ -e "$1" ]; then bad "$(basename "$1") exists"; else ok; fi
}
expect_same() {   # expect_same <file> <saved copy>
    if cmp -s "$1" "$2"; then ok; else bad "$(basename "$1") changed"; diff "$2" "$1" | sed 's/^/    | /'; fi
}
# Neither application key may appear in any output.
expect_no_secrets() {
    expect_not_out "$UP_KEY"
    expect_not_out "$RD_KEY"
    expect_not_out "$FAKE_SECRET"
    expect_not_out "$FAKE_SECRET_LOWER"
}
# The age-secret-shaped value appears in neither the output nor offsite.env.
expect_secret_kept_out() {
    expect_no_secrets
    if [ -f "$(env_file)" ] && grep -qi 'age-secret-key-' "$(env_file)" \
            && ! grep -qi 'age-secret-key-' "$WORK/planted.env" 2>/dev/null; then
        bad "offsite.env holds an age-secret-shaped value"
    else
        ok
    fi
}
# The permission bits, following a symlink, as e.g. 0o600.
mode_of() { python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

# ── Tenant ──────────────────────────────────────────────────────────────────
# Fisqua's tenant slug rule: 1-63 characters, lowercase letters, digits and
# single hyphens, starting with a letter; platform, www, api, admin and app
# are reserved. A reserved word inside a longer slug is not reserved.
TENANT_63="abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc"
for t in ahr sbmal captua-test a1-b2-c3 a "$TENANT_63" api-test apps my-app; do
    case_ "tenant valid: $t"
    new_unit
    run -- --tenant "$t"
    expect_status 0
    expect_line "$(env_file)" "DTK_OFFSITE_TENANT=$t"
    expect_no_key "$(env_file)" DTK_OFFSITE_REMOTE
done

for t in AHR Ahr ahr/x /ahr ahr/ -ahr ahr- ahr--x ahr_x "ahr x" " ahr" "ahr;x" "ahr.x" \
         1ahr 9 "${TENANT_63}d" platform www api admin app; do
    case_ "tenant invalid: '$t'"
    new_unit
    run -- --tenant "$t"
    expect_status 1
    expect_out "refusing the tenant prefix given with --tenant"
    expect_out "starting with a letter"
    expect_out "was NOT recorded"
    expect_absent "$(env_file)"
done

case_ "tenant invalid under --advisory"
new_unit
run -- --advisory --tenant AHR
expect_status 0
expect_out "refusing the tenant prefix"
expect_out "--advisory: not failing the caller"
expect_absent "$(env_file)"

case_ "tenant with no value"
new_unit
run -- --tenant
expect_status 1
expect_out "--tenant needs a tenant prefix"

# ── Dump recipient ──────────────────────────────────────────────────────────
for r in "$RCPT" "$RCPT_UPPER"; do
    case_ "recipient valid: ${r:0:12}"
    new_unit
    run -- --dump-recipient "$r"
    expect_status 0
    expect_line "$(env_file)" "DTK_OFFSITE_DUMP_RECIPIENT=$r"
done

for r in "$RCPT_BADSUM" "$RCPT_MIXED" "$RCPT_M" "$RCPT_HRP" "$RCPT_SHORT" "${RCPT}q" " $RCPT" "age1" "notakey"; do
    case_ "recipient invalid: '${r:0:12}'"
    new_unit
    run -- --dump-recipient "$r"
    expect_status 1
    expect_out "refusing the catalogue dump recipient from --dump-recipient"
    expect_absent "$(env_file)"
done

case_ "recipient: an age secret key on the command line"
new_unit
run -- --dump-recipient "$FAKE_SECRET"
expect_status 1
expect_out "age PRIVATE key"
expect_out "The value is not printed"
expect_no_secrets
expect_absent "$(env_file)"

case_ "recipient: a lowercase age secret key"
new_unit
LOWER_SECRET="$(printf '%s' "$FAKE_SECRET" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
run -- --dump-recipient "$LOWER_SECRET"
expect_status 1
expect_out "age PRIVATE key"
expect_not_out "$LOWER_SECRET"

case_ "recipient: a secret key as a stray argument is not echoed"
new_unit
run -- "$FAKE_SECRET"
expect_status 1
expect_out "unknown argument (not printed"
expect_no_secrets

case_ "recipient: a secret key recorded in offsite.env is refused, not printed"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_DUMP_RECIPIENT=%s\n' "$ROOT/usr/local/bin/rclone" "$FAKE_SECRET" > "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
run --
expect_status 1
expect_out "shaped like an age"
expect_no_secrets
expect_same "$(env_file)" "$WORK/saved.env"

case_ "recipient invalid under --advisory"
new_unit
run -- --advisory --dump-recipient "$RCPT_BADSUM"
expect_status 0
expect_out "refusing the catalogue dump recipient"
expect_absent "$(env_file)"

# ── Fresh unit, upload and read keys together ───────────────────────────────
case_ "fresh unit: both keys, tenant and recipient"
new_unit
KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr --dump-recipient "$RCPT"
expect_status 0
expect_no_secrets
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:$BUCKET"
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=ahr"
expect_line "$(env_file)" "DTK_OFFSITE_DUMP_RECIPIENT=$RCPT"
expect_line "$(env_file)" "DTK_RCLONE_CONFIG=$(conf_file)"
expect_line "$(conf_file)" "[b2unit]"
expect_line "$(conf_file)" "[b2read]"
# Each key in its own section, and never the other's.
UP_SECTION="$(sed -n '/^\[b2unit\]/,/^\[/p' "$(conf_file)")"
RD_SECTION="$(sed -n '/^\[b2read\]/,$p' "$(conf_file)")"
case "$UP_SECTION" in *"$UP_ID"*) ok ;; *) bad "upload section lacks the upload key id" ;; esac
case "$UP_SECTION" in *"$RD_ID"*|*"$RD_KEY"*) bad "upload section holds the read key" ;; *) ok ;; esac
case "$RD_SECTION" in *"account = $RD_ID"*) ok ;; *) bad "read section lacks the read key id" ;; esac
case "$RD_SECTION" in *"$UP_ID"*|*"$UP_KEY"*) bad "read section holds the upload key" ;; *) ok ;; esac

case_ "idempotence: the same run again changes nothing"
cp "$(env_file)" "$WORK/saved.env"
cp "$(conf_file)" "$WORK/saved.conf"
run DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr --dump-recipient "$RCPT"
expect_status 0
expect_same "$(env_file)" "$WORK/saved.env"
expect_same "$(conf_file)" "$WORK/saved.conf"
expect_out "already holds a complete [b2read]"

case_ "idempotence: an update-style run (no key, no options) changes nothing"
run -- --advisory
expect_status 0
expect_same "$(env_file)" "$WORK/saved.env"
expect_same "$(conf_file)" "$WORK/saved.conf"

case_ "update-style run twice more: still nothing"
run -- --advisory
run -- --advisory
expect_status 0
expect_same "$(env_file)" "$WORK/saved.env"
expect_same "$(conf_file)" "$WORK/saved.conf"

# ── Same key id for both remotes ────────────────────────────────────────────
case_ "same key id supplied for both remotes"
new_unit
KF="$(key_file same.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$UP_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "the read key id is the same as the upload key id"
expect_no_secrets
expect_absent "$(conf_file)"
expect_absent "$(env_file)"

case_ "same key id under --advisory: still refused, and nothing written"
run DTK_OFFSITE_KEY_FILE="$KF" -- --advisory
expect_status 0
expect_out "the read key id is the same as the upload key id"
expect_out "--advisory: not failing the caller"
expect_absent "$(conf_file)"
expect_absent "$(env_file)"

case_ "read key id equal to the installed upload section's"
new_unit
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
cp "$(env_file)" "$WORK/saved.env"
cp "$(conf_file)" "$WORK/saved.conf"
KF="$(key_file rdsame.key "READ_KEY_ID=$UP_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "already"
expect_out "holds the key id supplied as the READ key"
expect_no_secrets
expect_same "$(conf_file)" "$WORK/saved.conf"
expect_same "$(env_file)" "$WORK/saved.env"

# ── Adding a read key to a provisioned unit ─────────────────────────────────
case_ "read key added later: appended beside the upload section"
new_unit
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run DTK_OFFSITE_KEY_FILE="$KF" -- --tenant sbmal
expect_status 0
cp "$(conf_file)" "$WORK/before.conf"
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_no_secrets
expect_out "Adding the [b2read] remote"
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:$BUCKET"
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=sbmal"
# The old file is a byte-for-byte prefix of the new one.
if [ "$(head -c "$(wc -c < "$WORK/before.conf")" "$(conf_file)" | cmp -s - "$WORK/before.conf"; echo $?)" = 0 ]; then ok; else bad "the upload section was not preserved byte for byte"; fi
expect_line "$(conf_file)" "account = $RD_ID"

case_ "read key added later: the same run again changes nothing"
cp "$(env_file)" "$WORK/saved.env"
cp "$(conf_file)" "$WORK/saved.conf"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_same "$(conf_file)" "$WORK/saved.conf"
expect_same "$(env_file)" "$WORK/saved.env"

case_ "a different read key over an existing [b2read] is refused"
KF2="$(key_file rd2.key "READ_KEY_ID=000fakeread000000000000099" "READ_APP_KEY=K000FAKEotherReadKey00099")"
run DTK_OFFSITE_KEY_FILE="$KF2" --
expect_status 1
expect_out "different key id"
expect_not_out "K000FAKEotherReadKey00099"
expect_same "$(conf_file)" "$WORK/saved.conf"
expect_same "$(env_file)" "$WORK/saved.env"

case_ "appending that would change how another section reads is not promoted"
new_unit
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run DTK_OFFSITE_KEY_FILE="$KF" --
cp "$(conf_file)" "$WORK/drift.conf"
cp "$(env_file)" "$WORK/drift.env"
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run FAKE_RCLONE_DRIFT=1 DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "was not promoted"
expect_out "  changed or unread,"
expect_same "$(conf_file)" "$WORK/drift.conf"
expect_same "$(env_file)" "$WORK/drift.env"
LEFT=0
for f in "$ROOT"/var/lib/dtk/rclone.conf.*; do [ -e "$f" ] && LEFT=1; done
if [ "$LEFT" -eq 1 ]; then bad "a temporary config was left behind"; else ok; fi

case_ "read key with no upload remote is not used"
new_unit
KF="$(key_file rdonly.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_out "The read key supplied was NOT used"
expect_no_secrets
expect_absent "$(conf_file)"
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE

case_ "incomplete read key material"
new_unit
KF="$(key_file rdhalf.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_out "INCOMPLETE read key material — missing: READ_APP_KEY"
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:$BUCKET"
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE
if grep -q '^\[b2read\]' "$(conf_file)"; then bad "a read section was written from half a key"; else ok; fi

case_ "read key id outside the token class"
new_unit
KF="$(key_file rdbad.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=bad[id]" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "refusing the B2 read key id"
expect_absent "$(conf_file)"

case_ "read application key outside the token class is refused and not printed"
new_unit
KF="$(key_file rdbadkey.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=sec#ret[x]")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "refusing the B2 read application key"
expect_not_out "sec#ret[x]"
expect_absent "$(conf_file)"

case_ "read remote recorded in a bad shape is refused"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_READ_REMOTE=nobucket\n' "$ROOT/usr/local/bin/rclone" > "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
run --
expect_status 1
expect_out "refusing the read remote recorded in"
expect_same "$(env_file)" "$WORK/saved.env"

# ── An offsite.env from before 0.1.0 ────────────────────────────────────────
legacy_unit() {
    new_unit
    cat > "$(conf_file)" <<EOF
[b2unit]
type = b2
hard_delete = false
account = $UP_ID
key = $UP_KEY
EOF
    printf 'DTK_RCLONE_BIN=%s\nDTK_RCLONE_CONFIG=%s\nDTK_OFFSITE_REMOTE=b2unit:%s\n' \
        "$ROOT/usr/local/bin/rclone" "$(conf_file)" "$BUCKET" > "$(env_file)"
}

case_ "old three keys only: a plain run keeps them and adds nothing"
legacy_unit
run -- --advisory
expect_status 0
expect_line "$(env_file)" "DTK_RCLONE_BIN=$ROOT/usr/local/bin/rclone"
expect_line "$(env_file)" "DTK_RCLONE_CONFIG=$(conf_file)"
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:$BUCKET"
expect_no_key "$(env_file)" DTK_OFFSITE_TENANT
expect_no_key "$(env_file)" DTK_OFFSITE_DUMP_RECIPIENT
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE
cp "$(env_file)" "$WORK/saved.env"
run -- --advisory
expect_same "$(env_file)" "$WORK/saved.env"

case_ "old three keys only: options add the new keys, and later runs keep them"
legacy_unit
run -- --tenant ahr --dump-recipient "$RCPT"
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:$BUCKET"
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=ahr"
expect_line "$(env_file)" "DTK_OFFSITE_DUMP_RECIPIENT=$RCPT"
cp "$(env_file)" "$WORK/saved.env"
run -- --advisory
expect_same "$(env_file)" "$WORK/saved.env"

case_ "a changed tenant without --change-tenant is refused"
cp "$(env_file)" "$WORK/saved.env"
run -- --tenant sbmal
expect_status 1
expect_out "refusing to replace the recorded tenant ahr"
expect_out "keep their keys there; new ones would go under sbmal/"
expect_out "was NOT recorded"
expect_same "$(env_file)" "$WORK/saved.env"

case_ "a changed tenant without --change-tenant, under --advisory"
run -- --advisory --tenant sbmal
expect_status 0
expect_out "refusing to replace the recorded tenant ahr"
expect_same "$(env_file)" "$WORK/saved.env"

case_ "the same tenant again needs no flag"
run -- --tenant ahr
expect_status 0
expect_not_out "refusing to replace"
expect_same "$(env_file)" "$WORK/saved.env"

case_ "a changed tenant with --change-tenant is applied and said"
run -- --tenant sbmal --change-tenant
expect_status 0
expect_out "replaces the recorded tenant ahr"
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=sbmal"
expect_line "$(env_file)" "DTK_OFFSITE_DUMP_RECIPIENT=$RCPT"

case_ "--change-tenant on a unit with no recorded tenant"
new_unit
run -- --tenant ahr --change-tenant
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=ahr"

case_ "--change-tenant alone is a caller error"
new_unit
run -- --change-tenant
expect_status 1
expect_out "--change-tenant needs --tenant NAME"
expect_absent "$(env_file)"

case_ "a changed recipient is applied with a note, no flag needed"
legacy_unit
run -- --dump-recipient "$RCPT"
expect_status 0
run -- --dump-recipient "$RCPT_UPPER"
expect_status 0
expect_out "--dump-recipient replaces the recorded recipient"
expect_line "$(env_file)" "DTK_OFFSITE_DUMP_RECIPIENT=$RCPT_UPPER"

case_ "offsite.env with a line this script does not write: options not recorded"
legacy_unit
echo "DTK_OFFSITE_BWLIMIT=1M" >> "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
run -- --tenant ahr
expect_status 0
expect_out "is not in the format this script writes"
expect_out "was NOT recorded"
expect_same "$(env_file)" "$WORK/saved.env"

case_ "legacy unit with no recorded config path: read key refused, not appended"
new_unit
cat > "$(conf_file)" <<EOF
[b2unit]
type = b2
account = $UP_ID
key = $UP_KEY
EOF
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_REMOTE=b2unit:%s\n' "$ROOT/usr/local/bin/rclone" "$BUCKET" > "$(env_file)"
cp "$(conf_file)" "$WORK/saved.conf"
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "has not established that file"
expect_same "$(conf_file)" "$WORK/saved.conf"

case_ "the same, with --config-path naming the file: appended"
run DTK_OFFSITE_KEY_FILE="$KF" -- --config-path "$(conf_file)"
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"
expect_line "$(conf_file)" "[b2read]"

# ── Review round 1 (Codex and adversarial review) ───────────────────────────

# B1: an age-secret-shaped value is never printed and never written, wherever
# it comes from.
secret_case() {   # secret_case <label> <expected status> -- <run args...>
    local label="$1" want="$2"
    shift 3
    case_ "age secret via $label"
    run "$@"
    expect_status "$want"
    expect_secret_kept_out
    expect_out "not printed"
}
for s in "$FAKE_SECRET" "$FAKE_SECRET_LOWER"; do
    new_unit
    secret_case "--tenant ${s:0:4}" 1 -- -- --tenant "$s"
    new_unit
    secret_case "--config-path ${s:0:4}" 1 -- -- --config-path "/$s"
    new_unit
    secret_case "--prefix ${s:0:4}" 1 -- -- --prefix "$ROOT/$s"
done
for key in DTK_OFFSITE_TENANT DTK_RCLONE_CONFIG DTK_OFFSITE_REMOTE DTK_OFFSITE_READ_REMOTE DTK_OFFSITE_BWLIMIT; do
    for s in "$FAKE_SECRET" "$FAKE_SECRET_LOWER"; do
        new_unit
        case "$key" in
            DTK_RCLONE_CONFIG) v="/$s" ;;
            DTK_OFFSITE_REMOTE|DTK_OFFSITE_READ_REMOTE) v="b2unit:$s" ;;
            *) v="$s" ;;
        esac
        printf 'DTK_RCLONE_BIN=%s\n%s=%s\n' "$ROOT/usr/local/bin/rclone" "$key" "$v" > "$(env_file)"
        cp "$(env_file)" "$WORK/planted.env"
        secret_case "recorded $key ${s:0:4}" 1 -- --
        expect_same "$(env_file)" "$WORK/planted.env"
    done
done
rm -f "$WORK/planted.env"
for field in KEY_ID BUCKET READ_KEY_ID; do
    new_unit
    lines=("KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")
    for i in 0 1 2 3 4; do
        case "${lines[i]}" in "$field="*) lines[i]="$field=$FAKE_SECRET" ;; esac
    done
    KF="$(key_file secret.key "${lines[@]}")"
    secret_case "key file $field" 1 -- DTK_OFFSITE_KEY_FILE="$KF" --
    expect_absent "$(conf_file)"
done

# B2: a run interrupted after the config was written, with read keys in the
# key file, resumes on the next run.
case_ "interrupted run with read keys: the first run fails at offsite.env"
new_unit
KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run FAKE_CHOWN_FAIL="offsite.env." DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr
expect_status 1
expect_absent "$(env_file)"
expect_line "$(conf_file)" "[b2read]"
cp "$(conf_file)" "$WORK/saved.conf"
case_ "interrupted run with read keys: the re-run resumes"
run DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr
expect_status 0
expect_out "already holds a complete [b2read]"
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:$BUCKET"
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"
expect_same "$(conf_file)" "$WORK/saved.conf"

# M1: the file an append would rename over must be a path of the safe class.
case_ "symlinked config whose target has a quote in its name"
legacy_unit
EVIL="$ROOT/x';touch pwned;'.conf"
mv "$(conf_file)" "$EVIL"
ln -s "$EVIL" "$(conf_file)"
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "refusing the resolved rclone config path"
if [ -L "$(conf_file)" ]; then ok; else bad "the case did not set up its symlink"; fi
if grep -q '^\[b2read\]' "$EVIL"; then bad "appended through an unsafe target"; else ok; fi

# M2: a recorded read remote that cannot belong to a freshly written upload
# remote is dropped, and said.
case_ "fresh write: recorded read remote on another bucket is dropped"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_REMOTE=b2unit:old-bucket-1\nDTK_OFFSITE_READ_REMOTE=b2read:old-bucket-1\n' \
    "$ROOT/usr/local/bin/rclone" > "$(env_file)"
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_out "dropped"
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:$BUCKET"
case_ "fresh write: recorded read remote with no section in the new file is dropped"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_READ_REMOTE=b2read:%s\n' "$ROOT/usr/local/bin/rclone" "$BUCKET" > "$(env_file)"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_out "dropped"
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE

# M3: a recorded read remote must not name the upload remote, nor another bucket.
case_ "recorded read remote naming the upload remote is refused"
legacy_unit
echo "DTK_OFFSITE_READ_REMOTE=b2unit:$BUCKET" >> "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
run --
expect_status 1
expect_out "names the upload remote"
expect_same "$(env_file)" "$WORK/saved.env"
case_ "recorded read remote on another bucket than the upload remote is refused"
legacy_unit
echo "DTK_OFFSITE_READ_REMOTE=b2read:other-bucket-2" >> "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
run --
expect_status 1
expect_out "not the upload remote's bucket"
expect_same "$(env_file)" "$WORK/saved.env"

# M4, revised: listings cannot tell the two keys' roles apart (both keys
# list), so nothing infers a swap from them. With a tenant, both probes list
# the tenant prefix, which is all the backend ever lists and all a
# prefix-scoped key may list; without one the upload probe lists the bucket.
case_ "online probes: prefix-scoped keys, both probes list the tenant prefix"
new_unit
KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run FAKE_ONLINE=1 FAKE_LSF_PREFIX_ONLY=ahr DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr
expect_status 0
expect_out "a listing of b2unit:$BUCKET/ahr succeeded"
expect_out "a listing of b2read:$BUCKET/ahr succeeded"
expect_not_out "did not succeed"
expect_not_out "swapped"
expect_no_secrets
case_ "online probes: an upload listing that fails says nothing about a swap"
new_unit
run FAKE_ONLINE=1 FAKE_LSF_FAIL=b2unit DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr
expect_status 0
expect_out "the listing of b2unit:$BUCKET/ahr did not succeed"
expect_out "a listing of b2read:$BUCKET/ahr succeeded"
expect_not_out "swapped"
case_ "online probes: with no tenant the upload probe lists the bucket"
new_unit
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run FAKE_ONLINE=1 DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_out "a listing of b2unit:$BUCKET succeeded"
if grep -q "^lsf .* b2unit:$BUCKET\$" "$ROOT/rclone.log"; then ok; else bad "the upload probe did not list the bucket root"; fi

# Any HTTP status is an answer from api.backblazeb2.com; only a connection
# that fails (refused, a name that does not resolve, TLS, a timeout) is not.
for st in 405 403 404 500; do
    case_ "online probes: api.backblazeb2.com answers $st, so both probes are attempted"
    new_unit
    KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
    run FAKE_HTTP_STATUS="$st" DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr
    expect_status 0
    expect_out "a listing of b2unit:$BUCKET/ahr succeeded"
    expect_out "a listing of b2read:$BUCKET/ahr succeeded"
    expect_not_out "did not answer"
done
for how in refused dns; do
    case_ "online probes: api.backblazeb2.com unreachable ($how), so neither is attempted"
    new_unit
    KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
    run FAKE_CURL_FAIL="$how" DTK_OFFSITE_KEY_FILE="$KF" -- --tenant ahr
    expect_status 0
    expect_out "api.backblazeb2.com did not answer"
    expect_not_out "a listing of b2unit:$BUCKET/ahr succeeded"
    if grep -q "^lsf " "$ROOT/rclone.log" 2>/dev/null; then bad "a listing was attempted"; else ok; fi
done

# M5: the read key comes from the key file only.
case_ "read key in the environment is ignored"
new_unit
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run DTK_B2_READ_KEY_ID="$RD_ID" DTK_B2_READ_APP_KEY="$RD_KEY" DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
if grep -q '^\[b2read\]' "$(conf_file)"; then bad "a read section was written from the environment"; else ok; fi
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE

# M6: the append replaces a file, so it needs the lock.
case_ "append without flock is refused"
legacy_unit
cp "$(conf_file)" "$WORK/saved.conf"
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
RUN_PATH="$FAKEBIN:$NOLOCKBIN"
run DTK_OFFSITE_KEY_FILE="$KF" --
RUN_PATH="$DEFAULT_PATH"
expect_status 1
expect_out "flock is not installed"
expect_out "refusing to add the read key"
expect_same "$(conf_file)" "$WORK/saved.conf"
case_ "fresh write without flock still works"
new_unit
KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
RUN_PATH="$FAKEBIN:$NOLOCKBIN"
run DTK_OFFSITE_KEY_FILE="$KF" --
RUN_PATH="$DEFAULT_PATH"
expect_status 0
expect_line "$(conf_file)" "[b2read]"

# M7: refusals say what was left, not that nothing changed.
case_ "read refusal says what was left"
legacy_unit
KF="$(key_file rdsame.key "READ_KEY_ID=$UP_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "No [b2read] section was written and $(env_file) was not changed"
expect_not_out "nothing was changed"
expect_out "What this run did:"
case_ "same key id refusal says what was left"
new_unit
KF="$(key_file same.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$UP_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "No credential was written and $(env_file) was not changed"
expect_not_out "nothing was changed"

# M8: xtrace in the caller never reaches the keys.
case_ "bash -x prints no key"
new_unit
KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
RUN_SHELL="/bin/bash -x"
run DTK_OFFSITE_KEY_FILE="$KF" --
RUN_SHELL="/bin/bash"
expect_status 0
expect_no_secrets
case_ "SHELLOPTS=xtrace prints no key"
new_unit
run SHELLOPTS=xtrace DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_no_secrets

# M9: the old-bytes check, the symlink branch and the mode after the rename.
case_ "append: the old file changing between copy and rename stops it"
legacy_unit
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run FAKE_RCLONE_TOUCH="$(conf_file)" DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "old file: changed or unread"
if grep -q '^\[b2read\]' "$(conf_file)"; then bad "promoted over a changed file"; else ok; fi
LEFT=0
for f in "$ROOT"/var/lib/dtk/rclone.conf.*; do [ -e "$f" ] && LEFT=1; done
if [ "$LEFT" -eq 1 ]; then bad "a temporary config was left behind"; else ok; fi

case_ "append through a symlink writes the target and keeps the link"
legacy_unit
mkdir -p "$ROOT/mnt"
mv "$(conf_file)" "$ROOT/mnt/live.conf"
chmod 0644 "$ROOT/mnt/live.conf"
ln -s "$ROOT/mnt/live.conf" "$(conf_file)"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
if [ -L "$(conf_file)" ]; then ok; else bad "the symlink was replaced by a file"; fi
expect_line "$ROOT/mnt/live.conf" "[b2read]"
if [ "$(mode_of "$ROOT/mnt/live.conf")" = "0o600" ]; then ok; else bad "target mode $(mode_of "$ROOT/mnt/live.conf") after mv"; fi
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"

case_ "append to a plain file: mode 0600 after the rename"
legacy_unit
chmod 0644 "$(conf_file)"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
if [ "$(mode_of "$(conf_file)")" = "0o600" ]; then ok; else bad "mode $(mode_of "$(conf_file)") after mv"; fi

# ── Review round 2 ──────────────────────────────────────────────────────────

# N1: on the kept path, a complete [b2read] at a config path this run has not
# established is not recorded.
case_ "kept path: complete [b2read] at an unestablished path is not recorded"
new_unit
cat > "$(conf_file)" <<EOF
[b2unit]
type = b2
account = $UP_ID
key = $UP_KEY
[b2read]
type = b2
account = $RD_ID
key = $RD_KEY
EOF
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_REMOTE=b2unit:%s\n' "$ROOT/usr/local/bin/rclone" "$BUCKET" > "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "has not established that file"
expect_same "$(env_file)" "$WORK/saved.env"
expect_no_secrets
case_ "kept path: the same with --config-path is recorded"
run DTK_OFFSITE_KEY_FILE="$KF" -- --config-path "$(conf_file)"
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"

# N2: a recorded read remote naming the upload remote is refused before the
# fresh write publishes anything.
case_ "fresh write: recorded read remote naming the upload remote is refused first"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_READ_REMOTE=b2unit:%s\n' "$ROOT/usr/local/bin/rclone" "$BUCKET" > "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 1
expect_out "names the upload remote"
expect_absent "$(conf_file)"
expect_same "$(env_file)" "$WORK/saved.env"
case_ "fresh write: the same with a read key supplied replaces it"
KF="$(key_file both.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET" "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"

# N3: with no upload remote recorded, a recorded read remote is dropped.
case_ "no upload remote: a recorded read remote is dropped"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_READ_REMOTE=b2read:%s\n' "$ROOT/usr/local/bin/rclone" "$BUCKET" > "$(env_file)"
run --
expect_status 0
expect_out "dropped"
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE
case_ "no upload remote: a recorded read remote naming b2unit is refused"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_READ_REMOTE=b2unit:%s\n' "$ROOT/usr/local/bin/rclone" "$BUCKET" > "$(env_file)"
cp "$(env_file)" "$WORK/saved.env"
run --
expect_status 1
expect_out "names the upload remote"
expect_same "$(env_file)" "$WORK/saved.env"

# N4: a value that merely contains the words is not a key.
case_ "tenant containing age-secret-key but not a key is accepted"
new_unit
run -- --tenant age-secret-key-archive
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=age-secret-key-archive"
case_ "and a later run reads that file back"
run -- --advisory
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=age-secret-key-archive"
case_ "bucket containing age-secret-key but not a key is accepted"
new_unit
KF="$(key_file up.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=age-secret-key-bucket")"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_REMOTE=b2unit:age-secret-key-bucket"
case_ "config path containing age-secret-key but not a key is accepted"
new_unit
mkdir -p "$ROOT/srv/age-secret-key-notes"
run -- --config-path "$ROOT/srv/age-secret-key-notes/rclone.conf"
expect_status 0
expect_line "$(env_file)" "DTK_RCLONE_CONFIG=$ROOT/srv/age-secret-key-notes/rclone.conf"
case_ "the full key shape in mixed case is still refused unprinted"
new_unit
MIXED_SECRET="AGE-secret-KEY-1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
run -- --tenant "$MIXED_SECRET"
expect_status 1
expect_not_out "$MIXED_SECRET"
expect_absent "$(env_file)"

# R3-1: a truncated private key is still a key for refusing; a value that
# only resembles the words is not.
case_ "truncated lowercase age secret as tenant is refused unprinted"
new_unit
TRUNC_SECRET="age-secret-key-1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
run -- --tenant "$TRUNC_SECRET"
expect_status 1
expect_not_out "$TRUNC_SECRET"
expect_absent "$(env_file)"
case_ "eight bech32 characters after the prefix is enough to refuse"
new_unit
run -- --tenant "age-secret-key-1qqqqqqqq"
expect_status 1
expect_not_out "age-secret-key-1qqqqqqqq"
expect_absent "$(env_file)"
case_ "age-secret-key-test as tenant is accepted"
new_unit
run -- --tenant age-secret-key-test
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=age-secret-key-test"

# N5: the whole-file refusal names a line.
case_ "whole-file refusal says a line"
new_unit
printf 'DTK_RCLONE_BIN=%s\nDTK_OFFSITE_TENANT=%s\n' "$ROOT/usr/local/bin/rclone" "$FAKE_SECRET_LOWER" > "$(env_file)"
run --
expect_status 1
expect_out "holds a line shaped like an age"
expect_no_secrets

# M5 residual: under --advisory (update.sh), the read key is not taken from
# a key file, since DTK_OFFSITE_KEY_FILE can come from .env there.
case_ "advisory run ignores the read key in DTK_OFFSITE_KEY_FILE"
legacy_unit
cp "$(conf_file)" "$WORK/saved.conf"
KF="$(key_file rd.key "READ_KEY_ID=$RD_ID" "READ_APP_KEY=$RD_KEY")"
run DTK_OFFSITE_KEY_FILE="$KF" -- --advisory
expect_status 0
expect_out "not written under --advisory"
expect_same "$(conf_file)" "$WORK/saved.conf"
expect_no_key "$(env_file)" DTK_OFFSITE_READ_REMOTE
case_ "advisory run with no read keys in the file prints no note"
KF2="$(key_file uponly.key "KEY_ID=$UP_ID" "APP_KEY=$UP_KEY" "BUCKET=$BUCKET")"
run DTK_OFFSITE_KEY_FILE="$KF2" -- --advisory
expect_status 0
expect_not_out "under --advisory, which is how"
case_ "the same run without --advisory adds it"
run DTK_OFFSITE_KEY_FILE="$KF" --
expect_status 0
expect_line "$(env_file)" "DTK_OFFSITE_READ_REMOTE=b2read:$BUCKET"

# ── Nothing read was ever passed to rclone on its command line ──────────────
case_ "no key on any rclone argument list"
if grep -rqF -e "$UP_KEY" -e "$RD_KEY" "$WORK"/unit.*/rclone.log 2>/dev/null; then
    bad "an application key reached rclone's argv"
else
    ok
fi

echo ""
echo "provision-rclone tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
