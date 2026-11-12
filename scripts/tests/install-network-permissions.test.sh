#!/bin/bash
# Tests for scripts/install-network-permissions.sh: the polkit rule that lets
# the appliance user (pi) scan, join and forget Wi-Fi networks through
# NetworkManager.
#
#   bash scripts/tests/install-network-permissions.test.sh
#
# Each case runs the real script under --prefix against a fresh temporary
# root. Nothing touches the machine's own /etc.
#
# Version: 0.1.0-beta

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
SCRIPT="$SCRIPTS/install-network-permissions.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-network-permissions-test.XXXXXX")"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CASE=""
ok()   { PASS=$((PASS + 1)); echo "  ok    $CASE: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $CASE: $1"; }
eq()   { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3: got '$1', expected '$2'"; fi; }
has()  { case "$OUT" in *"$1"*) ok "says: $1" ;; *) fail "does not say: $1 (output: $OUT)" ;; esac; }

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sum_of()  { cksum < "$1"; }

RULE_NAME="40-captua-network.rules"

# The rule as verified on the bench unit.
EXPECTED="$WORK/expected.rules"
cat > "$EXPECTED" <<'EOF'
polkit.addRule(function(action, subject) {
    if (subject.user == "pi" &&
        (action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system")) {
        return polkit.Result.YES;
    }
});
EOF

# A fresh root; with_dir=1 gives it an empty etc/polkit-1/rules.d.
new_root() {
    R="$WORK/root.$1"
    rm -rf "$R"
    mkdir -p "$R/etc"
    if [ "${2:-1}" = 1 ]; then mkdir -p "$R/etc/polkit-1/rules.d"; fi
    RULE="$R/etc/polkit-1/rules.d/$RULE_NAME"
}
run() {
    OUT="$(bash "$SCRIPT" --prefix "$R" 2>&1)"
    RC=$?
}

# ── 1. Installs the file, mode 644 ─────────────────────────────────────────
CASE="install"
new_root 1
run
eq "$RC" 0 "exits 0"
if [ -f "$RULE" ]; then ok "$RULE_NAME exists"; else fail "$RULE_NAME missing"; fi
eq "$(mode_of "$RULE" 2>/dev/null)" 644 "mode is 644"
if [ -e "$RULE.new" ]; then fail "$RULE_NAME.new left behind"; else ok "no $RULE_NAME.new left behind"; fi
eq "$(ls -A "$R/etc/polkit-1/rules.d")" "$RULE_NAME" "rules.d holds exactly $RULE_NAME"

# ── 2. Body equals the verified rule ───────────────────────────────────────
CASE="body"
if cmp -s "$RULE" "$EXPECTED"; then ok "body equals the verified rule"; else fail "body differs from the verified rule"; fi

# ── 3. Exactly three action ids, user pi ───────────────────────────────────
CASE="actions"
IDS="$(grep -o 'org\.freedesktop\.[A-Za-z0-9._-]*' "$RULE" | sort | tr '\n' ' ')"
eq "$IDS" "org.freedesktop.NetworkManager.network-control org.freedesktop.NetworkManager.settings.modify.system org.freedesktop.NetworkManager.wifi.scan " "the three NetworkManager ids and no other"
if grep -qF 'subject.user == "pi"' "$RULE"; then ok "tests subject.user == \"pi\""; else fail "does not test subject.user == \"pi\""; fi

# ── 4. Sorts before 49- ────────────────────────────────────────────────────
CASE="order"
FIRST="$(printf '%s\n%s\n' "49-polkit-pkla-compat.rules" "$RULE_NAME" | LC_ALL=C sort | head -n 1)"
eq "$FIRST" "$RULE_NAME" "sorts before 49-polkit-pkla-compat.rules"

# ── 5. Second run leaves the same checksum ─────────────────────────────────
CASE="idempotent"
BEFORE="$(sum_of "$RULE")"
run
eq "$RC" 0 "second run exits 0"
eq "$(sum_of "$RULE")" "$BEFORE" "checksum unchanged"

# ── 6. Other content is replaced ───────────────────────────────────────────
CASE="replace"
new_root 6
echo "// something else" > "$RULE"
chmod 600 "$RULE"
run
eq "$RC" 0 "exits 0"
if cmp -s "$RULE" "$EXPECTED"; then ok "file replaced by the rule"; else fail "file not replaced by the rule"; fi
eq "$(mode_of "$RULE" 2>/dev/null)" 644 "an existing mode 600 file ends at mode 644"

# ── 7. No rules.d: warn, exit 0, create nothing ────────────────────────────
CASE="no rules.d"
new_root 7 0
run
eq "$RC" 0 "exits 0"
has "not installed"
has "Wi-Fi"
has "is not a directory"
if [ -d "$R/etc/polkit-1/rules.d" ]; then fail "rules.d was created"; else ok "rules.d still does not exist"; fi

# ── 7b. rules.d is a regular file: warn, exit 0, wording is true ──────────
CASE="rules.d is a file"
new_root 7b 0
mkdir -p "$R/etc/polkit-1"
echo "not a directory" > "$R/etc/polkit-1/rules.d"
run
eq "$RC" 0 "exits 0"
has "not installed"
has "is not a directory"
case "$OUT" in *"does not exist"*) fail "says 'does not exist' for an existing file" ;; *) ok "does not say 'does not exist'" ;; esac
if [ -f "$R/etc/polkit-1/rules.d" ]; then ok "the file is left as it was"; else fail "the file was removed or replaced"; fi

