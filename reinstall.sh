#!/bin/sh
# Build flat and flat-wm and install them to $PREFIX (default ~/.local).
#
# Running processes are left alone: zig writes each file next to the old one
# and renames it over, so the running compositor and window manager keep the
# old binary until the next login.
#
# usage: ./reinstall.sh [--if-changed] [--hook]
#   --if-changed  do nothing if no source file changed since the last install
#   --hook        report as a Claude Code Stop hook (JSON on stdout)

set -u

root=$(cd "$(dirname "$0")" && pwd)
prefix=${PREFIX:-$HOME/.local}
state=${XDG_STATE_HOME:-$HOME/.local/state}/flat
stamp=$state/reinstall.stamp
log=$state/reinstall.log

if_changed=false
hook=false
for arg in "$@"; do
    case $arg in
        --if-changed) if_changed=true ;;
        --hook) hook=true ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$state"

# a hook may fire again before the last build finished
exec 9>"$state/reinstall.lock"
if ! flock -n 9; then
    $hook || echo "another reinstall is running" >&2
    exit 0
fi

# hash of every tracked or new, not ignored file of both programs
sources_hash() {
    cd "$root" &&
        git ls-files -z -co --exclude-standard -- compositor wm |
        xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
}

hash=$(sources_hash)
if $if_changed && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$hash" ]; then
    exit 0
fi

# escape for a JSON string
json() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN { ORS = "\\n" } { print }' | sed 's/\\n$//'
}

report_failure() {
    msg="reinstall failed in $1, see $log"
    if $hook; then
        tail_log=$(tail -n 30 "$log")
        # let Claude see the error once, do not block again while it is handling it
        if printf '%s' "$hook_input" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
            printf '{"systemMessage":"%s"}\n' "$(json "$msg")"
        else
            printf '{"decision":"block","reason":"%s"}\n' "$(json "$msg
$tail_log")"
        fi
    else
        tail -n 30 "$log" >&2
        echo "$msg" >&2
    fi
    exit 1
}

hook_input=
$hook && hook_input=$(cat)

: >"$log"
build() {
    echo "== $1" >>"$log"
    (cd "$root/$1" && shift && zig build -Doptimize=ReleaseSafe --prefix "$prefix" "$@" install) >>"$log" 2>&1
}

build compositor -Dxwayland=true || report_failure compositor
build wm || report_failure wm

echo "$hash" >"$stamp"

msg="flat and flat-wm installed to $prefix, active after the next login"
if $hook; then
    printf '{"systemMessage":"%s"}\n' "$(json "$msg")"
else
    echo "$msg"
fi
