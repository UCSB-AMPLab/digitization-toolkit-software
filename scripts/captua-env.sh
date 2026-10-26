#!/bin/bash
# Shared by the scripts that read settings from the environment. Sourced, never run.
#
# Settings are named CAPTUA_<X>. The DTK_<X> names stay accepted because a
# rollback restores code that knows only those, and a unit's .env and systemd
# drop-ins keep them. The backend applies the same rule to its own settings,
# so a name works the same way in a script and in the backend.
#
# captua_env <X> [default]
#   Prints the value of CAPTUA_<X>, else DTK_<X>, else the default. An empty
#   variable counts as unset, as in ${VAR:-default}. When both are set to
#   different values CAPTUA_<X> wins and one warning names both variables on
#   stderr. The warning never carries a value: some settings are secrets.
#
# rollback-update.sh carries its own copy of this function, because its kept
# copy under /var/lib/dtk runs with no scripts/ directory beside it.
#
# Version: 0.1.0-beta
captua_env() {
    local suffix="$1" default="${2:-}"
    local new="CAPTUA_$suffix" old="DTK_$suffix"
    local new_value="${!new:-}" old_value="${!old:-}"

    if [ -n "$new_value" ] && [ -n "$old_value" ] && [ "$new_value" != "$old_value" ]; then
        echo "⚠ Both $new and $old are set to different values; using $new." >&2
    fi
    if [ -n "$new_value" ]; then
        printf '%s' "$new_value"
    elif [ -n "$old_value" ]; then
        printf '%s' "$old_value"
    else
        printf '%s' "$default"
    fi
}
