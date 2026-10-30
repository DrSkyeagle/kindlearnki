#!/bin/sh
# Guest-side diagnostics for a stalled reader.lua (kept in harness/emu, runs in guest).
for p in $(pidof luajit); do
    echo "=== pid $p ==="
    grep -E '^(State|Name|Threads)' /proc/$p/status
    echo -n "wchan: "; cat /proc/$p/wchan 2>/dev/null; echo
    echo "--- fd ---"; ls -l /proc/$p/fd 2>/dev/null
    echo "--- task wchan ---"; cat /proc/$p/task/*/wchan 2>/dev/null; echo
    echo "--- stack ---"; cat /proc/$p/stack 2>/dev/null
done
echo "=== log size/mtime ==="
ls -l /tmp/ko2.log /mnt/us/koreader/settings.reader.lua /mnt/us/koreader/crash.log 2>/dev/null
echo "=== last log ==="
tail -5 /tmp/ko2.log
echo "=== dmesg tail ==="
dmesg | tail -10
