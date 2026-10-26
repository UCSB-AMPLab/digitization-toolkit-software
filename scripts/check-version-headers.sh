#!/usr/bin/env bash
#
# Checks that every source file carries the release's version header.
#
# The release is the one line of VERSION. Each source file names the release
# it was last changed in, on exactly one header line:
#
#   Python      Version: 0.1.0-beta          (last line of the module docstring,
#                                             or "# Version: …" with none)
#   TS/JS       // Version: 0.1.0-beta
#   Svelte      // Version: 0.1.0-beta       (in the <script> opening comment,
#                                             or <!-- Version: … --> with none)
#   CSS         /* Version: 0.1.0-beta */
#   Shell, ps1  # Version: 0.1.0-beta
#   bat         REM Version: 0.1.0-beta
#
# A release bumps the header of every file it changes, so before a tag every
# file changed since the previous tag must name the new release. With no
# argument this checks every source file against VERSION; with --since <ref>
# it checks only the superproject's files changed since <ref>, and the
# submodules' files changed since the commits <ref> pinned them at.
#
# Source files are the backend's Python (not alembic/versions, whose files
# record past schemas), the frontend's src/ and e2e/ (.ts .js .svelte .css),
# and the superproject's scripts (shell, PowerShell and batch; not the
# systemd units or config files beside them). Run from the superproject.
#
# Exit status: 0 when every file checked names the release, 1 otherwise.
#
# Version: 0.1.0-beta

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RELEASE="$(head -n 1 VERSION | tr -d '[:space:]')"
SINCE=""
if [ "${1:-}" = "--since" ]; then
    SINCE="${2:?--since needs a ref}"
fi

backend_files() {
    if [ -n "$SINCE" ]; then
        git -C backend diff --name-only --diff-filter=d "$(git rev-parse "$SINCE:backend")" HEAD -- '*.py'
    else
        git -C backend ls-files '*.py'
    fi | grep -v '^alembic/versions/' | sed 's|^|backend/|'
}

frontend_files() {
    if [ -n "$SINCE" ]; then
        git -C frontend diff --name-only --diff-filter=d "$(git rev-parse "$SINCE:frontend")" HEAD -- src e2e
    else
        git -C frontend ls-files src e2e
    fi | grep -E '\.(ts|js|svelte|css)$' | sed 's|^|frontend/|'
}

script_files() {
    local f
    if [ -n "$SINCE" ]; then
        git diff --name-only --diff-filter=d "$SINCE" HEAD -- scripts
    else
        git ls-files scripts
    fi | while read -r f; do
        case "$f" in
            *.sh|*.ps1|*.bat) echo "$f" ;;
            *.service|*.conf) ;;
            *) if head -n 1 "$f" | grep -qE '^#!.*\b(ba)?sh\b'; then echo "$f"; fi ;;
        esac
    done
}

missing=0
wrong=0
checked=0
while read -r f; do
    [ -n "$f" ] || continue
    checked=$((checked + 1))
    lines="$(grep -nE '^[[:space:]]*(#|//|/\*|\*|<!--|REM|rem)?[[:space:]]*Version: ' "$f" || true)"
    count="$(printf '%s' "$lines" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
        echo "no header:      $f"
        missing=$((missing + 1))
        continue
    fi
    if [ "$count" -gt 1 ]; then
        echo "two headers:    $f"
        wrong=$((wrong + 1))
        continue
    fi
    value="$(printf '%s' "$lines" | sed -E 's/.*Version: ([0-9A-Za-z.+-]+).*/\1/')"
    if [ "$value" != "$RELEASE" ]; then
        echo "says $value: $f"
        wrong=$((wrong + 1))
    fi
done < <(backend_files; frontend_files; script_files)

echo "$checked files checked against $RELEASE: $missing without a header, $wrong wrong."
[ "$missing" -eq 0 ] && [ "$wrong" -eq 0 ]
