# herdr-remote-core

A graphical remote for [herdr](https://herdr.dev), the agent multiplexer for the
terminal, on iPad, iPhone, Mac and Windows. This repository holds the Rust core
that talks to an unmodified herdr server, locally over its Unix socket or
remotely over SSH. Herdr Remote is a working title and an unofficial project,
not affiliated with herdr.

## How it connects

herdr exposes a newline-delimited JSON API on `~/.config/herdr/herdr.sock`.
Remotely, the core opens one SSH session and a `direct-streamlocal@openssh.com`
channel per request straight to that socket. Nothing is installed on the server.

A dedicated key can be locked down in `~/.ssh/authorized_keys` so that it can
open channels but never run a shell or command:

```
restrict,port-forwarding,command="/usr/bin/false" ssh-ed25519 AAAA... herdr-remote
```

`restrict,port-forwarding` alone still lets the key run commands.

`port-forwarding` also allows TCP forwarding through the server, so a stolen
device key could reach other machines from there. `permitopen` does not help:
sshd applies it to the streamlocal channel too and then refuses `herdr.sock`
(OpenSSH 10.3). If no other login needs it, `AllowTcpForwarding no` in
`sshd_config` closes TCP forwarding for everyone. Otherwise use one key per
device and remove a lost device's line right away.

## Layout

- `crates/herdr-proto`: request, response and event types, protocol version check
- `crates/herdr-transport`: local socket and SSH streamlocal transport, requests and event subscriptions
- `crates/herdr-core`: session state from snapshot and events, agent board, sync driver with reconnect, pane content as styled lines
- `crates/herdr-ffi`: UniFFI bindings for the apps (`scripts/build-ffi.sh` builds the XCFramework and Swift code)
- `crates/uniffi-bindgen`: the binding generator, kept out of the app library
- `crates/herdr-spike`: read-only command line probe (`ping`, `list`, `read`, `watch`, `board`, `check`, `view`, `bench`)
- `docs`: research and design notes

Planned: the apps under `apps/` (SwiftUI for Apple platforms, Tauri for Windows).

## Setup

Requires a stable Rust toolchain (edition 2024).

```sh
./setup.sh          # checks the toolchain, builds and tests
cargo run -p herdr-spike -- ping
cargo run -p herdr-spike -- --ssh user@host --identity ~/.ssh/key bench
```

The spike only calls read-only methods. Pass `--accept-new-host-key` once to
record an unknown host key.

## Verify

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

CI runs the same checks on Linux, macOS and Windows.

## Release

There are no releases yet. The apps will ship through their platform channels
once they exist.

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or
[MIT](LICENSE-MIT), at your option.
