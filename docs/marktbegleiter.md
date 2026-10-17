# Marktbegleiter: Remote-Clients für herdr und KI-Coding-Agenten

Stand: 17.10.2026 · Recherche nur im Web, keine App installiert.
Legende: **[F]** = belegte Angabe aus Listing, Doku oder Review · **[I]** = eigene Schlussfolgerung

## Die gesuchte App („Herdr Tab“ / „hört da ab“)

[I] Am wahrscheinlichsten ist **herdrup**, gesprochen „herdr up“, was nach „hört da ab“ klingt. Infrage kommen auch **Heeler for herdr** und **Herdy**. Alle drei sind native iOS-Clients speziell für herdr. Ein offizielles GUI- oder Mobile-Angebot gibt es in der herdr-Doku nicht [F] ([llms.txt](https://herdr.dev/llms.txt)).

## Die Wettbewerber im Einzelnen

**1. herdrup** · iPhone/iPad, als iPad-App auch auf Apple-Silicon-Macs · kostenlos, Apache-2.0 [F] ([Wiki](https://github.com/jerryfane/herdrup/wiki))
- Verbindung: SSH in reinem Swift (swift-nio-ssh/Citadel). Push läuft über ein herdrup-Relay. **Nötig ist der herdr-Fork jerryfane/herdr** (Gram-, Push- und Live-Terminal-APIs). Der Umstieg verlangt einen Neustart von herdr, dabei werden die laufenden Agenten beendet [F].
- Gut: Status-Board mit den Gruppen Needs you / Working / Done / Stopped. Feste Farbcodes (amber, blau, grün, rot) auf dunklem Navy. SwiftTerm-Terminal mit Suche, Resize und Anzeige der Tipp-Latenz. „Gram“ ist ein Chat mit dem Agenten. Gastzugang per Einmal-QR [F].
- Schwach [I]: Die Abhängigkeit vom Fork ist die größte Hürde. Push-Texte laufen über einen fremden Server.

**2. Heeler for herdr** · iPhone/iPad, Mac als iPad-App · kostenlos, Apache-2.0 · 5,0★ bei 10 Bewertungen · v0.1.14 [F] ([App Store](https://apps.apple.com/us/app/id6797263135), [bitdoze](https://www.bitdoze.com/md/best-herdr-clients.md))
- Verbindung: herdr-JSON-API über SSH `direct-streamlocal` direkt auf `herdr.sock`. Keine offenen Ports, kein Fork. Ab herdr 0.7.5, dazu ein Plugin für QR-Pairing und Push [F].
- Gut: Eine Konsole für alle Hosts, sortiert nach Priorität (Blocked zuerst). libghostty-Terminal mit nativem Scrollback. Nativer Composer mit Autokorrektur, IME, Diktat und Anhängen (SFTP bis 64 MiB). E2E-verschlüsselter Push und Live Activities. Worktree-Launch, Jump-Hosts, Tailscale/ZeroTier, Multi-Route-Hosts [F].
- Kritik aus Reviews [F]: Claude meldet „done“, obwohl noch ein Shell-Befehl auf Antwort wartet. Codex-Freigaben sind umständlich. Agenten und Sessions lassen sich in der App nicht umbenennen. Gespeicherte Hosts springen bei Host-Key-Wechsel oder MFA auf „Attention“.
- [I] Kommt dem geplanten Konzept am nächsten und ist der direkte Wettbewerber.

**3. Herdy – Your herdr companion** · iPhone/iPad, Mac M1 als iPad-App · 2,99 $ · noch keine Bewertungen [F] ([App Store](https://apps.apple.com/us/app/id6807917079))
- SSH oder Mosh, kein Relay, kein Account. Session-Liste mit Start, Wechsel, Resume und Stop. Terminal, Diktat, Anhänge [F].
- [I] Eher ein Terminal mit Session-Picker. Ein Status-Board oder Push wird nicht erwähnt.

**4. Moshi** („Moshi: herdr/tmux on SSH/MOSH“) · iPhone, iPad, Watch, Vision Pro, Android · Desktop-App mit Tauri für macOS, Windows und Linux · Freemium, Pro 7,99 $/Monat bzw. 69,99 $/Jahr, Lifetime 249 $ · **4,7★ bei 568 Bewertungen** [F] ([App Store](https://apps.apple.com/app/id6757859949), [herdr-Guide](https://getmoshi.app/guides/herdr))
- Verbindung: SSH, Mosh nur in Pro. Ein `moshi-hook` auf dem Host liefert Events und Push [F].
- Gut: Inbox als Kanban (Needs you / Working / Done) wie in der herdr-Sidebar. Freigaben vom Sperrbildschirm, der Watch und der Dynamic Island. Workspace-Picker beim Verbinden. „Open terminal“ springt in den richtigen Tab. Shortcut-Panel mit herdr-Tasten. Gesten: 1 Finger wechselt den Tab, 2 Finger Pane oder Workspace, Pinch zoomt. Whisper-Diktat on-device [F].
- Kritik [F]: Der Hook blockiert lokale Freigabe-Prompts bis zum Timeout. Das Freigabe-Sheet ist für ein simples Ja/Nein zu schwer. „Open terminal“ funktionierte nicht. Die herdr-Funktionen kosten Geld.
- [I] Marktführer nach Reichweite und Vorbild für Push und Approvals.

**5. Happy (Coder)** · iPhone/iPad · Freemium, Plus 19,99 $/Monat · 4,9★ bei ca. 1.000 Bewertungen [F] ([App Store](https://apps.apple.com/us/app/id6748571505))
- Verbindung: CLI oder Desktop-App auf dem Rechner, E2E-verschlüsseltes Cloud-Relay (selbst hostbar), Pairing per QR [F].
- Gut: Diffs mit Dateiliste, Auswahl von Modell und Reasoning-Effort, Gruppierung nach Projekt, Entwürfe synchron zwischen Phone und Rechner, Foto als Prompt [F].
- Kritik [F]: Wirkt unpoliert, Breaking Changes, Navigationsbugs. Alte Chats brauchen „Minuten zum Aufholen“.

**6. Claude App mit Remote Control (Anthropic)** · iOS, Android, Web · ab Claude Pro [F] ([Doku](https://code.claude.com/docs/en/remote-control))
- Verbindung: Ausgehendes HTTPS über die Anthropic-API, keine Inbound-Ports. Server-Modus mit bis zu 32 Sessions, Worktree-Spawn [F].
- Kritik [F]: „Message could not be sent“ in der iOS-App, QR öffnet einen Chat statt der Session, Verbindungsabbrüche ([Issue](https://claudeissues.com/issue/41670-bug-remote-control-does-not-work-on-iphone-17pro-within-claude-app-code), [HN](https://hn.nuxt.dev/item/47148454)). Funktioniert nur mit Claude.

**7. Omnara** · iOS, Web, Watch · Freemium · 4,3★ bei 18 Bewertungen [F] ([Review](https://aicoolies.com/reviews/omnara-review)). Logs, Diffs, One-Tap-Approvals, Handoff vom Desktop. Cloud-Account. Laut Privacy-Label werden Daten mit der Identität verknüpft [F].

**8. Tactic Remote** · iOS/macOS · kostenpflichtig. Node-Server mit tmux, WebSocket über LAN (Bonjour) oder Cloudflare Tunnel. Y/N-Toolbar, Snippets. Laut eigenem Blog brechen Sessions ab, wenn iOS die App suspendiert [F] ([Blog](https://tacticremote.com/blog/2026-02-28-best-ios-apps-for-remote-ai-coding-agents)).

**Desktop und Web rund um herdr** [F] ([bitdoze](https://www.bitdoze.com/md/best-herdr-clients.md)):
- **herdrm**: SwiftUI und SwiftTerm für macOS, SSH. Sidebar mit Spaces und Agents, ⌘K-Suche.
- **Herdr UI**: GPUI, nur mit lokalem Daemon.
- **ColliePWA**: Inbox mit Blocked zuerst, Quick-Replies, Auth über Tailnet und Pairing-Tokens.
- **herdrweb**: echte RPCs wie `pane.read` und `agent.prompt`, Shiki-Diffs, aber ohne Auth.
- **Sherpr**: nur Android. SSH, lokale Notifications ohne Push-Provider.

Termius und Blink bieten solides SSH/Mosh, kennen aber keine Agenten und haben keinen Push [F].

## Vergleichstabelle

| App | Plattformen | Preis | Verbindung | Host-Komponente | Board | Push/Approve | Bewertung |
|---|---|---|---|---|---|---|---|
| herdrup | iOS/iPadOS (+Mac) | gratis | SSH + Push-Relay | **herdr-Fork** | ja | ja | – |
| Heeler | iOS/iPadOS (+Mac) | gratis | SSH → herdr.sock | Plugin | ja | E2E, Live Act. | 5,0 (10) |
| Herdy | iOS/iPadOS (+Mac) | 2,99 $ | SSH/Mosh | keine | Liste | nein? | – |
| Moshi | iOS, Watch, Android, Desktop | Freemium | SSH/Mosh + Hook | moshi-hook | Kanban | ja, Watch/DI | 4,7 (568) |
| Happy | iOS/iPadOS | Freemium | Cloud-Relay E2E | CLI | Liste | ja | 4,9 (~1k) |
| Claude RC | iOS/Android/Web | Abo | Anthropic-Relay | keine | Liste | teils | Bugs |
| Omnara | iOS/Web/Watch | Freemium | Cloud | CLI | ja | ja | 4,3 (18) |
| Tactic Remote | iOS/macOS | kostenpflichtig | WS/LAN/CF-Tunnel | Node | – | ja | – |

[I] Keiner der Clients deckt iPhone, iPad, Mac **nativ** und Windows zugleich ab. Moshi kommt mit seinen getrennten Mobile- und Desktop-Apps am nächsten.

## Lehren, die man übernehmen sollte

1. **Triage zuerst**: Die Übersicht sortiert Blocked, dann Working, dann Done, dann Idle, in festen Statusfarben (Heeler, herdrup, Moshi, Collie).
2. **Leichte Freigaben**: Approve/Deny direkt in der Notification, als Live Activity oder auf der Watch. Kein schweres Sheet (siehe Kritik an Moshi).
3. **Deep Link**: Ein Tipp auf die Notification öffnet genau den passenden Pane-Tab, und das muss zuverlässig klappen.
4. **Nativer Composer** mit Autokorrektur, Diktat und Anhängen, getrennt vom Terminal. Dazu eine Tastenleiste (Esc, Tab, Ctrl, Pfeile) und Quick-Replies.
5. **Echtes Terminal** (libghostty oder SwiftTerm) mit Scrollback und Suche, einen Tipp entfernt.
6. **Direkt-SSH auf `herdr.sock`** wie bei Heeler: kein Fork, kein Relay, QR-Pairing, Schlüssel in der Keychain, Jump-Hosts und Tailscale.
7. **iPad und Mac** mit Sidebar, ⌘K-Suche und mehreren Hosts in einer Ansicht (herdrm).
8. **Umbenennen** von Agenten und Sessions in der App (Review-Wunsch bei Heeler).

## Fallstricke, die man vermeiden sollte

- **Abhängigkeit von einem herdr-Fork** (herdrup). Stattdessen nur die offizielle Socket-API nutzen und die Version prüfen.
- **Transcripts per Screen-Scraping auslesen**: Das bricht, sobald sich die Agent-UI ändert (herdr-web-ui). Besser echte RPCs verwenden.
- **Falscher Status**: „done“, obwohl der Agent noch wartet (Heeler). Den Status von herdr übernehmen, nicht raten.
- **Hooks, die lokale Prompts blockieren** (Moshi). Den Desktop-Flow nie stören.
- **Langsamer Verlauf**: Happy braucht Minuten zum Aufholen. Besser inkrementell laden und puffern.
- **Verbindungsverlust beim Suspend unter iOS** (Tactic, Claude RC). Lösungen sind ein schneller Reconnect mit Resume und Push über APNs statt einer offenen Verbindung. [I] Für Push ohne Relay braucht es trotzdem einen APNs-Sender. Optionen: ein E2E-verschlüsselter Minimal-Dienst wie bei Heeler oder lokale Notifications im Hintergrund.
- **Undurchsichtige Paywall** für Kernfunktionen (Moshi Pro) und zu dünne Auth (herdrweb ohne Auth).
