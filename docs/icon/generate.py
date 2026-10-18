#!/usr/bin/env python3
"""Erzeugt die Icon-Skizzen A-C (hell/dunkel) fuer Amiscara Agents, Issue #82.

Die Skizzen sind 1024x1024 mit Vorschau-Maske (abgerundetes Quadrat).
Fuer Icon Composer werden spaeter Hintergrund und Ebenen einzeln exportiert.
"""
from pathlib import Path

OUT = Path(__file__).parent
S = 1024
AMBER = {"light": "#FF9500", "dark": "#FF9F0A"}  # Systemorange wie .blocked in der Sidebar


def doc(body: str, defs: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">'
        f'<defs><clipPath id="mask"><rect width="{S}" height="{S}" rx="228"/></clipPath>{defs}</defs>'
        f'<g clip-path="url(#mask)">{body}</g></svg>'
    )


def glow_defs(mode: str) -> str:
    a = AMBER[mode]
    return (
        f'<radialGradient id="glow"><stop offset="0" stop-color="{a}" stop-opacity=".75"/>'
        f'<stop offset="1" stop-color="{a}" stop-opacity="0"/></radialGradient>'
        f'<radialGradient id="dot" cx=".38" cy=".35"><stop offset="0" stop-color="#FFE2B0"/>'
        f'<stop offset=".55" stop-color="{a}"/><stop offset="1" stop-color="#E07000"/></radialGradient>'
    )


def amber_dot(cx, cy, r):
    return (
        f'<circle cx="{cx}" cy="{cy}" r="{r * 2.6}" fill="url(#glow)"/>'
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#dot)"/>'
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="3"/>'
    )


# --- A: Stacked panes, Petrol -> Smaragd -------------------------------------
def concept_a(mode: str) -> str:
    if mode == "light":
        bg = ("#E6F4F1", "#BFE3DC")
        panes = [("#2E8C8A", .30), ("#1F9E86", .45), ("#0E7C74", .92)]
        rim, prompt = "#ffffff", "#ffffff"
    else:
        bg = ("#0B2A2E", "#04161A")
        panes = [("#2BB3A3", .22), ("#2FD1A5", .34), ("#14A08C", .88)]
        rim, prompt = "#BFFFF0", "#F2FFFB"
    defs = (
        f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{bg[0]}"/>'
        f'<stop offset="1" stop-color="{bg[1]}"/></linearGradient>'
        '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".38"/>'
        '<stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>'
        '<filter id="sh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="18" stdDeviation="22" '
        f'flood-color="{"#063B36" if mode == "light" else "#000"}" flood-opacity="{.25 if mode == "light" else .5}"/></filter>'
        + glow_defs(mode)
    )
    body = '<rect width="1024" height="1024" fill="url(#bg)"/>'
    # drei Scheiben, von hinten (oben rechts) nach vorn (unten links)
    w, h = 560, 430
    for i, (col, op) in enumerate(panes):
        x, y = 327 - i * 95, 200 + i * 95
        body += (
            f'<g filter="url(#sh)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="72" fill="{col}" fill-opacity="{op}"/></g>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="72" fill="url(#sheen)"/>'
            f'<rect x="{x + 2}" y="{y + 2}" width="{w - 4}" height="{h - 4}" rx="70" fill="none" stroke="{rim}" stroke-opacity=".55" stroke-width="4"/>'
        )
    fx, fy = 327 - 2 * 95, 200 + 2 * 95
    # >_ auf der vorderen Scheibe
    px, py = fx + 120, fy + 215
    body += (
        f'<path d="M{px} {py - 85} L{px + 95} {py} L{px} {py + 85}" fill="none" stroke="{prompt}" '
        f'stroke-width="46" stroke-linecap="round" stroke-linejoin="round"/>'
        f'<rect x="{px + 150}" y="{py + 62}" width="140" height="46" rx="23" fill="{prompt}"/>'
    )
    # Agent wartet: Punkt oben rechts auf der hintersten Scheibe
    body += amber_dot(327 + w - 82, 200 + 82, 38)
    return doc(body, defs)


