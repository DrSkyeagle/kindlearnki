#!/usr/bin/env bash
# Programmatic navigation of the Kindlearnki UI inside the emulated Kindle.
#
# Touch injection does not work in this QEMU machine (no Cypress TrueTouch
# events reach the guest), so navigation goes through KOReader's own
# httpinspector plugin (port 8080 inside the guest).  Two routes exist:
#
#   * high level -- the Lead's optional debug hook:
#       /koreader/globals/KindlearnkiDebug/open_study/<n>
#   * generic  -- KOReader's window stack, no plugin changes needed:
#       /koreader/UIManager/_window_stack/<i>/widget/<method>/<arg>
#
# This script uses the debug hook when it is present and falls back to the
# window stack otherwise, so it keeps working before and after the hook lands.
#
# Usage (inside WSL / via emu.cmd):
#   emu_nav.sh top              list widgets on the UIManager window stack
#   emu_nav.sh decklist         open the deck list screen (KindlearnkiStudy event)
#   emu_nav.sh study [ROW]      open the study screen for deck row ROW (default 1)
#   emu_nav.sh card [ROW]       decklist + study (alias for study)
#   emu_nav.sh answer           tap 显示答案 on the study screen
#   emu_nav.sh rate N           rate the current card 1..4 (重来/困难/记住/太简单)
#   emu_nav.sh sync             press the deck screen's 同步 button
#   emu_nav.sh close            close the top Kindlearnki screen
#   emu_nav.sh hook N           call _G.KindlearnkiDebug.open_study(N) if present
#   emu_nav.sh state            print what is currently on screen
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

INSPECTOR=http://127.0.0.1:8080

insp() {
    # insp '/koreader/...' -> body as text (trims the trailing newline)
    guest_ssh "curl -sS -m 10 '$INSPECTOR$1'" 2>/dev/null | tr -d '\r' | sed -e '$a\' | head -c 200000
}

insp_q() { insp "$@" >/dev/null 2>&1 || true; }

require_inspector() {
    [ -n "$(qemu_pid)" ] || die "QEMU is not running (run emu_up.sh)"
    if wait_inspector 90; then
        return 0
    fi
    die "httpinspector is not answering on guest port 8080; restart KOReader (emu_push_plugin.sh)"
}

stack_count() {
    local n
    n=$(guest_ssh_q "curl -sS -m 10 '$INSPECTOR/koreader/UIManager/_window_stack/' 2>/dev/null | grep -o '_window_stack/[0-9][0-9]*' | sort -u | wc -l")
    echo "${n:-0}"
}

widget_name() {
    insp "/koreader/UIManager/_window_stack/$1/widget/name" 2>/dev/null | head -1
}

