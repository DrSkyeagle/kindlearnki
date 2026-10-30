#!/usr/bin/env bash
# Stop the emulator cleanly (QMP quit) and clear the sockets it leaves behind.
#
#   emu_down.sh            # quit QEMU, keep machines/kv/disk.qcow2 (state persists)
#   emu_down.sh --reset    # also discard guest changes (eink reset kv, one-off ~slow)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

if qemu_running; then
    log "asking QEMU to quit (pid $(qemu_pid))"
    python3 "$QMP_PY" --machine "$MACHINE" quit >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        qemu_running || break
        sleep 1
    done
    if qemu_running; then
        log "QMP quit did not stop it; killing pid $(qemu_pid)"
        kill "$(qemu_pid)" 2>/dev/null || true
    fi
else
    log "QEMU was not running"
fi
rm -f "$QMP_SOCK" "$SERIAL_SOCK"

if [ "${1:-}" = "--reset" ]; then
    log "discarding guest changes (eink reset $MACHINE)"
    ( cd "$EMU_ROOT" && ./eink reset "$MACHINE" )
fi

log "down; machine state kept in $MACHINE_DIR"
