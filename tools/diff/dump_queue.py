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
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile

from anki.collection import Collection
from google.protobuf.json_format import MessageToDict


def _copy_collection(path: str) -> tuple[str, str]:
    workdir = tempfile.mkdtemp(prefix="kindleanki-diff-")
    target = os.path.join(workdir, "collection.anki2")
    for suffix in ("", "-wal", "-shm"):
        source = path + suffix
        if os.path.exists(source):
            shutil.copy2(source, target + suffix)
    return workdir, target


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
    args = parser.parse_args(argv)

    workdir, path = _copy_collection(args.collection)
    try:
        col = Collection(path)
        try:
            if args.deck is not None:
                col.decks.select(args.deck)
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
