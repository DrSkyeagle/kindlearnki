#!/usr/bin/env bash
# Launch the Desktop KOReader emulator used to try the plugin on the computer.
#
#   wsl -d KO-test -e bash /mnt/d/ankindle/tools/run_emulator.sh
#
# Why Wayland and not X11: WSLg's virtual X root can be much larger than the
# physical monitor (2560x2680 on a 1920x1080 display here), and an X11 window
# can end up outside the visible area -- the process runs, the taskbar shows it,
# and nothing is on screen.  As a native Wayland client the compositor places
# the window itself, which is always visible.
#
# The window is 0.66x the Voyage panel (708x956 at 198 dpi) so it fits a laptop
# screen while keeping the plugin's layout units identical to the device.
set -euo pipefail

KO="${KO:-/root/koanki-test/squashfs-root/usr/lib/koreader}"

if [ ! -d "$KO" ]; then
    echo "KOReader tree not found: $KO" >&2
    exit 1
fi

# Make sure the plugin under development is the one that loads.
if [ -n "${PLUGIN_DIR:-}" ] && [ -d "$PLUGIN_DIR" ]; then
    rm -rf "$KO/plugins/kindlearnki.koplugin"
    cp -r "$PLUGIN_DIR" "$KO/plugins/"
fi

cd "$KO"
exec env \
    KO_HOME="$KO" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}" \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    SDL_VIDEODRIVER=wayland \
    LIBGL_ALWAYS_SOFTWARE=1 \
    GALLIUM_DRIVER=llvmpipe \
    EMULATE_READER_W="${EMULATE_READER_W:-708}" \
    EMULATE_READER_H="${EMULATE_READER_H:-956}" \
    EMULATE_READER_DPI="${EMULATE_READER_DPI:-198}" \
    ./luajit reader.lua
