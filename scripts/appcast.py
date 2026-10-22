#!/usr/bin/env python3
"""Writes the Sparkle feed (appcast.xml) for one Mac release.

Called by scripts/release.sh; the values come as environment variables:
OUTPUT_PATH, VERSION, BUILD, ZIP_URL, ZIP_LENGTH, ZIP_ED_SIGNATURE,
MIN_SYSTEM, PUB_DATE and NOTES_URL. Modeled on Kastellan's
tools/appcast.py.
"""

import os
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
FEED_URL = "https://github.com/staude/amiscara-agents/releases/download/updates/appcast.xml"


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"appcast: {name} is missing")
    return value


def main() -> None:
    output = Path(required("OUTPUT_PATH"))
    version = required("VERSION")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Amiscara Agents"
    ET.SubElement(channel, "link").text = FEED_URL
    ET.SubElement(channel, "description").text = "Signierte Versionen der Mac-App"
    ET.SubElement(channel, "language").text = "de"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "pubDate").text = required("PUB_DATE")
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = required("BUILD")
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = required("MIN_SYSTEM")
    # The changelog has no sections per version yet; the release page
    # carries the notes.
    ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink").text = required("NOTES_URL")
    ET.SubElement(item, "enclosure", {
        "url": required("ZIP_URL"),
        f"{{{SPARKLE_NS}}}edSignature": required("ZIP_ED_SIGNATURE"),
        "length": required("ZIP_LENGTH"),
        "type": "application/octet-stream",
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(rss)
    ET.indent(tree, space="  ")
    tree.write(output, encoding="UTF-8", xml_declaration=True)


if __name__ == "__main__":
    main()
