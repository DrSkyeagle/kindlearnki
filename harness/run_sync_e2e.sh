#!/usr/bin/env bash
# End-to-end sync test: start the mock AnkiWeb, run the plugin's real client
# against it over a socket, in both protocol modes.
#
#   wsl -d KO-test -e bash /mnt/d/ankindle/harness/run_sync_e2e.sh
set -uo pipefail

KO=${KO:-/root/koanki-test/squashfs-root/usr/lib/koreader}
COLLECTION=${COLLECTION:-/mnt/c/deepseekharness/koanki/bench/work/live/collection.anki2}
PLUGIN_DIR=${PLUGIN_DIR:-/mnt/d/ankindle/kindlearnki.koplugin}
PORT=${PORT:-9123}

fail=0
for mode in normal structural chunkfail; do
    log="/tmp/mock-sync-${mode}.jsonl"
    rm -f "$log"
    python3 /mnt/d/ankindle/harness/mock_ankiweb.py \
        --port "$PORT" --fixture "$COLLECTION" --mode "$mode" --log "$log" \
        >/tmp/mock-sync-${mode}.out 2>&1 &
    server=$!
    for _ in $(seq 1 50); do
        if grep -q "mock ankiweb on" /tmp/mock-sync-${mode}.out 2>/dev/null; then
            break
        fi
        sleep 0.2
    done

    echo "=== mode=$mode"
    (
        cd "$KO"
        COLLECTION="$COLLECTION" MOCK_PORT="$PORT" MOCK_LOG="$log" MOCK_MODE="$mode" \
            PLUGIN_DIR="$PLUGIN_DIR" ./luajit /mnt/d/ankindle/harness/sync_e2e.lua
    )
    status=$?
    kill "$server" 2>/dev/null
    wait "$server" 2>/dev/null
    if [ "$status" -ne 0 ]; then
        fail=1
        echo "MODE-FAILED $mode (log: $log)"
        tail -20 /tmp/mock-sync-${mode}.out
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "SYNC-E2E-PASS"
else
    echo "SYNC-E2E-FAIL"
fi
exit "$fail"
