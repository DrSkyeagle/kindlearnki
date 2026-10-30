"""A tiny AnkiWeb sync server for end-to-end tests.

Implements just enough of the v11 collection protocol for the plugin's own
client to run a full sync against a real socket: zstd-framed JSON bodies, the
`anki-sync` header, and the meta/start/applyChanges/chunk/applyChunk/
sanityCheck2/finish/download/upload endpoints.

Two modes:

  normal      -- every sync completes; applyChunk bodies are recorded.
  structural  -- the first applyChanges returns a deck change, which makes the
                 client adopt the server collection (download) and replay its
                 pending rows, then sync again.

  chunkfail   -- the first applyChunk fails with HTTP 500, so the client must
                 keep the rows pending; the next sync pushes them successfully.

Every request body is appended to LOG (one JSON object per line) so a test can
assert what actually went over the wire.

    python3 mock_ankiweb.py --port 9123 --fixture /tmp/x.anki2 --mode normal \
        --log /tmp/mock-sync.jsonl
"""
import argparse
import ctypes
import json
import os
import sqlite3
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ZSTD_CANDIDATES = [
    "/root/koanki-test/squashfs-root/usr/lib/koreader/libs/libzstd.so.1",
    "libzstd.so.1",
    "libzstd.so",
]


def load_zstd():
    last = None
    for candidate in ZSTD_CANDIDATES:
        try:
            lib = ctypes.CDLL(candidate)
        except OSError as error:  # noqa: PERF203 - trying a list
            last = error
            continue
        lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
        lib.ZSTD_compressBound.restype = ctypes.c_size_t
        lib.ZSTD_compress.argtypes = [
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
            ctypes.c_size_t, ctypes.c_int,
        ]
        lib.ZSTD_compress.restype = ctypes.c_size_t
        lib.ZSTD_decompress.argtypes = [
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
        ]
        lib.ZSTD_decompress.restype = ctypes.c_size_t
        lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
        lib.ZSTD_isError.restype = ctypes.c_uint
        return lib
    raise RuntimeError(f"no zstd library: {last}")


ZSTD = load_zstd()


def zcompress(data: bytes) -> bytes:
    capacity = ZSTD.ZSTD_compressBound(len(data))
    buffer = ctypes.create_string_buffer(capacity)
    written = ZSTD.ZSTD_compress(buffer, capacity, data, len(data), 3)
    if ZSTD.ZSTD_isError(written):
        raise RuntimeError("zstd compress failed")
    return buffer.raw[:written]


def zdecompress(data: bytes) -> bytes:
    # Sync payloads are small except the collection download; grow on demand.
    capacity = max(64 * 1024, len(data) * 8)
    for _ in range(6):
        buffer = ctypes.create_string_buffer(capacity)
        written = ZSTD.ZSTD_decompress(buffer, capacity, data, len(data))
        if not ZSTD.ZSTD_isError(written):
            return buffer.raw[:written]
        capacity *= 4
    raise RuntimeError("zstd decompress failed")


class State:
    def __init__(self, args):
        self.args = args
        self.lock = open(args.log, "a", encoding="utf-8")
        self.fixture_bytes = open(args.fixture, "rb").read()
        connection = sqlite3.connect(args.fixture)
        row = connection.execute("select mod, scm, usn from col").fetchone()
        connection.close()
        self.mod = row[0] + 1        # differs from the client, forces a sync
        self.scm = row[1]
        self.usn = row[2]
        self.structural_pending = args.mode == "structural"
        self.chunk_failed_once = False
        self.requests = 0

    def record(self, path, body):
        self.requests += 1
        entry = {"n": self.requests, "path": path}
        try:
            entry["body"] = json.loads(body.decode("utf-8"))
        except Exception:  # noqa: BLE001 - binary payloads
            entry["body"] = f"<{len(body)} bytes>"
        self.lock.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self.lock.flush()


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # keep the test output readable
            pass

        def _read(self):
            # LuaSocket sends `Transfer-Encoding: chunked` for a non-seekable
            # ltn12 source, which is exactly what the plugin's transport uses.
            encoding = (self.headers.get("transfer-encoding") or "").lower()
            if "chunked" in encoding:
                chunks = []
                while True:
                    line = self.rfile.readline().strip()
                    if not line:
                        continue
                    size = int(line.split(b";")[0], 16)
                    if size == 0:
                        self.rfile.readline()
                        break
                    chunks.append(self.rfile.read(size))
                    self.rfile.read(2)  # trailing CRLF
                raw = b"".join(chunks)
            else:
                length = int(self.headers.get("content-length") or 0)
                raw = self.rfile.read(length) if length else b""
            if not raw:
                return b""
            return zdecompress(raw)

        def _send(self, body: bytes, status=200):
            self.send_response(status)
            self.send_header("content-type", "application/octet-stream")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):  # noqa: N802 - http.server API
            path = self.path.split("/")[-1]
            body = self._read()
            if self.headers.get("anki-sync") is None:
                self._send(b"", status=400)
                return
            if path not in ("upload", "download", "finish"):
                state.record(path, body)

            if path == "meta":
                reply = {
                    "mod": state.mod, "scm": state.scm, "usn": state.usn,
                    "ts": int(time.time()), "msg": "", "cont": True,
                    "hostNum": 0, "empty": False, "media_usn": 0,
                }
                self._send(zcompress(json.dumps(reply).encode()))
            elif path == "start":
                reply = {"graves": {"cards": [], "notes": [], "decks": []}}
                self._send(zcompress(json.dumps(reply).encode()))
            elif path == "applyChanges":
                if state.structural_pending:
                    state.structural_pending = False
                    deck = {
                        "id": 1700000000001, "name": "PhoneDeck",
                        "mod": int(time.time()), "usn": state.usn,
                        "dyn": 0, "collapsed": False, "conf": 1,
                    }
                    reply = {"models": [], "decks": [[deck], []], "tags": []}
                else:
                    reply = {"models": [], "decks": [[], []], "tags": []}
                self._send(zcompress(json.dumps(reply).encode()))
            elif path == "chunk":
                self._send(zcompress(json.dumps({"done": True}).encode()))
            elif path == "applyChunk":
                state.record("applyChunk.pg", body)
                if state.args.mode == "chunkfail" and not state.chunk_failed_once:
                    state.chunk_failed_once = True
                    self._send(b"the server exploded", status=500)
                    return
                self._send(zcompress(b"{}"))
            elif path == "sanityCheck2":
                reply = {"status": "ok", "c": [0], "s": [0]}
                self._send(zcompress(json.dumps(reply).encode()))
            elif path == "finish":
                state.mod = int(time.time() * 1000)
                state.usn += 1
                self._send(zcompress(json.dumps(state.mod).encode()))
            elif path == "download":
                state.record("download", body)
                self._send(zcompress(state.fixture_bytes))
            elif path == "upload":
                state.record("upload", body)
                self._send(zcompress(b"OK"))
            else:
                self._send(zcompress(b"{}"))

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9123)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--mode",
        choices=["normal", "structural", "chunkfail"], default="normal")
    parser.add_argument("--log", required=True)
    args = parser.parse_args()

    state = State(args)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(state))
    with open(args.log, "w", encoding="utf-8"):
        pass
    print(f"mock ankiweb on :{args.port} mode={args.mode}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