# --- B: In Hoerweite, Indigo -> Violett ---------------------------------------
def concept_b(mode: str) -> str:
    if mode == "light":
        bg = ("#EEEBFF", "#D3CCFA")
        ring = ["#5B4BDB", "#6A4FE0", "#7C55E6", "#8E5CEB"]
        ops = [.16, .24, .34, .55]
        rim = "#ffffff"
    else:
        bg = ("#1A1440", "#0A0720")
        ring = ["#6F5CFF", "#7E62FF", "#9468FF", "#AE73FF"]
        ops = [.14, .2, .3, .5]
        rim = "#D9CFFF"
    defs = (
        f'<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{bg[0]}"/>'
        f'<stop offset="1" stop-color="{bg[1]}"/></linearGradient>'
        '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".35"/>'
        '<stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>'
        '<filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="14" stdDeviation="18" '
        f'flood-color="{"#2A1E7A" if mode == "light" else "#000"}" flood-opacity="{.22 if mode == "light" else .5}"/></filter>'
        + glow_defs(mode)
    )
    body = '<rect width="1024" height="1024" fill="url(#bg)"/>'
    cx, cy = 512, 528
    for r, col, op in zip([400, 300, 205, 118], ring, ops):
        body += (
            f'<g filter="url(#sh)"><circle cx="{cx}" cy="{cy}" r="{r}" fill="{col}" fill-opacity="{op}"/></g>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#sheen)"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r - 2}" fill="none" stroke="{rim}" stroke-opacity=".5" stroke-width="4"/>'
        )
    body += amber_dot(cx, cy, 52)
    return doc(body, defs)


# --- C: Die kleine Herde, Salbei/Waldgruen ------------------------------------
def concept_c(mode: str) -> str:
    if mode == "light":
        bg = ("#EEF3EA", "#D2E0C9")
        back, front = ("#7A9A6A", .38), ("#3F6B45", .9)
        rim = "#ffffff"
    else:
        bg = ("#17241A", "#0A120C")
        back, front = ("#9CC488", .34), ("#4E8A58", .85)
        rim = "#DDF2D4"
    defs = (
        f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{bg[0]}"/>'
        f'<stop offset="1" stop-color="{bg[1]}"/></linearGradient>'
        '<radialGradient id="sheen" cx=".35" cy=".25" r=".7"><stop offset="0" stop-color="#fff" stop-opacity=".45"/>'
        '<stop offset=".6" stop-color="#fff" stop-opacity="0"/></radialGradient>'
        '<filter id="sh" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="14" stdDeviation="16" '
        f'flood-color="{"#1F3A22" if mode == "light" else "#000"}" flood-opacity="{.25 if mode == "light" else .55}"/></filter>'
        + glow_defs(mode)
    )
    body = '<rect width="1024" height="1024" fill="url(#bg)"/>'

    def pebble(cx, cy, rx, ry, col, op):
        return (
            f'<g filter="url(#sh)"><ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{col}" fill-opacity="{op}"/></g>'
            f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="url(#sheen)"/>'
            f'<ellipse cx="{cx}" cy="{cy}" rx="{rx - 2}" ry="{ry - 2}" fill="none" stroke="{rim}" stroke-opacity=".5" stroke-width="4"/>'
        )

    # hintere Reihe (drei), vordere Reihe (drei, der mittlere leuchtet amber)
    for cx, cy in [(300, 420), (512, 380), (724, 420)]:
        body += pebble(cx, cy, 128, 108, *back)
    for cx, cy in [(282, 640), (742, 640)]:
        body += pebble(cx, cy, 140, 120, *front)
    body += (
        '<ellipse cx="512" cy="660" rx="300" ry="250" fill="url(#glow)"/>'
        '<g filter="url(#sh)"><ellipse cx="512" cy="660" rx="140" ry="120" fill="url(#dot)"/></g>'
        '<ellipse cx="512" cy="660" rx="140" ry="120" fill="url(#sheen)"/>'
        f'<ellipse cx="512" cy="660" rx="138" ry="118" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="4"/>'
    )
    return doc(body, defs)


CONCEPTS = {"A": concept_a, "B": concept_b, "C": concept_c}

if __name__ == "__main__":
    for key, fn in CONCEPTS.items():
        for mode in ("light", "dark"):
            (OUT / f"concept-{key}-{mode}.svg").write_text(fn(mode))
    print("ok")
