# App-Icon Amiscara Agents – Konzept A „Stacked panes“

Entscheidung in [#82](https://github.com/staude/amiscara-agents/issues/82): drei Glasscheiben wie Terminal-Panes, `>_` auf der vorderen, ein Amber-Punkt oben rechts („Agent wartet“).

## Ebenen für Icon Composer

`layers.py` erzeugt `layers/` (1024 × 1024, transparent, flache Füllung). Glas, Glanz, Schatten und Maske setzt Icon Composer.

| Gruppe (hinten → vorn) | Datei | Composer |
|---|---|---|
| 1 | `1-pane-back.svg` | Glass an, Translucency hoch |
| 2 | `2-pane-mid.svg` | Glass an, Translucency mittel |
| 3 | `3-pane-front.svg` | Glass an, nahezu deckend |
| 4 | `4-prompt.svg` | in Gruppe 3, Glass aus |
| 5 | `5-dot.svg` | eigene Gruppe, Glass an, leichter Glow |

Hintergrund als Composer-Fill (Verlauf oben → unten).

## Farben

| Element | Hell | Dunkel | Tinted |
|---|---|---|---|
| Hintergrund | `#E6F4F1` → `#BFE3DC` | `#0B2A2E` → `#04161A` | System |
| Scheibe hinten | `#2E8C8A` 30 % | `#2BB3A3` 22 % | Weiß 22 % |
| Scheibe Mitte | `#1F9E86` 45 % | `#2FD1A5` 34 % | Weiß 38 % |
| Scheibe vorn | `#0E7C74` 92 % | `#14A08C` 88 % | Weiß 62 % |
| `>_` | `#FFFFFF` | `#F2FFFB` | ausgestanzt |
| Punkt | `#FF9500` | `#FF9F0A` | Weiß 100 % |

Der Punkt nutzt dasselbe Systemorange wie `.blocked` in der Sidebar (`StatusStyle.swift`).

## Akzentfarbe der App

`AccentColor` = Scheibe vorn, angehoben für Kontrast auf Text:

- Hell `#0E7C74` (Kontrast auf Weiß ca. 5,1 : 1)
- Dunkel `#2FD1A5` (Kontrast auf `#1C1C1E` ca. 8,7 : 1)

`preview-tinted.svg` ist eine grobe Vorschau der Tinted-Erscheinung.
