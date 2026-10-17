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

### Fixed

- Windows build: the SSH agent connects through the OpenSSH named pipe (#3).
