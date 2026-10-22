# Release der Apple-Apps

Die Mac-App wird außerhalb des App Stores verteilt: mit Developer ID signiert, von Apple notarisiert, das Ticket angeheftet (`scripts/release.sh`). Die Apps für iPhone, iPad, Apple Watch und Apple TV gehen über TestFlight (`scripts/testflight.sh`). Beides läuft lokal auf einem Mac mit Xcode oder in GitHub Actions (`.github/workflows/apple-release.yml`, siehe [CI](#ci)).

## Einmalige Einrichtung

1. **Developer-ID-Zertifikat anlegen.** In developer.apple.com unter Certificates ein Zertifikat vom Typ „Developer ID Application“ für das Team `7N2W4T6UPV` erzeugen, herunterladen und per Doppelklick in den Anmelde-Schlüsselbund importieren. Danach muss es hier auftauchen:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   Das vorhandene „Apple Development“-Zertifikat reicht nur für lokale Testbuilds.

2. **App-spezifisches Passwort** auf appleid.apple.com erzeugen (Anmelden und Sicherheit, App-spezifische Passwörter), Name z. B. `notarytool AmiscaraAgents`.

3. **Notarisierungsprofil speichern.** Das Passwort landet im Schlüsselbund, nicht im Repo:

   ```sh
   xcrun notarytool store-credentials AmiscaraAgents \
       --apple-id <apple-id> --team-id 7N2W4T6UPV
   xcrun notarytool history --keychain-profile AmiscaraAgents
   ```

   Ein Profil aus der Zeit vor der Umbenennung (`HerdrRemote`) funktioniert weiter mit `NOTARY_PROFILE=HerdrRemote scripts/release.sh`.

4. **Sparkle-Schlüssel erzeugen** (einmal, für die Updates, siehe [Updates der Mac-App](#updates-der-mac-app)). Das Werkzeug kommt mit dem Sparkle-Paket, nach dem ersten Xcode-Build liegt es unter `target/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin`:

   ```sh
   target/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account amiscara-agents
   ```

   Der private Schlüssel bleibt im Anmelde-Schlüsselbund (Eintrag „amiscara-agents“), nie im Repo. Den ausgegebenen öffentlichen Schlüssel in `apps/AmiscaraAgents/project.yml` bei `SUPublicEDKey` statt `__SPARKLE_PUBLIC_KEY__` eintragen, `xcodegen generate` ausführen und beides (`project.yml`, `Info.plist`) committen. Den Schlüssel nie ersetzen: Installierte Apps nehmen nur Updates an, die mit ihm signiert sind. Eine eigene Sicherung (`generate_keys --account amiscara-agents -x <datei>`) gehört in den Passwortmanager.

## Release bauen

```sh
scripts/bump-build.sh          # Build-Nummer +1, nie zurücksetzen
git commit -am "chore(release): build N"
scripts/release.sh             # oder --install für /Applications
```

`release.sh` prüft zuerst Zertifikat, Notarisierungsprofil, xcodegen und einen sauberen Git-Stand und bricht sonst ab, bevor gebaut wird. Danach:

1. Rust-Core (`scripts/build-ffi.sh release`) und Xcode-Projekt (`xcodegen generate`)
2. Archiv (`xcodebuild archive`, Release)
3. Export mit Developer ID (`scripts/ExportOptions.plist`), Hardened Runtime
4. Notarisierung (`notarytool submit --wait`) und `stapler staple`
5. Prüfung: `codesign -dv`, `spctl -a -t exec`, `stapler validate`
6. Sparkle-Feed (`scripts/sparkle-feed.sh`): das Zip mit dem Sparkle-Schlüssel signieren (`sign_update`) und `appcast.xml` schreiben (`scripts/appcast.py`). In der CI ist das ein eigener Schritt nach dem Build, damit der Schlüssel weder Xcode noch Cargo oder Swift-Pakete erreicht.

Ergebnis: `target/release-app/AmiscaraAgents-<version>-<build>.zip` und `target/release-app/appcast.xml`. `release.sh` bricht vorher ab, solange `SUPublicEDKey` noch der Platzhalter ist.

Lokal gebaut, veröffentlicht man so (der Feed verweist auf das Zip im Release `apple-v<version>`):

```sh
gh release create apple-v<version> target/release-app/AmiscaraAgents-*.zip --title "Amiscara Agents <version> (Mac)"
gh release upload updates target/release-app/appcast.xml --clobber
```

## Updates der Mac-App

Die Mac-App sucht mit [Sparkle](https://sparkle-project.org) nach Updates, wie Kastellan und TorroMail: beim Start und danach alle 24 Stunden, oder über „Amiscara Agents › Nach Updates suchen …“ und in den Einstellungen unter „Updates“. Ein neues Update lädt im Hintergrund und wird beim nächsten Beenden installiert; in den Einstellungen lässt sich die automatische Suche abschalten.

- Feed: `https://github.com/staude/amiscara-agents/releases/download/updates/appcast.xml`. Der Release `updates` (Vorabversion, wird nie „Latest“) sammelt die Feeds aller Apps, auch `latest.json` der Desktop-App. So stört es nicht, dass Mac- und Desktop-Versionen getrennte Tags haben (`apple-v*`, `desktop-v*`).
- Sparkle vergleicht die Build-Nummer (`CFBundleVersion`). Releases kommen darum aus der CI (`<CURRENT_PROJECT_VERSION>.<Lauf>.<Versuch>`) oder lokal nach `scripts/bump-build.sh`, nie zweimal mit derselben Nummer.
- Debug-Builds und Builds mit dem Platzhalter-Schlüssel suchen nicht nach Updates, damit sich ein Entwickler-Build nie durch ein Release ersetzt.

## Warum keine Sandbox

Die App liest `~/.config/herdr/herdr.sock` und öffnet SSH-Verbindungen zu beliebigen Hosts. Die App Sandbox würde beides blockieren. Für den App Store bräuchte es eine andere Lösung (z. B. Security-Scoped Bookmarks für den Socket), das ist erst Thema, wenn eine Store-Version ansteht.

## TestFlight (iPhone, iPad, Watch, Apple TV)

```sh
scripts/bump-build.sh          # jede hochgeladene Build-Nummer gibt es nur einmal
git commit -am "chore(release): build N"
scripts/testflight.sh          # oder: ios, tvos
```

Das Skript baut die Rust-Slices (`iphoneos`, `appletvos`), archiviert `AmiscaraAgents-iOS` (mit der Watch-App) und `AmiscaraAgents-tvOS` und lädt beide mit `scripts/ExportOptions-TestFlight.plist` hoch. Lokal meldet sich Xcode mit dem Account aus Xcode › Einstellungen › Accounts an. Vorher muss der App-Eintrag in App Store Connect existieren, und das CloudKit-Schema muss in Production deployt sein, sonst sehen TestFlight-Builds keine Daten.

## CI

`.github/workflows/apple-release.yml` baut beides auf GitHubs Runner `xcode-27` (Vorschau-Image mit Xcode 27.1 und den SDKs für macOS 27, iOS 27 und tvOS; das Image `macos-26` hat nur Xcode 26):

- **mac:** `scripts/release.sh` mit API-Key, Ergebnis als Workflow-Artefakt `amiscara-agents-mac`.
- **testflight:** `scripts/testflight.sh` für iOS und tvOS.

Starten von Hand unter Actions › Apple release › Run workflow oder

```sh
gh workflow run apple-release.yml -f target=both   # mac, testflight oder both
```

Ein Tag `apple-v<MARKETING_VERSION>` (z. B. `apple-v0.1.0`) startet beides, veröffentlicht das Mac-Zip als Release in diesem Repo und ersetzt danach `appcast.xml` im Release `updates`: Ab dann bekommen installierte Mac-Apps das Update. Die Build-Nummer ist in der CI `<CURRENT_PROJECT_VERSION>.<Lauf>.<Versuch>`, z. B. `1.14.1`, ohne Commit. Sie liegt damit immer über der lokalen Nummer `1`; wer danach lokal hochlädt, setzt `CURRENT_PROJECT_VERSION` vorher mit `scripts/bump-build.sh` höher.

### Einmalige Einrichtung für die CI

Alle Daten liegen als Secrets in der GitHub-Umgebung `apple-release`, nie im Repo. Pull Requests und Forks kommen nicht an sie heran.

1. **App-Store-Connect-API-Key anlegen.** In App Store Connect unter Benutzer und Zugriff › Integrationen › App Store Connect API › Team-Schlüssel einen Schlüssel erzeugen:
   - Rolle **Admin**, wenn die CI ohne hinterlegte Zertifikate signieren soll (Xcode-Cloud-Signierung legt dann verwaltete Zertifikate an; das darf nur Admin).
   - Rolle **App-Manager** reicht, wenn die Zertifikate als `.p12` hinterlegt werden (Schritt 2 und 3). Profile legt Xcode damit selbst an.
   - Die `.p8`-Datei lässt sich nur einmal herunterladen. Key-ID und Issuer-ID stehen auf derselben Seite.
   - Derselbe Schlüssel meldet `notarytool` an, ein App-spezifisches Passwort braucht die CI nicht.

2. **Developer-ID-Zertifikat** (für die Mac-App): wie oben unter „Einmalige Einrichtung“ Schritt 1 anlegen und importieren. Nur der Account Holder darf es erzeugen. Danach in der Schlüsselbundverwaltung unter „Meine Zertifikate“ das Zertifikat „Developer ID Application: … (7N2W4T6UPV)“ samt privatem Schlüssel als `.p12` mit Passwort exportieren.

3. **Apple-Distribution-Zertifikat** (für TestFlight, optional): ist eins im Schlüsselbund (`security find-identity -v -p codesigning | grep "Apple Distribution"`), genauso als `.p12` exportieren. Fehlt es, legt Xcode bei einem lokalen `scripts/testflight.sh` eines an.

4. **Secrets setzen** (fragt die `.p12`-Passwörter verdeckt ab und schreibt nichts auf die Platte):

   ```sh
   target/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account amiscara-agents -x ~/Desktop/sparkle-key
   scripts/apple-ci-secrets.sh --key-id <Key-ID> --issuer-id <Issuer-ID> \
       --key ~/Downloads/AuthKey_<Key-ID>.p8 \
       --devid ~/Desktop/developer-id.p12 --dist ~/Desktop/apple-distribution.p12 \
       --sparkle ~/Desktop/sparkle-key
   ```

   Danach `.p8`, `.p12` und `sparkle-key` sicher ablegen (Passwortmanager) und aus Downloads und Schreibtisch löschen.

5. **Umgebung prüfen.** Das Skript legt die Umgebung gleich mit ihren Regeln an, bevor es Secrets speichert: Nur `main` und Tags `apple-v*` dürfen sie benutzen. Unter Settings › Environments › `apple-release` › „Deployment branches and tags“ nachsehen. Der Workflow selbst läuft auf anderen Branches ebenfalls nicht.
6. **Tags schützen.** Unter Settings › Rules › Rulesets ein Tag-Ruleset für `apple-v*` und `desktop-v*` anlegen (Ziel: Tags, Regeln „Restrict creations“, „Restrict updates“, „Restrict deletions“, Ausnahme nur für Admins). Der Workflow prüft zusätzlich, dass der Commit eines Tags auf `main` liegt, und bricht sonst ab, bevor er die Signierdaten liest.
7. **Erster Lauf:** `gh workflow run apple-release.yml -f target=mac`, danach `-f target=testflight`.

Secrets: `SPARKLE_ED_PRIVATE_KEY` (signiert die Updates), `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8`, `KEYCHAIN_PASSWORD` (zufällig, schützt nur den temporären Schlüsselbund im Runner), optional `APPLE_DEVID_P12` und `APPLE_DEVID_P12_PASSWORD`, `APPLE_DIST_P12` und `APPLE_DIST_P12_PASSWORD`.

`xcode-27` ist bei GitHub noch ein Vorschau-Image. Sobald es ein reguläres Image mit Xcode 27 gibt, `runs-on` und `XCODE_APP` im Workflow anpassen.
