#!/usr/bin/env bash
# End-to-end sync on the emulated Kindle against the mock AnkiWeb.
#
# Runs the real plugin (arm firmware, real KOReader) on a socket to
# harness/mock_ankiweb.py, so the whole path -- settings, hkey handling, zstd,
# applyChanges, adoption, replay, push -- is exercised on the target platform
# without credentials.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

FIXTURE=${FIXTURE:-/tmp/guest-coll.anki2}
MOCK_LOG=${MOCK_LOG:-/tmp/guest-mock.jsonl}
PORT=${PORT:-9123}
MODE=${MODE:-structural}

log "stopping KOReader in the guest"
guest_ssh 'pkill -f "[r]eader.lua" >/dev/null 2>&1; sleep 2; true' || true

log "installing the prepared collection and test settings"
cat "$FIXTURE" | guest_ssh "cat > $GUEST_COLLECTION.tmp && mv -f $GUEST_COLLECTION.tmp $GUEST_COLLECTION"
settings_file=$(mktemp)
cat >"$settings_file" <<LUA
return {
    endpoint = "http://127.0.0.1:$PORT/",
    hkey = "e2e-guest-key",
}
LUA
guest_ssh "mkdir -p $GUEST_KO/settings"
cat "$settings_file" | guest_ssh "cat > $GUEST_KO/settings/kindleanki.lua"
rm -f "$settings_file"
guest_ssh_q "grep -c '127.0.0.1:$PORT' $GUEST_KO/settings/kindleanki.lua" || true

log "starting the mock server ($MODE) on :$PORT"
rm -f "$MOCK_LOG"
python3 "$(dirname "$here")/mock_ankiweb.py" --port "$PORT" --fixture "$FIXTURE" \
    --mode "$MODE" --log "$MOCK_LOG" >/tmp/guest-mock.out 2>&1 &
mock_pid=$!
for _ in $(seq 1 40); do
    grep -q "mock ankiweb on" /tmp/guest-mock.out 2>/dev/null && break
    sleep 0.2
done
if ! kill -0 "$mock_pid" 2>/dev/null; then
    # A stale server on the port would silently answer the guest while we log
    # nothing, which is how an earlier run "passed" with an empty request log.
    log "mock server did not start:"; cat /tmp/guest-mock.out || true; exit 1
fi

log "publishing the mock on the guest loopback (ssh -R)"
ssh -N -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no     -i "$SSH_KEY" -p "$GUEST_SSH_PORT"     -R "$PORT:127.0.0.1:$PORT" "root@127.0.0.1" >/tmp/guest-mock-tunnel.log 2>&1 &
tunnel_pid=$!
sleep 2
if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    log "reverse tunnel failed:"; cat /tmp/guest-mock-tunnel.log || true
fi

log "starting KOReader"
start_koreader
# Wait for the http inspector, not for a log line: the log carries lines from
# the previous run and matches immediately, which made the sync fire before
# KOReader was listening.
for _ in $(seq 1 90); do
    if guest_ssh_q "curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/koreader/ | grep -q 200" 2>/dev/null; then
        break
    fi
    sleep 2
done
guest_ssh_q "grep 'kindleanki: koreader=' $GUEST_KO_LOG | tail -1" || true

log "triggering a sync"
guest_ssh "curl -sS -m 60 'http://127.0.0.1:8080/koreader/event/KindleAnkiSync'" || true
for _ in $(seq 1 60); do
    [ -s "$MOCK_LOG" ] && break
    sleep 2
done
sleep 5

log "mock requests:"
grep -o '"path": "[a-zA-Z.]*"' "$MOCK_LOG" | sort | uniq -c || true

log "plugin log:"
guest_ssh "grep 'kindleanki' $GUEST_KO_LOG | tail -20" || true

kill "$tunnel_pid" 2>/dev/null
kill "$mock_pid" 2>/dev/null
wait "$mock_pid" 2>/dev/null

log "restoring: removing test settings and restarting KOReader"
guest_ssh "rm -f $GUEST_KO/settings/kindleanki.lua; pkill -f '[r]eader.lua' >/dev/null 2>&1; sleep 2; true" || true
