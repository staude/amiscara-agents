#!/usr/bin/env python3
"""Baut das App-Icon als Icon-Composer-Datei aus den Ebenen von layers.py, Issue #82.

Schreibt apps/AmiscaraAgents/AmiscaraAgents/AppIcon.icon (icon.json und die
Ebenen als SVG) und die Akzentfarbe ins Asset-Katalog. Farben pro Erscheinung
wie in README.md; tinted und clear leitet das System aus Hell ab.
Das Ergebnis laesst sich in Icon Composer oeffnen und dort feinjustieren.
"""
import json
import shutil
from pathlib import Path

import layers

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "apps/AmiscaraAgents/AmiscaraAgents"
ICON = APP / "AppIcon.icon"
ACCENT = APP / "Assets.xcassets/AccentColor.colorset/Contents.json"

BACKGROUND = {
    "light": ("#E6F4F1", "#BFE3DC"),
    "dark": ("#0B2A2E", "#04161A"),
}
# Ebene: (hell, Deckkraft hell), (dunkel, Deckkraft dunkel)
COLORS = {
    "1-pane-back": (("#2E8C8A", 0.30), ("#2BB3A3", 0.22)),
    "2-pane-mid": (("#1F9E86", 0.45), ("#2FD1A5", 0.34)),
    "3-pane-front": (("#0E7C74", 0.92), ("#14A08C", 0.88)),
    "4-prompt": (("#FFFFFF", 1.0), ("#F2FFFB", 1.0)),
    "5-dot": (("#FF9500", 1.0), ("#FF9F0A", 1.0)),
}
ACCENT_COLORS = {"light": "#0E7C74", "dark": "#2FD1A5"}


def srgb(hex_color: str, alpha: float = 1.0) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"


def fill(light: str, dark: str, kind: str = "solid") -> list:
    return [
        {"value": {kind: light}},
        {"appearance": "dark", "value": {kind: dark}},
    ]


def layer(name: str, glass: bool = True) -> dict:
    (light, light_alpha), (dark, dark_alpha) = COLORS[name]
    return {
        "fill-specializations": fill(srgb(light, light_alpha), srgb(dark, dark_alpha)),
        "glass": glass,
        "image-name": f"{name}.svg",
        "name": name,
    }


def group(*members: dict, translucency: float) -> dict:
    return {
        "layers": list(members),
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "translucency": {"enabled": True, "value": translucency},
    }


def icon_json() -> dict:
    light, dark = BACKGROUND["light"], BACKGROUND["dark"]
    return {
        "fill-specializations": [
            {"value": {"linear-gradient": [srgb(light[0]), srgb(light[1])]}},
            {"appearance": "dark", "value": {"linear-gradient": [srgb(dark[0]), srgb(dark[1])]}},
        ],
        # Composer listet die Gruppen von vorn nach hinten.
        "groups": [
            group(layer("5-dot"), translucency=0.2),
            group(layer("4-prompt", glass=False), layer("3-pane-front"), translucency=0.1),
            group(layer("2-pane-mid"), translucency=0.5),
            group(layer("1-pane-back"), translucency=0.7),
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }


def accent_json() -> dict:
    def color(hex_color: str) -> dict:
        r, g, b = (f"0x{hex_color[i:i + 2]}" for i in (1, 3, 5))
        return {"color-space": "srgb", "components": {"alpha": "1.000", "red": r, "green": g, "blue": b}}

    return {
        "colors": [
            {"color": color(ACCENT_COLORS["light"]), "idiom": "universal"},
            {
                "appearances": [{"appearance": "luminosity", "value": "dark"}],
                "color": color(ACCENT_COLORS["dark"]),
                "idiom": "universal",
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }


if __name__ == "__main__":
    if ICON.exists():
        shutil.rmtree(ICON)
    (ICON / "Assets").mkdir(parents=True)
    for name, inner in layers.LAYERS.items():
        (ICON / "Assets" / f"{name}.svg").write_text(layers.svg(inner))
    (ICON / "icon.json").write_text(json.dumps(icon_json(), indent=2) + "\n")
    ACCENT.write_text(json.dumps(accent_json(), indent=2) + "\n")
    print(f"ok: {ICON.relative_to(ROOT)}")
