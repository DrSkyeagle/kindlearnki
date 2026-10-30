#!/usr/bin/env python3
"""Convert a binary PPM (P6) to PNG using only the Python standard library.

The QEMU build in /root/kvemu/eink-emulator has no libpng, so
`eink-qmp.py screendump foo.png` fails; it can only write PPM.  WSL's system
python3 has no Pillow and there is no ImageMagick, so this tiny converter is
used instead: zlib is in the standard library and a 1072x1448 RGB frame
compresses in well under a second.

    python3 ppm2png.py in.ppm out.png [--scale N]
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        raise ValueError(f"{path}: not a binary PPM (P6)")
    # Header: magic, width, height, maxval; whitespace/comments between tokens.
    pos = 2
    fields: list[int] = []
    while len(fields) < 3:
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":  # comment to end of line
            while pos < len(data) and data[pos : pos + 1] != b"\n":
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    width, height, maxval = fields
    if maxval != 255:
        raise ValueError(f"{path}: only 8-bit PPM supported (maxval={maxval})")
    pos += 1  # exactly one whitespace byte after maxval
    pixels = data[pos:]
    expected = width * height * 3
    if len(pixels) < expected:
        raise ValueError(
            f"{path}: short pixel data: {len(pixels)} < {expected} bytes")
    return width, height, pixels[:expected]


def png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def write_png(path: Path, width: int, height: int, rgb: bytes, scale: int) -> None:
    if scale > 1:
        rows = []
        for y in range(height):
            row = rgb[y * width * 3 : (y + 1) * width * 3]
            rows.append(b"".join(row[x * 3 : x * 3 + 3] * scale
                                 for x in range(width)))
        scaled_row = b"".join(rows[y] * scale for y in range(height))
        width *= scale
        height *= scale
        raw = b"".join(b"\x00" + scaled_row[y * width * 3 : (y + 1) * width * 3]
                       for y in range(height))
    else:
        raw = b"".join(b"\x00" + rgb[y * width * 3 : (y + 1) * width * 3]
                       for y in range(height))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(raw, 6))
        + png_chunk(b"IEND", b"")
    )
    path.write_bytes(png)


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    scale = 1
    for a in argv[1:]:
        if a.startswith("--scale="):
            scale = max(1, int(a.split("=", 1)[1]))
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = Path(args[0]), Path(args[1])
    width, height, rgb = read_ppm(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    write_png(dst, width, height, rgb, scale)
    print(f"{dst} ({width}x{height}, scale={scale})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
