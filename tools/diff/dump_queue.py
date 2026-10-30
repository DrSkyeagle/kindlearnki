#!/usr/bin/env python3
"""Dump the v3 scheduler's view of a collection, using Anki's real backend.

This is the golden side of the differential test in `doc/SCHED-SPEC.md`:
the Lua scheduler has to reproduce the queue order and land inside the same
interval ranges that this script records.

Usage (the interpreter must have the `anki` package; the koanki workspace venv
at C:\\deepseekharness\\koanki\\.venv does):

    python dump_queue.py --collection <collection.anki2> --out out/queue.json
    python dump_queue.py --collection <collection.anki2> --limit 20

The collection is copied (with its -wal/-shm siblings) to a temporary directory
before opening, so the source file is never locked or modified.

The copy is *sanitised* before the real backend sees it.  A collection produced
by older builds of this project (or by any writer that binds a Lua string where
SQLite expects a BLOB, such as lua-ljsqlite3 without `sql.blob()`) can store a
protobuf column with SQLite's TEXT storage class.  rslib reads those columns as
`Vec<u8>` and rejects TEXT with `DBError { info: "InvalidType" }`, so the whole
collection is unreadable to the reference backend even though the bytes are a
valid protobuf.  `sanitize_copy()` fixes that generically: for every column
*declared* BLOB in the schema but stored as TEXT it casts the value back to a
BLOB (byte-for-byte identical payload, only the storage class changes).  It
never touches the source file and logs every repair to stderr as
`FIXTURE-SANITIZED <table>.<column> TEXT->BLOB (<n> row(s))`.  A pre-existing
row-order note for `tags` is reported as `FIXTURE-NOTE ... (informational)`;
it does not affect the scheduler dump.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time

from anki.collection import Collection
from google.protobuf.json_format import MessageToDict


def _copy_collection(path: str) -> tuple[str, str]:
    workdir = tempfile.mkdtemp(prefix="kindleanki-diff-")
    target = os.path.join(workdir, "collection.anki2")
    for suffix in ("", "-wal", "-shm"):
        source = path + suffix
        if os.path.exists(source):
            shutil.copy2(source, target + suffix)
    # copy2 preserves the source's mode; the sanitizer needs to write the copy.
    try:
        os.chmod(target, 0o666)
    except OSError:
        pass
    return workdir, target


def _unicase(left: str, right: str) -> int:
    """Approximation of Anki's `unicase` collation, needed to open the DB.

    Only used by the sanitizer's own sqlite3 connection (the reference backend
    registers the real collation itself).  Case-folding is enough to keep the
    integrity check meaningful without pulling in a Unicode collation table.
    """
    left, right = left.casefold(), right.casefold()
    return (left > right) - (left < right)


def _declared_blob_columns(connection: sqlite3.Connection) -> list[tuple[str, str]]:
    columns = []
    tables = [
        row[0]
        for row in connection.execute(
            "select name from sqlite_master where type = 'table'"
            " and name not like 'sqlite_%'"
        )
    ]
    for table in tables:
        for row in connection.execute('pragma table_info("%s")' % table):
            declared = (row[2] or "").upper()
            if "BLOB" in declared:
                columns.append((table, row[1]))
    return columns


def sanitize_copy(path: str) -> tuple[list[str], list[str]]:
    """Fix BLOB-declared columns that are physically stored as TEXT.

    Returns (repairs, notes).  Both are human-readable and are echoed to stderr;
    repairs are also recorded in the dump payload so a golden file documents
    that its source needed sanitation.
    """
    repairs: list[str] = []
    notes: list[str] = []
    connection = sqlite3.connect(path)
    connection.create_collation("unicase", _unicase)
    try:
        for table, column in _declared_blob_columns(connection):
            text_rows = connection.execute(
                'select count(*) from "%s" where typeof("%s") = "text"'
                % (table, column)
            ).fetchone()[0]
            if not text_rows:
                continue
            connection.execute(
                'update "%s" set "%s" = cast("%s" as blob)'
                ' where typeof("%s") = "text"'
                % (table, column, column, column)
            )
            repairs.append(
                "%s.%s TEXT->BLOB (%d row(s))" % (table, column, text_rows)
            )
        connection.commit()
        for row in connection.execute("pragma integrity_check"):
            if row[0] != "ok":
                notes.append(str(row[0]))
    finally:
        connection.close()
    for repair in repairs:
        print("FIXTURE-SANITIZED " + repair, file=sys.stderr)
    for note in notes:
        print("FIXTURE-NOTE integrity_check: %s (informational)" % note, file=sys.stderr)
    return repairs, notes


def _card_dict(card) -> dict:
    return {
        "id": card.id,
        "note_id": card.note_id,
        "deck_id": card.deck_id,
        "type": card.ctype,
        "queue": card.queue,
        "due": card.due,
        "ivl": card.interval,
        "factor": card.ease_factor,
        "reps": card.reps,
        "lapses": card.lapses,
        "left": getattr(card, "left", None),
    }


def _states_dict(states) -> dict:
    # Protobuf -> plain dict keeps the script's output language-neutral; the Lua
    # side never needs to know about protobuf for the comparison.
    return MessageToDict(states, preserving_proto_field_name=True)


def _lua(value, indent=0):
    """Serialise a JSON-ish value as a Lua table literal.

    The Lua test suite has no JSON decoder yet (the sync layer owns that), and
    emitting a table keeps the differential test independent of it.
    """
    pad = "  " * indent
    child = "  " * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{}"
        lines = ["{"]
        for key in sorted(value, key=str):
            lines.append(f'{child}["{key}"] = {_lua(value[key], indent + 1)},')
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "{}"
        lines = ["{"]
        for item in value:
            lines.append(f"{child}{_lua(item, indent + 1)},")
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "nil"
    if isinstance(value, (int, float)):
        return repr(value)
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection", required=True)
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--out", default="-")
    parser.add_argument("--format", choices=("json", "lua"), default="json")
    parser.add_argument("--deck", type=int, default=None,
                        help="activate this deck before dumping")
    parser.add_argument("--no-sanitize", action="store_true",
                        help="skip the BLOB/TEXT storage-class repair on the copy")
    args = parser.parse_args(argv)

    workdir, path = _copy_collection(args.collection)
    try:
        repairs: list[str] = []
        notes: list[str] = []
        if not args.no_sanitize:
            repairs, notes = sanitize_copy(path)
        col = Collection(path)
        try:
            # Snapshot identity, read before any mutation below (deck selection
            # bumps col.mod, and the Lua test compares these against the fixture
            # to detect a re-downloaded/rewritten collection).
            identity = {
                "crt": int(col.db.scalar("select crt from col")),
                "mod": int(col.db.scalar("select mod from col")),
            }
            if args.deck is not None:
                col.decks.select(args.deck)
            effective_deck = int(col.decks.get_current_id())
            counts = col.sched.counts()
            # 26.09 returns a plain (new, learning, review) tuple; older
            # bindings returned an object with named fields.
            if hasattr(counts, "new"):
                counts_dict = {
                    "new": counts.new,
                    "learning": counts.learning,
                    "review": counts.review,
                }
            else:
                new, learning, review = counts
                counts_dict = {
                    "new": new,
                    "learning": learning,
                    "review": review,
                }
            queued = col.sched.get_queued_cards(fetch_limit=args.limit)
            payload = {
                "source": os.path.abspath(args.collection),
                # Snapshot identity: the Lua test uses crt/mod to detect that the
                # fixture was re-downloaded (or otherwise rewritten) after the
                # golden was produced, in which case it skips instead of lying.
                "crt": identity["crt"],
                "mod": identity["mod"],
                "dumped_at": int(time.time()),
                "limit": int(args.limit),
                # The deck the counts/queue were taken for: either --deck or the
                # collection's active deck at dump time.  The test derives its
                # local counts for this deck subtree.
                "deck": effective_deck,
                "today": int(col.sched.today),
                "counts": counts_dict,
                "queued": [
                    {
                        "card": _card_dict(entry.card),
                        "queue": int(entry.queue),
                        "states": _states_dict(entry.states),
                    }
                    for entry in queued.cards
                ],
                "sanitized": repairs,
                "integrity_notes": notes,
            }
        finally:
            col.close()
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if args.format == "lua":
        # Wrap in a function so `dofile` returns the table.
        text = "return " + _lua(payload) + "\n"
    else:
        text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.out == "-":
        sys.stdout.write(text)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"wrote {args.out} ({len(payload['queued'])} queued cards)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
