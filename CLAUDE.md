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
- Mac-App unter `apps/HerdrRemote`, Xcode-Projekt nur über xcodegen (`project.yml`), `.xcodeproj` und `Generated/` sind nicht eingecheckt.
- App bauen: `./setup.sh` einmal, danach `xcodebuild -project apps/HerdrRemote/HerdrRemote.xcodeproj -scheme HerdrRemote -derivedDataPath target/xcode build`. Der Pre-Build-Schritt ruft `scripts/build-ffi.sh`.
- Bindings ohne UI prüfen: `scripts/ffi-smoke.sh` (lokal), mit `HERDR_SMOKE_SSH=user@host HERDR_SMOKE_KEY=<key>` zusätzlich der SSH- und Host-Key-Ablauf.
- `MACOSX_DEPLOYMENT_TARGET` nicht für den Rust-Build setzen: Mit 27.0 lassen sich die Proc-Macro-Dylibs nicht mehr laden.
