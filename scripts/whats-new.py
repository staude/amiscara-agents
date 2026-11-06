#!/usr/bin/env python3
"""Checks that apps/whats-new.json has notes for a release (#341).

Usage: scripts/whats-new.py check <mac|desktop> <version>

Exits 0 when the app has an entry for the version with German and English
notes; otherwise prints why on stderr and exits 1. The release scripts call
it so that no update goes out without the "What's New" text the apps show.
"""

import json
import sys
from pathlib import Path

FILE = Path(__file__).resolve().parent.parent / "apps" / "whats-new.json"
APPS = ("mac", "desktop")


def has_notes(entry: object, version: str) -> bool:
    if not isinstance(entry, dict) or entry.get("version") != version:
        return False
    for lang in ("de", "en"):
        notes = entry.get(lang)
        if not isinstance(notes, list) or not any(isinstance(n, str) and n.strip() for n in notes):
            return False
    return True


def main(argv: list[str]) -> int:
    if len(argv) != 4 or argv[1] != "check" or argv[2] not in APPS:
        print("usage: whats-new.py check <mac|desktop> <version>", file=sys.stderr)
        return 2
    app, version = argv[2], argv[3]
    try:
        data = json.loads(FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        print(f"whats-new: cannot read apps/whats-new.json: {err}", file=sys.stderr)
        return 1
    entries = data.get(app) if isinstance(data, dict) else None
    if not isinstance(entries, list) or not any(has_notes(e, version) for e in entries):
        print(f"whats-new: no notes for {app} {version} in apps/whats-new.json", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
