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

# ── Fakes ───────────────────────────────────────────────────────────────────
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/sh
exit 7
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
    print(json.dumps(data))
    sys.exit(0)
if "lsf" in rest:
    sys.exit(0)
sys.exit(2)
EOF
chmod +x "$FAKEBIN"/*

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
    OUT="$(env -i HOME="$WORK" PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin" \
              FAKE_RCLONE_LOG="$ROOT/rclone.log" ${envs[@]+"${envs[@]}"} \
              /bin/bash "$SCRIPT" --prefix "$ROOT" "$@" 2>&1)"
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
}

# ── Tenant ──────────────────────────────────────────────────────────────────
for t in ahr sbmal captua-test a1-b2-c3; do
    case_ "tenant valid: $t"
    new_unit
    run -- --tenant "$t"
    expect_status 0
    expect_line "$(env_file)" "DTK_OFFSITE_TENANT=$t"
    expect_no_key "$(env_file)" DTK_OFFSITE_REMOTE
done

for t in AHR Ahr ahr/x /ahr ahr/ -ahr ahr- ahr--x ahr_x "ahr x" " ahr" "ahr;x" "ahr.x"; do
    case_ "tenant invalid: '$t'"
    new_unit
    run -- --tenant "$t"
    expect_status 1
    expect_out "refusing the tenant prefix given with --tenant"
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
expect_out "age PRIVATE key"
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

case_ "same key id under --advisory: refused, exit 0"
run DTK_OFFSITE_KEY_FILE="$KF" -- --advisory
expect_status 0
expect_out "the read key id is the same as the upload key id"
expect_absent "$(conf_file)"

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

case_ "a changed tenant is applied and said"
run -- --tenant sbmal
expect_status 0
expect_out "replaces the recorded tenant ahr"
expect_line "$(env_file)" "DTK_OFFSITE_TENANT=sbmal"

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
