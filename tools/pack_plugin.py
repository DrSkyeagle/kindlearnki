#!/usr/bin/env python3
"""Package kindleanki.koplugin as a zip that can be dropped on the Kindle.

    python tools/pack_plugin.py            # build out/kindleanki.koplugin-<ver>.zip
    python tools/pack_plugin.py --check    # compare archive bytes with sources

The archive contains a single top-level `kindleanki.koplugin/` directory, which
is what KOReader expects under `koreader/plugins/`.  Tests and developer docs are
excluded: they are large, and the plugin must not pay for them at runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "kindleanki.koplugin"
OUT = ROOT / "out"

EXCLUDED_DIRS = {"tests", "doc"}
EXCLUDED_SUFFIXES = {".anki2", ".anki2-wal", ".anki2-shm", ".log"}


def version() -> str:
    text = (PLUGIN / "core" / "version.lua").read_text(encoding="utf-8")
    match = re.search(r'VERSION\s*=\s*"([^"]+)"', text)
    if not match:
        raise SystemExit("cannot find VERSION in core/version.lua")
    return match.group(1)


def iter_files():
    for path in sorted(PLUGIN.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(PLUGIN)
        if any(part in EXCLUDED_DIRS for part in relative.parts[:-1]):
            continue
        if path.suffix in EXCLUDED_SUFFIXES:
            continue
        yield path, relative


LUA_SYNTAX_CHECK = """
local bad = 0
for i = 1, #arg do
    local chunk, err = loadfile(arg[i])
    if not chunk then
        bad = bad + 1
        print("FAIL " .. arg[i] .. ": " .. tostring(err))
    end
end
os.exit(bad == 0 and 0 or 1)
"""


def syntax_check() -> int:
    """Compile every packaged Lua file before writing the archive.

    A syntax error in a module that no offline test loads shipped once, and the
    device only found it when the menu item required the module.  The bundled
    LuaJIT is right here, so there is no excuse for a zip that does not compile.
    """
    luajit = ROOT / "tools" / "lj" / "luajit.exe"
    if not luajit.exists():
        print("syntax check skipped (bundled luajit not found)")
        return 0
    files = [str(path) for path, _ in iter_files()]
    result = subprocess.run([str(luajit), "-e", LUA_SYNTAX_CHECK, *files])
    return result.returncode


def build(target: Path) -> int:
    if syntax_check() != 0:
        print("REFUSING to package: syntax errors above")
        return 1
    target.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, relative in iter_files():
            archive.write(path, "kindleanki.koplugin/" + relative.as_posix())
            count += 1
    print(f"wrote {target} ({count} entries)")
    return 0


def check(target: Path) -> int:
    if not target.exists():
        print(f"FAILED: {target} does not exist (run without --check first)")
        return 1
    problems = []
    with zipfile.ZipFile(target) as archive:
        names = set(archive.namelist())
        expected = set()
        for path, relative in iter_files():
            name = "kindleanki.koplugin/" + relative.as_posix()
            expected.add(name)
            if name not in names:
                problems.append(f"missing from archive: {name}")
                continue
            archived = archive.read(name)
            source = path.read_bytes()
            if hashlib.sha256(archived).digest() != hashlib.sha256(source).digest():
                problems.append(f"content differs from source: {name}")
        for extra in sorted(names - expected):
            problems.append(f"extra entry: {extra}")

    if problems:
        print("FAILED")
        for problem in problems:
            print("  - " + problem)
        return 1
    print(f"PASS ({len(expected)} entries match the sources byte for byte)")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out", default=None)
    args = parser.parse_args(argv)

    target = Path(args.out) if args.out else OUT / f"kindleanki.koplugin-{version()}.zip"
    return check(target) if args.check else build(target)


if __name__ == "__main__":
    raise SystemExit(main())
