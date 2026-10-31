#!/usr/bin/env bash
# Shared settings for the Kindle Voyage eink-emulator harness.
#
# Everything in harness/emu/ is meant to be executed *inside* WSL distro
# `KO-test` (the QMP socket and the emulator build live there).  From Windows
# run the wrappers: emu.cmd up|push|shot|status|...
#
# Shellcheck disable=SC2034

EMU_ROOT=${EMU_ROOT:-/root/kvemu/eink-emulator}
MACHINE=${MACHINE:-kv}
MODEL=${MODEL:-kindle-voyage}
FIRMWARE=${FIRMWARE:-5.13.6}

# Windows D:\ankindle == /mnt/d/ankindle inside WSL.
HOST_REPO=${HOST_REPO:-/mnt/d/ankindle}
PLUGIN_SRC=${PLUGIN_SRC:-$HOST_REPO/kindlearnki.koplugin}
OUT_DIR=${OUT_DIR:-$HOST_REPO/out/emu}
FIXTURE=${FIXTURE:-/mnt/c/deepseekharness/koanki/bench/work/live/collection.anki2}

GUEST_SSH_PORT=${GUEST_SSH_PORT:-2222}
SSH_KEY=$EMU_ROOT/build/ssh/id_ed25519
SSH_OPTS=(-i "$SSH_KEY" -p "$GUEST_SSH_PORT"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8 -o ServerAliveInterval=15 -o LogLevel=ERROR)
GUEST=root@127.0.0.1

MACHINE_DIR=$EMU_ROOT/machines/$MACHINE
QMP_SOCK=$MACHINE_DIR/$MACHINE.qmp.sock
SERIAL_SOCK=$MACHINE_DIR/$MACHINE.serial.sock
QMP_PY=$EMU_ROOT/scripts/eink-qmp.py
SERIAL_LOG=$MACHINE_DIR/$MACHINE.serial.log

mkdir -p "${RUN_LOG_DIR:-/root/kvemu/logs}"
RUN_LOG=${RUN_LOG:-${RUN_LOG_DIR:-/root/kvemu/logs}/run-$MACHINE.log}

# Where KOReader is unpacked on the WSL side, used to (re)install the tree.
KO_TREE=${KO_TREE:-/root/kvemu/ko/koreader}
KO_ZIP=${KO_ZIP:-/root/kvemu/dl/koreader-kindlepw2-v2026.07.1.zip}

# Paths *inside the guest*.
GUEST_KO=/mnt/us/koreader
GUEST_PLUGIN=$GUEST_KO/plugins/kindlearnki.koplugin
GUEST_DATA=$GUEST_KO
GUEST_COLLECTION=$GUEST_KO/kindlearnki/collection.anki2
GUEST_SETTINGS=$GUEST_KO/settings
# reader.lua opens G_reader_settings at DataStorage:getDataDir().."/settings.reader.lua"
# and on Kindle the data dir is "." (cwd = /mnt/us/koreader), so this file is
# next to reader.lua, NOT under settings/ (getSettingsDir() is only used for
# plugin-specific *.lua files such as settings/kindlearnki.lua).
GUEST_READER_SETTINGS=$GUEST_KO/settings.reader.lua
GUEST_PLUGIN_SETTINGS=$GUEST_SETTINGS/kindlearnki.lua
GUEST_KO_LOG=/tmp/ko2.log

log()  { printf '[emu] %s\n' "$*" >&2; }
die()  { printf '[emu][FATAL] %s\n' "$*" >&2; exit 1; }

qemu_pid() {
    # -name kv is on the QEMU command line; matches only this machine.
    pgrep -f "qemu-system-arm.*-name $MACHINE( |$)" 2>/dev/null | head -1
}

qemu_running() { [ -n "$(qemu_pid)" ]; }

guest_ssh() {
    # guest_ssh 'shell command'  -- stdin is forwarded, so tar/rsync style pipes work.
    ssh "${SSH_OPTS[@]}" "$GUEST" "$@"
}

guest_ssh_q() { guest_ssh "$@" 2>/dev/null; }

wait_ssh() {
    local timeout=${1:-360} start now
    start=$(date +%s)
    while :; do
        if guest_ssh_q 'true'; then
            return 0
        fi
        if ! qemu_running; then
            return 2
        fi
        now=$(date +%s)
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 3
    done
}

# Print the wall-clock seconds a fresh QEMU needs until SSH answers.
boot_seconds() {
    local start now
    start=$(date +%s)
    wait_ssh "${1:-360}" || return $?
    now=$(date +%s)
    echo $(( now - start ))
}

# --- KOReader control ------------------------------------------------------
# `[l]uajit` keeps pgrep/pkill -f from matching the ssh wrapper shell that
# carries this very pattern in its own command line.
koreader_pid() {
    guest_ssh_q 'pgrep -f "[l]uajit" | head -1'
}

