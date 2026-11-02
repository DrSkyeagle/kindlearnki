"""Wait for the Kindle, install 0.3.3, then prove the PagePress switch flips.

The device sleeps until the user touches it, so this polls the KOReader HTTP
inspector.  When it answers:

  1. install kindlearnki 0.3.3 from the dev host's http.server (the old
     ``kindleanki.koplugin`` directory is removed first -- leaving it in place
     makes KOReader load the OLD core.* modules and the new plugin breaks);
  2. copy the installed ``core/version.lua`` into ``koreader/web/`` and read it
     back over the inspector's static route, so the version is verified and not
     assumed;
  3. copy ``crash.log`` into ``koreader/web/`` every minute and look for the
     two lines that matter, which only appear after the user restarts KOReader:
         kindlearnki: koreader=v2026.07.1 model=KindleVoyage ...
         kindlearnki: page buttons: enabled deviced keypad (0/1/1 -> 1/1/1)
  4. stop as soon as both are seen (or after the deadline) and leave a
     summary in ``out/poller.log``.

Everything is idempotent: running it again only reinstalls and re-reads.
"""
import os
import sys
import time
import urllib.request
import urllib.error
import urllib.parse

DEVICE = os.environ.get("DEVICE", "http://192.168.0.143:8080")
HOST = os.environ.get("HOST", "http://192.168.0.136:8000")
VERSION = os.environ.get("VERSION", "0.3.3")
REPORT = os.environ.get("REPORT", "D:/ankindle/out/poller.log")
PLUGINS = "/mnt/us/koreader/plugins"
WEB = "/mnt/us/koreader/web"
DEADLINE_HOURS = float(os.environ.get("DEADLINE_HOURS", "12"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "30"))
INSTALL_ONLY = "--install-only" in sys.argv


# Never let a desktop HTTP proxy intercept LAN calls to the Kindle.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def log(line):
    stamp = time.strftime("%m-%d %H:%M:%S")
    text = f"{stamp} {line}"
    print(text, flush=True)
    with open(REPORT, "a", encoding="utf-8") as handle:
        handle.write(text + "\n")


def fetch(path, timeout=20):
    try:
        with _OPENER.open(DEVICE + path, timeout=timeout) as response:
            return response.read().decode("utf-8", "replace")
    except Exception as error:  # noqa: BLE001 - network weather
        return None


def inspector(command, timeout=120):
    """Run a shell command inside KOReader via globals/os/execute."""
    quoted = '"' + command + '"'
    encoded = urllib.parse.quote(quoted, safe="")
    url = f"{DEVICE}/koreader/globals/os/execute/{encoded}"
    try:
        with _OPENER.open(url, timeout=timeout) as response:
            return response.read().decode("utf-8", "replace")
    except Exception as error:  # noqa: BLE001
        log(f"inspector error: {error}")
        return None



def online():
    body = fetch("/koreader/", timeout=8)
    return body is not None


def install():
    steps = [
        f"rm -rf {PLUGINS}/kindleanki.koplugin",
        f"wget -q -O /tmp/kk-{VERSION}.tgz {HOST}/kindlearnki-koplugin-{VERSION}.tgz",
        f"rm -rf {PLUGINS}/kindlearnki.koplugin",
        f"mkdir -p {PLUGINS} {WEB}",
        f"tar -xzf /tmp/kk-{VERSION}.tgz -C {PLUGINS}",
        f"cp {PLUGINS}/kindlearnki.koplugin/core/version.lua {WEB}/kaver.txt",
    ]
    command = " && ".join(steps)
    log("installing " + VERSION)
    inspector(command)
    time.sleep(2)
    body = fetch("/kaver.txt")
    if not body:
        log("version read-back failed")
        return False
    line = next((l.strip() for l in body.splitlines() if "VERSION" in l), "?")
    ok = f'"{VERSION}"' in line
    log(f"version read-back: {'ok' if ok else 'MISMATCH'} ({line})")
    return ok


def look_for_key_lines():
    inspector(f"cp /mnt/us/koreader/crash.log {WEB}/kacrash.txt 2>/dev/null || true")
    body = fetch("/kacrash.txt") or ""
    started = [l for l in body.splitlines() if "kindlearnki: koreader=" in l]
    keys = [l for l in body.splitlines() if "page buttons:" in l]
    return started, keys


def main():
    log(f"watching for the Kindle ({DEADLINE_HOURS} h, every {POLL_SECONDS} s)")
    deadline = time.time() + DEADLINE_HOURS * 3600
    while time.time() < deadline:
        if online():
            break
        time.sleep(POLL_SECONDS)
    else:
        log("device never came online")
        return 1

    log("device is online")
    if not install():
        return 1
    log("installed; waiting for a KOReader restart (the user must do that)")
    if INSTALL_ONLY:
        return 0

    seen_start = False
    while time.time() < deadline:
        time.sleep(60)
        if not online():
            log("device went back to sleep")
            continue
        started, keys = look_for_key_lines()
        if started and not seen_start:
            seen_start = True
            log("plugin start line: " + started[-1].strip())
        if keys:
            for line in keys:
                log("key line: " + line.strip())
            if any("enabled deviced keypad" in l for l in keys):
                log("RESULT: the plugin switched the PagePress rocker on")
                inspector(f"rm -f {WEB}/kacrash.txt {WEB}/kaver.txt")
                return 0
            log("RESULT: a page-buttons line was seen, but nothing was switched on")
        elif seen_start:
            log("started, but no page-buttons line yet")
    log("deadline reached without a key line")
    return 2


if __name__ == "__main__":
    sys.exit(main())
