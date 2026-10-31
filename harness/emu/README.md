# Kindlearnki eink-emulator harness (Kindle Voyage 5.13.6 in QEMU)

Real-firmware QEMU emulator used to **visually verify the plugin's 1072x1448
layout** without touching a physical Kindle.  Everything here runs in WSL2
distro `KO-test`; the Windows wrapper `emu.cmd` drives it.

Status: **working** (2026-10-31).  The plugin loads on the emulated Voyage
(`kindlearnki: koreader=v2026.07.1 model=KindleVoyage html=ok sqlite=ok
zstd=ok ca=yes`), the deck list and the study card view render, and screenshots
are captured headlessly through QMP.  One-command loop after a code change:
**~20 s** (warm) / **~2.5 min** (cold boot).

## TL;DR for the Lead

```bat
D:\ankindle\harness\emu\emu.cmd up                 :: boot/reuse machine, push plugin, start KOReader
D:\ankindle\harness\emu\emu.cmd status             :: pids, log line, inspector, on-screen widgets
D:\ankindle\harness\emu\emu.cmd refresh study-front --nav study   :: push+restart+navigate+shot
D:\ankindle\harness\emu\emu.cmd refresh study-answer --nav study --answer
D:\ankindle\harness\emu\emu.cmd shot my-name       :: screenshot current screen only
D:\ankindle\harness\emu\emu.cmd nav answer         :: 显示答案
D:\ankindle\harness\emu\emu.cmd nav rate 3         :: rate card 1..4, renders next card
D:\ankindle\harness\emu\emu.cmd nav decklist       :: open the deck list
D:\ankindle\harness\emu\emu.cmd evidence           :: write out\emu\plugin-load.log
```

PNGs land in `D:\ankindle\out\emu\<name>.png` plus a timestamped
`<name>-YYYYmmdd-HHMMSS.png` copy.  `emu.cmd refresh` always pushes the current
`D:\ankindle\kindlearnki.koplugin` and restarts KOReader, so it is the normal
"after editing the plugin" command.  It is safe to re-run with QEMU up or down.

## What runs where

