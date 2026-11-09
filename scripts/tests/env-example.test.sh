#!/bin/bash
# Checks that .env.example names every setting the backend's settings model
# reads (backend/app/core/config.py), set or commented out, so the two cannot
# drift apart again (NEH-327).
#
#   bash scripts/tests/env-example.test.sh
#
# A field declared with validation_alias=_names("X") is read as CAPTUA_X or
# DTK_X, and either name in .env.example counts. Any other field is read under
# its own name, in capitals. The backend submodule must be checked out.
#
# Version: 0.1.0-beta

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
CONFIG="$ROOT/backend/app/core/config.py"
EXAMPLE="$ROOT/.env.example"

PASS=0
FAIL=0

if [ ! -f "$CONFIG" ]; then
    echo "  FAIL  $CONFIG not found; check out the backend submodule"
    exit 1
fi

# Lines of the form `    name: type = ...` inside the Settings class, in
# either case: pydantic-settings matches names without regard to case, so
# `app_version` is read as APP_VERSION.
# The class ends at the first line after it that is not indented.
fields="$(awk '/^class Settings\(/ {in_class = 1; next}
    in_class && /^[^ \t#]/ {exit}
    in_class' "$CONFIG" \
    | grep -E '^    [A-Za-z][A-Za-z0-9_]*: ')"
if [ -z "$fields" ]; then
    echo "  FAIL  no settings fields found in $CONFIG"
    exit 1
fi

while IFS= read -r line; do
    field="${line#    }"; field="${field%%:*}"
    field="$(printf '%s' "$field" | tr '[:lower:]' '[:upper:]')"
    alias="$(printf '%s\n' "$line" | sed -nE 's/.*_names\("([A-Z0-9_]+)"\).*/\1/p')"
    if [ -n "$alias" ]; then
        pattern="^(# ?)?(CAPTUA|DTK)_${alias}="
        name="CAPTUA_${alias} / DTK_${alias}"
    else
        pattern="^(# ?)?${field}="
        name="$field"
    fi
    if grep -qE "$pattern" "$EXAMPLE"; then
        PASS=$((PASS + 1)); echo "  ok    $name"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL  $name is read by config.py but not in .env.example"
    fi
done <<< "$fields"

# Every field found must have been checked: a loop that did not run would
# otherwise report success with nothing checked.
expected="$(printf '%s\n' "$fields" | wc -l | tr -d ' ')"
if [ $((PASS + FAIL)) -ne "$expected" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL  checked $((PASS + FAIL - 1)) of $expected settings fields"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
