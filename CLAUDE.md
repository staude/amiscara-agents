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

- Gegen einen produktiv genutzten herdr-Server nur lesende Methoden aufrufen (`ping`, `*.list`, `*.get`, `pane.read`, `session.snapshot`, `events.subscribe`), außer es ist ausdrücklich anders gewünscht.
- Schreibende Methoden (`agent.prompt`, `pane.send_keys`, `pane.send_text`, Anlegen von Workspaces) nur gegen eine eigene Test-Session testen: `herdr --session herdr-remote-test server` startet einen getrennten Server mit Socket `~/.config/herdr/sessions/herdr-remote-test/herdr.sock`. Danach `herdr session stop herdr-remote-test`.
- Protokollversion steht in `herdr_proto::SUPPORTED_PROTOCOL` und wird bei `ping` geprüft.
- Aufbau orientiert sich an `~/dev/torromail` (Workspace-Lints, Edition 2024).
- App unter `apps/HerdrRemote` mit zwei Targets aus denselben Quellen: `HerdrRemote` (macOS 27) und `HerdrRemote-iOS` (iOS 27, iPhone und iPad). Xcode-Projekt nur über xcodegen (`project.yml`), `.xcodeproj` und `Generated/` sind nicht eingecheckt. Plattform-Unterschiede gebündelt in `Platform.swift`.
- App bauen: `./setup.sh` einmal, danach `xcodebuild -project apps/HerdrRemote/HerdrRemote.xcodeproj -scheme HerdrRemote -derivedDataPath target/xcode build`. Das Aggregate-Target `HerdrFFI` ruft `scripts/build-ffi.sh` vor beiden App-Targets; fehlt das Framework, baut `xcodegen generate` es einmal (`postGenCommand`).
- Aufs iPad oder iPhone: `scripts/install-ios.sh` (findet das angeschlossene Gerät, baut, installiert per `devicectl`, startet ohne Debugger).
- Bindings ohne UI prüfen: `scripts/ffi-smoke.sh` (lokal), mit `HERDR_SMOKE_SSH=user@host HERDR_SMOKE_KEY=<key>` zusätzlich der SSH- und Host-Key-Ablauf.
- `MACOSX_DEPLOYMENT_TARGET` nicht für den Rust-Build setzen: Mit 27.0 lassen sich die Proc-Macro-Dylibs nicht mehr laden. Für die iOS-Slices setzt `build-ffi.sh` dagegen `IPHONEOS_DEPLOYMENT_TARGET=27.0`, sonst baut aws-lc für 27.1 und der Linker warnt. Nach einer Änderung daran `cargo clean -p aws-lc-sys --target <ios-triple>`.
- Skripte, die Xcode ausführt, laufen mit `/bin/bash` 3.2: keine leeren Arrays unter `set -u` ohne `${a[@]+"${a[@]}"}`. Xcode-Builds zum Prüfen mit minimalem PATH starten: `env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild ...`.
- Der iOS-Simulator lässt sich auf work nicht starten (CoreSimulator veraltet), Bauen für den Simulator geht.