# ── 8. rules.d not writable: non-zero ──────────────────────────────────────
CASE="unwritable"
if [ "$(id -u)" = 0 ]; then
    echo "  skip  $CASE: running as root"
else
    new_root 8
    chmod 500 "$R/etc/polkit-1/rules.d"
    run
    if [ "$RC" -ne 0 ]; then ok "exits non-zero (got $RC)"; else fail "exited 0 on an unwritable directory"; fi
    if [ -e "$RULE.new" ]; then fail "$RULE_NAME.new left behind"; else ok "no $RULE_NAME.new left behind"; fi
    case "$OUT" in *"✓"*) fail "prints the success line although the write failed" ;; *) ok "no success line in the output" ;; esac
    chmod 700 "$R/etc/polkit-1/rules.d"
fi

# ── 8b. Destination is a directory: error, non-zero, nothing left behind ──
CASE="destination is a directory"
new_root 8b
mkdir "$RULE"
run
if [ "$RC" -ne 0 ]; then ok "exits non-zero (got $RC)"; else fail "exited 0 with a directory at the destination"; fi
case "$OUT" in *"✓"*) fail "prints the success line" ;; *) ok "no success line in the output" ;; esac
if [ -e "$RULE.new" ]; then fail "$RULE_NAME.new left behind"; else ok "no $RULE_NAME.new left behind"; fi
if [ -e "$RULE/$RULE_NAME.new" ] || [ -e "$RULE/$(basename "$RULE_NAME").new" ] || [ -n "$(ls -A "$RULE")" ]; then fail "something was moved into the directory"; else ok "the directory is empty"; fi

# ── 9. The three callers ───────────────────────────────────────────────────
CASE="callers"
for f in setup.sh install-service.sh update.sh; do
    if grep -E '^[[:space:]]*"\$SCRIPT_DIR/install-network-permissions\.sh"$' "$SCRIPTS/$f" >/dev/null 2>&1; then
        ok "$f calls install-network-permissions.sh, bare"
    else
        fail "$f has no bare, uncommented call to install-network-permissions.sh"
    fi
done

# update.sh runs the call before it stops the service.
CALL_LINE="$(grep -nE '^[[:space:]]*"\$SCRIPT_DIR/install-network-permissions\.sh"$' "$SCRIPTS/update.sh" | head -n 1 | cut -d: -f1)"
STOP_LINE="$(grep -nE '^[[:space:]]*SERVICE_STOPPED=1' "$SCRIPTS/update.sh" | head -n 1 | cut -d: -f1)"
if [ -n "$CALL_LINE" ] && [ -n "$STOP_LINE" ] && [ "$CALL_LINE" -lt "$STOP_LINE" ]; then
    ok "update.sh calls it (line $CALL_LINE) before the service stop (line $STOP_LINE)"
else
    fail "update.sh call line '$CALL_LINE' is not before the first SERVICE_STOPPED=1 '$STOP_LINE'"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
