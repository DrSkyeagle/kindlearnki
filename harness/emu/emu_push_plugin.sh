#!/usr/bin/env bash
# Push the working plugin + the test collection into the emulated Kindle and
# restart KOReader, waiting until the plugin's capability line appears in the log.
#
#   harness/emu/emu_push_plugin.sh               # push, fixture only if missing
#   harness/emu/emu_push_plugin.sh --force-fixture
#   harness/emu/emu_push_plugin.sh --no-restart  # copy files, leave KOReader alone
#
# This is the script to run after editing kindlearnki.koplugin/**.  It is
# idempotent: it stops lab126_gui, replaces the plugin tree, reuses the existing
# collection unless it changed, merges the httpinspector autostart flag into
# settings.reader.lua, restarts KOReader only if asked, and verifies the log.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

restart=1
copy_fixture=auto
for arg in "$@"; do
    case "$arg" in
        --no-restart) restart=0 ;;
        --force-fixture) copy_fixture=force ;;
        --no-fixture) copy_fixture=skip ;;
        *) die "unknown argument: $arg" ;;
    esac
done

[ -d "$PLUGIN_SRC" ] || die "plugin source not found: $PLUGIN_SRC"
[ -n "$(qemu_pid)" ] || die "QEMU for machine '$MACHINE' is not running (run emu_up.sh first)"
wait_ssh 120 || die "guest SSH is not answering on 127.0.0.1:$GUEST_SSH_PORT"

# The stock framework must be gone before KOReader gets the RAM (and before the
# launcher would touch /proc/keypad).
stop_framework

# --- 1. plugin tree -------------------------------------------------------
log "pushing plugin: $PLUGIN_SRC -> $GUEST_PLUGIN"
tar -cf - -C "$(dirname "$PLUGIN_SRC")" "$(basename "$PLUGIN_SRC")" \
    | guest_ssh "mkdir -p $GUEST_KO/plugins && tar -C $GUEST_KO/plugins -xf -"

# --- 2. test collection ---------------------------------------------------
if [ "$copy_fixture" = auto ] || [ "$copy_fixture" = force ]; then
    [ -s "$FIXTURE" ] || die "fixture not found: $FIXTURE"
    local_bytes=$(stat -c %s "$FIXTURE")
    guest_bytes=$(guest_ssh_q "stat -c %s $GUEST_COLLECTION 2>/dev/null" || true)
    if [ "$copy_fixture" = force ] || [ "$guest_bytes" != "$local_bytes" ]; then
        log "pushing collection ($local_bytes bytes) -> $GUEST_COLLECTION"
        guest_ssh "mkdir -p $GUEST_KO/kindlearnki"
        cat "$FIXTURE" | guest_ssh "cat > $GUEST_COLLECTION.tmp && mv -f $GUEST_COLLECTION.tmp $GUEST_COLLECTION"
    else
        log "collection already up to date ($guest_bytes bytes), skipping"
    fi
elif [ "$copy_fixture" = skip ]; then
    log "collection copy skipped by request"
fi

# --- 3. httpinspector autostart ------------------------------------------
# The Lead's debug hook is called over HTTP (port 8080) from inside the guest,
# so the inspector must be listening without a touch/menu tap.
if guest_ssh_q "grep -q '\"httpinspector\"' $GUEST_READER_SETTINGS 2>/dev/null"; then
    log "httpinspector autostart already configured"
else
    log "merging httpinspector autostart into $GUEST_READER_SETTINGS"
    tmp_local=/tmp/emu-settings-$MACHINE-$$.lua
    guest_ssh_q "cat $GUEST_READER_SETTINGS 2>/dev/null" >"$tmp_local" || true
    python3 - "$tmp_local" <<'PY'
import re, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
table = ('    ["httpinspector"] = {\n'
         '        ["autostart"] = true,\n'
         '        ["port"] = 8080,\n'
         '    },\n')
if not text.strip():
    text = "-- added by harness/emu: HTTP inspector for automated navigation\nreturn {\n" + table + "}\n"
elif '["httpinspector"]' not in text:
    # LuaSettings files end with the closing brace of the returned table.
    idx = text.rstrip().rfind("}")
    if idx < 0:
        raise SystemExit("cannot find closing brace in settings.reader.lua")
    text = text[:idx] + table + text[idx:]
open(path, "w", encoding="utf-8").write(text)
PY
    guest_ssh "mkdir -p $GUEST_SETTINGS && cat > $GUEST_READER_SETTINGS.tmp" <"$tmp_local"
    guest_ssh "mv -f $GUEST_READER_SETTINGS.tmp $GUEST_READER_SETTINGS"
    rm -f "$tmp_local"
fi

# --- 4. optional restart + verification -----------------------------------
if [ "$restart" = 0 ]; then
    log "--no-restart: plugin pushed, KOReader left as is"
    exit 0
fi

log "restarting KOReader"
fix_startup_script
stop_koreader
guest_ssh "rm -f $GUEST_KO_LOG"
start_koreader
log "waiting for plugin log line (up to 240 s; TCG boot is slow)"
if line=$(wait_plugin_log 240); then
    log "plugin loaded: $line"
    case "$line" in
        *model=KindleVoyage*) ;;
        *) log "WARNING: plugin loaded but device model is not KindleVoyage" ;;
    esac
else
    rc=$?
    log "ERROR: plugin did not log its capability line (rc=$rc)"
    guest_ssh_q "echo '--- /tmp/ko2.log (tail) ---'; tail -40 $GUEST_KO_LOG 2>/dev/null
        echo '--- crash.log (tail) ---'; tail -40 $GUEST_KO/crash.log 2>/dev/null" || true
    exit 1
fi

log "KOReader pid: $(koreader_pid)"
if wait_inspector 90; then
    log "httpinspector ready on guest 127.0.0.1:8080"
else
    log "WARNING: httpinspector (port 8080) did not answer within 90 s; programmatic navigation will not work"
fi
log "done; capture a screenshot with: emu_shot.sh <name>"
