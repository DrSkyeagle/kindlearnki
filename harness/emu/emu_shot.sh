#!/usr/bin/env bash
# Capture the emulated Kindle panel and save it as a PNG under D:\ankindle\out\emu.
#
#   harness/emu/emu_shot.sh <name>          # -> out/emu/<name>.png (+ timestamped)
#
# Run inside WSL (`wsl -d KO-test -- bash ...`) or from Windows via emu.cmd shot.
# Works whether QEMU is paused or running; fails clearly if QEMU is not up.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

name=${1:-shot}
name=${name%.png}
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "screenshot name may only contain A-Za-z0-9._-"

[ -n "$(qemu_pid)" ] || die "QEMU for machine '$MACHINE' is not running (run emu_up.sh first)"

mkdir -p "$OUT_DIR"
stamp=$(date +%Y%m%d-%H%M%S)
ppm=/tmp/emu-shot-$name-$$.ppm
png_latest=$OUT_DIR/$name.png
png_stamped=$OUT_DIR/$name-$stamp.png

log "QMP screendump -> $ppm"
python3 "$QMP_PY" --machine "$MACHINE" screendump "$ppm" >/dev/null

log "converting PPM -> PNG"
python3 "$here/ppm2png.py" "$ppm" "$png_latest" >/dev/null
cp -f "$png_latest" "$png_stamped"
rm -f "$ppm"

# Print the Windows-style path for the caller (the Lead reads this).
win_path="D:\\ankindle\\out\\emu\\$name.png"
echo "$win_path"
echo "also: D:\\ankindle\\out\\emu\\$name-$stamp.png"
