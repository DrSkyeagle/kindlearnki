#!/usr/bin/env bash
# Collect the "it really runs" evidence into out/emu/plugin-load.log:
# machine identity, plugin capability line from KOReader's log, httpinspector
# state, and which KindleAnki screens are currently on the window stack.
#
#   emu_evidence.sh
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

out=$OUT_DIR/plugin-load.log
mkdir -p "$OUT_DIR"

{
    echo "generated: $(date -Is) (host Asia/Shanghai)"
    echo "machine:   $MACHINE  model=$MODEL  firmware=$FIRMWARE"
    echo "qemu pid:  $(qemu_pid || echo '(not running)')"
    echo "koreader:  $(koreader_pid || echo '(not running)')"
    echo
    echo "=== guest identity ==="
    guest_ssh 'uname -a; printf "usid: "; cat /proc/usid; echo; printf "firmware: "; head -1 /mnt/us/system/version.txt; printf "uptime: "; cut -d" " -f1 /proc/uptime; echo s'
    echo
    echo "=== plugin log lines (/tmp/ko2.log) ==="
    guest_ssh "grep -a 'kindleanki:' $GUEST_KO_LOG 2>/dev/null || echo '(none)'"
    echo
    echo "=== httpinspector (guest 127.0.0.1:8080) ==="
    guest_ssh "curl -sS -m 5 -o /dev/null -w 'globals endpoint: http %{http_code}\n' http://127.0.0.1:8080/koreader/globals/"
    if hook=$(guest_ssh "curl -sS -m 5 'http://127.0.0.1:8080/koreader/globals/KindleAnkiDebug' 2>/dev/null"); then
        echo "KindleAnkiDebug: $hook"
    else
        echo "KindleAnkiDebug: absent (nav falls back to the window stack)"
    fi
    echo
    echo "=== on-screen KindleAnki widgets ==="
    "$here/emu_nav.sh" state 2>/dev/null || true
    echo
    echo "=== installed plugin ==="
    guest_ssh "ls -l $GUEST_PLUGIN/main.lua; stat -c 'collection: %s bytes, mtime %y' $GUEST_COLLECTION 2>/dev/null || echo 'collection: missing'"
} | tee "$out"

echo "written: D:\\ankindle\\out\\emu\\plugin-load.log"
