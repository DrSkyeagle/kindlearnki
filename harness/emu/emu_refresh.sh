#!/usr/bin/env bash
# One command for "I changed the plugin, give me a screenshot".
#
#   emu_refresh.sh <name>                       # push plugin, restart KOReader, shot home
#   emu_refresh.sh <name> --nav decklist        # ... then open the deck list
#   emu_refresh.sh <name> --nav study --answer  # ... then a study card with the answer
#   emu_refresh.sh <name> --nav "study 2" --nav answer
#
# Robust to every state we have seen: QEMU down or up, KOReader running or
# dead, stale QMP sockets, framework running.  Safe to re-run.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

name=""
nav=()
force_fixture=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --nav)
            nav+=("$2")
            shift 2
            ;;
        --decklist | --study)
            nav+=("${1#--}")
            shift
            ;;
        --answer)
            nav+=("answer")
            shift
            ;;
        --rate)
            nav+=("rate $2")
            shift 2
            ;;
        --keep-progress)
            # Rating cards writes revlog/scheduler state into the guest
            # collection; by default we restore the fixture so repeated runs
            # show the same counts.  This flag keeps what is in the guest.
            force_fixture=0
            shift
            ;;
        --shot-only)
            shot_only=1
            shift
            ;;
        -h | --help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            [ -z "$name" ] || die "unknown argument: $1"
            name=$1
            shift
            ;;
    esac
done
[ -n "$name" ] || die "missing screenshot name (e.g. emu_refresh.sh study-card)"

if [ "${shot_only:-0}" != 1 ]; then
    log "step 1/3: bring the emulator up and push the current plugin"
    up_args=()
    [ "$force_fixture" = 1 ] && up_args+=(--force-fixture)
    "$here/emu_up.sh" "${up_args[@]}"
fi

if [ "${#nav[@]}" -gt 0 ]; then
    log "step 2/3: navigate (${nav[*]})"
    for step in "${nav[@]}"; do
        # shellcheck disable=SC2086
        "$here/emu_nav.sh" $step
        sleep 1
    done
else
    log "step 2/3: no navigation requested"
fi

log "step 3/3: screenshot"
"$here/emu_shot.sh" "$name"