| piece | host | notes |
|---|---|---|
| QEMU machine `kv` | WSL `KO-test`, `/root/kvemu/eink-emulator` | `kindle-voyage`, firmware 5.13.6, 512 MB, TCG |
| machine state | `/root/kvemu/eink-emulator/machines/kv/` | `disk.qcow2` persists between boots; `kv.serial.log` |
| QEMU logs | `/root/kvemu/logs/run-kv.log` | stdout of `./eink run` |
| guest SSH | `root@127.0.0.1:2222` (host side) | key `build/ssh/id_ed25519` |
| guest QMP | `machines/kv/kv.qmp.sock` | used for screendump |
| guest serial | `machines/kv/kv.serial.log` | real boot/firmware log |
| KOReader tree | guest `/mnt/us/koreader` (86 MB) | kindlepw2 v2026.07.1, started directly via `luajit reader.lua` |
| plugin | guest `/mnt/us/koreader/plugins/kindlearnki.koplugin` | pushed from `D:\ankindle\kindlearnki.koplugin` |
| collection | guest `/mnt/us/koreader/kindlearnki/collection.anki2` | copied from `C:\deepseekharness\koanki\bench\work\live\collection.anki2` |
| KOReader settings | guest `/mnt/us/koreader/settings.reader.lua` | `httpinspector.autostart=true` is merged in |
| KOReader log | guest `/tmp/ko2.log` | plugin lines + `card render` lines |
| screenshots | `D:\ankindle\out\emu\` | PNG, 1072x1448 |

Host D:\ankindle == `/mnt/d/ankindle`; WSL invocations use
`wsl -d KO-test -- bash /mnt/d/ankindle/harness/emu/<script>`.

## Scripts

All are bash, run inside WSL; `emu.cmd`/`emu.ps1` are thin Windows wrappers.
`env.sh` holds all paths/constants and is sourced by every script.

| script | purpose |
|---|---|
| `emu_up.sh` | create machine if missing, start QEMU (headless, QMP+serial sockets, `-watchdog-action none`), wait SSH, stop framework, fix startup-script hash, install KOReader tree if missing, then delegate to `emu_push_plugin.sh`. Idempotent; reuses a running QEMU; removes stale sockets; if QEMU dies during boot it prints the tail of `kv.serial.log` instead of retrying. |
| `emu_push_plugin.sh` | tar the current plugin into the guest, restore the fixture collection (`--force-fixture` to always, `--no-fixture` to skip), merge httpinspector autostart, restart KOReader, wait for `kindlearnki: ... model=KindleVoyage`, wait for port 8080. |
| `emu_shot.sh <name>` | QMP screendump (`eink-qmp.py --machine kv screendump /tmp/x.ppm`) + stdlib-only PPM→PNG conversion (`ppm2png.py`; the QEMU build has no libpng) → `out/emu/<name>.png` (+ timestamped copy). Prints both Windows paths. Fails clearly if QEMU is down. |
| `emu_nav.sh <cmd>` | programmatic navigation through KOReader's httpinspector — see below. |
| `emu_refresh.sh <name> [--nav X ...]` | one command: `emu_up.sh` → navigation → screenshot. Restores the fixture collection each run by default (`--keep-progress` to keep rating state). |
| `emu_status.sh` | one-screen status: QEMU pid, QMP state, guest uptime/memory, KOReader pid, capability line, inspector HTTP code, on-screen widgets, recent PNGs. |
| `emu_evidence.sh` | writes `out/emu/plugin-load.log` with guest identity, plugin log lines, inspector/hook state. |
| `emu_down.sh [--reset]` | QMP quit + remove sockets; `--reset` additionally discards guest changes. |
| `guest.sh <cmd>` | run one command in the guest over ssh (stdin forwarded, so pipes work). |
| `ppm2png.py` | dependency-free PPM(P6)→PNG converter (zlib only). |

## Programmatic navigation (no touch injection needed)

Touch injection through QMP does not reach the guest (known limitation), and
`screendump`+event routes are enough.  `emu_nav.sh` uses KOReader's
**httpinspector** plugin, which is started automatically on port 8080 because
`settings.reader.lua` contains:

```lua
["httpinspector"] = {
    ["autostart"] = true,
    ["port"] = 8080,
}
```

Two routes:

1. **Lead's debug hook** (preferred when present, not yet in the plugin):
   ```
   curl -sS "http://127.0.0.1:8080/koreader/globals/KindlearnkiDebug/open_study/1"
   ```
   `curl` exists in the guest (`/usr/bin/curl`); `wget -qO-` also works.  The
   generic global-function call mechanism is verified (`/koreader/globals/tostring/5`
   returns `"5"`), so this URL will work as soon as `_G.KindlearnkiDebug` is
   defined on plugin load.  `emu_nav.sh study` automatically prefers the hook
   when present and otherwise uses route 2, so nothing needs to change.
2. **KOReader window stack** (works today, needs no plugin change):
   ```
   # open the deck list
   curl -sS "http://127.0.0.1:8080/koreader/event/KindlearnkiStudy"
   # which widgets are on screen
   curl -sS "http://127.0.0.1:8080/koreader/UIManager/_window_stack/2/widget/name"
   # read the first deck row's id, then open it
   curl -sS "http://127.0.0.1:8080/koreader/UIManager/_window_stack/2/widget/layout/rows/1/deck_id"
   curl -sS "http://127.0.0.1:8080/koreader/UIManager/_window_stack/2/widget/on_open/1787138061852"
   # study screen: 显示答案 / rate 1..4
   curl -sS "http://127.0.0.1:8080/koreader/UIManager/_window_stack/3/widget/_show_answer/"
   curl -sS "http://127.0.0.1:8080/koreader/UIManager/_window_stack/3/widget/_rate/3"
   ```
   All of this is wrapped by `emu_nav.sh {top,state,decklist,study [ROW],answer,
   rate N,close,hook N}`.  Note the trailing `/` to *call* a function with no
   args; with args the URL is `.../method/arg` (no trailing slash).

## Timings measured on this host (TCG, 12 cores)

| step | time |
|---|---|
| QEMU start → guest SSH ready (warm disk) | **~31 s** |
| KOReader start → `model=KindleVoyage` line | **~15-20 s** (warm), up to 60 s after a fresh boot |
| KOReader start → httpinspector 200 on :8080 | +3-10 s after the plugin line |
| full `emu.cmd refresh ... --nav study` (warm QEMU, already running) | **~22 s** |
| full `emu.cmd up` after `kill -9` of QEMU (cold, plugin push included) | **~2 m 15 s** |

## Pitfalls (beyond the three in doc/模拟器.md)

1. **`-watchdog-action none` is mandatory** — otherwise the guest watchdog
   resets and `-no-reboot` kills QEMU after a few minutes (`emu_up.sh` passes it).
2. **Launcher blocks on `/proc/keypad`** — that is why we `stop lab126_gui`
   and run `luajit reader.lua` directly instead of `koreader.sh`.
3. **`/var/tmp/koreader.sh` modal (new)** — `Kindle:isStartupScriptUpToDate()`
   md5-compares `/var/tmp/koreader.sh` with `./koreader.sh`.  `/var/tmp` is
   tmpfs, so after every boot the mismatch shows a modal
   "KOReader's startup script has been updated / Ignore / Quit" *before* the UI
   and waits for a tap forever (log stops after the migration lines).  Fix:
   `fix_startup_script()` copies `/mnt/us/koreader/koreader.sh` to
   `/var/tmp/koreader.sh` before every start.
4. **`pkill -f <pattern>` over ssh kills its own shell (new)** — the remote
   shell's command line contains the pattern, so `pkill -f cvm` or
   `pkill -f reader.lua` kills the ssh session (rc 255) halfway through.  Use
   `[c]vm` / `[l]uajit` bracket patterns, as `env.sh` does.
5. **No libpng in the QEMU build (new)** — `screendump ... .png` fails; write
   `.ppm` and convert.  WSL has no Pillow/ImageMagick, so `ppm2png.py` does it
   with stdlib zlib.
6. **httpinspector settings path (new)** — `reader.lua` opens
   `G_reader_settings` at `<data dir>/settings.reader.lua`, and on Kindle the
   data dir is `.` (cwd `/mnt/us/koreader`), so the file is
   `/mnt/us/koreader/settings.reader.lua` — *not* `settings/settings.reader.lua`.
   `autostart` must be true or nothing listens on 8080.
7. **Rating cards mutates the fixture collection (new)** — `_rate` writes
   scheduler state into the guest `collection.anki2`, so counts drift between
   runs.  `emu_refresh.sh` restores the fixture by default.
8. **Stale sockets after a killed QEMU (new)** — `kv.qmp.sock`/`kv.serial.sock`
   survive `kill -9` and make `./eink run` refuse to start; `emu_up.sh` removes
   them after verifying no QEMU process owns them.
9. **Memory** — framework off (~130 MB freed); KOReader runs in ~360 MB of 512 MB.
10. **`/mnt/us` writes can be lost on hard kill** — `cache=writethrough` helps,
    but always let `emu_push_plugin.sh`/`emu_up.sh` re-push plugin+collection
    after a forced shutdown.

## Safety

Never touches the physical Kindle at `192.168.0.143`.  No sync is performed;
the fixture is only used for the local review UI guards.
