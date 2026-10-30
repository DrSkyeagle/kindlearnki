#!/usr/bin/env python3
"""Move (and raise) an X11 window so it lands on the visible screen.

WSLg's virtual desktop can be larger than the physical monitor (it follows the
Windows scaling factor), so an app that asks to be centred can end up at a
negative or off-screen coordinate -- the process runs, the window exists, and
the taskbar shows it, but nothing is visible.  That is exactly what happened to
the KOReader emulator window (`+913+1716` on a 2560x2680 root).

    DISPLAY=:0 python3 harness/place_window.py 0x600035 60 40
    DISPLAY=:0 python3 harness/place_window.py --name KOReader 60 40

With `--name`, the window is looked up in the X tree by title substring.
"""

from __future__ import annotations

import ctypes
import os
import re
import subprocess
import sys


def open_display(name: str):
    x11 = ctypes.CDLL("libX11.so.6")
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XMoveWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int]
    x11.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    display = x11.XOpenDisplay(name.encode())
    if not display:
        raise SystemExit(f"cannot open display {name}")
    return x11, display


def find_window(name_hint: str) -> int:
    output = subprocess.run(
        ["xwininfo", "-root", "-tree"],
        capture_output=True, text=True, check=True,
    ).stdout
    for line in output.splitlines():
        if name_hint.lower() in line.lower():
            match = re.search(r"(0x[0-9a-fA-F]+)", line)
            if match:
                return int(match.group(1), 16)
    raise SystemExit(f"no window matching {name_hint!r}")


def main(argv):
    display_name = os.environ.get("DISPLAY") or ":0"
    args = list(argv[1:])
    if not args:
        raise SystemExit(__doc__)

    if args[0] == "--name":
        window = find_window(args[1])
        args = args[2:]
    else:
        window = int(args[0], 0)
        args = args[1:]

    x = int(args[0]) if len(args) > 0 else 60
    y = int(args[1]) if len(args) > 1 else 40

    x11, display = open_display(display_name)
    x11.XMoveWindow(display, window, x, y)
    x11.XRaiseWindow(display, window)
    x11.XFlush(display)
    x11.XSync(display, 0)
    x11.XCloseDisplay(display)
    print(f"moved window {hex(window)} to {x},{y} on {display_name}")


if __name__ == "__main__":
    main(sys.argv)
