# Übergabe: Herdr Remote, Stand 2026-10-17

Diese Datei fasst die Session zusammen, in der das Projekt entstanden ist (Claude-Desktop-App auf work). Eine neue Session liest sie zuerst und arbeitet von hier aus weiter.

## Ziel

Grafische Oberfläche für herdr (Agent-Multiplexer im Terminal, https://herdr.dev). Der herdr-Server auf work bleibt unverändert, die App ist ein weiterer Client. Bedienung auf iPad, iPhone, Mac und Windows mit Maus, Touch und Tastatur. Die Verfügbarkeit auf mehreren Plattformen ist das Alleinstellungsmerkmal.

Konzept und Entscheidungen: Vault-Notiz `/Users/staude/Obsidian/Frank/02 Projekte/Herdr Remote.md`.

## Entscheidungen

- Rust-Core (dieses Repo), SwiftUI für iPad, iPhone und Mac (UniFFI), Tauri 2 für Windows
- Transport: SSH (russh) mit `direct-streamlocal@openssh.com` direkt auf `herdr.sock`, auf work wird nichts installiert. Lokal der Unix-Socket.
- Aufbau nach dem Vorbild TorroMail (`~/dev/torromail`): Rust-Workspace, später `apps/` für die Oberflächen
- Xcode-Projekte nur über xcodegen (`project.yml`), siehe Vault-CLAUDE.md

## Erkenntnisse zur herdr-API (herdr 0.9.4/0.9.5, Protokoll 22)

- Socket `~/.config/herdr/herdr.sock` (0600). Newline-JSON `{"id","method","params"}`, Antwort `{"id","result"}` oder `{"id","error":{"code","message"}}`.
- **Pro Verbindung eine Anfrage**, danach schließt der Server. Ausnahme: `events.subscribe` hält die Verbindung offen, erst kommt `{"result":{"type":"subscription_started"}}`, dann ein Event pro Zeile.
- `pane.agent_status_changed`, `pane.output_matched` und `pane.scroll_changed` brauchen ein `pane_id` je Abo. Alle anderen Event-Typen gehen global (`GLOBAL_SUBSCRIPTIONS` in `herdr-proto`).
- Es gibt kein Output-Event: `pane_output_changed` steht im Schema, wird in 0.9.4 aber nie gesendet. `PaneInfo.revision` zählt nur Metadaten (Titel, Status), nicht den Inhalt, und `pane.read` liefert `revision` immer als 0. Der interne Inhaltszähler `content_revision` ist nur über Copy-Mode-Methoden sichtbar. Eine offene Pane muss deshalb per `pane.read` abgefragt und auf dem Client verglichen werden.
- `pane.read` antwortet mit `{"type":"pane_read","read":{pane_id, text, revision, truncated, ...}}`. `format: "ansi"` liefert einen fertig gerenderten Bildschirm: nur SGR-Sequenzen (`ESC[...m`, u. a. Truecolor `38;2;r;g;b`) und `\r\n`-Zeilenenden, keine Cursor-Bewegungen. Geprüft über alle Panes, sichtbar und mit 400 Zeilen Verlauf.
- Vollständiges Schema: `herdr api schema --json`. Agent-Anleitung: `herdr --skill`.
- Das interne Protokoll von `herdr-client.sock` (TUI-Attach) nicht verwenden.

## Stand des Codes

- `crates/herdr-proto`: Anfrage- und Antworttypen, Pong, Workspace, Pane, PaneRead, 3 Tests
- `crates/herdr-transport`: `Connection::local` und `Connection::ssh` (Schlüsseldatei oder SSH-Agent, known_hosts mit optionalem Trust on first use, Host-Zertifikate werden abgelehnt), `request`, `subscribe`
- `crates/herdr-spike`: CLI mit `ping`, `list`, `read <pane> [--ansi]`, `watch`, `bench`. Alles nur lesend.
- Build, Tests und clippy sind sauber. Nichts committet.

Messwerte lokal (Unix-Socket): `ping` im Mittel 0,2 ms, `pane.read ansi` mit 6,6 KB im Mittel 0,4 ms. Für die Live-Darstellung reicht lokal also erneutes Lesen pro Revision locker.

## Offene Schritte

1. **SSH-Test gegen work: erledigt am 2026-10-17, mit Befund.** Die Session läuft auf work selbst, getestet wurde deshalb gegen `127.0.0.1`. Die eigene Tailnet-IP (100.126.69.37) antwortet von work aus nicht auf Port 22.
   - Testschlüssel `~/.ssh/herdr_remote_spike` ist angelegt (Backup: `~/.ssh/authorized_keys.bak-herdr-remote-20261017`). Zeile: `restrict,port-forwarding,command="/usr/bin/false" ssh-ed25519 ... herdr-remote-spike`.
   - `restrict,port-forwarding` allein ließ `ssh -T host 'echo x'` durch. Erst `command="/usr/bin/false"` sperrt Shell und Exec, Streamlocal geht weiter.
   - Aufruf: `cargo run -p herdr-spike -- --ssh staude@127.0.0.1 --identity ~/.ssh/herdr_remote_spike --accept-new-host-key bench`
   - Ergebnis: Aufbau etwa 90 ms. `ping` n=50 min 2,5 ms, Mittel 100,5 ms. `pane.read ansi` (5,7 KB) Mittel 108,6 ms. Lokal per Socket 0,2 ms.
   - **Ursache der 100 ms liegt in herdr, nicht in SSH.** `bench` misst jetzt getrennt: Kanal öffnen 0,7 ms, `ping` auf dem offenen Kanal 104 ms. herdr liest die erste Anfragezeile nicht blockierend und schläft bei fehlenden Daten jeweils `CONNECTION_POLL_INTERVAL` = 100 ms (`src/api/server.rs`, `read_initial_request_line_with_limits`). Unverändert in 0.9.4, 0.9.5 und Master. Lokal fällt das nicht auf, weil die Anfrage direkt nach `connect` im Puffer liegt. Über SSH verbindet sshd den Socket schon beim Öffnen des Kanals, die Daten kommen erst danach. Gegenprobe lokal mit Pause zwischen Verbinden und Senden: 1 ms Pause ergibt 102 ms Antwortzeit, 50 ms Pause ergibt 50 ms.
   - Folgen: Jede Anfrage über SSH hat bis zu 100 ms Zusatzlatenz. Parallele Kanäle gehen, der Durchsatz ist also nicht begrenzt, nur die Latenz. `events.subscribe` zahlt das nur einmal beim Start. Für die Live-Darstellung heißt das: Revision per Event, `pane.read` parallel, Anzeige etwa 100 ms hinterher.
   - Saubere Lösung: Upstream-Fix in herdr (z. B. `poll(2)` mit Timeout statt `sleep`). Issue oder PR bei github.com/herdrdev/herdr nur nach Franks Freigabe. Entscheidung vom 2026-10-17: erst einmal weitermachen. Wird die Latenz in der Live-Ansicht ein ernstes Problem, das Thema wieder aufbringen.
   - Neu im Transport: `Connection::open_channel` und `request_on` (Kanal vorab öffnen). Im Spike nur für die getrennte Messung genutzt.
   - Offen: derselbe Test vom MacBook Air über das NetBird-Tailnet.
2. Die Marktbegleiter-Recherche lief in einem Hintergrund-Agenten. Ergebnis: `docs/marktbegleiter.md`, sobald fertig. Daraus Lessons für die Oberfläche ins Vault-Konzept übernehmen.
3. Projekt-Infrastruktur nach `Projekt-Standards` (Vault `00 Kontext/`): privates GitHub-Repo, Issues pro Aufgabe, CHANGELOG, CI. GitHub-Repo erst nach Rückfrage anlegen. Lokal angelegt am 2026-10-17: README, CHANGELOG, Lizenzdateien (MIT oder Apache-2.0), `setup.sh`, `.github/workflows/ci.yml` (fmt, clippy, Tests auf Linux, macOS, Windows). Der lokale Socket ist jetzt `cfg(unix)`, damit Windows baut. Der Windows-Build ist lokal nicht prüfbar (aws-lc-sys braucht das Windows-SDK), das übernimmt die CI.
4. **herdr-core, Teil 1 (Issue #1, Branch `feature/1-session-state`):** `SessionState` aus `session.snapshot` plus Events, Board nach Dringlichkeit, Sync-Treiber mit globalem Abo, Status-Abo pro Pane, gesammeltem Neu-Snapshot bei Strukturänderungen und Reconnect mit Backoff. `herdr-spike board` zeigt das Board live, lokal und per SSH getestet. Live-Events und Reconnect sind nur per Unit-Test geprüft, weil während der Session keine anderen Agents liefen.
   - Wichtig zum Event-Format: Globale Events kommen als `{"event":"pane_created","data":{"type":"pane_created",...}}`, Abos pro Pane als `{"event":"pane.agent_status_changed","data":{...}}` ohne `type`. herdr bedient jeden Abo-Typ in eigener Schleife (100 ms Takt), die Reihenfolge über Typen hinweg ist nicht garantiert. Deshalb gibt es bei Strukturänderungen einen neuen Snapshot statt Einzel-Updates.
   - `Subscription::next` ist nicht abbruchsicher, im Core liest jedes Abo in einer eigenen Task.
5. **Pane-Inhalt (Issue #2, Branch `feature/2-terminal-emulation`):** Kein Terminal-Emulator, sondern ein SGR-Parser (`herdr-core::terminal`), der den Text in Zeilen aus gleich gestylten Abschnitten zerlegt. Passt direkt auf `AttributedString` und Web-Spans. `herdr-core::pane::follow` fragt die offene Pane per `pane.read` ab, 150 ms bei Änderungen, bis 1 s bei Ruhe. `herdr-spike check` vergleicht den geparsten Text aller Panes mit herdrs Textfassung (alle gleich, 0,35 bis 1 ms pro Bildschirm im Debug-Build), `herdr-spike view <pane>` folgt einer Pane live.
6. **herdr-ffi, Mac-App, Release (Issues #7, #8, #9; PRs #10, #11, #12, gestapelt, in dieser Reihenfolge mergen):**
   - `herdr-ffi` mit UniFFI 0.32.2: `HostSession` mit `SessionObserver`, `followPane` mit `PaneObserver`, Schlüssel erzeugen, `authorized_keys`-Zeile. `scripts/build-ffi.sh` baut `HerdrFFI.xcframework` und die Swift-Bindings nach `apps/HerdrRemote/Generated` (nicht eingecheckt).
   - Transport: Schlüssel aus dem Speicher, fest hinterlegter Host-Key, Fehler `UnknownHostKey`/`HostKeyChanged` mit Fingerprint. Sync stoppt bei Fehlern, die eine Entscheidung brauchen, und teilt seine Verbindung mit dem Pane-Follower.
   - Mac-App `apps/HerdrRemote`: SwiftUI, macOS 27, `net.staude.herdrremote`, Schlüssel pro Host in der Keychain, Host-Key-Abfrage, Seitenleiste, Board über alle Hosts, Live-Pane. Nur lesend.
   - Geprüft per `scripts/ffi-smoke.sh` (lokal und SSH inkl. Host-Key-Ablauf). Die Oberfläche selbst und die Keychain sind noch nicht durchgeklickt, der Session fehlte die Bildschirmaufnahme-Berechtigung.
   - `scripts/release.sh` für Developer ID und Notarisierung. Es fehlen noch das Developer-ID-Application-Zertifikat und das notarytool-Profil, siehe `docs/release.md`.
   - Sicherheitsbefund: `port-forwarding` im `authorized_keys`-Eintrag erlaubt auch TCP-Weiterleitung. `permitopen` hilft nicht, weil sshd damit auch den Streamlocal-Kanal ablehnt (getestet). Einziger Weg: `AllowTcpForwarding no` in `sshd_config`, betrifft alle Logins. Entscheidung bei Frank.
7. **Eingaben (Issue #14):** `herdr-core::actions` (`agent.prompt`, `pane.send_keys`, `pane.send_text`), FFI-Methoden, in der App Schalter „Eingaben erlauben“ pro Host (Standard an) und Eingabeleiste unter der Pane: Antwortzeile bei `blocked` (1, 2, 3, Enter, Esc), Tastenleiste, Eingabefeld. Getestet nur gegen die Test-Session `herdr-remote-test` (Text plus Enter kommt an, Prompt an eine Shell und ungültige Tasten werden abgelehnt). Den Freigabe-Ablauf mit echtem Agent testet Frank per Klick.
8. **iPad und iPhone (Issue #16):** Target `HerdrRemote-iOS` (iOS 27) mit denselben Quellen, `Platform.swift` für die Unterschiede, Board als Startansicht auf dem iPhone, sofortiger Reconnect beim Wechsel in den Vordergrund. XCFramework mit drei Slices. Baut für Gerät und Simulator; der Simulator startet auf work nicht (CoreSimulator veraltet), Installation und Klicktest macht Frank am Gerät (Befehle im README).
9. **Aufbau wie herdr (Issue #24):** zwei Spalten statt drei. Seitenleiste pro Host mit „Spaces“ (Worktrees eingerückt) und „Agents“ („Space · Tab“), rechts Tab-Reiter, Pane-Auswahl bei geteilten Tabs, Terminal und Eingabe. Auslöser war Franks erster iPad-Test: Board und Seitenleiste zeigten die Agents doppelt, zwei Spaces hießen „enon“. Den Git-Branch zeigt herdr selbst an, die API liefert ihn nicht.
10. Danach: Benachrichtigungen (lokal auf dem Mac, später Push aufs iPhone), Release einrichten, Windows mit Tauri.

## Hinweise für die nächste Session

- Git-Identität ist gesetzt (`Frank Neumann-Staude <frank@staude.net>`).
- Vault-Regeln aus `/Users/staude/Obsidian/Frank/CLAUDE.md` beachten (Schreibstil ohne Em-Dash, Rückfragen per AskUserQuestion, Daily Note mit frischem `date`).
- Gegen den laufenden herdr-Server nur lesende Methoden nutzen, solange Frank nichts anderes sagt. Dort laufen echte Agent-Sitzungen.
