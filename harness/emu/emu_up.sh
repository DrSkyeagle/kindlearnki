#!/usr/bin/env bash
# Bring the Kindle Voyage emulator from "nothing" to "our plugin is loaded".
#
#   harness/emu/emu_up.sh            # cold start or reuse a running machine
#   harness/emu/emu_up.sh --no-push  # only boot + framework off + KOReader check
#
# Idempotent: a running QEMU is reused, a dead one is reported with the real
# reason from machines/<name>/<name>.serial.log instead of being retried blindly.
# Ends by delegating to emu_push_plugin.sh, which installs the working plugin +
# fixture collection, restarts KOReader and verifies the `model=KindleVoyage`
# capability line in /tmp/ko2.log.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

push_args=()
for arg in "$@"; do
    case "$arg" in
        --no-push) push_args+=(--no-restart) ;;  # boot only; still copies files
        --force-fixture) push_args+=(--force-fixture) ;;
        *) push_args+=("$arg") ;;
    esac
done

# --- 0. machine exists? ----------------------------------------------------
if [ ! -d "$MACHINE_DIR" ]; then
    log "machine '$MACHINE' does not exist; creating it (~3 min, needs network)"
    ( cd "$EMU_ROOT" && ./eink create "$MACHINE" --model "$MODEL" --firmware "$FIRMWARE" --mrpi )
fi

# --- 1. QEMU --------------------------------------------------------------
qemu_started_at=0
if qemu_running; then
    log "QEMU already running (pid $(qemu_pid)); reusing it"
else
    # Sockets from a killed QEMU block `eink run`; no process owns them here.
    if [ -S "$QMP_SOCK" ] || [ -S "$SERIAL_SOCK" ]; then
        log "removing stale QEMU sockets from a previous boot"
    fi
    rm -f "$QMP_SOCK" "$SERIAL_SOCK"
    log "starting QEMU (headless, QMP+serial sockets, -watchdog-action none)"
    ( cd "$EMU_ROOT" && setsid nohup ./eink run "$MACHINE" \
        --headless --qmp-socket --serial-socket -- -watchdog-action none \
        >"$RUN_LOG" 2>&1 </dev/null & )
    qemu_started_at=$(date +%s)
    for _ in $(seq 1 30); do
        qemu_running && break
        sleep 1
    done
    if ! qemu_running; then
        tail -20 "$RUN_LOG" >&2 2>/dev/null || true
        tail -40 "$SERIAL_LOG" >&2 2>/dev/null || true
        die "QEMU did not start; see $RUN_LOG and $SERIAL_LOG"
    fi
    log "QEMU pid $(qemu_pid)"
fi

# --- 2. wait for the guest -------------------------------------------------
log "waiting for guest SSH on 127.0.0.1:$GUEST_SSH_PORT (cold boot ~60-120 s)"
ssh_start=$(date +%s)
set +e
wait_ssh 300
ssh_rc=$?
set -e
if [ "$ssh_rc" -eq 2 ]; then
    tail -60 "$SERIAL_LOG" >&2 2>/dev/null || true
    die "QEMU died while booting; serial log above. Do not just retry: read the reason."
elif [ "$ssh_rc" -ne 0 ]; then
    tail -60 "$SERIAL_LOG" >&2 2>/dev/null || true
    die "guest SSH did not come up within 300 s; serial log above"
fi
if [ "$qemu_started_at" -ne 0 ]; then
    log "guest SSH ready $(( $(date +%s) - qemu_started_at )) s after QEMU start"
else
    log "guest SSH ready ($(( $(date +%s) - ssh_start )) s)"
fi
log "guest uptime: $(guest_ssh_q 'cut -d" " -f1 /proc/uptime') s"

# --- 3. guest prerequisites ------------------------------------------------
# Stock framework off: frees ~130 MB of the 512 MB and keeps the launcher from
# blocking on /proc/keypad.
stop_framework
# /var/tmp is tmpfs; reader.lua blocks on a modal otherwise (see env.sh).
fix_startup_script

# --- 4. KOReader tree ------------------------------------------------------
if ! guest_ssh_q "test -f $GUEST_KO/reader.lua"; then
    log "KOReader tree missing in guest; installing it (one-off, ~3.5 min)"
    if [ -d "$KO_TREE" ]; then
        tar -cf - -C "$(dirname "$KO_TREE")" "$(basename "$KO_TREE")" \
            | guest_ssh "mkdir -p /mnt/us && tar -C /mnt/us -xf -"
    elif [ -s "$KO_ZIP" ]; then
        tmp=$(mktemp -d)
        unzip -q "$KO_ZIP" -d "$tmp"
        tar -cf - -C "$tmp" koreader | guest_ssh "tar -C /mnt/us -xf -"
        rm -rf "$tmp"
    else
        die "no KOReader tree ($KO_TREE) and no zip ($KO_ZIP) to install from"
    fi
    log "KOReader tree installed"
fi

# --- 5. plugin + fixture + KOReader restart --------------------------------
"$here/emu_push_plugin.sh" "${push_args[@]}"

log "up: QEMU pid $(qemu_pid), KOReader pid $(koreader_pid)"
log "screenshot: emu_shot.sh <name>   |   navigate: emu_nav.sh decklist|study|answer|rate N"
