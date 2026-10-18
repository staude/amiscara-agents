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

### Fixed

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
