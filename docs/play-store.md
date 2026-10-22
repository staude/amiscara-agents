# Google Play

What the Play Console needs for the Android app (`apps/android`), and the
order of the steps. Package name `net.staude.amiscara.agents`; it is fixed
after the first upload.

## Steps

1. Developer account (personal) with identity check.
2. Upload key: `scripts/android-upload-key.sh` once. Back up the keystore
   (`~/.android/amiscara-agents-upload.p12`) and its password (Keychain
   item `amiscara-agents-upload`) like the updater key of the desktop app.
3. Create the app in the Play Console, opt in to Play App Signing (Google
   keeps the app signing key, the upload key above only proves uploads).
4. Fill in the listing, the content rating questionnaire, the data safety
   form, the privacy policy URL and the foreground service declaration
   (texts below).
5. `scripts/android-release.sh 0.1.0`: raises `versionCode`, builds the
   signed bundle `apps/android/app/build/outputs/bundle/release/app-release.aab`,
   commits and tags `android-v0.1.0`. Upload it to the internal test track.
6. Closed test: a personal account created after November 2023 needs at
   least 12 testers who stay opted in for 14 days before it may apply for
   production.
7. Production.

## Listing (German)

- **Name:** Amiscara Agents
- **Short description (80):** Coding-Agents in herdr steuern: sehen, wer
  wartet, antworten, Prompts senden.
- **Description:**

  Amiscara Agents ist die mobile Oberfläche für herdr, den Terminal-Manager
  für Coding-Agents wie Claude Code und Codex. Die App verbindet sich per
  SSH mit Ihren eigenen Rechnern und zeigt Spaces, Tabs und Agents so, wie
  herdr sie führt.

  - Sehen, welcher Agent wartet, arbeitet oder fertig ist, über alle Hosts
  - Terminal jedes Panes live, mit Verlauf und Suche
  - Antworten mit einem Tipp, Prompts, Schnellantworten, Fotos und Dateien
  - Spaces, Tabs und Worktrees anlegen, umbenennen und schließen
  - Benachrichtigungen mit Antwort-Knöpfen, Bereitschaft im Hintergrund
  - Widget, Schnelleinstellungs-Kachel, Tastenkürzel auf dem Tablet

  Voraussetzung ist ein Rechner mit herdr und SSH-Zugang. Die App erzeugt
  pro Host einen eigenen Schlüssel, der das Gerät nicht verlässt. Es gibt
  kein Konto, keinen Server dazwischen und keine Werbung.

- **Category:** Tools. **Tags:** developer tools.
- **Contact:** e-mail of the developer account.
- **Screenshots:** phone (at least 2) and 7" and 10" tablet, from the
  emulator: sidebar, a space with a waiting agent, settings.

## Foreground service declaration (`specialUse`)

The Console asks why the app uses the type `specialUse` and shows a video
link field.

> The user turns on "Bereitschaft" (standby) in the settings or the Quick
> Settings tile. The service then keeps the SSH connections to the user's
> own herdr hosts open, so the app can notify when a coding agent waits for
> an answer or is done, and send the answer from the notification. The
> hosts are the user's own computers; there is no server of ours that could
> send pushes, so no other API (FCM, WorkManager) can deliver these events
> in time. The ongoing notification shows the connected hosts and has a
> "Beenden" button. Without standby the app uses no foreground service.

Video: screen recording of turning standby on, the ongoing notification, a
waiting agent's notification and answering it.

## Data safety

- **Data collected:** none. The app has no analytics, crash reporting or
  ads and talks to no server of the developer.
- **Data shared:** none.
- Terminal content, prompts and uploaded files go only between the device
  and the hosts the user adds, over SSH (encrypted in transit). Play counts
  transfers to a server the user chooses as not collected; answer
  accordingly, and "Data is encrypted in transit: yes" where asked.
- **Deletion:** everything stays on the device; uninstalling deletes it.
  Keys are excluded from backup (`data_extraction_rules.xml`).

## Content rating

Questionnaire category "Utility, productivity, communication or other".
No user-to-user content through the developer, no purchases, no
location. Expected rating: everyone / PEGI 3.

## Privacy policy (draft, German)

Needs a public URL, e.g. a page in this repository (once it is public)
or on staude.net.

> **Datenschutzerklärung Amiscara Agents (Android)**
>
> Amiscara Agents verbindet sich ausschließlich mit den Rechnern, die Sie in
> der App eintragen, per SSH. Der Entwickler betreibt keinen Server für die
> App und erhält keine Daten von ihr: keine Nutzungsstatistik, keine
> Absturzberichte, keine Werbung, kein Konto.
>
> Auf dem Gerät speichert die App die Host-Einträge, einen SSH-Schlüssel
> pro Host (verschlüsselt mit dem Android-Keystore) und Ihre Einstellungen.
> Diese Daten verlassen das Gerät nicht und sind von Sicherungen und der
> Geräteübertragung ausgenommen. Terminal-Inhalte, Prompts und Dateien, die
> Sie hochladen, gehen verschlüsselt nur an Ihre eigenen Hosts.
>
> Berechtigungen: Kamera nur zum Scannen eines QR-Codes, Geräte im lokalen
> Netzwerk für Hosts im Heim- oder VPN-Netz, Benachrichtigungen für
> wartende Agents. Mit dem Löschen der App sind alle Daten entfernt.
>
> Kontakt: Frank Neumann-Staude, [Adresse und E-Mail ergänzen]
