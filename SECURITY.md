# Security policy

Amiscara Agents holds SSH keys and opens sessions to your machines, so
security reports are welcome and handled first.

## Reporting a vulnerability

Please do **not** open a public issue. Report it privately through
GitHub's [security advisories](https://github.com/staude/amiscara-agents/security/advisories/new)
("Report a vulnerability" on the Security tab). Include what is affected
(app and platform, version or commit), how to reproduce it and what an
attacker gains.

You get an answer within a week. Fixes are released as soon as they are
ready and credited in the advisory unless you prefer otherwise.

## Scope

In scope:

- the apps (Mac, iPhone, iPad, Apple TV, Apple Watch, Android, Windows,
  Linux) and the Rust crates in this repository
- key handling: generation, storage in the platform key store, the QR and
  `amiscara-agents://` pairing links, the restricted `authorized_keys` line
  the apps suggest
- host key checks, the iCloud records the Apple apps exchange, the desktop
  updater

Out of scope: herdr itself (report to [herdr](https://herdr.dev)), OpenSSH,
and setups that deliberately widen the suggested key line (for example
allowing SFTP, which the README describes as full access to the account).

## Supported versions

Only the latest release of each app gets security fixes.
