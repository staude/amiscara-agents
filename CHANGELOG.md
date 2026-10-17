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

### Fixed

- Windows build: the SSH agent connects through the OpenSSH named pipe (#3).
