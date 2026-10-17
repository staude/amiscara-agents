# herdr-remote-core - Projektregeln

## Zweck

Rust-Core für eine grafische herdr-Oberfläche auf iPad, iPhone, Mac und Windows. Spricht die Socket-API eines unveränderten herdr-Servers an, lokal oder per SSH-Streamlocal.

Konzept: Vault `02 Projekte/Herdr Remote.md`. Aktueller Stand und nächste Schritte: `HANDOFF.md`.

## Setup & Start

- Bauen: `cargo build`
- Tests: `cargo test`, Lint: `cargo clippy`, Format: `cargo fmt`
- Probe lokal: `cargo run -p herdr-spike -- list`
- Probe per SSH: `cargo run -p herdr-spike -- --ssh user@host --identity <key> bench`

## Besonderheiten

- Gegen einen produktiv genutzten herdr-Server nur lesende Methoden aufrufen (`ping`, `*.list`, `*.get`, `pane.read`, `events.subscribe`), außer es ist ausdrücklich anders gewünscht.
- Protokollversion steht in `herdr_proto::SUPPORTED_PROTOCOL` und wird bei `ping` geprüft.
- Aufbau orientiert sich an `~/dev/torromail` (Workspace-Lints, Edition 2024).
- Apple-Oberflächen kommen später nach `apps/`, Xcode-Projekt nur über xcodegen.