koreader_running() { [ -n "$(koreader_pid)" ]; }

stop_koreader() {
    guest_ssh 'pkill -f "[l]uajit" >/dev/null 2>&1
        i=0
        while pgrep -f "[l]uajit" >/dev/null 2>&1; do
            i=$((i + 1))
            [ "$i" -ge 10 ] && { pkill -9 -f "[l]uajit" >/dev/null 2>&1; break; }
            sleep 1
        done
        true'
}

start_koreader() {
    # The 2026.07.1 launcher (koreader.sh) writes /proc/keypad and hangs forever
    # in the emulator; reader.lua is started directly instead (manual, pitfall 2).
    guest_ssh "cd $GUEST_KO && KOREADER_DIR=$GUEST_KO setsid nohup ./luajit ./reader.lua >$GUEST_KO_LOG 2>&1 </dev/null & true"
}

stop_framework() {
    # Without this the stock Kindle UI holds ~130 MB of the 512 MB and KOReader
    # is killed/slow; it is also what makes the /proc/keypad write unnecessary.
    # `[c]vm`: a plain `pkill -f cvm` matches the ssh wrapper shell carrying the
    # pattern itself in its command line and kills its own session (ssh rc 255).
    #
    # Stopping it once is not enough: init starts the Java framework around 46 s
    # into the boot (after our first stop), it finishes near 118 s, repaints the
    # Kindle Home over KOReader and takes the 130 MB back.  Keep stopping it
    # until the boot has settled and cvm stays gone.
    local waited=0
    while [ "$waited" -lt 180 ]; do
        local uptime
        uptime=$(guest_ssh_q 'cut -d. -f1 /proc/uptime 2>/dev/null' 2>/dev/null || echo 0)
        if guest_ssh_q 'pgrep -f "[c]vm" >/dev/null 2>&1' 2>/dev/null; then
            guest_ssh 'stop lab126_gui >/dev/null 2>&1
                pkill -f "[c]vm" >/dev/null 2>&1
                true' 2>/dev/null || true
        elif [ "${uptime:-0}" -gt 130 ] 2>/dev/null; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    guest_ssh 'stop lab126_gui >/dev/null 2>&1
        pkill -f "[c]vm" >/dev/null 2>&1
        true'
}

fix_startup_script() {
    # Kindle:isStartupScriptUpToDate() md5-compares /var/tmp/koreader.sh with
    # ./koreader.sh; when they differ reader.lua shows a modal "startup script
    # has been updated / Ignore / Quit" box *before* the UI starts and waits for
    # a tap (which we cannot inject).  /var/tmp is tmpfs, so every fresh boot
    # loses the copy and the box comes back.  Copy it across instead.
    guest_ssh 'test -f /mnt/us/koreader/koreader.sh && cp -f /mnt/us/koreader/koreader.sh /var/tmp/koreader.sh; true'
}

# Wait until the plugin writes its capability line to /tmp/ko2.log.
# Echoes the log line on success.  Returns 1 on timeout, 2 if QEMU died.
wait_plugin_log() {
    local timeout=${1:-240} start line now
    start=$(date +%s)
    while :; do
        line=$(guest_ssh_q "grep -a -m1 'kindlearnki: koreader=' $GUEST_KO_LOG 2>/dev/null" || true)
        if [ -n "$line" ]; then
            printf '%s\n' "$line"
            return 0
        fi
        qemu_running || return 2
        now=$(date +%s)
        if (( now - start >= timeout )); then
            return 1
        fi
        sleep 3
    done
}

plugin_caps_line() {
    guest_ssh_q "grep -a -m1 'kindlearnki: koreader=' $GUEST_KO_LOG 2>/dev/null" || true
}

# httpinspector starts from a UIManager:nextTick after the plugin list is up,
# a few seconds after the plugin line even on a warm boot.
inspector_http_code() {
    guest_ssh_q "curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/koreader/globals/ 2>/dev/null" || true
}

wait_inspector() {
    local timeout=${1:-90} start code
    start=$(date +%s)
    while :; do
        code=$(inspector_http_code)
        if [ "$code" = "200" ]; then
            return 0
        fi
        (( $(date +%s) - start >= timeout )) && return 1
        sleep 2
    done
}

wait_guest_boot_settle() {
    # /mnt/us is a separate partition mounted by the framework; KOReader can
    # start before it exists.  Also wait for the framework itself to be up.
    local i
    for i in $(seq 1 60); do
        if guest_ssh_q 'test -f /mnt/us/system/version.txt && mountpoint -q /mnt/us' ; then
            return 0
        fi
        sleep 2
    done
    # Not fatal: some images do not expose mountpoint; let the caller decide.
    return 1
}
