# Amiscara Agents

A graphical remote for [herdr](https://herdr.dev), the agent multiplexer for the
terminal, on Mac, iPad, iPhone, Apple Watch, Apple TV, Windows and Linux. The apps talk to an
unmodified herdr server, locally over its Unix socket or remotely over SSH;
nothing is installed on the server. Amiscara Agents is an unofficial project,
not affiliated with herdr.

This repository holds the shared Rust core and both apps: a SwiftUI app for the
Apple platforms and a Tauri app for Windows and Linux. The Rust crates keep
their `herdr-*` names: they describe the herdr protocol, not the app.

## Platforms

| Platform | App | Minimum | Hosts | Notifications | Install |
|---|---|---|---|---|---|
| Mac | SwiftUI, `apps/AmiscaraAgents` | macOS 27 | this Mac (socket) and SSH | local, plus menu bar | Developer ID build, [Release](#release) |
| iPad, iPhone | SwiftUI, same sources | iOS 27 | SSH | push through iCloud from the Mac app | `scripts/install-ios.sh` |
| Apple TV | SwiftUI, same sources | tvOS 26 | SSH, home network only | none | `scripts/install-ios.sh` |
| Apple Watch | SwiftUI, `apps/AmiscaraAgents/Watch` | watchOS 26 | none: through the iPhone and iCloud | mirrored from the iPhone | with the iOS app |
| Windows | Tauri 2, `apps/desktop` | Windows 10, x64 or ARM64 | SSH | toasts, while in the tray | installer from the releases repo |
| Linux | Tauri 2, `apps/desktop` | WebKitGTK 4.1 | this machine (socket) and SSH | libnotify, while in the tray | AppImage or deb from the releases repo |
| Android | Kotlin, Compose, `apps/android` | Android 10 | SSH | with answer buttons, while the app or its standby service runs | `scripts/install-android.sh`, Google Play (testing) |

All apps share the same host model, the same restricted `authorized_keys` line
and the same `amiscara-agents://add-host?v=1&...` link (QR code on the Apple
devices), so a host is set up the same way everywhere.

## What the apps do

- Hosts, spaces (worktrees under their repository), tabs and the agents of
  all hosts, waiting agents first; `Bereich/Name` spaces grouped (see below).
- The live pane screen, split tabs side by side, search, scrollback up to
  1000 lines, font zoom; for Claude panes the conversation itself, read from
  `~/.claude/projects` on the host, and optionally paging through
  full-screen agents and fetching their transcript (#187); experimentally,
  long lines wrap at the window width instead of scrolling sideways (#191).
- Input under the pane: prompts to agents, text to shells, keys such as
  Enter, Esc or 1/2/3 to answer an agent waiting for approval, quick replies.
  Each host has a switch to keep it read-only. A prompt starting with `/`
  goes live into the agent's own input line, so Claude Code shows its
  commands and skills in the pane (↑↓ pick, Tab takes, Enter runs).
- New space, tab (with an agent) and worktree, rename, close.
- Files and images uploaded to `~/.amiscara-agents/uploads/` on the host,
  their paths appended to the prompt (needs SFTP, see below).
- Notifications when an agent waits or finishes, with answer buttons, and a
  quick switcher (⌘K or Ctrl+K).

The Apple Watch has no SSH (watchOS gives normal apps no sockets): it shows
the agents from the iPhone and from the boards the Mac app leaves in iCloud,
the screen excerpt of a waiting agent, answer keys that go out through the
iPhone, and complications with the number of waiting agents (also in the
Smart Stack).

Only on the Apple devices: widgets, Siri and Shortcuts, the Mac menu bar,
dictation, the camera for QR codes, push to iPhone and iPad. Only on the
desktop app: the tray and start with the system.

## How it connects

herdr exposes a newline-delimited JSON API on `~/.config/herdr/herdr.sock`.
Remotely, the core opens one SSH session and one channel per request to that
socket. Nothing is installed on the server.

A device key is locked down in `~/.ssh/authorized_keys` so that it reaches the
herdr socket and nothing else (#132):

```
restrict,command="case \"$SSH_ORIGINAL_COMMAND\" in *sftp*) exit 1 ;; *) exec nc -U \"$HOME/.config/herdr/herdr.sock\" ;; esac" ssh-ed25519 AAAA... amiscara-agents
```

`restrict` turns off all forwarding (TCP and Unix sockets), the PTY and agent
forwarding; the forced command connects every session to the herdr socket,
whatever the client asks to run. Every app shows this line for its key in the
host editor; it reaches herdr through a session running `herdr`. The desktop
app can log in through the SSH agent instead (Windows OpenSSH agent,
`SSH_AUTH_SOCK` on Linux); that key then needs such a line too.

Older lines used `restrict,port-forwarding,command="/usr/bin/false"` and a
`direct-streamlocal` channel. They keep working (the app tries streamlocal
first and switches to the session when sshd refuses it), but `port-forwarding`
also allows TCP forwarding through the host, so a stolen key could reach other
machines from there; `permitopen` cannot narrow it, it refuses streamlocal too
(OpenSSH 10.3). Replace such lines with the one the host editor shows now.
Other options that do not work: `permitlisten="none"` is not accepted in
`authorized_keys` (sshd rejects the whole line).

**Uploads:** files need the per-host switch "Bilder hochladen (SFTP)" (Apple)
or "Dateien hochladen (SFTP)" (desktop) and the key line with
`*sftp*) exec /usr/libexec/sftp-server ;;` instead of `*sftp*) exit 1 ;;`
(the host editor shows the right one). On Linux hosts the path of
`sftp-server` differs, e.g. `/usr/lib/openssh/sftp-server`. That key can then
read and write every file of the user, including `~/.ssh/authorized_keys`, so
it is effectively full access to that account. The Claude conversation is read
over SFTP as well.

## Organizing spaces: `Bereich/Name`

herdr has no folders above spaces. The apps group spaces by name instead:
everything before the first `/` is the group, the rest is the space's name.

```
Privat/Bürgertreff      → group "Privat":  Bürgertreff
Privat/Dorfkino         →                  Dorfkino
Arbeit/energieausweis   → group "Arbeit":  energieausweis
```

Each group is a foldable row with its number of spaces and waiting agents;
folding is remembered per device. Groups appear where their first space is
in herdr's order, spaces without `/` stay where they are. Spaces around the
`/` are ignored (`Privat / Dorfkino`), a name with an empty part (`/Dorfkino`,
`Privat/`) is not grouped. Linked worktrees stay under their repository, even
when their branch looks like `feature/x`. The name lives on the server, so all
devices show the same groups without any sync; herdr itself simply shows the
full name. Name a space this way when creating it or via "Umbenennen …". The
logic is in `crates/herdr-core/src/spaces.rs`.

The grouping is a per-host switch in the Apple apps: "Spaces nach Namen
gruppieren" in the host settings ("…" › "Bearbeiten …"), on by default.
Switched off, that host shows its spaces as herdr does, with full names in
herdr's order (linked worktrees still under their repository), in the sidebar,
⌘K, ⌘1-⌘9, agent rows, notifications, menu bar and Siri. The change applies
at once. The desktop app reads the same setting (`groupSpaces` in
`hosts.json`) but has no switch for it yet.

## Layout

- `crates/herdr-proto`: request, response and event types, protocol version check
- `crates/herdr-transport`: local socket and SSH streamlocal transport, requests and event subscriptions
- `crates/herdr-core`: session state from snapshot and events, agent board, sync driver with reconnect, pane content as styled lines
- `crates/herdr-session`: the live session for the apps (connect and reconnect, view records, pane followers, actions, uploads, Claude history, add-host links)
- `crates/herdr-ffi`: UniFFI bindings for the Swift and Android apps (`scripts/build-ffi.sh` builds the XCFramework and Swift code, `scripts/build-android-ffi.sh` the `.so` files and Kotlin code)
- `crates/uniffi-bindgen`: the binding generator, kept out of the app library
- `crates/herdr-spike`: read-only command line probe (`ping`, `list`, `read`, `watch`, `board`, `check`, `view`, `bench`)
- `apps/AmiscaraAgents`: SwiftUI app for Mac, iPad, iPhone and Apple TV, project generated by xcodegen
- `apps/desktop`: Tauri 2 app for Windows and Linux (Svelte, TypeScript, crate `amiscara-desktop`)
- `apps/android`: Android app (Kotlin, Jetpack Compose, Gradle)
- `docs`: research and design notes, icon sources, release setup

Session logic belongs in `herdr-session`; `herdr-ffi` and the desktop crate
are thin layers over it.

## Setup

Requires a stable Rust toolchain (edition 2024).

```sh
./setup.sh          # checks the toolchain, builds and tests
cargo run -p herdr-spike -- ping
cargo run -p herdr-spike -- --ssh user@host --identity ~/.ssh/key bench
```

The spike only calls read-only methods. Pass `--accept-new-host-key` once to
record an unknown host key.

On Linux the workspace includes the desktop crate, which needs WebKitGTK
(packages in [apps/desktop/README.md](apps/desktop/README.md#setup)); without
it, build the core with `--exclude amiscara-desktop`.

## Mac, iPad and iPhone

```sh
./setup.sh    # also builds herdr-ffi and runs xcodegen on macOS
xcodebuild -project apps/AmiscaraAgents/AmiscaraAgents.xcodeproj -scheme AmiscaraAgents \
    -derivedDataPath target/xcode build
open target/xcode/Build/Products/Debug/AmiscaraAgents.app
```

iPad and iPhone (scheme `AmiscaraAgents-iOS`, same sources). Build, install and
launch on a connected device with developer mode on:

```sh
scripts/install-ios.sh                # the only connected iPhone, iPad or Apple TV
scripts/install-ios.sh "iPad (2)"     # by name or UDID when several are connected
scripts/install-ios.sh --release      # Release build; --no-launch installs only
```

On iOS there is no local socket; hosts are SSH only. The app reconnects as
soon as it returns to the foreground. `scripts/build-ffi.sh` builds the slice
the current Xcode platform needs and keeps the others in the framework.
Platform differences are collected in `Platform.swift`.

`scripts/ffi-smoke.sh` exercises the Swift bindings without the UI against
the local server; with `HERDR_SMOKE_SSH=user@host HERDR_SMOKE_KEY=<key>` it
also runs the SSH and host key flow.

**Notifications:** the Mac app shows local notifications and writes one entry
per pane and state to the private iCloud database
(`iCloud.net.staude.amiscara.agents`); iPhone and iPad subscribe to it, so
Apple delivers a push with answer buttons even while the app is closed. The
devices find the host by the fingerprint of its SSH host key. Without a
running Mac app, iPhone and iPad notify only while the app runs.

### Apple TV

Scheme `AmiscaraAgents-tvOS` (tvOS 26, same sources), installed with
`scripts/install-ios.sh` like the other devices; the Apple TV must be paired
with Xcode once (Window → Devices and Simulators). On the TV a tab bar holds
**Agents** (all agents as cards, waiting first), **Spaces** and **Hosts**;
swipes on the Siri Remote scroll a focused pane, the back button returns.
Camera, clipboard, files, the app's own dictation, widgets, notifications and
keyboard shortcuts do not exist on tvOS and are left out there. With the app
in the top row of the home screen, the **Top Shelf** shows the agents of all
hosts (waiting first); selecting one opens its pane. The app updates them
while it runs, like the widgets on iPhone and Mac. The layered icon and the
Top Shelf images come from `docs/icon/A/tvicon.swift` (Icon Composer has no
tvOS).

**Pairing:** under Hosts → „Mit iPhone koppeln“ the TV shows a QR code with
its own public key. Scanning it with the iPhone camera opens the app there;
it adds a restricted line (herdr socket only, no forwarding, no shell, no
files; see "How it connects") to `~/.ssh/authorized_keys` on the
chosen hosts over SFTP, keeping the old file as `authorized_keys.bak-amiscara`,
and leaves the host data for the TV in the private iCloud database. The TV's
private key never leaves it. iPhone and TV need the same Apple ID.

**Network:** the Apple TV reaches a host **only directly in the home network**
(plain IP or Bonjour name). There is no NetBird (or other VPN client) for
tvOS, so addresses that only work through the VPN, such as
`work.staude.internal` or `100.x` Tailnet IPs, do not work on the TV. The Mac
app on a host therefore publishes its Bonjour name (`<LocalHostName>.local`)
in iCloud under its SSH host key, and the TV connects through it; the pinned
host key is still checked. For hosts without a running Mac app (e.g. a Linux
server) set an address the TV can reach by hand in the host settings on the
TV.

## Windows and Linux

```sh
cd apps/desktop
npm install
npx tauri dev       # window with hot reload (also works on the Mac)
npm run check       # svelte-check, TypeScript
npm run mock        # the window with sample data in a browser, no herdr needed
```

Hosts live in `hosts.json` in the app data folder, private keys in the OS key
store (Windows Credential Manager, Secret Service on Linux). Closing the window
keeps the app in the tray with its sessions, so notifications keep coming;
there is no push as on the Apple devices, the app has to run. Keyboard
shortcuts use Ctrl where the Mac uses ⌘. Setup, shortcuts, links and the
release process: [apps/desktop/README.md](apps/desktop/README.md).

## Android

```sh
./setup.sh                      # also the Rust targets and cargo-ndk when an Android SDK is there
scripts/install-android.sh      # builds, installs and launches on a phone or emulator
```

Needs Android Studio (SDK, JDK) and the NDK the app names in
`apps/android/app/build.gradle.kts`. Gradle builds the Rust core itself
before compiling. Details: [apps/android/README.md](apps/android/README.md).
Plan and phases: #179.

Release to Google Play: `scripts/android-upload-key.sh` once, then
`scripts/android-release.sh <version>` per upload (signed App Bundle, higher
`versionCode`, tag `android-v<version>`). Console texts, data safety and
the steps: [docs/play-store.md](docs/play-store.md).

## Testing input

Test input only against a separate session, never the one with real work:

```sh
herdr --session herdr-remote-test server &
HERDR_SMOKE_WRITE_SOCKET=~/.config/herdr/sessions/herdr-remote-test/herdr.sock \
    scripts/ffi-smoke.sh
herdr session stop herdr-remote-test
```

## Verify

```sh
scripts/check.sh            # fmt, clippy, tests, npm run check
scripts/check.sh --apple    # also builds the Mac and iOS schemes
scripts/check.sh --android  # also builds the Android app with lint
```

Pull requests are checked this way on the machine, before merging. GitHub
Actions run only for `desktop-v*` tags and when started by hand (`gh
workflow run ci.yml`), to save Actions minutes: tests on Linux, macOS and
Windows, the core for iOS and tvOS, the Android app, the desktop app on all three systems,
and by hand also the installers as artifacts. Start it by hand before a
release or after platform-specific changes.

## Release

- **Mac:** ships outside the App Store, signed with Developer ID and
  notarized: `scripts/bump-build.sh`, commit, `scripts/release.sh`. One-time
  setup (certificate, notarytool profile) in [docs/release.md](docs/release.md).
- **iPad, iPhone, Apple TV:** installed from Xcode with
  `scripts/install-ios.sh` for now; TestFlight is planned.
- **Windows and Linux:** released by tag (`scripts/desktop-release.sh`) to the
  public repository
  [staude/amiscara-agents-releases](https://github.com/staude/amiscara-agents-releases),
  from which the app updates itself; see
  [apps/desktop/README.md](apps/desktop/README.md#deploy). Windows builds are
  not code signed yet.

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or
[MIT](LICENSE-MIT), at your option.
