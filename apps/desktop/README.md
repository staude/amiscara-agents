# Amiscara Agents for Windows and Linux

Tauri 2 app with a Svelte and TypeScript frontend. The Rust side
(`src-tauri`, crate `amiscara-desktop`) uses `herdr-session`, the same core
the Swift apps reach through `herdr-ffi`. Plan and phases: #141.

## Setup

Needs Node 22 or newer and the Rust toolchain of the workspace. On Linux
also WebKitGTK and friends:

```sh
sudo apt-get install libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf
```

On Windows, WebView2 ships with Windows 10 and 11.

```sh
cd apps/desktop
npm install
npx tauri dev       # window with hot reload
npm run check       # svelte-check, TypeScript
npx tauri build     # bundles under target/release/bundle
```

The Mac has the SwiftUI app; `npx tauri dev` works there for development.

`npm run mock` serves the window to a normal browser (http://localhost:1420)
with sample hosts, spaces and panes instead of the Rust side
(`src/dev/mock.ts`), for layout work without a herdr server. The mock is
not part of the build.

## Hosts and keys

- Hosts: `hosts.json` in the app data folder (`%APPDATA%\net.staude.amiscara.agents`
  on Windows, `~/.local/share/net.staude.amiscara.agents` on Linux), same
  fields as `HostConfig` of the Apple apps.
- Private keys: OS store under the service `net.staude.amiscara.agents.ssh-key`,
  one entry per host id (Windows Credential Manager, Secret Service on Linux).
- Login per host: a key of its own (the window shows the restricted
  `authorized_keys` line) or the SSH agent. On Linux a host can also be the
  local herdr socket.
- `amiscara-agents://add-host?...` links: pasted with the link button in the
  sidebar, or opened from elsewhere (the installers register the scheme, a
  dev build registers it on start).

## Tray and notifications

Closing the window keeps the app in the tray (Windows notification area,
Linux status icon) with its sessions, so notifications keep coming; "Beenden"
in the tray menu quits. "Mit dem System starten" in the settings (⚙) starts
it in the tray without a window (`--hidden`). There is no push as on the
Apple devices: the app has to run.

Toasts on Windows need the Start menu entry the installer creates; a dev
build shows them under PowerShell's name. On Linux a notification server
with actions (GNOME, KDE, most others) shows the answer buttons.

## Keyboard

| Keys | Action |
|---|---|
| Ctrl+K | Quick switcher for spaces and agents |
| Ctrl+1 … 9 | Space by position on the current host |
| Ctrl+Shift+[ / ], Ctrl+PageUp/Down | Previous / next tab |
| Ctrl+F, F3, Shift+F3 | Search in the pane |
| Ctrl+plus / minus / 0 | Terminal font size |
| Ctrl+Alt+1 … 3 | Answer a waiting agent |
| Ctrl+Alt+arrows, Ctrl+., Ctrl+Shift+Enter | Arrow keys, Esc, Enter to the pane |

Ctrl+Alt shortcuts are ignored for keys typed with AltGr.

## Links

- `amiscara-agents://add-host?v=1&...`: add a host (see `herdr_session::link`).
- `amiscara-agents://open?host=<host id>&workspace=<id>&pane=<id>`: open a pane.

## Icon

`icon.svg` is the dark variant of the app icon (`docs/icon/A`) without
glass. `npm run icons` renders it (needs `rsvg-convert`) and writes
`src-tauri/icons`, including the tray icons (`icon-waiting.svg` adds the
amber badge).

## Deploy

Test installers without a release: start CI by hand (Actions > CI > Run
workflow, or `gh workflow run ci.yml`); the "Desktop app" jobs then leave
them as artifacts. With `gh workflow run ci.yml -f scope=installers` only
the installers are built (Windows x64 and ARM64, Linux), without the tests
on macOS and Windows. Pull requests run the full chain without the
installers; check them first with `scripts/check.sh`.
Releases go to the public repository
[staude/amiscara-agents-releases](https://github.com/staude/amiscara-agents-releases),
because this one is private and the updater must read `latest.json` without
a token:

```sh
scripts/desktop-release.sh 0.2.0      # version in package.json and Cargo.toml, commit, tag
git push && git push origin desktop-v0.2.0
```

The workflow `.github/workflows/desktop-release.yml` checks that tag and
version match, drafts the release, builds Windows x64 (NSIS, MSI), Windows ARM64 (NSIS only,
cross-compiled) and Linux
(AppImage, deb) with `tauri-action`, signs the update files and publishes.

Secrets of the GitHub environment `desktop-release`, which only tags
`desktop-v*` may use (normal CI builds get no key and make no update files):

- `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: the
  updater key, created with `npx tauri signer generate`; the private key is
  kept by the maintainer outside the repository. Back it up: without
  it, installed apps accept no further update. Its public half is
  `plugins.updater.pubkey` in `tauri.conf.json`.
- `RELEASES_TOKEN`: a fine-grained personal access token with
  "Contents: Read and write" on `amiscara-agents-releases` only.

The app checks `latest.json` on start and offers the update; on Windows
the installer runs passively and restarts the app. The AppImage updates
itself, a `.deb` does not (install the new one by hand).

Windows builds are not code signed yet (decision of 2026-10-18): SmartScreen
asks once per version. A certificate later goes in as
`bundle.windows.signCommand`; the place is marked in the release workflow.
