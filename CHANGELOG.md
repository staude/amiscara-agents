# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `herdr-proto` with request, response and event types for herdr protocol 22.
- `herdr-transport` with local Unix socket and SSH streamlocal connections,
  host key checks against `known_hosts` and optional trust on first use.
- `Connection::open_channel` and `request_on` to open a request channel ahead of time.
- `herdr-spike` read-only probe with `ping`, `list`, `read`, `watch` and `bench`.
- Competitor research in `docs/marktbegleiter.md`.
- `herdr-core` with `SessionState` (built from `session.snapshot`, updated by
  events) and the agent board sorted blocked, working, done, idle (#1).
- `herdr-core::sync` driver: global and per-pane status subscriptions, debounced
  re-snapshot on structural events, reconnect with backoff, `watch` channel (#1).
- Typed `AgentStatus`, `WorkspaceInfo`, `TabInfo`, `PaneInfo`, `SessionSnapshot`
  and `Event` with `parse_event` in `herdr-proto` (#1).
- `Connection::subscribe_to` for subscriptions with parameters (#1).
- `herdr-spike board` prints the live board (#1).
- `herdr-core::terminal`: parses `pane.read` ANSI output (SGR only) into lines of
  styled spans with colors, attributes and display width (#2).
- `herdr-core::pane::follow` keeps an open pane current by polling `pane.read`,
  150 ms while it changes, up to 1 s while quiet (#2).
- `herdr-spike check` compares parsed screens with herdr's plain text,
  `herdr-spike view` follows one pane (#2).
- `herdr-ffi`: UniFFI bindings with `HostSession`, `SessionObserver`,
  `follow_pane`/`PaneObserver`, ed25519 key generation and the restricted
  `authorized_keys` line (#7).
- `scripts/build-ffi.sh` builds `HerdrFFI.xcframework` and the Swift bindings (#7).
- `herdr-transport`: in-memory keys (`Identity::Key`), pinned host keys and
  structured `UnknownHostKey`/`HostKeyChanged` errors with fingerprint (#7).
- `herdr-core::sync` stops on errors that need the user and shares the live
  connection through `SyncState::connection` (#7).
- Mac app `apps/HerdrRemote` (SwiftUI, macOS 27, xcodegen): hosts with a
  per-host ed25519 key in the Keychain and the `authorized_keys` line to copy,
  host key confirmation on first contact and a warning on change, sidebar
  with workspaces and panes, agent board across hosts, live pane screen.
  Read-only (#8).
- `scripts/ffi-smoke.sh`: headless check of the Swift bindings, optionally
  including the SSH host key flow (#8).
- `scripts/release.sh`: Developer ID archive, export, notarization, stapling
  and Gatekeeper checks, with precondition checks up front; `scripts/bump-build.sh`;
  setup steps in `docs/release.md` (#9).
- `herdr-core::actions`: `send_prompt` (`agent.prompt`), `send_keys`,
  `send_text` with `AgentBlocked` and `Rejected` errors (#14).
- `herdr-ffi`: `HostSession.sendPrompt`, `sendKeys`, `sendText` (#14).
- Mac app: per-host switch "Eingaben erlauben" (default on), input bar under
  the pane with one-tap answers while an agent is blocked (1, 2, 3, Enter,
  Esc), key bar and composer; prompts go to agents, text plus Enter to shells (#14).
- `scripts/ffi-smoke.sh` tests input against a named test session given in
  `HERDR_SMOKE_WRITE_SOCKET` and refuses the default socket (#14).
- iPad and iPhone app: target `HerdrRemote-iOS` (iOS 27) sharing the sources
  with the Mac app; board first on iPhone, scrollable key bar, answer row that
  wraps on narrow screens, SSH hosts only, reconnect on returning to the
  foreground (#16).
- `scripts/build-ffi.sh` builds macOS, iOS and iOS simulator slices into one
  XCFramework and only the slice the current Xcode platform needs (#16).
- App layout like herdr: two columns; the sidebar lists per host the spaces
  (linked worktrees indented under their repository, named after their
  directory) and the agents as "space · tab", waiting ones first; the detail
  shows herdr's tab bar, a pane picker for split tabs, terminal and input.
  The separate board column is gone (#24).
- `WorkspaceItem` carries repo key, worktree name and active tab (#24).
- `scripts/install-ios.sh`: builds the iOS app for the connected iPad or
  iPhone (or one given by name or UDID), installs and launches it (#26).
- Images in prompts: paperclip in the composer (Photos, on the Mac also files),
  HEIC and oversized images become JPEG up to 2560 px, upload to
  `~/.herdr-remote/uploads/` on the host, paths appended to the prompt (#28).
- Upload over SFTP on the same SSH session (`russh-sftp`), or a direct write
  for the local host; per-host switch "Bilder hochladen (SFTP)", default off,
  and the key line then uses `command="/usr/libexec/sftp-server"` (#28).
- Create spaces and tabs: "+" next to "spaces" (name and directory, `~`
  expanded by the app) and at the end of the tab bar; the app opens the new
  space or tab, herdr's own client keeps its focus (#30).
- A visible "…" menu next to each host name (edit, reconnect, remove); the
  long-press menu on the section header did not open on iPad (#30).
- Host editor: "Zeile kopieren" turns into a green "Kopiert" for two seconds,
  with haptic feedback on iOS (#33).
- Dictation: microphone at the left of the key bar; German speech recognition
  (on the device where possible) writes into the composer while speaking, a
  second tap or sending stops it; no keyboard needed. While the iPad screen
  is shared to a Mac, iPadOS gives apps only silence; the app notices after
  1.5 s and says so instead of recording nothing (#31). The message now names
  the cause: iPadOS mutes the microphone for all apps while the iPad is remote
  controlled from a Mac (#46).
- Notifications: "claude wartet" / "claude ist fertig" with host, space, tab
  and title when an agent starts waiting or finishes; tap opens the pane; no
  banner for the pane on screen; app badge counts waiting agents; per-host
  switch "Benachrichtigungen" (default on). On iOS only while the app runs (#40).
- `SessionState::attention_since` and `SessionUpdate.attention` report agents
  that newly need the user (#40).
- Spaces show herdr's extra rows: the git branch of the space's focused pane
  (from `worktree.list`, refreshed after each snapshot and every 30 s) and
  custom tokens from plugins or agents; a linked worktree is named after its
  branch like in herdr instead of its directory (#42).
- Agents list like herdr's default rows: "space · tab" (tab only when the space
  has several tabs), then just the agent; a switch next to "agents" sorts
  "grouped" (space order, herdr's default) or "nach Status" (waiting first),
  remembered per device (#44).
- "spaces" and "agents" fold per host; folded they show the count, agents
  also how many are waiting; remembered per device (#47).
- Quick replies above the key bar: saved prompts such as "weiter" or
  "/compact" sent with one tap (agents get a prompt, shells text plus Enter);
  added, edited, reordered and deleted in a sheet, stored per device (#54).
- Add a host by QR code: "QR-Code zeigen" in a host's menu shows host, port,
  user, socket and the trusted host key as a versioned
  `herdr-remote://add-host?v=1&...` link (for "Dieser Mac" with a host name
  you enter and the key from `/etc/ssh/ssh_host_ed25519_key.pub`). iPhone and
  iPad scan it in the host editor (or open or paste the link), which fills in
  the host and creates the device key; the host key is pinned only after the
  user confirms its fingerprint. Links are checked strictly in Rust and never
  replace a host key the app already trusts (#63).
- Quick switcher (⌘K, or the magnifier in the sidebar): searches spaces and
  agents on all hosts by name, branch, agent and title and jumps there.
  Keyboard shortcuts in the "Gehe zu" and "Tasten" menus: ⌘1 to ⌘9 for the
  spaces of the current host, ⇧⌘[ and ⇧⌘] for tabs, ⌘. Esc, ⌃C, ⇧⌘↩ Enter,
  ⌥⌘ arrows and ⌥⌘1 to ⌥⌘3 for the key bar (#60).
- Shortcuts and Siri: "Welche Agents warten?" answers from the live state of
  all hosts, "Agent öffnen" opens the app on a chosen agent; both read only
  (#64).
- Images can be pasted into the composer (⌘V, or "Aus Zwischenablage" under
  the paperclip) and are attached like picked photos; text paste is
  unchanged, and text wins when the clipboard holds both (#56).
- Split tabs side by side on the Mac and iPad (regular width): every pane in
  herdr's arrangement with its own live screen, font shrunk to fit its
  columns; tapping a pane selects it for the input bar. Only the selected pane
  is read at full pace, the others every 1 to 4 s. The iPhone keeps the pane
  picker. Core: `session.snapshot` layouts in `SessionState`, resizes from
  `layout_updated` applied in place, `pane::follow_paced` and
  `PaneFollow.set_live` (#61).
- Zoom the pane view: pinch, ⌘+ / ⌘- / ⌘0 (View menu, also on the iPad with
  a hardware keyboard) or the "Aa" menu in the pane header change the
  terminal font size (8 to 28 pt), one size for all panes, kept across
  launches (#65).
- Rename spaces, tabs and agents from the app (context menu or swipe on a
  space or agent row, context menu on a tab), only with input allowed.
  Agent names come from the snapshot's `agents` list; after `agent.rename`
  the sync driver takes a fresh snapshot (`SyncState::request_snapshot`) (#59).
- Mac menu bar item with the number of waiting agents over all hosts and a
  menu to jump to one; it opens the main window if it is closed. Hosts stay
  connected and notifications keep coming while the window is closed (#62).
- Start an agent in a new space or tab: "Agent starten" in the "Neuer Space"
  sheet (last choice remembered) and a menu next to the tab "+". The core
  calls `agent.start`, names the agent after its kind (`claude-2` when taken)
  and waits a few seconds for a pane that is still starting its shell (#57).
- "Neuer Worktree …" in the context menu of a Git space and in the ✨ menu
  next to the tab "+" (long presses are unreliable on iPad): branch, base and
  name (all optional), opened as a new space via `worktree.create`, optionally
  with an agent started in it (#58).
- Pane view scrolls back into history: scrolling to the top (or "Älteren
  Verlauf laden") loads 200, 500, then 1000 lines of scrollback, herdr's
  limit, and keeps them live; "Nur Bildschirm" goes back. In a split tab
  only the selected pane loads history. Core:
  `pane::follow_with_history`, FFI `PaneFollow.setHistoryLines` (#53).
- Search in the pane view: ⌘F (Edit menu, or the magnifier in the pane
  header) opens a search bar; matches in the shown lines, including loaded
  history, are highlighted (ignoring case and accents); Return or ⌘G jumps to
  the next, ⇧⌘G to the previous, Esc closes. In a split tab it searches the
  selected pane (#55).
- Space groups by name: `Privat/Dorfkino` shows as "Dorfkino" under a
  foldable group row "Privat" with its number of spaces and waiting agents;
  folding is kept per device. Split at the first `/`, trimmed; linked
  worktrees stay under their repository and never form a group. ⌘K, ⌘1-⌘9,
  agent rows, notifications, menu bar and Siri show the short name with the
  group. Core: `herdr_core::spaces` (parsing and sidebar order), FFI
  `SessionUpdate.spaceOrder`, `WorkspaceItem.name`/`group`,
  `BoardItem.workspaceName`/`workspaceGroup` (#80).
- Space groups by name can be switched off per host: "Spaces nach Namen
  gruppieren" in the host settings, on by default (also for saved hosts).
  Off, the host shows herdr's flat order and full names everywhere, linked
  worktrees still nested; the switch applies without reconnecting. Core:
  `spaces::arrange(_, by_name)`, FFI `HostSession.start(..., group_spaces_by_name)`
  and `set_group_spaces_by_name` (#86).
- Close tabs and spaces: "Tab schließen …" in the tab's context menu,
  "Space schließen …" in the space row's, both also in the ✨ menu next to
  the tab "+" (long presses are unreliable on iPad). Always confirmed, with
  a warning when an agent inside is working or waiting. A repository's
  space closes together with its linked worktree spaces, which herdr
  requires; the checkouts stay. After closing the shown tab, herdr's
  active tab is shown. Core: `actions::close_tab`, `close_workspace` (#93).
- App icon (#82): concept A "Stacked panes", three glass panes with `>_`
  and an amber dot, as an Icon Composer file (`AppIcon.icon`) for iPhone,
  iPad and Mac with light and dark colours; tinted and clear come from the
  system. Accent colour petrol `#0E7C74`, in dark mode `#2FD1A5`. Generated
  by `docs/icon/A/appicon.py`.
- Conversation history for Claude Code panes (#102): herdr keeps no
  scrollback for full-screen programs, so a button in the pane header opens
  the conversation from Claude Code's session file on the host (prompts,
  answers, tool calls; older parts on request). The file is found by the
  pane's directory and its title, read from the end in steps of about 30
  entries. Over SSH it needs SFTP like image uploads. Core:
  `herdr_core::claude`, transport `list_files` and `read_file_range`,
  `herdr-spike history <pane>`.
- Widgets for iPhone, iPad and Mac (#106): waiting agents as a number
  (small), the agents of all hosts, waiting first (medium, large), and on
  the iOS lock screen. A tap opens the pane (`amiscara-agents://open?...`).
  The app writes the board into an App Group (`Shared/WidgetSnapshot.swift`)
  when it changes and at least every five minutes; widgets hold no
  connection, so on iOS they show the state of the app's last run, with
  its age.
- Pushes to iPhone, iPad and Apple Watch (#94): the Mac app on the host
  sends "wartet" and "fertig" through APNs to the devices registered there,
  so they arrive while the iOS app sleeps. iPhones and iPads with file
  access for the host leave their push token in
  `~/.amiscara-agents/push/` over SFTP. "Wartet" notifications, local and
  pushed, have answer buttons (1, 2, 3, Enter, Esc) that also show on the
  Watch; a tap reconnects in the background and sends the key. The APNs key
  (.p8) is set in the host settings of "Dieser Mac" and stays in the
  Keychain. Transport `write_file` replaces a file on the host.
- Drop files and screenshots onto the input bar (#116), on the Mac and the
  iPad, with a highlight while dragging; the paperclip's file dialog takes
  any file as well. Images are prepared as before (`img-…`), other files go
  up unchanged under their own name (`file-<time>-<name>`, any extension,
  up to 20 MB). The text of a Finder text clipping goes into the prompt,
  as a .txt attachment when longer than 2000 characters. Errors say why a
  file was refused.
- Pushes go through the user's private iCloud database (#119) instead of
  an own APNs key: the Mac app on the host writes one CloudKit record per
  pane and state ("wartet", "fertig"), iPhones and iPads with the same
  Apple ID subscribe, and Apple sends the push with the answer buttons.
  Devices find the host by its SSH host key fingerprint. No key and no
  server; the .p8 settings and the device files in
  `~/.amiscara-agents/push/` are gone. Settings of "Dieser Mac" show the
  iCloud state and send a test push.
- Select and copy text across lines (#123): "Text auswählen" in the pane
  header (also in split tabs) and in the conversation view opens the
  content in the system text view, where a selection can span lines (drag,
  ⇧-click, ⌘A/⌘C on the Mac, handles on iPhone and iPad), with "Alles
  kopieren". Error lines and banners can be selected as well.
- Apple TV target (#126, part of #95): `AmiscaraAgents-tvOS` (tvOS 26)
  from the same sources, with tvOS slices of the Rust core in
  `HerdrFFI.xcframework`. Features tvOS lacks are left out there (camera,
  clipboard, files, the app's dictation, widgets, notifications, keyboard
  shortcuts, text selection); `InputBarTV.swift` offers answers, keys,
  quick replies and a prompt field. `scripts/install-ios.sh` installs on an
  Apple TV as well; CI checks herdr-ffi for iOS and tvOS.
- Apple TV pairing with the iPhone (#127): the TV makes its own SSH key and
  shows a QR code; scanned with the iPhone camera, the app adds a
  restricted line (herdr socket only, no shell, no files) to
  `~/.ssh/authorized_keys` on the chosen hosts over SFTP (backup
  `authorized_keys.bak-amiscara`) and leaves the host data for the TV in
  the private iCloud database. The Mac app publishes its Bonjour name
  (`work.local`) there under its host key, so the TV, which has no VPN on
  tvOS, connects through the home network.
- Apple TV layout (#128): tab bar with Agents (cards, waiting first),
  Spaces and Hosts (pairing, adding, state and connection errors); the
  Siri Remote scrolls a focused pane and loads older history at the top.
  A space opens in its own screen: tabs as segments with new tab, start
  agent and a "…" menu (rename and close tab or space), then pane picker,
  header, terminal and input as focus rows.
- Apple TV icon and Top Shelf images (part of #130): Icon Composer has no
  tvOS, so `docs/icon/A/tvicon.swift` draws concept A as a three-layer image
  stack (background, panes, `>_` with dot) and the Top Shelf images into the
  asset catalog.
- Apple TV input and management (#129): arrow keys left and right in the key
  bar, quick replies editable on the TV, "Neuer Space …" per host in the
  Spaces tab, and "Agent benennen …" and "Neuer Worktree …" in the space's
  "…" menu, next to renaming and closing tabs and spaces.
- Apple TV Top Shelf (#130): with the app in the top row, the full-screen
  shelf of tvOS 26 pages through the waiting, working and finished agents
  (state, space, agent, host; backdrops per state prepared by
  `docs/icon/A/tvicon.swift`); selecting one opens its pane in the Agents
  tab. The TV app writes the same snapshot
  as the widgets into an App Group and tells tvOS when it changed. Board
  cards read state, agent, space and tab to VoiceOver.
- Pushes through iCloud also for the Mac app's SSH hosts (#125): events of a
  connected SSH host go out under that host's key fingerprint, so one
  running Mac covers hosts without their own Mac app, such as a Linux
  server. Before writing, the Mac skips an event another Mac (or the host's
  own Mac app) wrote within the last minute with the same title and text,
  so no push comes twice. Switch "Auch für SSH-Hosts senden" in the push
  settings of "Dieser Mac", on by default.
- Desktop app for Windows and Linux, first step (#142): Tauri 2 with Svelte
  and TypeScript in `apps/desktop`, Rust crate `amiscara-desktop`. The window
  opens with an empty host list; CI builds and bundles it on Windows (NSIS,
  MSI) and Linux (deb, AppImage).
- Desktop app: hosts, keys and live sessions (#143). Hosts in `hosts.json`
  in the app data folder, private keys in the OS store (Credential Manager,
  Secret Service), never in the file. SSH with a key of its own (restricted
  `authorized_keys` line with copy button) or the SSH agent; on Linux also
  the local socket. Host key prompt with fingerprint, "add host" links pasted
  or opened (`amiscara-agents://`; an opened link pins no host key, the first
  connection asks for the fingerprint), sidebar with spaces and panes, live pane
  view with prompt input.
- Desktop app: main window like the Mac app (#144). Sidebar with spaces
  (name groups, worktrees indented, branch and token rows) and agents
  (grouped or by state), foldable; tabs, split tabs side by side, terminal
  with bottom anchor, history paging, search (Ctrl+F, F3) and zoom
  (Ctrl+plus/minus/0); input bar with answers for waiting agents, keys, quick
  replies (editable), attachments by drag and drop, paste or file dialog
  (#116 rules), Claude conversation history (#102). `npm run mock` shows the
  window in a browser with sample data.
- Desktop app: tray, notifications, management and shortcuts (#145). Tray
  icon with the number of waiting agents and a menu to open them; closing
  the window keeps the app and its sessions in the tray, optional start
  with the system. Notifications when an agent waits or finishes (Windows
  toasts, libnotify) open the pane, answer buttons send 1, 2, 3, Enter or
  Esc; none for the pane on screen, switchable per host. New space, tab
  (with agent) and worktree, rename, close with confirmation. Quick switcher
  (Ctrl+K), Ctrl+1 to 9 for spaces, Ctrl+Shift+[ ] and Ctrl+PageUp/Down for
  tabs, Ctrl+Alt+1 to 3 and arrows, Ctrl+. (Esc) and Ctrl+Shift+Enter for the
  pane. `amiscara-agents://open?host=…&pane=…` opens a pane.
- Desktop releases and updates (#146): tag `desktop-v<version>`
  (`scripts/desktop-release.sh`) builds Windows (NSIS, MSI) and Linux
  (AppImage, deb) installers and publishes them with a signed `latest.json`
  in the public repository `staude/amiscara-agents-releases`. The app looks
  for updates on start and in the settings, installs and restarts. Windows
  builds are not code signed yet.
- Tab in an empty input field goes to the pane, like the Tab key of the
  key bar (Claude Code takes its suggested prompt, a shell completes);
  Return in an empty field sends Enter to the pane. Mac, iPad and iPhone
  with a hardware keyboard, Windows and Linux.
- Host boards in iCloud (#156): the Mac app writes the agents of each host
  it pushes for as a `HostBoard` record (at most every 10 s, at least every
  5 minutes) and adds the last 12 screen lines to "wartet" records
  (`excerpt`, `HostSession.screenExcerpt`). iPhone, iPad and Apple TV take
  the agents of hosts they cannot reach from there, and the iPhone widget
  fetches the boards itself, woken by a silent push, so it stays current
  when the app does not run. Groundwork for the Apple Watch (#161).
- Apple Watch app (#157, watchOS 26): agents of all hosts, waiting first,
  and per waiting agent the screen excerpt from the Mac with the keys 1, 2,
  3, Enter and Esc. The Watch has no SSH (watchOS gives normal apps no
  sockets): the agents come from the iPhone over WatchConnectivity and from
  the Mac's boards in iCloud, answers go to the iPhone, which sends them
  over its own session and is launched in the background for that. The
  answer buttons of notifications on the Watch go the same way.
- Watch complications and Smart Stack (#158): circular with the number of
  waiting agents, rectangular with the first one ("Space · Tab", agent,
  host), inline and corner. They read the iPhone's snapshot the Watch app
  leaves in the App Group and fetch the Mac's boards from iCloud; a board
  push wakes the Watch app, which redraws them. A waiting agent raises the
  widget in the Smart Stack; a tap opens it in the Watch app.
- Prompts from the Watch (#159): in the detail of an agent that does not
  wait, the iPhone's quick replies (sent along in the application context)
  and a prompt to dictate or scribble; they go out through the iPhone as
  `agent.prompt`. Double tap sends the first answer key of a waiting agent.
- Command channel through iCloud (#160): when the iPhone is out of reach,
  the Watch leaves its answer key or prompt as an `AgentCommand` record;
  the Mac app runs it on the host and writes an `AgentCommandResult` back.
  Off by default ("Befehle von der Apple Watch annehmen" in the Mac's push
  settings); only the keys 1, 2, 3, Enter, Esc and prompts, keys only while
  the agent waits, the host's "Eingaben erlauben" applies, commands expire
  after 60 s and run once (the Mac that deletes the record runs it). The
  Mac app registers for remote notifications for this.
- Windows on ARM (ARM64): NSIS installer cross-compiled in CI and in
  desktop releases, with its own `windows-aarch64` entry for the updater.
  `gh workflow run ci.yml -f scope=installers` builds only the installers.
- Appearance setting "Wie das System" (default), "Hell" or "Dunkel":
  Mac settings window (⌘,), iPad and iPhone in the sidebar menu, Windows
  and Linux in the settings (⚙), including the window frame.
- Live mode for slash commands: a prompt to an agent that starts with `/`
  is typed straight into the agent's input line, so Claude Code shows its
  commands and skills in the pane; ↑↓ pick, Tab takes a suggestion (typing
  continues after it), Enter runs, Esc goes to the agent. All apps.
- Android app scaffold under `apps/android` (Kotlin, Jetpack Compose, minSdk
  29): Gradle builds `herdr-ffi` with `scripts/build-android-ffi.sh`
  (cargo-ndk, Kotlin bindings through UniFFI) and a first screen checks
  that the core loads; `scripts/install-android.sh`, `scripts/check.sh
  --android` and an Android job in the full CI chain (#173).
- Android: hosts with a key of their own (Android Keystore), the restricted
  `authorized_keys` line to copy or share, host key confirmation, live
  connection state with hints, editor, adding by QR code, pasted or opened
  link (an opened link's host key is not trusted), reconnect in the
  foreground, and the Android 17 local network permission (#174).
- `herdr-ffi` writes Rust panics to logcat on Android (#174).
- Android: main view with spaces and agents per host, side by side from
  700 dp, a space with tabs, split panes on wide screens, the terminal with
  pinch zoom, history and search, and the input bar with answers, key bar,
  quick replies, photo and file attachments and live mode (#175).
- Android: create, rename and close spaces, tabs and worktrees, start and
  name agents, the Claude Code conversation, quick switcher, settings for
  the terminal and the quick replies, and the keyboard shortcuts of the
  other apps (#176).
- Android: notifications when an agent waits or is done, with answer
  buttons that also work while the app is closed, and a standby
  (foreground service, Quick Settings tile, start on boot) that keeps the
  sessions open in the background (#177).
- Android: home screen widget with the waiting and working agents of all
  hosts, `scripts/android-upload-key.sh` and `scripts/android-release.sh`
  for signed App Bundles, and the Play Console texts in
  `docs/play-store.md` (#178).
- Web addresses in a pane's output are links in all apps (not on tvOS):
  found in the text by `herdr-core::terminal`, since herdr drops OSC 8
  targets; an address the terminal or an agent wrapped links all its parts
  to the whole address. The desktop app opens them through
  `tauri-plugin-opener` (#186).
- Experimental setting "Zeilen umbrechen" in all apps (not on tvOS): long
  lines wrap at the view width instead of scrolling sideways. The pane is
  followed with herdr's `recent_unwrapped` reads, which join the rows the
  terminal wrapped at the pane width; rows of box-drawing characters are
  clipped. herdr does not support this as such, and full-screen agents
  such as Claude Code wrap their own lines, so the setting says so (#191).
- Scrolling in full-screen agents such as Claude Code, which herdr keeps no
  scrollback for: page up and down through the agent's own view, back to the
  end, and its whole transcript as plain text through `agent.read` (needs an
  idle agent; narrows the request down, since herdr 0.9.5 falls back to the
  screen when the history is shorter than asked). Off by default, since both
  move the agent's view on the host too: setting "Vollbild-Agenten scrollen"
  in all apps (#187).
- Arrow keys in an empty composer go to the pane, to move through an
  agent's question or a shell's history without the key bar; with text
  they move the cursor as before.
- `apple-release.yml` builds the Apple apps in GitHub Actions on the
  `xcode-27` runner: the notarized Mac app as an artifact (attached to a
  release for `apple-v*` tags) and the iOS and tvOS apps for TestFlight,
  signed with an App Store Connect API key and optional `.p12`
  certificates from the environment `apple-release`.
  `scripts/apple-ci-secrets.sh` stores them, `scripts/testflight.sh`
  uploads to TestFlight locally too, and `scripts/release.sh` accepts the
  API key and a `BUILD_NUMBER` instead of the keychain profile.
- The Mac app looks for updates with Sparkle, like Kastellan and TorroMail:
  at start and every 24 hours, through "Nach Updates suchen …" in the app
  menu and in the settings, which can also turn the automatic search off.
  `scripts/sparkle-feed.sh` signs the zip with the Sparkle key and writes
  `appcast.xml` (after `scripts/release.sh`, in CI as a step of its own); a tag run of `apple-release.yml`
  publishes the release and replaces the feed in the release `updates`.

- Files for a public repository: `SECURITY.md` (private reports through
  GitHub security advisories), `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
  issue and pull request templates, and `docs/third-party-notices.md` on
  the licenses of the bundled dependencies.
- Reproducible screenshots of all apps (#199): `scripts/screenshots.sh`
  builds a demo with fictional projects in a herdr session of its own
  (`scripts/screenshots/`), starts the Mac app, the iPhone, iPad and Apple
  TV simulators, the Android emulator and the desktop app in a demo mode of
  their debug builds and saves the important views to `target/screenshots`.
  See `docs/screenshots.md`.
- Screenshots of all apps in the README, from the seeded demo, kept in
  `docs/screenshots` by `scripts/screenshots/publish.sh` (#199).
- Android in English (#207): English is the default language, German stays
  in `values-de`; texts built in code (errors, default quick replies) come
  from the resources too, and Android 13 and later offer the per-app
  language setting (`locales_config.xml`).
- English for the Apple apps (Mac, iPhone, iPad, Apple TV, Apple Watch,
  widgets, Top Shelf, Siri phrases and permission texts), with the String
  Catalog shared by all targets; the default quick replies follow the app
  language (#207).
- The desktop app (Windows, Linux) speaks German and English: the system
  language decides, English when it is neither, or the new setting
  "Sprache" / "Language". Tray menu, notifications and the default quick
  replies follow it; `SCREENSHOT_LANG=en` takes the desktop screenshots in
  English (#207).
- Named herdr sessions for hosts (#213): the host editor has a "Session"
  field that sets the socket path from the name, with the sessions of
  local hosts to pick from. "Add another session…" on a host lists its
  sessions (over SSH this needs SFTP) and creates an entry for the chosen
  one with its own key. The host list shows the session of an entry.
- iPhone Duo support (#215): the pane's buttons (conversation, select text,
  search, font size) move into the vertical bar at the side of the screen,
  the terminal no longer shows through it, and unfolded the sidebar ends
  at the fold. The composer keeps its text and images when the layout
  swaps the input bar. `scripts/screenshots.sh --platform duo` captures
  the outer display. The widget comes in the extra large sizes as well
  (two columns, or one tall column) for the inner display and the iPad.
- Swipe actions on agent rows (#230): swiping right confirms a waiting
  agent or sends the first quick reply, swiping left offers Esc, Control-C
  and rename. Only for hosts with input on.
- Prompt history per agent pane (#229): the clock button next to the
  composer lists the prompts sent from it to this agent, newest first and
  searchable; picking one puts it into the composer to edit and send
  again. Up to 50 per pane, on the device only and outside backups. Shell
  input and live slash commands are not kept.
- Handoff of the open space and pane between Mac, iPhone and iPad (#231):
  the other device offers it in the Dock or app switcher and opens the
  same pane. Hosts are matched by SSH host key, user and herdr session,
  so each device uses its own host entry; without one the app just opens.
- Optional app lock (#232): with "App sperren" on, the app asks for Face
  ID, Touch ID or the passcode when it starts and when it comes back after
  the chosen time (at once, 1 or 5 minutes). Until then the content is
  covered, on iOS also in the app switcher. Off by default; the settings
  are in the menu next to the hosts (iOS) and in the settings window (Mac).
- Siri and Shortcuts can send prompts (#226): "Prompt an Agent senden"
  asks for the agent and the text, "Prompt an letzten Agent senden" goes
  to the agent the last prompt went to, for the Action button. Same checks
  as the composer (input on, host reachable).
- Live Activity on the iPhone (#224): working and waiting agents show on
  the Lock Screen and in the Dynamic Island, up to three, waiting first,
  with the last line of the screen; a waiting agent has the answer buttons
  of its notification. Started while the app is in front, updated live
  and from the Mac's boards in iCloud in the background (iOS rations those
  pushes, so it can lag; an outdated one says so). "Live-Aktivität" in the menu next to the hosts turns it off.
- Git changes of a pane (#228): the ± button in the pane header (Mac,
  iPhone, iPad) shows what changed in the pane's working directory against
  `HEAD`, untracked files included, per file with colored hunks and a
  search. Read only: the host runs Git in a short-lived, unfocused tab of
  the space (`GIT_OPTIONAL_LOCKS=0`) and the app reads the result through
  the file access (needs input and "Bilder hochladen" on). Core:
  `Session::working_tree_diff`, `Connection::remove_file`, `herdr_core::diff`.
- Control Center controls on iPhone and iPad (#227): "Wartende Agents"
  shows how many agents wait and opens the first; "Diktat an letzten
  Agent" opens the agent the last prompt went to with dictation running.
  Both also work on the Lock Screen and the Action button. Links
  `amiscara-agents://open` without a pane now just open the app.
- Share extension on iPhone and iPad (#225): "Share → Amiscara Agents" in
  Safari, Photos, Mail and other apps takes text, a link or up to five
  images, lets you pick the agent and edit the prompt, and hands it to the
  app: a notification opens the agent with the composer filled (images
  attached), and the prompt is sent from there. The extension itself holds
  no SSH session. New App ID `net.staude.amiscara.agents.share` with the
  App Group.
- Pages agents open on the host (#247): `scripts/host/amiscara-open` stands
  in as `BROWSER` in herdr panes, opens the page on the host as before and
  reports it as pane metadata (`open_id`, `open_url_0` to `open_url_14`,
  two minutes). Mac (remote hosts), iPhone, iPad, Android and the desktop
  app offer it ("Agent möchte eine Seite öffnen"); opening it on one device
  takes it back on the host, so the others drop it. Pages on the host's
  `localhost` load through the SSH connection: a listener on the device's
  loopback, the same port where free, `direct-tcpip` or, for restricted
  keys, the new `amiscara-tcp` case of the key line, switched on per host
  with "Lokale Webseiten weiterleiten". Core: `PaneInfo::tokens`,
  `SessionState::open_requests`, `SessionUpdate::open_requests`,
  `Session::open_url`, `Session::dismiss_open_request`,
  `Connection::forward_tcp`, `authorized_keys_line(…, allow_web, …)`.
- Handoff from other AI tools (#236): text from Claude, ChatGPT or another
  tool goes to an agent as `handoff-<date>-<time>.md` in its composer, with
  a prompt that is kept for next time ("Lies die Übergabe in dieser Datei
  und setze sie um:" by default); the path follows the prompt when it is
  sent. Three ways in: the share extension, now also on the Mac (new
  target `AmiscaraAgentsShare`, it opens the app itself) and with the
  switch "Als Übergabe-Datei" for long text and Markdown files; "Übergabe
  aus Zwischenablage …" (⌥⌘V in "Gehe zu", a toolbar button on iPhone and
  iPad); and links `amiscara-agents://prompt?text=…&host=…&pane=…`. The
  clipboard and links open a sheet with the agents of the connected hosts
  and a preview. Template and details in `docs/ai-handoff.md`.
- File browser (#259): the folder button in the pane header (Mac, iPhone,
  iPad) opens the pane's working directory read only, directories first
  with size and date, a path bar up to `~`, hidden entries (dot files,
  `node_modules`, `target`) behind a switch. Text files open with search
  (the first MB), images up to 10 MB as images, other files show size and
  type. The home directory is the limit, checked on the real path. Needs
  the file access ("Bilder hochladen"), not input. Core:
  `Connection::list_dir`, `Connection::read_file_head`,
  `herdr_core::browse`, `Session::list_directory`,
  `Session::open_pane_directory`, `Session::file_preview`.
- Last tab per space (#263): a space opened from its row (sidebar, ⌘1 to ⌘9,
  quick switcher) comes back on the tab and pane shown last, also after a
  restart (Mac, iPhone, iPad, Windows, Linux). A tab closed on the host
  falls back to herdr's active tab; an agent row still opens its own tab.
- Files to the agent and editing (#271): in the file browser a file goes to
  the pane's composer with "An Agent senden" (context menu of a row, or the
  toolbar of an open file) as a chip with its host path, no upload; sending
  puts the path into the prompt. Text files up to 256 KB in UTF-8 without
  Windows line endings open with "Bearbeiten" in an editor without
  autocorrection and typographic quotes; "Sichern" (⌘S) writes the file in
  place and refuses when its size or modification time changed on the host
  since it was opened, offering to reload; saved but not read back, it
  loads the file again. Both need input allowed for the host besides the
  file access. Mac, iPhone and iPad. Core:
  `Connection::write_file`, `herdr_transport::CHANGED_ON_HOST`,
  `herdr_core::browse::save`, `browse::MAX_EDIT_BYTES`,
  `FilePreview::editable`, `Session::save_file`,
  `SessionError::FileChanged`, `browse::SAVED_NOT_READ`,
  `SessionError::SavedNotRead`.
- Agent choice questions as buttons (#272): when Claude Code asks for a
  permission or with AskUserQuestion, the pane shows one button per option
  with its text above the composer (Mac, iPhone, iPad); a tap sends the
  option's digit. Local notifications for a waiting agent offer the same
  options as actions (up to three, plus Abbrechen). Free text, several
  answers and pushes through iCloud keep the fixed answers. Core:
  `herdr_core::question`, `PaneContent.question`, `Session::choice_question`.
- Siri and Shortcuts: "Was macht der Agent?" (#275) answers for one agent
  with its status, how long it has been in it and the last three lines of
  its screen without input box and footer, also as text for further steps
  ("Was macht <Agent> in Amiscara Agents?"). The duration is the time the
  session saw the state begin (#274), else the Mac's. On the iPhone and iPad,
  hosts out of reach answer from the Mac's board, with screen lines only
  for waiting agents, and the agent picker of all agent intents also lists
  their agents. Siri also understands an agent by its space name.
- Folders in VS Code (#288): `scripts/host/code` stands in for `code` in
  herdr panes; `code <folder>` reports the folder as pane metadata
  (`editor_id`, `editor_path_0` to `editor_path_14`, 30 seconds) and returns
  at once. The Mac app (remote hosts) and the desktop app offer it ("Agent
  möchte einen Ordner in VS Code öffnen") and open
  `vscode://vscode-remote/ssh-remote+<target><path>`; opening marks it done
  (`editor_done`, needs input allowed), as does "Ignorieren"; otherwise the stand-in opens the
  real `code` on the host after 30 seconds, also at the host itself; a newer
  `code` in the same pane replaces the request. "In VS Code öffnen" in a space's context menu and in the
  pane header opens the pane's working directory the same way. New optional
  per-host "SSH-Ziel für VS Code", default `user@host`. Core:
  `SessionState::editor_requests`, `vscode_url`,
  `SessionUpdate::editor_requests`, `Session::dismiss_editor_request`,
  `pane_folder`, `space_folder`.
- Secrets (#291): "Geheimnisse …" in a host's menu (Mac, iPhone, iPad) sends
  environment variables such as tokens to `~/.amiscara-agents/env/<NAME>` on
  the host over SFTP (folder 0700, file 0600), never through a pane. Names
  are `[A-Z_][A-Z0-9_]*`; the value stays in this device's Keychain
  (`net.staude.amiscara.agents.secret`, not in iCloud) so it can be sent
  again, and "Entfernen" deletes it on the host and the device. Needs file
  access and input allowed. `scripts/host/amiscara-env <NAME>` prints a
  value for running agents, `--names` lists them for the shell line that
  exports all of them in herdr panes. Core: `Connection::write_private_file`,
  `list_files_if_present`, `herdr_session::secrets`, `Session::send_secret`,
  `remove_secret`, `secret_names`. Names the shells of herdr panes need
  (`PATH`, `HOME`, `SHELL`, `USER`, `LOGNAME`, `PWD`, `IFS`, `TERM`,
  `HERDR_*`, `LD_*`, `DYLD_*`) are refused in the core, the sheet (which says
  why) and `amiscara-env` (#293); a Keychain error after a successful send
  reads "Auf dem Host gespeichert, aber nicht im Schlüsselbund: …".
- Conversation search (#303): a search field in the host dashboard (Mac,
  iPhone, iPad) searches all Claude Code conversations of the host on
  Return, ignoring case, at least two characters. Hits are grouped by space
  (the pane's directory or the deepest one above it, else "Ohne Space" with
  the directory), then by session with its title, each with a snippet and
  date, newest first, at most 200 and 20 lines per session file. A tap
  opens the conversation at the hit, marked, with "Neuere Einträge laden"
  below. Index-free: a local host's files are read directly; over SSH with
  input allowed and a space open a script runs grep in a short-lived,
  unfocused tab (prompts, answers and shown tool fields only, files of the
  last 30 days first, no subagents, 300 lines in all), otherwise the app reads the files of the last 30 days,
  newest first, up to 300 MB, and says so. Progress with "Abbrechen"; a
  cancel closes the tab. Needs file access. Core: `Connection::is_local`,
  `claude::Query`, `hits_in_line`, `snippet`, `search_script`,
  `read_hit_line`, `read_forward`, `Session::search_conversations`,
  `claude_history_at`, `claude_history_after`, `TranscriptSpan`.
- Token usage (#302): the host dashboard (Mac, iPhone, iPad) shows "Heute:
  n Tokens, ~$x" for the host and under each Claude agent, read from Claude
  Code's session files in the working directories of the open Claude agents
  (subagents included, each message counted once per `message.id` and
  `requestId`). A tap opens the last 30 days per day, unfolding into model
  and folder. Costs are estimated in US dollars from an editable price table
  per model (Settings on the Mac, the sidebar menu on iPhone and iPad) with
  Anthropic's list prices as defaults; models without a price count as
  tokens only. "Tageskosten im Widget" (off by default) adds today's total
  per host to the medium widget's footer. Needs file access like uploads;
  each file is read once and afterwards only what was appended, kept in the
  cache directory between runs. Core: `herdr_core::usage`,
  `Session::usage`, `usage_state`, `restore_usage_state`;
  `herdr-spike usage <cwd> [--days N]` prints tokens per local day and model.
  `scripts/usage-sums-test.sh` checks the app's sums against the bindings.
- Approvals (#296): with a GitHub token per host (host settings, section
  "GitHub", fine-grained with Issues: Read; only in this device's Keychain,
  `net.staude.amiscara.agents.github-token`, not in iCloud) the overview and
  the host dashboard show "Freigaben": open issues with `awaiting-approval`
  in the GitHub repositories of the host's spaces, with the "Überblick für
  die Freigabe" of the latest enon-tools plan comment. When the issue's
  planning tab `plan-<nr>` waits with the question "Ja"/"Später", the app
  answers it there ("Freigeben", "Später", "Mit Hinweis freigeben", which
  adds a note to "Ja"); otherwise it shows `/issue-approve <nr>` to copy, or
  "Tab öffnen" while the tab asks something else. The app never sets a
  label itself. Needs file access to read the repositories' Git configs.
  Mac, iPhone, iPad. Core: `herdr_core::github` (`origin_repo`,
  `plan_overview`), `Session::github_repos`.
- Quick composer on the Mac (#307): ⌃⌥Space opens a floating window from
  any app, without bringing the app to the front, for a prompt to the last
  agent; the agent can be switched in the window, Enter sends, Esc closes,
  and the key bar's Esc and ⌃C go to the target pane. The shortcut can be
  changed or cleared under "Schnelleingabe" in the settings (Swift package
  KeyboardShortcuts). With the app lock on, the shortcut brings up the lock
  instead once the delay is over.
- Sorting spaces (#243, #245): per host as herdr has them, by name (A–Z,
  Z–A) or manually; manual starts from the order shown and changes by drag
  and drop in the sidebar, within a group and only on the same host. Stored
  per host on Mac, iPhone, iPad, Android, Windows and Linux; the running
  session rebuilds its order without reconnecting. Core:
  `herdr_core::spaces::SpaceSort`, `SessionUpdate::space_order`,
  `Session::set_space_sort`.
- The sort menu next to "Spaces" shows the current order as text ("wie
  herdr", "Name A–Z", "Name Z–A", "Manuell") instead of an icon (#254).
- Dragging a space shows a line where it will land; places the drop would
  refuse draw none (#255).
- Summary of new output (#273): a pane opened again after at least
  15 minutes whose screen has more than a changed bottom line offers
  "Zusammenfassen" above the terminal. The on-device model (Apple
  Intelligence) writes two sentences about what happened since the last
  visit, for Claude panes from the conversation when file access is on,
  otherwise from the new lines. Nothing leaves the device; the last visit
  per pane is kept for 7 days. Mac, iPhone and iPad. Core:
  `Session::recent_text`.
- Overview across all hosts (#274): the agents of all hosts grouped into
  waiting, working and done, newest first, with the time in that state;
  hosts without a connection show their last state or the Mac's board in
  iCloud with its age. First entry of the sidebar on Mac, iPad and iPhone,
  the start of the Apple TV. Core: agents report since when they are in
  their state.
- The last screen while offline (#276): each pane's last screen stays on
  the device (memory and cache directory, up to 500 rows per pane,
  40 panes, 7 days). While the host is not live the pane shows it dimmed
  under "Stand von …, Verbindung wird aufgebaut" (or "keine Verbindung"),
  and the app reopens the last space and pane on launch, also before the
  host is back. Mac, iPhone, iPad and Apple TV. Core: pane content to and
  from JSON.
- Answer keys from anywhere (#277): while the shown pane's agent waits for
  an answer, arrows, Enter and Esc go to its pane on the Mac regardless of
  focus; other text fields such as the pane search keep them, and the
  composer keeps arrows and Enter while it has text (Esc still cancels).
- Dashboard per host (#278): the host's name or "Dashboard" in the sidebar
  opens a page in the widget's look, the waiting count large, the working
  ones below and a row per agent that opens it; the badge counts the
  waiting ones. The last live agents stay while the host reconnects, also
  after "Neu verbinden", and without a connection the Mac's board in iCloud
  stands in. ⌘1 to ⌘9 follow the dashboard's host. Mac, iPhone and iPad.
- Spotlight (#308): spaces (name, host, branch) and agents (name, space,
  status) of every host are indexed, so typing a name in the system search
  finds it; a tapped result opens the app on that space or agent, even with
  the window closed. Written at most every 30 seconds; a host without a
  connection keeps its last entries until it is removed, a space closes or
  an agent finishes. "Spaces und Agents in Spotlight" in the Mac's settings
  window and the iPhone's "Erscheinungsbild" menu turns it off. Mac and
  iPhone/iPad; not tvOS or Watch.
- Host health on the dashboard (#306): a row of tiles under the counts with
  load (orange from one per core), memory, free disk (orange under 10 %
  free), uptime with the OS and the herdr version, read every 60 seconds
  while the dashboard is open. `scripts/host/amiscara-health` prints them as
  one JSON line (macOS and Linux); the key's line gets a fixed
  `amiscara-health` case that prints a marker and runs it from
  `~/.amiscara-agents/bin/`, "Dieser Mac" runs it directly. Without the
  script or with an older key line the dashboard says what to do instead.
  Mac, iPhone and iPad. Core: `Connection::health_line`,
  `herdr_session::health`, `Session::host_health`.
- Chains (#300): "Kette anlegen …" in an agent's context menu (Mac, iPhone,
  iPad) sends a saved prompt of up to 160 characters to an agent of the same
  host, itself included, when this one finishes or starts waiting; once or
  every time, but every time and on waiting only to another agent, and
  not every time both ways between two agents. A chain is kept on the
  host as metadata of its pane (up to 3 per agent), so every device shows it
  as "Kette: → <Ziel>" under the agent and it ends with the pane. It runs on
  a device that is connected with input allowed; with several, the first to
  claim the state change on the host sends, so the prompt goes out once. A
  target that is gone or refuses the prompt marks the chain failed ("Kette
  fehlgeschlagen") and it never runs again; a target waiting at a dialog or
  a dropped connection skips this run only. The host's dashboard lists the
  chains with delete and this device's log of the last 50 runs (gesendet,
  fehlgeschlagen, übersprungen). herdr 0.9.5 reports a turn interrupted with
  Esc as done too, so it fires a "fertig" chain. Core:
  `herdr_core::chains`, `BoardItem::chains`, `SessionUpdate::chain_results`,
  `Session::set_chain_runner`, `set_chain`, `remove_chain`; `AgentInfo` reads
  `state_change_seq` and `completion_seq`.
- Claude sessions of a folder (#304): "Claude-Sitzungen …" in a space's
  menu lists the Claude Code sessions of the shown pane's folder (from the
  sidebar: the space's), the 30 newest with
  title (from `/rename`, else Claude's own, else the first prompt), last
  activity and file size. "In neuer Pane fortsetzen" opens a tab in that
  folder and starts `claude --resume <id>` there, with the shell's current
  environment; "In dieser Pane fortsetzen" does it in the shown shell pane
  of the same folder. Needs file access like the conversation view; Mac,
  iPhone and iPad. Core: `claude::list_sessions`, `start_agent` takes agent
  arguments, `Session::claude_sessions`, `resume_claude`.

### Changed

- README and screenshots cover the features since 22 October; the
  screenshot run adds the overview, host dashboard, file browser and an
  offline pane for Mac, iPhone and iPad, from the new `-demoView` values
  `overview`, `dashboard`, `files` and `offline` (#290). The new
  `-demoHome` sets `HOME` at launch, because the simulators ignore
  `SIMCTL_CHILD_HOME`; the iPhone and iPad conversation and file browser
  shots read the demo home again instead of the app container.
- iPhone Duo: the dictation microphone sits in the vertical bar instead
  of the key row while the bar is shown (#222).
- The magnifier in a pane header and in the iPhone Duo's side bar closes
  the pane search again and shows as selected while it is open (#220).
- The core no longer words a refused "add host" link in German:
  `herdr-session` returns `LinkError` and `herdr-ffi` `AddHostLinkError`
  with the reason, and the apps put it in the user's language. The desktop
  app's own errors are codes the webview words as well (#207).
- Desktop releases go to this repository instead of
  `staude/amiscara-agents-releases`, written with the workflow's own token
  (no `RELEASES_TOKEN`); the updater reads `latest.json` from the release
  `updates`, which the release workflow replaces after publishing. Tags must
  point to a commit on `main`. The app now also looks every 24 hours and can
  stop looking automatically ("Automatisch nach Updates suchen").
- The workflows pin third-party actions to commit SHAs, which Dependabot
  keeps up to date, so a moved tag cannot reach the signing secrets.
- The terminal is no longer always dark: it follows the app's appearance
  or is set to light or dark on its own, with the color scheme Standard,
  Solarized or Terminal (macOS), on all apps (Mac settings, the appearance
  menu on iPad and iPhone, settings on Windows and Linux). "Mindestkontrast"
  (on by default) lightens or darkens text colors below WCAG AA contrast,
  so programs that pick colors for another background stay readable.
- CI no longer runs for pull requests, only for `desktop-v*` tags and by
  hand; `scripts/check.sh` runs the checks on the machine before a merge.
- CI checks pull requests on Linux only; the full chain (macOS, Windows,
  iOS and tvOS, desktop installers) runs for release tags and by hand, to
  save Actions minutes. Pushes to `main` no longer run CI.
- README covers all platforms: overview of Mac, iPad, iPhone, Apple TV,
  Windows and Linux with what each app does, notifications per platform and
  the release path of each.
- Renamed the app to Amiscara Agents (#84): `apps/AmiscaraAgents` with targets
  and schemes `AmiscaraAgents` and `AmiscaraAgents-iOS`, bundle ID
  `net.staude.amiscara.agents`, QR and link scheme `amiscara-agents://add-host`
  (the old `herdr-remote://` is no longer accepted), uploads in
  `~/.amiscara-agents/uploads/`, generated key comments `amiscara-agents <device>`.
  Hosts, keys and quick replies are stored under the new names; hosts have to be
  added again. The Rust crates keep their `herdr-*` names.
- New crate `herdr-session` with the live session (reconnects, updates for
  the view, pane followers, actions, uploads, Claude history, key lines),
  shared by `herdr-ffi` and the desktop app (#142). The Swift API is unchanged.
- The "add host" link moved to `herdr-session::link`; `herdr-session` sessions
  can log in through the SSH agent (`SshIdentity::Agent`) (#143).
- The README covers features per platform, the security model, host setup,
  limits, architecture and building from source in much more detail.
- CI runs the full chain for every pull request and push to `main`, now
  that the repository is public (Actions minutes are free); installers
  stay manual.
- Personal notes are no longer in the repository: `HANDOFF.md` and the
  personal parts of `CLAUDE.md` moved to untracked local files
  (`CLAUDE.local.md`), `setup.sh` no longer sets a git identity, and
  examples use neutral host names (`mac.example.internal`).
- The desktop crate and `package.json` declare the license
  (MIT OR Apache-2.0).
- TestFlight exports sign by hand with explicit App Store profiles
  (`ExportOptions-TestFlight-ios.plist`, `-tvos.plist`), which the App Store
  Connect API key in CI can see; `apple-ci-secrets.sh --appstore-profiles`.

### Fixed

- iPhone Duo: the composer's text field no longer sits under the keyboard.
  On the iPhone the "Tastatur ausblenden" button moved from the keyboard
  toolbar, whose height the keyboard avoidance did not count, into the
  composer row (#256).
- Panes no longer stay unreadable after the iPhone wakes up until the app
  restarts: a pane follower moves on to the session's new connection
  instead of hanging on the dead one, opening a channel over SSH gives up
  after 10 s and closes the dead link, iPhone, iPad, Apple TV and Android
  (without standby) reconnect remote hosts after at least 30 s in the
  background, and the Mac after waking from sleep (#258).
- Agents that finished or started waiting while the Mac slept or the
  phone sat in the background notify again after the reconnect, locally
  and through iCloud on the Watch and iPhone: the session now connects
  again at once and keeps what it knew instead of starting over (#264).
- Dictation no longer quits the app right after granting speech
  recognition access on first use; the access handler ran with main actor
  isolation on a background queue. The Watch app's replies to the iPhone
  had the same pattern (#218).
- Apple apps with "Zeilen umbrechen" on: a frame line of a wide pane (such
  as Claude Code's rules) no longer widens the terminal beyond the window,
  which squeezed the Mac sidebar to half its width and cut the wrapped
  lines off at the right; the history hints wrap as well (#191).
- The Mac release signs with an explicit Developer ID provisioning profile
  ("Amiscara Agents Developer ID", secret `APPLE_DEVID_PROFILE` in CI):
  an App Store Connect API key neither sees Xcode's own team profiles nor
  may use cloud-managed certificates, so the export failed in CI.
- The Linux desktop build in CI ran out of disk space while bundling the
  AppImage; the job (and the release workflow) now frees space first.
- Device keys reach only the herdr socket (#132): new `authorized_keys`
  lines (host editor, Apple TV pairing) use `restrict` without
  `port-forwarding` and a forced command that connects every session to
  `herdr.sock` with `nc -U` (SFTP only for keys with uploads on). A stolen
  key can no longer forward TCP through the host. The transport tries the
  streamlocal channel first and switches to a session running `herdr` when
  sshd refuses it, so old lines keep working; `authorizedKeysLine` takes the
  host's socket path.
- Apple TV: "Neuer Tab mit Agent" opens a dialog with the agent kinds
  instead of a menu that could be empty or unreachable with the remote.
- Uploaded file names keep only letters, digits, `.`, `_` and `-`, and in a
  shell pane the appended upload paths are single-quoted, so a crafted file
  name cannot add a shell command (follow-up to #116).
- QR scanner on iPhone and iPad no longer stays black: the app asks for
  camera access first and starts the scanner once it is on screen; if the
  camera cannot start, the reason is shown. While the iPad is remote
  controlled from a Mac, iPadOS still shows no camera picture.
- Windows build: the SSH agent connects through the OpenSSH named pipe (#3).
- Pane view no longer stays black after switching panes: a fresh scroll view
  per pane, a plain stack instead of a lazy one, and the view starts at the
  bottom like a terminal (#50).
- `scripts/install-ios.sh` regenerates the Xcode project first, so it builds
  after a branch switch with added or removed files (#38).
- Xcode builds: `build-ffi.sh` works with the bash 3.2 that Xcode runs, the
  framework is built by its own aggregate target `HerdrFFI` with declared
  outputs and only replaced when the libraries changed, and `xcodegen
  generate` builds it once when it is missing (#18).
- iPad and iPhone: "Host hinzufügen" in the sidebar, on the iPhone board and as a
  button when no host exists; the toolbar on the split view never showed (#20).
- Paperclip with upload off explains how to turn it on instead of doing
  nothing; the photo picker opens reliably on iOS; the host editor cannot be
  swiped away with unsaved changes (#35).
- Host status is a button on all platforms: it shows the state, the full error,
  a hint for common causes (VPN off, SSH off, socket missing, key not
  authorized) and "Jetzt verbinden"; tooltips never showed on iPad (#22).
- The QR code for "Dieser Mac" warns when the host name is a short name
  like "work": the Mac may resolve it through a search domain, iPhone and
  iPad often do not, so the scanned host could not connect.
- iOS keyboard: a tap on the key bar or a quick reply no longer brings the
  keyboard back, the composer only gets its focus back if it had it, and a
  button above the keyboard hides it (#97).
- Dictation keeps what was said before a pause: the recognizer starts its
  transcription over after each utterance, which replaced the beginning (#98).
- History for full-screen programs such as Claude Code: when herdr has no
  rows above the screen, the pane says so instead of seeming to load
  nothing (#101).
- The open pane no longer keeps loading after the host reconnects, e.g. when
  the app comes back to the foreground: it follows the pane again on the
  new session (#104). On the iPhone, opening a pane a second time no longer
  keeps loading either: the collapsed split view shows the earlier pane
  view again without a new appear, and that view had stopped following
  when it disappeared. Pane views now follow until they are released (#107).
- Reopening a pane over SSH no longer keeps loading: a pane follower is
  stopped between requests, since an SSH request dropped half way left
  the session unable to open new channels (#107).
- Mac: the terminal's dark background no longer shows through the glass
  sidebar; it stays inside the pane (#112).
