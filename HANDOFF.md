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
- Es gibt kein globales Output-Event. Jede Pane hat aber ein `revision` in `pane.list`, damit lassen sich Änderungen erkennen.
- `pane.read` antwortet mit `{"type":"pane_read","read":{pane_id, text, revision, truncated, ...}}`. `format: "ansi"` liefert Truecolor-Sequenzen (`38;2;r;g;b`), `\r\n`-Zeilenenden.
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
4. Danach: `herdr-core` (Zustand, Event-Abo, Revisions-Abgleich, Terminal-Emulation über alacritty_terminal oder vt100), `herdr-ffi` (UniFFI), Mac-App mit SwiftUI.

## Hinweise für die nächste Session

- Git-Identität ist gesetzt (`Frank Neumann-Staude <frank@staude.net>`).
- Vault-Regeln aus `/Users/staude/Obsidian/Frank/CLAUDE.md` beachten (Schreibstil ohne Em-Dash, Rückfragen per AskUserQuestion, Daily Note mit frischem `date`).
- Gegen den laufenden herdr-Server nur lesende Methoden nutzen, solange Frank nichts anderes sagt. Dort laufen echte Agent-Sitzungen.
