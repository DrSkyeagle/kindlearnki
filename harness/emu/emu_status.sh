#!/usr/bin/env bash
# Print the state of the emulator in one screen: pids, boot time, KOReader
# plugin line, httpinspector, on-screen Kindlearnki widgets, recent screenshots.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

echo "== machine =="
pid=$(qemu_pid || true)
if [ -n "$pid" ]; then
    echo "qemu:      running pid=$pid"
    echo "qmp:       $(python3 "$QMP_PY" --machine "$MACHINE" status 2>/dev/null | tr -d '\n ') "
    echo "run log:   $RUN_LOG"
    echo "serial:    $SERIAL_LOG"
else
    echo "qemu:      not running"
fi

echo
echo "== guest =="
if [ -n "$pid" ] && guest_ssh_q 'true'; then
    echo "ssh:       root@127.0.0.1:$GUEST_SSH_PORT ok"
    echo "uptime:    $(guest_ssh_q 'cut -d" " -f1 /proc/uptime') s"
    echo "framework: $(guest_ssh_q 'pgrep -c "lab126_gui" 2>/dev/null || echo 0') lab126_gui processes"
    mem=$(guest_ssh_q 'free -m' | awk '/^Mem:/{print $3"/"$2" MB used"}')
    echo "memory:    ${mem:-unknown}"
    ko=$(koreader_pid || true)
    if [ -n "$ko" ]; then
        echo "koreader:  running pid=$ko"
    else
        echo "koreader:  not running"
    fi
    echo "caps line: $(plugin_caps_line || echo '(none yet)')"
    code=$(guest_ssh_q "curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/koreader/globals/" || true)
    echo "inspector: ${code:-down} (guest 127.0.0.1:8080)"
    echo "plugin ts: $(guest_ssh_q "stat -c '%y' $GUEST_PLUGIN/main.lua 2>/dev/null")"
    echo "collection: $(guest_ssh_q "stat -c '%s bytes, mtime %y' $GUEST_COLLECTION 2>/dev/null || echo '(missing)'")"
else
    echo "ssh:       not reachable (QEMU down or still booting)"
fi

echo
echo "== UI =="
if [ -n "$pid" ] && guest_ssh_q 'true'; then
    "$here/emu_nav.sh" state 2>/dev/null || true
else
    echo "unavailable"
fi

echo
echo "== screenshots (newest 8) =="
ls -1t "$OUT_DIR" 2>/dev/null | head -8 | sed 's/^/  /' || echo "  (none yet)"
echo "  dir: D:\\ankindle\\out\\emu"
