#!/bin/bash
# Tests for the placeholder detection in scripts/generate-secrets.sh.
#
#   bash scripts/tests/generate-secrets.test.sh
#
# generate-secrets.sh needs root, a Pi serial, /var/lib/dtk and docker compose,
# so it is not run whole. The functions that read .env and decide whether a
# value is a placeholder are taken out of the real script by name and run as an
# ordinary user; they touch no file but the one they are pointed at.
#
# The cases that matter are the values a unit can actually start from: a unit
# set up from .env.example has to get fresh secrets on first boot, so every
# secret .env.example ships must read as a placeholder, and so must every value
# it has shipped before, since an older card can still carry one.
#
# Version: 0.1.0-beta

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
SECRETS="$SCRIPTS/generate-secrets.sh"
EXAMPLE="$(dirname "$SCRIPTS")/.env.example"

PASS=0
FAIL=0
CASE=""

# ── Helpers ─────────────────────────────────────────────────────────────────
ok()   { PASS=$((PASS + 1)); echo "  ok    $CASE: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $CASE: $1"; }

# The text of one top-level function, from "name() {" to the first "}" in
# column one.
extract() {  # extract <script> <function>
    awk -v f="$2" '
        $0 ~ "^" f "\\(\\) \\{" { on = 1 }
        on { print }
        on && /^\}/ { exit }
    ' "$1"
}

load() {  # load <script> <function>...
    local script="$1" fn body
    shift
    for fn in "$@"; do
        body="$(extract "$script" "$fn")"
        if [ -z "$body" ]; then
            fail "no function $fn in $(basename "$script")"
            return 1
        fi
        eval "$body"
    done
}

expect_placeholder() {  # expect_placeholder <function> <value> <what>
    if "$1" "$2"; then ok "$3 '$2' is a placeholder"; else fail "$3 '$2' is not treated as a placeholder"; fi
}

expect_real() {  # expect_real <function> <value> <what>
    if "$1" "$2"; then fail "$3 '$2' is treated as a placeholder"; else ok "$3 '$2' is kept"; fi
}

CASE="load"
load "$SECRETS" get_env is_placeholder_secret is_placeholder_dbpass is_placeholder_bootstrap || {
    echo ""
    echo "$PASS passed, $FAIL failed"
    exit 1
}

# ── What .env.example ships ─────────────────────────────────────────────────
# Read through the script's own get_env, so an inline comment or stray space
# on the line is handled the way the script handles it on a unit.
CASE=".env.example"
ENV_FILE="$EXAMPLE"
expect_placeholder is_placeholder_secret "$(get_env SECRET_KEY)" "SECRET_KEY"
expect_placeholder is_placeholder_dbpass "$(get_env DATABASE_PASSWORD)" "DATABASE_PASSWORD"
expect_placeholder is_placeholder_bootstrap "$(get_env BOOTSTRAP_TOKEN)" "BOOTSTRAP_TOKEN"

# ── What the repo has shipped before ────────────────────────────────────────
# SECRET_KEY: .env.example until 2026-07-25, the backend's built-in default,
# and the example block in docs/developers/API_REFERENCE.md.
CASE="SECRET_KEY placeholders"
for v in "" \
         "your-secret-key-here-change-in-production" \
         "secret-key-here-change-in-production" \
         "dev-secret-change-me" \
         "change-this-to-a-random-string"; do
    expect_placeholder is_placeholder_secret "$v" "SECRET_KEY"
done

# DATABASE_PASSWORD: .env.example until 2026-01-10 and the compose default.
CASE="DATABASE_PASSWORD placeholders"
for v in "" "password" "change-this-in-production"; do
    expect_placeholder is_placeholder_dbpass "$v" "DATABASE_PASSWORD"
done

# ── Real secrets are kept ───────────────────────────────────────────────────
# A hand-provisioned unit's secrets are adopted, never rotated, so a real value
# must not match.
CASE="real secrets"
REAL="$(printf '%064d' 7 | tr 0 a)"
expect_real is_placeholder_secret "$REAL" "SECRET_KEY"
expect_real is_placeholder_dbpass "$REAL" "DATABASE_PASSWORD"
expect_real is_placeholder_bootstrap "$REAL" "BOOTSTRAP_TOKEN"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