find_widget() {
    # find_widget <name> -> prints stack index, fails if absent
    local target=$1 n i name
    n=$(stack_count)
    for ((i = 1; i <= n; i++)); do
        name=$(widget_name "$i" || true)
        if [ "$name" = "$target" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

wait_widget() {
    # wait_widget <name> [timeout-seconds] -> prints index
    local target=$1 timeout=${2:-90} start idx now
    start=$(date +%s)
    while :; do
        if idx=$(find_widget "$target"); then
            echo "$idx"
            return 0
        fi
        now=$(date +%s)
        (( now - start >= timeout )) && return 1
        sleep 2
    done
}

render_count() {
    guest_ssh_q "grep -ac 'kindlearnki: card render' /tmp/ko2.log 2>/dev/null" || echo 0
}

wait_render_after() {
    # wait_render_after <previous-count> [timeout] -- wait for one more card render
    local before=${1:-0} timeout=${2:-60} start now
    start=$(date +%s)
    while :; do
        now=$(date +%s)
        if [ "$(render_count)" -gt "$before" ] 2>/dev/null; then
            return 0
        fi
        (( now - start >= timeout )) && return 1
        sleep 1
    done
}

hook_present() {
    local body
    body=$(insp "/koreader/globals/KindlearnkiDebug" || true)
    case "$body" in
        *"No such table/object key"*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}

cmd_top() {
    local n i
    n=$(stack_count)
    echo "window stack ($n entries, bottom -> top):"
    for ((i = 1; i <= n; i++)); do
        printf '  [%d] %s\n' "$i" "$(widget_name "$i")"
    done
}

cmd_state() {
    local deck study
    deck=$(find_widget kindlearnki_deckview || true)
    study=$(find_widget kindlearnki_studyview || true)
    printf 'deckview: %s\nstudyview: %s\nhook: %s\n' \
        "${deck:-absent}" "${study:-absent}" "$(hook_present && echo present || echo absent)"
}

cmd_decklist() {
    require_inspector
    if find_widget kindlearnki_deckview >/dev/null; then
        log "deck list already open"
        return 0
    fi
    log "sending KindlearnkiStudy event"
    insp_q "/koreader/event/KindlearnkiStudy"
    if ! wait_widget kindlearnki_deckview 90 >/dev/null; then
        guest_ssh_q "tail -20 /tmp/ko2.log" >&2 || true
        die "deck list did not appear"
    fi
    log "deck list open"
}

cmd_study() {
    local row=${1:-1} idx deck_id
    require_inspector
    cmd_decklist || return 1

    # The Lead's debug hook takes a deck index; prefer it when it exists.
    if hook_present; then
        log "using _G.KindlearnkiDebug.open_study($row)"
        insp_q "/koreader/globals/KindlearnkiDebug/open_study/$row"
        if wait_widget kindlearnki_studyview 60 >/dev/null; then
            log "study screen open (debug hook)"
            return 0
        fi
        log "debug hook did not open the screen; falling back to the window stack"
    fi

    idx=$(find_widget kindlearnki_deckview) || die "deck view vanished"
    deck_id=$(insp "/koreader/UIManager/_window_stack/$idx/widget/layout/rows/$row/deck_id")
    case "$deck_id" in
        '' | *[!0-9]*)
            die "could not read deck id for row $row (got: $deck_id)" ;;
    esac
    log "opening deck row $row (deck_id=$deck_id)"
    insp_q "/koreader/UIManager/_window_stack/$idx/widget/on_open/$deck_id"
    if ! wait_widget kindlearnki_studyview 60 >/dev/null; then
        guest_ssh_q "tail -20 /tmp/ko2.log" >&2 || true
        die "study screen did not appear"
    fi
    log "study screen open"
}

cmd_answer() {
    local idx before
    require_inspector
    idx=$(find_widget kindlearnki_studyview) || die "study screen is not open"
    before=$(render_count)
    insp_q "/koreader/UIManager/_window_stack/$idx/widget/_show_answer/"
    if wait_render_after "$before" 60; then
        log "answer shown"
    else
        log "warning: answer repaint not observed within 60 s"
    fi
}

cmd_rate() {
    local rating=${1:?rating 1..4 required} idx before
    case "$rating" in 1|2|3|4) ;; *) die "rating must be 1..4" ;; esac
    require_inspector
    idx=$(find_widget kindlearnki_studyview) || die "study screen is not open"
    before=$(render_count)
    insp_q "/koreader/UIManager/_window_stack/$idx/widget/_rate/$rating"
    if wait_render_after "$before" 60; then
        log "rated $rating; next card rendered"
    else
        log "rated $rating (no new card render observed; session may have ended)"
    fi
}

cmd_sync() {
    # The deck screen's 同步 button runs whatever controller passed as
    # `on_sync`; calling the field directly is the closest we get to a tap in
    # this machine (touch injection does not reach the guest).
    local idx
    require_inspector
    idx=$(find_widget kindlearnki_deckview) || die "deck list is not open"
    insp_q "/koreader/UIManager/_window_stack/$idx/widget/on_sync/"
    log "pressed 同步 on the deck screen"
}

cmd_close() {
    local idx
    require_inspector
    if idx=$(find_widget kindlearnki_studyview); then
        insp_q "/koreader/UIManager/_window_stack/$idx/widget/close/"
        log "closed study screen"
    elif idx=$(find_widget kindlearnki_deckview); then
        insp_q "/koreader/UIManager/_window_stack/$idx/widget/close/"
        log "closed deck list"
    else
        log "no Kindlearnki screen is open"
    fi
}

cmd_hook() {
    local n=${1:?deck index required}
    require_inspector
    if ! hook_present; then
        guest_ssh_q "curl -sS -m 5 '$INSPECTOR/koreader/globals/KindlearnkiDebug'" >&2 || true
        die "_G.KindlearnkiDebug is not defined in this plugin build yet"
    fi
    insp_q "/koreader/globals/KindlearnkiDebug/open_study/$n"
    log "called _G.KindlearnkiDebug.open_study($n)"
}

case "${1:-}" in
    top) cmd_top ;;
    state) cmd_state ;;
    decklist) cmd_decklist ;;
    study | card) shift; cmd_study "${1:-1}" ;;
    answer) cmd_answer ;;
    rate) shift; cmd_rate "${1:-}" ;;
    sync) cmd_sync ;;
    close) cmd_close ;;
    hook) shift; cmd_hook "${1:-}" ;;
    *)
        sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
