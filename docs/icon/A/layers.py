#!/usr/bin/env python3
"""Zerlegt Konzept A (Stacked panes) in Ebenen fuer Icon Composer, Issue #82.

Jede Ebene ist ein 1024x1024-SVG mit transparentem Hintergrund und flacher
Fuellung. Glas, Glanzkante, Schatten und Maske setzt Icon Composer selbst.
Die Farben pro Erscheinung (hell, dunkel, tinted) stehen in README.md und
werden in Composer gesetzt; hier steht nur die Hell-Variante als Fuellung.
"""
from pathlib import Path

OUT = Path(__file__).parent / "layers"
S = 1024

# Geometrie aus generate.py, concept_a
W, H, R = 560, 430, 72
PANES = [(327 - i * 95, 200 + i * 95) for i in range(3)]  # hinten, mitte, vorn
FX, FY = PANES[2]
PX, PY = FX + 120, FY + 215
DOT = (327 + W - 82, 200 + 82, 38)

LIGHT = {
    "pane-back": "#2E8C8A",
    "pane-mid": "#1F9E86",
    "pane-front": "#0E7C74",
    "prompt": "#FFFFFF",
    "dot": "#FF9500",
}


def svg(inner: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">{inner}</svg>\n'


def pane(i: int, fill: str) -> str:
    x, y = PANES[i]
    return f'<rect x="{x}" y="{y}" width="{W}" height="{H}" rx="{R}" fill="{fill}"/>'


LAYERS = {
    # Reihenfolge = Gruppen in Composer, von hinten nach vorn
    "1-pane-back": pane(0, LIGHT["pane-back"]),
    "2-pane-mid": pane(1, LIGHT["pane-mid"]),
    "3-pane-front": pane(2, LIGHT["pane-front"]),
    "4-prompt": (
        f'<path d="M{PX} {PY - 85} L{PX + 95} {PY} L{PX} {PY + 85}" fill="none" stroke="{LIGHT["prompt"]}" '
        f'stroke-width="46" stroke-linecap="round" stroke-linejoin="round"/>'
        f'<rect x="{PX + 150}" y="{PY + 62}" width="140" height="46" rx="23" fill="{LIGHT["prompt"]}"/>'
    ),
    "5-dot": f'<circle cx="{DOT[0]}" cy="{DOT[1]}" r="{DOT[2]}" fill="{LIGHT["dot"]}"/>',
}


def tinted_preview() -> str:
    """Grobe Vorschau der Tinted-Erscheinung: nur Helligkeit, Systemtönung drüber."""
    body = f'<rect width="{S}" height="{S}" rx="228" fill="#121212"/>'
    for i, op in enumerate([.22, .38, .62]):
        body += pane(i, f"rgba(255,255,255,{op})")
    body += LAYERS["4-prompt"].replace(LIGHT["prompt"], "#121212")
    body += f'<circle cx="{DOT[0]}" cy="{DOT[1]}" r="{DOT[2]}" fill="#FFFFFF"/>'
    return svg(body)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for name, inner in LAYERS.items():
        (OUT / f"{name}.svg").write_text(svg(inner))
    (Path(__file__).parent / "preview-tinted.svg").write_text(tinted_preview())
    print("ok")
