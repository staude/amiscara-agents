# Release der Mac-App

Die App wird außerhalb des App Stores verteilt: mit Developer ID signiert, von Apple notarisiert, das Ticket angeheftet. Alles läuft über `scripts/release.sh`, Xcode muss installiert sein, aber nicht geöffnet werden.

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

Ergebnis: `target/release-app/AmiscaraAgents-<version>-<build>.zip`.

## Warum keine Sandbox

Die App liest `~/.config/herdr/herdr.sock` und öffnet SSH-Verbindungen zu beliebigen Hosts. Die App Sandbox würde beides blockieren. Für den App Store bräuchte es eine andere Lösung (z. B. Security-Scoped Bookmarks für den Socket), das ist erst Thema, wenn eine Store-Version ansteht.

## CI

GitHub-Runner haben noch kein Xcode mit macOS-27-SDK. Die CI prüft den Rust-Teil auf Linux, macOS und Windows, die App wird lokal gebaut.
